// Ported from Bilibili 线程撕裂者 (https://github.com/MrTangLuyao/Bilibili-thread-ripper,
// MIT), src/range-core.js, plus the small runtime pieces (cancellation, clock) that the
// browser gives the original for free.

import 'dart:async';
import 'dart:typed_data';

/// Monotonic milliseconds, the counterpart of `performance.now()`.
final Stopwatch _clock = Stopwatch()..start();
double nowMs() => _clock.elapsedMicroseconds / 1000.0;

/// A cancelled request (the original's AbortError). Never counts against a node.
class RipperAbort implements Exception {
  const RipperAbort([this.message = '播放器任务已取消']);
  final String message;
  @override
  String toString() => 'RipperAbort: $message';
}

/// A request that took too long (the original's TimeoutError).
class RipperTimeout implements Exception {
  const RipperTimeout(this.message);
  final String message;
  @override
  String toString() => 'RipperTimeout: $message';
}

/// A reply that was not the verified 206 asked for. [status] tells a refused signed
/// address (4xx) apart from a node that is down.
class RipperHttpError implements Exception {
  const RipperHttpError(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => 'RipperHttpError($status): $message';
}

bool isAbort(Object? error) => error is RipperAbort;

/// The counterpart of AbortController/AbortSignal: cancel once, listeners run once.
/// A child token is cancelled together with its parent.
class CancelToken {
  CancelToken([CancelToken? parent]) {
    if (parent != null) {
      if (parent.isCancelled) {
        cancel(parent.reason);
      } else {
        final remove = parent.onCancel(() => cancel(parent.reason));
        _detachParent = remove;
      }
    }
  }

  bool _cancelled = false;
  Object? _reason;
  final List<void Function()> _listeners = [];
  void Function()? _detachParent;
  Completer<void>? _completer;

  bool get isCancelled => _cancelled;
  Object get reason => _reason ?? const RipperAbort();

  /// Completes when cancelled.
  Future<void> get whenCancelled {
    if (_cancelled) return Future.value();
    return (_completer ??= Completer<void>()).future;
  }

  /// Registers [listener]; returns a function that removes it again.
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      scheduleMicrotask(listener);
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void cancel([Object? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason ?? const RipperAbort();
    _detachParent?.call();
    _detachParent = null;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener();
      } catch (_) {}
    }
    _completer?.complete();
  }

  /// Throws the reason when cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw reason;
  }

  /// Drops the link to the parent so a long-lived parent does not pile up listeners.
  void dispose() {
    _detachParent?.call();
    _detachParent = null;
  }
}

/// `Promise.any`: the first future to succeed wins; when all fail, the last error.
Future<T> firstSuccess<T>(List<Future<T>> futures) {
  final completer = Completer<T>();
  var pending = futures.length;
  Object? lastError;
  StackTrace? lastStack;
  if (pending == 0) {
    return Future.error(StateError('没有可用 CDN'));
  }
  for (final future in futures) {
    future.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        lastError = error;
        lastStack = stack;
        pending -= 1;
        if (pending == 0 && !completer.isCompleted) {
          completer.completeError(lastError!, lastStack);
        }
      },
    );
  }
  return completer.future;
}

/// Waits [ms], or throws the reason once [token] is cancelled.
Future<void> pause(double ms, CancelToken? token) {
  token?.throwIfCancelled();
  final completer = Completer<void>();
  void Function()? remove;
  final timer = Timer(Duration(microseconds: (ms * 1000).round()), () {
    remove?.call();
    if (!completer.isCompleted) completer.complete();
  });
  remove = token?.onCancel(() {
    timer.cancel();
    if (!completer.isCompleted) completer.completeError(token.reason);
  });
  return completer.future;
}

class ByteRange {
  const ByteRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
  @override
  String toString() => '$start-$end';
}

class Piece extends ByteRange {
  const Piece(this.index, int start, int end) : super(start, end);
  final int index;
}

class ContentRange {
  const ContentRange(this.start, this.end, this.total);
  final int start;
  final int end;
  final int? total;
  int get length => end - start + 1;
}

final RegExp _contentRangeRe = RegExp(
  r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
  caseSensitive: false,
);

ContentRange? parseContentRange(String? value) {
  if (value == null) return null;
  final match = _contentRangeRe.firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match[1]!);
  final end = int.tryParse(match[2]!);
  final total = match[3] == '*' ? null : int.tryParse(match[3]!);
  if (start == null || end == null || end < start) return null;
  if (match[3] != '*' && (total == null || total <= end)) return null;
  return ContentRange(start, end, total);
}

final RegExp _rangeHeaderRe = RegExp(
  r'^bytes=(\d+)-(\d*)$',
  caseSensitive: false,
);

/// `bytes=a-b` or the open `bytes=a-` that mpv asks for. Null when absent or malformed.
({int start, int? end})? parseRangeHeader(String? value) {
  if (value == null) return null;
  final match = _rangeHeaderRe.firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match[1]!);
  if (start == null) return null;
  final endText = match[2]!;
  if (endText.isEmpty) return (start: start, end: null);
  final end = int.tryParse(endText);
  if (end == null || end < start) return null;
  return (start: start, end: end);
}

List<Piece> splitRange(
  int start,
  int end,
  int concurrency, [
  int minChunkBytes = 128 * 1024,
]) {
  final length = end - start + 1;
  final limit = concurrency.clamp(1, 512);
  final minimum = minChunkBytes < 32 * 1024 ? 32 * 1024 : minChunkBytes;
  final count = (length / minimum).ceil().clamp(1, limit);
  final base = length ~/ count;
  final remainder = length % count;
  final pieces = <Piece>[];
  var cursor = start;
  for (var index = 0; index < count; index += 1) {
    final size = base + (index < remainder ? 1 : 0);
    pieces.add(Piece(index, cursor, cursor + size - 1));
    cursor += size;
  }
  return pieces;
}

Uint8List concatChunks(List<Uint8List> chunks, int expectedLength) {
  final output = Uint8List(expectedLength);
  var offset = 0;
  for (final bytes in chunks) {
    if (offset + bytes.length > expectedLength) {
      throw RangeError('子区间超出目标长度');
    }
    output.setRange(offset, offset + bytes.length, bytes);
    offset += bytes.length;
  }
  if (offset != expectedLength) {
    throw RangeError('子区间长度不符：$offset/$expectedLength');
  }
  return output;
}

final RegExp _mediaSuffixRe = RegExp(
  r'\.(?:m4s|mp4|flv)$',
  caseSensitive: false,
);
final RegExp mediaHostRe = RegExp(
  r'(?:^|\.)(?:bilivideo\.(?:com|cn|net)|akamaized\.net|szbdyd\.com|hdslb\.com|xycdn\.com|mountaintoys\.cn|nexusedgeio\.com|ahdohpiechei\.com)$',
  caseSensitive: false,
);

bool isBilibiliMediaUrl(String value) {
  final url = Uri.tryParse(value);
  if (url == null) return false;
  return url.scheme == 'https' &&
      _mediaSuffixRe.hasMatch(url.path) &&
      mediaHostRe.hasMatch(url.host);
}

final RegExp _hostShapeRe = RegExp(
  r'^[a-z\d](?:[a-z\d-]*[a-z\d])?(?:\.[a-z\d](?:[a-z\d-]*[a-z\d])?)+$',
);

/// A server added by hand in the custom CDN mode. Only its host name is kept, and only for
/// the Bilibili video servers [isBilibiliMediaUrl] accepts: the signed download addresses
/// must never be sent to anyone else.
String normalizeCdnHost(String? value) {
  final text = (value ?? '').trim().toLowerCase();
  if (text.isEmpty || text.length > 253) return '';
  final uri = Uri.tryParse(
    RegExp(r'^[a-z][a-z\d+.-]*://').hasMatch(text) ? text : 'https://$text',
  );
  final host = uri?.host ?? '';
  return _hostShapeRe.hasMatch(host) && mediaHostRe.hasMatch(host) ? host : '';
}

enum RipperCdnMode {
  mainland('大陆 CDN'),
  overseas('海外 CDN'),
  custom('自定义');

  const RipperCdnMode(this.desc);
  final String desc;
}

const List<int> ripperConcurrencyChoices = [4, 8, 16, 32, 64, 128];

/// The downloader's settings, normalized like the original's normalizeSettings.
class RipperSettings {
  RipperSettings({
    int concurrency = 8,
    this.autoConcurrency = true,
    this.mode = RipperCdnMode.mainland,
    List<String> customHosts = const [],
  }) : concurrency = ripperConcurrencyChoices.contains(concurrency)
           ? concurrency
           : 8,
       customHosts = customHosts
           .map(normalizeCdnHost)
           .where((e) => e.isNotEmpty)
           .toSet()
           .take(32)
           .toList(growable: false);

  final int concurrency;
  final bool autoConcurrency;
  final RipperCdnMode mode;
  final List<String> customHosts;

  final int minChunkBytes = 64 * 1024;
  final int firstByteTimeoutMs = 5500;
  final int stallTimeoutMs = 4000;
  final int attemptTimeoutMs = 15000;
  final int hedgeDelayMs = 900;

  RipperSettings withConcurrency(int threads) => _Override(this, threads);
}

class _Override extends RipperSettings {
  _Override(RipperSettings base, this._threads)
    : super(
        concurrency: base.concurrency,
        autoConcurrency: base.autoConcurrency,
        mode: base.mode,
        customHosts: base.customHosts,
      );
  final int _threads;
  @override
  int get concurrency => _threads;
}
