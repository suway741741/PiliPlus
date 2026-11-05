// The part of 线程撕裂者 that the browser does not need: mpv plays from a local HTTP
// server, and every byte range mpv asks for is fetched by [RipperDownloader] over many
// connections and CDN nodes, then streamed back in order.
//
// mpv (ffmpeg's http protocol) asks for `bytes=N-` and reads on for as long as its demuxer
// cache has room. The stream is cut into windows of a few seconds of media; a few windows
// download ahead of what mpv has read, each one split into pieces over the nodes. The first
// window of a request is a start (head raced on every node), the ones after it follow on.
// Finished windows are kept for a while, so a reconnect or a seek back is served at once.

import 'dart:async';
import 'dart:collection';
import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/downloader.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/transport.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

const int _kib = 1024;
const int _mib = 1024 * 1024;

/// Where playback stands, for the deadlines of the pieces on their way. Fed by the player.
class PlaybackClock {
  /// Seconds of media mpv has buffered ahead of the playhead.
  double aheadSeconds = 0;

  /// Playing or waiting to play: the buffer ahead runs down.
  bool active = false;
  double rate = 1;
  double _updatedAt = 0;

  void update({required double ahead, required bool active, double? rate}) {
    aheadSeconds = ahead < 0 ? 0 : ahead;
    this.active = active;
    if (rate != null && rate > 0) this.rate = rate;
    _updatedAt = nowMs();
  }

  /// The buffer ahead now, counting down since the last report while playing.
  double get aheadNow {
    if (!active) return aheadSeconds;
    final passed = (nowMs() - _updatedAt) / 1000 * rate;
    final ahead = aheadSeconds - passed;
    return ahead < 0 ? 0 : ahead;
  }
}

class _CacheEntry {
  _CacheEntry(this.start, this.chunks, this.length);
  final int start;
  final List<Uint8List> chunks;
  final int length;
  int get end => start + length - 1;

  /// The bytes from [from] to the end of this entry.
  Iterable<Uint8List> from(int from) sync* {
    var offset = start;
    for (final chunk in chunks) {
      final chunkEnd = offset + chunk.length;
      if (chunkEnd > from) {
        yield from > offset
            ? Uint8List.sublistView(chunk, from - offset)
            : chunk;
      }
      offset = chunkEnd;
    }
  }
}

/// Finished windows of one track, the oldest dropped first once over [capacity].
class _WindowCache {
  _WindowCache(this.capacity);
  final int capacity;
  final LinkedHashMap<int, _CacheEntry> _entries = LinkedHashMap();
  int _bytes = 0;

  void add(_CacheEntry entry) {
    if (entry.length <= 0 || entry.length > capacity) return;
    final old = _entries.remove(entry.start);
    if (old != null) _bytes -= old.length;
    _entries[entry.start] = entry;
    _bytes += entry.length;
    while (_bytes > capacity && _entries.isNotEmpty) {
      final first = _entries.keys.first;
      _bytes -= _entries.remove(first)!.length;
    }
  }

  /// The entry holding [offset], marked as recently used.
  _CacheEntry? at(int offset) {
    for (final entry in _entries.values) {
      if (entry.start <= offset && offset <= entry.end) {
        _entries.remove(entry.start);
        _entries[entry.start] = entry;
        return entry;
      }
    }
    return null;
  }

  /// The first cached byte after [offset], to stop a download window before it.
  int? nextStartAfter(int offset) {
    int? best;
    for (final entry in _entries.values) {
      if (entry.start > offset && (best == null || entry.start < best)) {
        best = entry.start;
      }
    }
    return best;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

class RipperTrack {
  RipperTrack._({
    required this.id,
    required this.kind,
    required this.session,
    required this.resolver,
    required this.mimeType,
    required this.bytesPerSecond,
  }) : _cache = _WindowCache(kind == 'audio' ? 12 * _mib : 48 * _mib);

  final String id;

  /// video / audio
  final String kind;
  final RipperSession session;
  final CdnResolver resolver;
  final String mimeType;

  /// From the DASH bandwidth; 0 when unknown.
  final double bytesPerSecond;
  final _WindowCache _cache;
  final Set<_StreamJob> _jobs = {};
  int? total;

  /// Where the last window delivered in order ended: a request from there is no start.
  int warmEnd = -1;

  /// Accelerated windows that failed and were served directly instead.
  int fallbacks = 0;
}

/// The tracks of one opened video (one quality, both tracks). Closing it stops their
/// downloads.
class RipperSession {
  RipperSession._(this._proxy) : bans = BanList();

  final RangeProxy _proxy;
  final BanList bans;
  final CancelToken token = CancelToken();
  final List<RipperTrack> tracks = [];
  bool get isClosed => token.isCancelled;

  /// Registers one track; returns the local address mpv plays it from, or null when no
  /// address of it can be accelerated.
  String? register(
    List<String> urls, {
    required String kind,
    int? bandwidth,
    String? mimeType,
  }) {
    if (isClosed) return null;
    final resolver = CdnResolver(urls, () => _proxy.settings, bans);
    if (resolver.urls().isEmpty) return null;
    final track = RipperTrack._(
      id: '${_proxy._nextId++}',
      kind: kind,
      session: this,
      resolver: resolver,
      mimeType: mimeType ?? (kind == 'audio' ? 'audio/mp4' : 'video/mp4'),
      bytesPerSecond: (bandwidth ?? 0) > 0 ? bandwidth! / 8 : 0,
    );
    tracks.add(track);
    _proxy._tracks[track.id] = track;
    return _proxy.urlOf(track);
  }

  void close() {
    if (isClosed) return;
    token.cancel(const RipperAbort('播放任务已结束'));
    for (final track in tracks) {
      _proxy._tracks.remove(track.id);
      track._cache.clear();
    }
    _proxy._sessions.remove(this);
  }
}

class RangeProxy {
  RangeProxy({
    required RipperTransport transport,
    required RipperSettings Function() settings,
    PlaybackClock? clock,
  }) : _settings = settings,
       clock = clock ?? PlaybackClock() {
    downloader = RipperDownloader(transport: transport, getSettings: settings);
  }

  final RipperSettings Function() _settings;
  RipperSettings get settings => _settings();
  final PlaybackClock clock;
  late final RipperDownloader downloader;
  HttpServer? _server;
  Future<void>? _starting;
  int? _port;
  final String _secret = List.generate(
    16,
    (_) => math.Random.secure().nextInt(16).toRadixString(16),
  ).join();
  final Map<String, RipperTrack> _tracks = {};
  final Set<RipperSession> _sessions = {};
  int _nextId = 1;

  /// The session that last had a byte delivered, for the status page.
  RipperSession? lastActive;

  int? get port => _port;

  String urlOf(RipperTrack track) =>
      'http://127.0.0.1:$_port/$_secret/${track.id}.m4s';

  Future<void> ensureStarted() {
    if (_server != null) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    HttpServer server;
    try {
      // The same port as before if possible: mpv may still hold addresses on it.
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        _port ?? 0,
        shared: false,
      );
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    server
      ..idleTimeout = const Duration(seconds: 30)
      ..autoCompress = false;
    _server = server;
    _port = server.port;
    server.listen(
      (request) {
        _handle(request).catchError((Object error) {
          if (kDebugMode) debugPrint('thread ripper: $error');
        });
      },
      onError: (Object error) {
        if (kDebugMode) debugPrint('thread ripper server: $error');
      },
      onDone: () {
        // iOS can take the listening socket away from a suspended app; the next session
        // binds it again.
        if (identical(_server, server)) _server = null;
      },
    );
  }

  /// After the app comes back from the background: iOS may have taken the listening
  /// socket away from the suspended app. Binds it again, on the same port, so the
  /// addresses mpv holds keep working.
  Future<void> heal() async {
    final server = _server;
    final port = _port;
    if (server == null || port == null) {
      if (_sessions.isNotEmpty) await ensureStarted();
      return;
    }
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
    } catch (_) {
      if (!identical(_server, server)) return;
      _server = null;
      try {
        await server.close(force: true);
      } catch (_) {}
      await ensureStarted();
    }
  }

  RipperSession openSession() {
    final session = RipperSession._(this);
    _sessions.add(session);
    return session;
  }

  Future<void> close() async {
    for (final session in List.of(_sessions)) {
      session.close();
    }
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    if (segments.length != 2 || segments.first != _secret) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final id = segments[1].replaceFirst(RegExp(r'\.m4s$'), '');
    final track = _tracks[id];
    if (track == null || track.session.isClosed) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final head = request.method == 'HEAD';
    if (!head && request.method != 'GET') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final range = parseRangeHeader(rangeHeader);
    if (rangeHeader != null && range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await response.close();
      return;
    }
    final job = _StreamJob(
      this,
      track,
      response,
      start: range?.start ?? 0,
      end: range?.end,
      partial: range != null,
      headOnly: head,
    );
    track._jobs.add(job);
    try {
      await job.run();
    } finally {
      track._jobs.remove(job);
      job.dispose();
    }
  }
}

class _Window {
  _Window(this.start, this.end, {this.cached}) {
    // Nobody may wait for the head of a window that fails; its error is not uncaught.
    headKnown.future.ignore();
  }
  final int start;

  /// Planned end; the first window of a track learns the real one from its head.
  int end;
  final _CacheEntry? cached;
  final StreamController<Uint8List> chunks = StreamController();
  final Completer<void> headKnown = Completer();
  int received = 0;
}

class _StreamJob {
  _StreamJob(
    this.proxy,
    this.track,
    this.response, {
    required this.start,
    required this.end,
    required this.partial,
    required this.headOnly,
  }) : token = CancelToken(track.session.token),
       cursor = start,
       _planned = start {
    // A closed session must not leave a write waiting.
    token.onCancel(() {
      if (!_goneSignal.isCompleted) _goneSignal.complete();
    });
  }

  final RangeProxy proxy;
  final RipperTrack track;
  final HttpResponse response;
  final int start;
  final int? end;
  final bool partial;
  final bool headOnly;
  final CancelToken token;

  /// The next byte mpv gets.
  int cursor;

  /// The last byte this request wants; known once the track's length is.
  int last = 1 << 62;

  /// Where the next window starts.
  int _planned;

  /// The first download of a request is a start, unless it carries on exactly where the
  /// last delivered window of this track ended.
  late bool _startupPending = start != track.warmEnd;
  final Queue<_Window> _windows = Queue();

  void dispose() => token.dispose();

  /// How much one window holds: a few seconds of media, a little less at a start.
  int _windowBytes(bool startup) {
    final bps = track.bytesPerSecond;
    if (bps <= 0) return startup ? _mib : 2 * _mib;
    final seconds = startup ? 2.5 : 4.0;
    final min = track.kind == 'audio' ? 256 * _kib : 512 * _kib;
    final bytes = (bps * seconds).clamp(min, 8.0 * _mib).round();
    return (bytes + 64 * _kib - 1) ~/ (64 * _kib) * (64 * _kib);
  }

  /// Windows downloading or done ahead of the one being written. None until mpv has
  /// read a little: ffmpeg opens a file by reading its first bytes, then its last ones,
  /// and only then reads on from just behind the header, each time on a new connection.
  int get _ahead => cursor - start >= 512 * _kib ? 1 : 0;

  /// When playback needs [offset]: the buffer ahead, plus the media between what mpv has
  /// and that byte.
  DeadlineFn? _deadlineFor(int offset) {
    final bps = track.bytesPerSecond;
    if (bps <= 0) return null;
    final clock = proxy.clock;
    // Paused, the same estimate at normal speed: nothing is due soon, so a piece that is
    // on its way gets no second copy, but one that stopped still does.
    return () {
      final seconds = clock.aheadNow + math.max(0, offset - cursor) / bps;
      return nowMs() + seconds * 1000 / (clock.active ? clock.rate : 1);
    };
  }

  Socket? _socket;
  bool _gone = false;
  final Completer<void> _goneSignal = Completer();

  void _onGone() {
    if (_gone) return;
    _gone = true;
    if (!_goneSignal.isCompleted) _goneSignal.complete();
    // mpv went away (a seek, a new video): stop the downloads at once.
    token.cancel(const RipperAbort('播放器断开连接'));
  }

  static const Map<int, String> _reasons = {
    200: 'OK',
    206: 'Partial Content',
    416: 'Range Not Satisfiable',
  };

  void _writeHead(int status, Map<String, String> headers) {
    final text = StringBuffer('HTTP/1.1 $status ${_reasons[status] ?? ''}\r\n');
    headers.forEach((name, value) => text.write('$name: $value\r\n'));
    text.write('Connection: close\r\n\r\n');
    _socket!.add(latin1.encode(text.toString()));
  }

  Future<void> run() async {
    // The connection is taken over from the HTTP server: dart:io does not notice there
    // that the client hung up (a pending flush just never completes), the socket does.
    final socket = _socket = await response.detachSocket(writeHeaders: false)
      ..listen(
        (_) {},
        onDone: _onGone,
        onError: (_) => _onGone(),
        cancelOnError: true,
      );
    var direct = false;
    var ok = false;
    try {
      if (_startupPending && track.kind == 'video' && !headOnly) {
        proxy.downloader.auto.newSession();
      }
      if (track.total == null) {
        try {
          if (headOnly) {
            await _probeTotal();
          } else {
            // The first window learns the length from its head.
            _plan();
            await _windows.first.headKnown.future;
          }
        } catch (error) {
          if (isAbort(error) || token.isCancelled) rethrow;
          // No node gave the head: ask the addresses Bilibili handed out directly.
          _dropWindows();
          await _totalDirect();
          direct = true;
        }
      }
      final total = track.total!;
      if (start >= total) {
        _writeHead(HttpStatus.requestedRangeNotSatisfiable, {
          'Content-Range': 'bytes */$total',
          'Content-Length': '0',
        });
        ok = true;
        return;
      }
      last = math.min(end ?? total - 1, total - 1);
      for (final window in _windows) {
        if (window.end > last) window.end = last;
      }
      _writeHead(partial ? HttpStatus.partialContent : HttpStatus.ok, {
        'Content-Type': track.mimeType,
        'Content-Length': '${last - start + 1}',
        'Accept-Ranges': 'bytes',
        if (partial) 'Content-Range': 'bytes $start-$last/$total',
      });
      if (!headOnly) {
        if (direct) {
          track.fallbacks += 1;
          await _passthrough(last);
        } else {
          await _pump();
        }
      }
      ok = true;
    } catch (error) {
      token.cancel();
      if (kDebugMode && !isAbort(error)) {
        debugPrint('thread ripper ${track.kind}: $error');
      }
    } finally {
      _dropWindows();
      if (ok && !_gone) {
        // Everything is written: close our side, mpv has read up to Content-Length.
        try {
          await socket.flush();
          await socket.close().timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
      // Otherwise the connection is just dropped; mpv reconnects or reports it.
      socket.destroy();
      if (!_goneSignal.isCompleted) _goneSignal.complete();
    }
  }

  void _dropWindows() {
    for (final window in _windows) {
      if (!window.chunks.isClosed) unawaited(window.chunks.close());
    }
    _windows.clear();
  }

  Future<void> _probeTotal() async {
    const probe = ByteRange(0, 64 * _kib - 1);
    final chunks = <Uint8List>[];
    await proxy.downloader.downloadRange(
      probe,
      track.resolver,
      signal: token,
      kind: track.kind,
      allowShort: true,
      onOrderedChunk: (bytes, start, total) {
        track.total ??= total;
        chunks.add(bytes);
      },
    );
    final length = chunks.fold<int>(0, (sum, e) => sum + e.length);
    track._cache.add(_CacheEntry(0, chunks, length));
  }

  /// The length of the file from one byte of it, asked of the original addresses.
  Future<void> _totalDirect() async {
    Object? lastError;
    for (final url in _directUrls()) {
      final attempt = CancelToken(token);
      final timer = Timer(
        const Duration(seconds: 10),
        () => attempt.cancel(const RipperTimeout('CDN 首字节超时')),
      );
      try {
        final reply = await proxy.downloader.transport.open(
          url,
          start,
          start,
          attempt,
        );
        reply.abort();
        final range = parseContentRange(reply.contentRange);
        if (reply.status == 206 && range?.total != null) {
          track.total ??= range!.total;
          return;
        }
        lastError = RipperHttpError('HTTP ${reply.status}', reply.status);
      } catch (error) {
        if (token.isCancelled) throw token.reason;
        lastError = error;
      } finally {
        timer.cancel();
        attempt.dispose();
      }
    }
    throw lastError ?? const RipperHttpError('没有可用 CDN');
  }

  List<String> _directUrls() => {
    ...track.resolver.originals.map(safeMediaUrl).nonNulls,
    ...track.resolver.urls(),
  }.toList();

  /// Adds the next window to the queue: from the cache when it holds that byte,
  /// otherwise a download that stops where the cache picks up again.
  void _plan() {
    final from = _planned;
    final total = track.total;
    if (total != null && from > last) return;
    final hit = track._cache.at(from);
    if (hit != null) {
      final to = math.min(hit.end, last);
      final window = _Window(from, to, cached: hit);
      _windows.add(window);
      _planned = to + 1;
      var room = to - from + 1;
      for (final chunk in hit.from(from)) {
        if (room <= 0) break;
        final piece = chunk.length > room
            ? Uint8List.sublistView(chunk, 0, room)
            : chunk;
        window.chunks.add(piece);
        room -= piece.length;
      }
      window.chunks.close();
      window.headKnown.complete();
      return;
    }
    final startup = _startupPending;
    _startupPending = false;
    var to = from + _windowBytes(startup) - 1;
    if (total != null) {
      to = math.min(to, last);
      final next = track._cache.nextStartAfter(from);
      if (next != null) to = math.min(to, next - 1);
    }
    final window = _Window(from, to);
    _windows.add(window);
    _planned = to + 1;
    _download(window, startup: startup);
  }

  void _download(_Window window, {required bool startup}) {
    final kept = <Uint8List>[];
    // Only the very first window of a track does not know where the file ends.
    final lengthUnknown = track.total == null;
    proxy.downloader
        .downloadRange(
          ByteRange(window.start, window.end),
          track.resolver,
          signal: token,
          kind: track.kind,
          startup: startup,
          allowShort: lengthUnknown,
          deadline: _deadlineFor(window.start),
          onOrderedChunk: (bytes, start, total) {
            if (start != window.start + window.received) {
              throw const RipperHttpError('媒体 Range 校验失败');
            }
            if (total != null) {
              if (track.total != null && track.total != total) {
                throw const RipperHttpError('媒体总长度不一致');
              }
              track.total ??= total;
            }
            if (!window.headKnown.isCompleted) {
              // The real end, once the head has told the length of the file.
              if (lengthUnknown && track.total != null) {
                if (window.end > track.total! - 1) {
                  window.end = track.total! - 1;
                }
                _planned = window.end + 1;
              }
              window.headKnown.complete();
            }
            window.received += bytes.length;
            kept.add(bytes);
            if (!window.chunks.isClosed) window.chunks.add(bytes);
          },
        )
        .then((_) {
          final length = window.received;
          if (length != window.end - window.start + 1) {
            throw const RipperHttpError('媒体 Range 长度不符');
          }
          track._cache.add(_CacheEntry(window.start, kept, length));
          proxy.lastActive = track.session;
          if (!window.chunks.isClosed) window.chunks.close();
        })
        .catchError((Object error) {
          // What arrived in order was checked against its Content-Range: keep it for the
          // request that comes next (ffmpeg reconnects a few bytes further on).
          if (window.received > 0) {
            track._cache.add(_CacheEntry(window.start, kept, window.received));
          }
          if (!window.headKnown.isCompleted) {
            window.headKnown.completeError(error);
          }
          if (!window.chunks.isClosed) {
            window.chunks
              ..addError(error)
              ..close();
          }
        });
  }

  /// Hands bytes to mpv. A failed write means mpv went away (a seek, a new video).
  Future<void> _write(Uint8List bytes) async {
    token.throwIfCancelled();
    try {
      _socket!.add(bytes);
      await Future.any([_socket!.flush(), _goneSignal.future]);
    } catch (_) {
      _onGone();
    }
    if (_gone) throw const RipperAbort('播放器断开连接');
    token.throwIfCancelled();
    cursor += bytes.length;
  }

  Future<void> _pump() async {
    while (cursor <= last) {
      token.throwIfCancelled();
      while (_windows.length < 1 + _ahead && _planned <= last) {
        _plan();
      }
      if (_windows.isEmpty) break;
      final window = _windows.first;
      try {
        await for (final bytes in window.chunks.stream) {
          await _write(bytes);
          if (_windows.length < 1 + _ahead && _planned <= last) _plan();
        }
        _windows.removeFirst();
        if (window.cached == null) track.warmEnd = cursor;
        if (cursor != window.end + 1) {
          throw const RipperHttpError('媒体 Range 长度不符');
        }
      } catch (error) {
        if (isAbort(error) || token.isCancelled) rethrow;
        // Every node failed this window: serve the rest of it straight from the addresses
        // Bilibili handed out, the way the player would have without acceleration.
        if (kDebugMode) debugPrint('thread ripper fallback: $error');
        _dropWindows();
        track.fallbacks += 1;
        track.warmEnd = -1;
        await _passthrough(math.max(window.end, cursor));
        _planned = cursor;
        _startupPending = true;
      }
    }
  }

  /// Plain single-connection download of [cursor]..[to] from the original addresses.
  Future<void> _passthrough(int to) async {
    Object? lastError;
    for (final url in _directUrls()) {
      if (cursor > to) return;
      final attempt = CancelToken(token);
      Timer? stall;
      void arm() {
        stall?.cancel();
        stall = Timer(
          const Duration(seconds: 15),
          () => attempt.cancel(const RipperTimeout('CDN 停止传输')),
        );
      }

      RipperResponse? reply;
      try {
        arm();
        reply = await proxy.downloader.transport.open(url, cursor, to, attempt);
        final range = parseContentRange(reply.contentRange);
        if (reply.status != 206 || range == null || range.start != cursor) {
          throw RipperHttpError('HTTP ${reply.status}', reply.status);
        }
        await for (final data in reply.body) {
          if (attempt.isCancelled) throw attempt.reason;
          arm();
          final bytes = data is Uint8List ? data : Uint8List.fromList(data);
          final room = to - cursor + 1;
          await _write(
            room < bytes.length ? Uint8List.sublistView(bytes, 0, room) : bytes,
          );
          if (cursor > to) break;
        }
        if (cursor > to) {
          reply.release();
          return;
        }
        lastError = const RipperHttpError('CDN 提前结束传输');
      } catch (error) {
        if (token.isCancelled) throw token.reason;
        lastError = attempt.isCancelled ? attempt.reason : error;
      } finally {
        stall?.cancel();
        if (cursor <= to) reply?.abort();
        attempt.dispose();
      }
    }
    if (cursor <= to) throw lastError ?? const RipperHttpError('没有可用 CDN');
  }
}

/// The app's default proxy: real network, Bilibili's headers.
RangeProxy createRangeProxy({
  required String userAgent,
  required String referer,
  required RipperSettings Function() settings,
}) => RangeProxy(
  transport: IoTransport(userAgent: userAgent, referer: referer),
  settings: settings,
);
