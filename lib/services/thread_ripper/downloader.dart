// Ported from Bilibili 线程撕裂者 (https://github.com/MrTangLuyao/Bilibili-thread-ripper,
// MIT), src/idm-downloader.js: one range is cut into pieces, the pieces go to several CDN
// nodes over many connections at once, every reply is checked against the bytes asked for,
// a straggler gets a second copy on another node, and the pieces are handed on in order.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/transport.dart';
import 'package:collection/collection.dart' show mergeSort;

const int _pieceRounds = 3;
const double _pieceRetryWindowMs = 25000;
// The pause before a piece's next round of addresses: half a second, doubling, at most two.
double _roundPause(int round) => math.min(2000, 500.0 * (1 << (round - 1)));
// Below this a resumed request saves less than its own round trip costs.
const int _resumeMinBytes = 32 * 1024;
// Hedging a piece with a playback deadline (see _hedgeDue).
const double _hedgeSlackMs = 1500;
const double _hedgePace = 0.6;
const double _hedgeFaster = 1.5;
// Queue classes, served in this order: the startup probe, then startup pieces, then
// everything else. A class never waits behind a lower one.
const int queueCritical = 0, queueStartup = 1, queueOrdinary = 2;
// Priority an ordinary request with a playback deadline gains per millisecond of waiting.
const double _queueAgingPerMs = 20 / 900;
// A shorter transfer is mostly round trip.
const int _speedSampleMinBytes = 48 * 1024;

/// When playback needs a range, as a clock time ([nowMs]); infinity when unknown.
typedef DeadlineFn = double Function();

double _noDeadline() => double.infinity;

class _QueueEntry {
  _QueueEntry({
    required this.completer,
    required this.signal,
    required this.priority,
    required this.deadlineAt,
    required this.deadline,
    required this.queueClass,
    required this.ages,
    required this.queuedAt,
    required this.sequence,
  });

  final Completer<void Function()> completer;
  final CancelToken? signal;
  final double priority;
  final double deadlineAt;
  final DeadlineFn? deadline;
  final int queueClass;
  final bool ages;
  final double queuedAt;
  final int sequence;
  void Function()? detach;
  bool released = false;
}

class _Semaphore {
  _Semaphore(int limit) : limit = limit.clamp(1, 512);

  int limit;
  int active = 0;
  final List<_QueueEntry> _queue = [];
  int _sequence = 0;
  void Function(int active, int limit, int queued)? onChange;

  int get queued => _queue.length;

  void setLimit(int value) {
    limit = value.clamp(1, 512);
    _drain();
  }

  void _drain() {
    try {
      _drainQueue();
    } finally {
      onChange?.call(active, limit, _queue.length);
    }
  }

  static double _urgency(_QueueEntry entry, double now) {
    // Read again at every pass: the player's deadline moves with the playhead and the
    // playback rate, and a queued piece may have become due while it waited.
    final deadlineAt = entry.deadline != null
        ? entry.deadline!()
        : entry.deadlineAt;
    if (!deadlineAt.isFinite) return 0;
    final remaining = deadlineAt - now;
    if (remaining <= 0) return 12;
    if (remaining <= 750) return 9;
    if (remaining <= 2000) return 6;
    return 0;
  }

  void _drainQueue() {
    while (active < limit && _queue.isNotEmpty) {
      final now = nowMs();
      // A bounded, recomputed boost keeps overdue primaries from sitting behind prefetch
      // work; a request with a deadline also gains priority while it waits. Sorting inside
      // the class keeps the startup probe and the startup pieces ahead of ordinary media.
      double rank(_QueueEntry entry) =>
          entry.priority +
          _urgency(entry, now) +
          (entry.ages ? (now - entry.queuedAt) * _queueAgingPerMs : 0);
      final ranks = {for (final entry in _queue) entry: rank(entry)};
      mergeSort(
        _queue,
        compare: (a, b) {
          final byClass = a.queueClass - b.queueClass;
          if (byClass != 0) return byClass;
          final byRank = ranks[b]!.compareTo(ranks[a]!);
          if (byRank != 0) return byRank;
          return a.sequence - b.sequence;
        },
      );
      final entry = _queue.removeAt(0);
      entry.detach?.call();
      if (entry.signal?.isCancelled == true) {
        entry.completer.completeError(entry.signal!.reason);
        continue;
      }
      active += 1;
      entry.completer.complete(() {
        if (entry.released) return;
        entry.released = true;
        active = math.max(0, active - 1);
        _drain();
      });
    }
  }

  // deadline: a function giving the clock time playback needs this request, or null; the
  // fixed deadlineAt is what callers without one pass.
  Future<void Function()> acquire(
    CancelToken? signal, {
    double priority = 0,
    double deadlineAt = double.infinity,
    int queueClass = queueCritical,
    bool ages = false,
    DeadlineFn? deadline,
  }) {
    if (signal?.isCancelled == true) return Future.error(signal!.reason);
    final entry = _QueueEntry(
      completer: Completer<void Function()>(),
      signal: signal,
      priority: priority,
      deadlineAt: deadlineAt,
      deadline: deadline,
      queueClass: queueClass,
      ages: ages,
      queuedAt: nowMs(),
      sequence: _sequence++,
    );
    entry.detach = signal?.onCancel(() {
      if (!_queue.remove(entry)) return;
      entry.completer.completeError(signal.reason);
      _drain();
    });
    _queue.add(entry);
    _drain();
    return entry.completer.future;
  }
}

class PieceResult {
  PieceResult(this.bytes, this.total, this.url);
  final Uint8List bytes;
  final int? total;
  final String url;
}

class _Recorder {
  int bytes = 0;
  final List<Uint8List> chunks = [];
}

class _Prefix {
  _Prefix(this.bytes, this.chunks);
  final int bytes;
  final List<Uint8List> chunks;
}

class _Context {
  _Context(this.base, this.recorder, this.startedAt, this.length)
    : seenAt = startedAt;
  final _Prefix? base;
  final _Recorder recorder;
  final double startedAt;
  final int length;
  int seenBytes = 0;
  double seenAt;
}

class _Plan {
  _Plan(this.recorder, this.part);
  final _Recorder recorder;
  final Piece part;
}

// Only measured per-request progress can spend this bounded rescue budget. The second
// budget is for pieces that will miss their deadline while their copy's node is not
// measured as clearly faster: that measurement can be stale.
class _EarlyHedge {
  _EarlyHedge(int limit)
    : _progressRemaining = math.max(0, limit),
      _staleRemaining = math.max(1, limit);
  int _progressRemaining;
  int _staleRemaining;

  bool claimProgress() {
    if (_progressRemaining <= 0) return false;
    _progressRemaining -= 1;
    return true;
  }

  bool claimStale() {
    if (_staleRemaining <= 0) return false;
    _staleRemaining -= 1;
    return true;
  }
}

class _TrialState {
  int waited = 0;
  int cursor = 0;
}

enum _Startup { none, startup, probe }

/// Receives the pieces of a range in order: the bytes, where they start, and the file's
/// total length from their Content-Range.
typedef OrderedChunk = FutureOr<void> Function(
  Uint8List bytes,
  int start,
  int? total,
);

class RangeResult {
  RangeResult(this.byteLength, this.total, this.hosts);
  final int byteLength;
  final int? total;
  final Set<String> hosts;
}

/// Hands the finished pieces on in order: each one as soon as every piece before it has
/// been handed over.
class _OrderedDelivery {
  _OrderedDelivery(this._starts, this._sink)
    : _ordered = List.filled(_starts.length, null);

  final List<int> _starts;
  final OrderedChunk _sink;
  final List<PieceResult?> _ordered;
  int _next = 0;
  Future<void> _operation = Future.value();

  Future<void> add(int index, PieceResult result) {
    _ordered[index] = result;
    return _operation = _operation.then((_) async {
      while (_next < _ordered.length && _ordered[_next] != null) {
        final item = _ordered[_next]!;
        _ordered[_next] = null;
        await _sink(item.bytes, _starts[_next], item.total);
        _next += 1;
      }
    });
  }

  Future<void> done() => _operation;
}

/// Transfer statistics for the settings page.
class RipperStats {
  /// Everything received, copies that lost their race included.
  int bytes = 0;

  /// What was handed on: the pieces that won.
  int useful = 0;
  final List<(double, int)> _recent = [];

  void add(int count) {
    bytes += count;
    final now = nowMs();
    if (_recent.isNotEmpty && now - _recent.last.$1 < 250) {
      final last = _recent.removeLast();
      _recent.add((last.$1, last.$2 + count));
    } else {
      _recent.add((now, count));
    }
    while (_recent.isNotEmpty && now - _recent.first.$1 > 3000) {
      _recent.removeAt(0);
    }
  }

  /// Bytes per second over the last three seconds.
  double get speed {
    final now = nowMs();
    while (_recent.isNotEmpty && now - _recent.first.$1 > 3000) {
      _recent.removeAt(0);
    }
    if (_recent.isEmpty) return 0;
    final total = _recent.fold<int>(0, (sum, e) => sum + e.$2);
    return total * 1000 / 3000;
  }
}

class RipperDownloader {
  RipperDownloader({
    required this.transport,
    required this.getSettings,
    AutoConcurrency? auto,
  }) : auto = auto ?? AutoConcurrency() {
    _semaphore = _Semaphore(_config().concurrency);
    _semaphore.onChange = (active, limit, queued) {
      if (_config().autoConcurrency) this.auto.demand(active, limit, queued);
    };
    _unsubscribe = this.auto.subscribe((_, _, _) => applySettings());
  }

  final RipperTransport transport;
  final RipperSettings Function() getSettings;
  final AutoConcurrency auto;
  final RipperStats stats = RipperStats();
  late final _Semaphore _semaphore;
  late final void Function() _unsubscribe;

  int get activeConnections => _semaphore.active;
  int get queuedRequests => _semaphore.queued;
  int get concurrency => _semaphore.limit;

  RipperSettings _config() {
    final settings = getSettings();
    if (!settings.autoConcurrency) return settings;
    // In the automatic mode the thread count is the controller's, everything else the
    // viewer's.
    return settings.withConcurrency(auto.threads);
  }

  void applySettings() => _semaphore.setLimit(_config().concurrency);

  void dispose() {
    _unsubscribe();
    transport.close();
  }

  // What one connection typically delivers here and how long a sub-chunk typically takes.
  // Sub-chunk sizing and the hedge delay follow these measurements.
  double _connectionBps = 0;
  double _pieceMs = 0;

  void _recordMeter(int bytes, double elapsedMs) {
    if (bytes < _speedSampleMinBytes || elapsedMs <= 0) return;
    final bps = bytes * 1000 / elapsedMs;
    _connectionBps = _connectionBps > 0
        ? _connectionBps * 0.7 + bps * 0.3
        : bps;
    _pieceMs = _pieceMs > 0 ? _pieceMs * 0.7 + elapsedMs * 0.3 : elapsedMs;
  }

  // A sub-chunk should keep its connection busy for a good part of a second, otherwise
  // request round trips dominate on high-latency routes. 64 KiB stays the floor while the
  // speed is still unknown, and a range still splits into at least one piece per node.
  int _adaptiveMinChunk(
    RipperSettings settings,
    int rangeLength,
    int pieceLimit, [
    int hostCount = 4,
  ]) {
    if (_connectionBps <= 0) return settings.minChunkBytes;
    final target = (_connectionBps * 0.6 / (64 * 1024)).floor() * 64 * 1024;
    final spread =
        (rangeLength /
                math.max(1, math.min(math.max(4, hostCount), pieceLimit)))
            .ceil();
    return math.max(
      settings.minChunkBytes,
      math.min(1024 * 1024, math.min(target, spread)),
    );
  }

  // A second copy starts once a piece takes clearly longer than pieces have been taking,
  // instead of always waiting the full fixed delay.
  double _hedgeDelayMs(RipperSettings settings) => _pieceMs > 0
      ? math.max(
          250,
          math.min(
            settings.hedgeDelayMs.toDouble(),
            (_pieceMs * 1.5).roundToDouble(),
          ),
        )
      : settings.hedgeDelayMs.toDouble();

  // Whether the second copy of a piece with a playback deadline should start now. Checked
  // every 50 ms once the first copy holds a connection.
  // - No data yet, or nothing new for a whole delay (stopped): copy.
  // - A deadline it meets with time to spare at its speed so far: no copy yet.
  // - The copy's node known to be clearly faster: copy.
  // - Slower than connections usually are, or no usual speed measured yet: copy.
  // - On pace: a copy on a node not measured yet is tried, as the chance of a faster one;
  //   a piece that will miss its deadline even so may spend a rescue slot anyway.
  bool _hedgeDue(
    _Context first,
    double delayMs,
    double deadlineAt,
    double copyBps,
    _EarlyHedge? rescue,
  ) {
    final now = nowMs(), ran = now - first.startedAt;
    final got = first.recorder.bytes;
    if (got != first.seenBytes) {
      first
        ..seenBytes = got
        ..seenAt = now;
    }
    if (ran < delayMs) return false;
    if (got == 0 || now - first.seenAt >= delayMs) return true;
    final rate = got * 1000 / ran;
    final finishAt = now + math.max(0, first.length - got) * 1000 / rate;
    if (finishAt <= deadlineAt - _hedgeSlackMs) return false;
    if (copyBps > rate * _hedgeFaster) return true;
    if (!(_connectionBps > 0) || rate < _connectionBps * _hedgePace) {
      return true;
    }
    if (!(copyBps > 0)) return true;
    return finishAt > deadlineAt && (rescue?.claimStale() ?? false);
  }

  Future<Uint8List> _readBody(
    RipperResponse response,
    CancelToken controller,
    RipperSettings settings,
    _Recorder received,
    int expected,
    void Function(int bytes) report,
  ) async {
    final completer = Completer<Uint8List>();
    final chunks = <Uint8List>[];
    var total = 0;
    Timer? stallTimer;
    void armStall() {
      stallTimer?.cancel();
      stallTimer = Timer(
        Duration(milliseconds: settings.stallTimeoutMs),
        () => controller.cancel(const RipperTimeout('CDN 子块停止传输')),
      );
    }

    StreamSubscription<List<int>>? subscription;
    final detach = controller.onCancel(() {
      subscription?.cancel();
      if (!completer.isCompleted) completer.completeError(controller.reason);
    });
    armStall();
    subscription = response.body.listen(
      (data) {
        if (completer.isCompleted) return;
        armStall();
        final chunk = data is Uint8List ? data : Uint8List.fromList(data);
        total += chunk.length;
        if (total > expected) {
          subscription?.cancel();
          completer.completeError(
            RipperHttpError('子块长度不符：$total/$expected'),
          );
          return;
        }
        chunks.add(chunk);
        received.bytes += chunk.length;
        // The recorder keeps what a failed attempt already received, so a retry or a
        // hedge copy can ask only for the missing tail.
        received.chunks.add(chunk);
        stats.add(chunk.length);
        if (settings.autoConcurrency) auto.activity();
        report(chunk.length);
      },
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            controller.isCancelled ? controller.reason : error,
          );
        }
      },
      onDone: () {
        if (completer.isCompleted) return;
        if (controller.isCancelled) {
          completer.completeError(controller.reason);
          return;
        }
        completer.complete(
          chunks.length == 1 ? chunks.first : concatChunks(chunks, total),
        );
      },
      cancelOnError: true,
    );
    try {
      return await completer.future;
    } finally {
      stallTimer?.cancel();
      detach();
    }
  }

  // begin: called once the request has its connection slot, and returns what to ask for.
  // A copy that waited in the queue resumes from what the first copy has received by
  // then, not from what it had when the copy was queued.
  Future<PieceResult> _attempt(
    Piece piece,
    String url,
    CancelToken signal,
    CdnResolver resolver, {
    double priority = 0,
    _Plan Function()? begin,
    DeadlineFn? deadline,
    void Function(double bps, double? etaMs)? observe,
    int queueClass = queueCritical,
    bool allowShort = false,
  }) async {
    final settings = _config();
    final deadlineAt = deadline?.call() ?? double.infinity;
    final release = await _semaphore.acquire(
      signal,
      priority: priority,
      deadlineAt: deadlineAt,
      queueClass: queueClass,
      ages: queueClass == queueOrdinary && deadlineAt.isFinite,
      deadline: deadline,
    );
    var received = _Recorder();
    if (begin != null) {
      try {
        final plan = begin();
        piece = plan.part;
        received = plan.recorder;
      } catch (_) {
        release();
        rethrow;
      }
    }
    final controller = CancelToken(signal);
    final firstByteTimer = Timer(
      Duration(milliseconds: settings.firstByteTimeoutMs),
      () => controller.cancel(const RipperTimeout('CDN 首字节超时')),
    );
    final totalTimer = Timer(
      Duration(milliseconds: settings.attemptTimeoutMs),
      () => controller.cancel(const RipperTimeout('CDN 子块总耗时超限')),
    );
    final startedAt = nowMs();
    RipperResponse? response;
    var succeeded = false;
    try {
      response = await transport.open(url, piece.start, piece.end, controller);
      firstByteTimer.cancel();
      final range = parseContentRange(response.contentRange);
      final exact =
          range != null && range.start == piece.start && range.end == piece.end;
      // The probe of a track whose length is still unknown may run past its end: the
      // node then answers with the tail of the file, which is just as good.
      final short =
          allowShort &&
          range != null &&
          range.start == piece.start &&
          range.total != null &&
          range.end == range.total! - 1 &&
          range.end < piece.end;
      if (response.status != 206 || !(exact || short)) {
        // The status tells a refused signed address (4xx) apart from a node that is down.
        throw RipperHttpError(
          'Range 校验失败：HTTP ${response.status}',
          response.status,
        );
      }
      final expected = range.length;
      final part = piece;
      final bytes = await _readBody(
        response,
        controller,
        settings,
        received,
        expected,
        observe == null
            ? (_) {}
            : (_) {
                final elapsed = math.max(1, nowMs() - startedAt);
                final bps = received.bytes * 1000 / elapsed;
                final remaining = math.max(0, part.length - received.bytes);
                observe(bps, bps > 0 ? remaining * 1000 / bps : null);
              },
      );
      if (bytes.length != expected) {
        throw RipperHttpError('子块长度不符：${bytes.length}/$expected');
      }
      final elapsedMs = math.max(1.0, nowMs() - startedAt);
      _recordMeter(bytes.length, elapsedMs);
      // The node answered either way; only a large enough transfer says how fast it is.
      resolver.success(
        url,
        bytes.length >= _speedSampleMinBytes
            ? bytes.length * 1000 / elapsedMs
            : 0,
      );
      succeeded = true;
      response.release();
      return PieceResult(bytes, range.total, url);
    } catch (thrown) {
      final error = controller.isCancelled ? controller.reason : thrown;
      final canceled = isAbort(error);
      // A copy that lost the race was cut off, not broken, and what it had received by
      // then is a measurement of its node.
      if (canceled && received.bytes >= _speedSampleMinBytes) {
        resolver.sample(
          url,
          received.bytes * 1000 / math.max(1, nowMs() - startedAt),
        );
      }
      // Received bytes tell a dead node (0 KiB) apart from a transfer that stalled midway.
      resolver.failure(url, error, received.bytes);
      if (settings.autoConcurrency) {
        final status = error is RipperHttpError ? error.status : 0;
        if (status == 412 || status == 429) {
          auto.pushback(status);
        } else if (!canceled && error is RipperTimeout && received.bytes == 0) {
          auto.slow();
        }
      }
      throw error;
    } finally {
      firstByteTimer.cancel();
      totalTimer.cancel();
      if (!succeeded) {
        // Invalid headers can fail before the body is read. Stop that response too,
        // otherwise it keeps downloading after releasing the slot.
        controller.cancel();
        response?.abort();
      }
      controller.dispose();
      release();
    }
  }

  List<String> _pieceCandidates(
    Piece piece,
    CdnResolver resolver,
    List<String> preferred,
    int round,
  ) {
    // The first preferred address is the node this piece was assigned to by speed; only a
    // retry round moves past it.
    final offset = preferred.isEmpty ? 0 : round % preferred.length;
    final rotated = [
      ...preferred.sublist(offset),
      ...preferred.sublist(0, offset),
    ];
    final rescue = resolver.rescueCandidates().where(
      (url) => !rotated.contains(url),
    );
    // The copies after the first go to the fastest known nodes, wherever they were
    // listed: a hedge that lands on the slowest node saves nothing.
    final rest = [...rotated.skip(1), ...rescue];
    mergeSort(
      rest,
      compare: (left, right) =>
          resolver.speed(right).compareTo(resolver.speed(left)),
    );
    final candidates = rotated.isNotEmpty ? [rotated.first, ...rest] : rest;
    for (final url in resolver.ordered(piece.index)) {
      if (!candidates.contains(url)) candidates.add(url);
    }
    return candidates;
  }

  Future<PieceResult> _downloadPiece(
    Piece piece,
    CdnResolver resolver,
    CancelToken signal,
    List<String> preferredUrls, {
    _Startup startupMode = _Startup.none,
    double priority = 0,
    DeadlineFn? deadline,
    _EarlyHedge? earlyHedge,
    bool allowShort = false,
  }) async {
    final deadlineNow = deadline ?? _noDeadline;
    final hasDeadline = deadline != null && deadline().isFinite;
    final settings = _config();
    final startup = startupMode != _Startup.none;
    final probe = startupMode == _Startup.probe;
    final startedAt = nowMs();
    Object? lastError;

    // The longest contiguous run of bytes fetched from the front of this piece so far. A
    // retry or a hedge copy asks only for what is still missing and splices the two
    // halves. Every kept byte came out of a response whose 206 Content-Range was verified.
    _Prefix? prefix;
    void keepProgress(_Prefix? base, _Recorder recorder) {
      final bytes = (base?.bytes ?? 0) + recorder.bytes;
      if (bytes > (prefix?.bytes ?? 0) && bytes < piece.length) {
        prefix = _Prefix(
          bytes,
          base != null
              ? [...base.chunks, ...recorder.chunks]
              : List.of(recorder.chunks),
        );
      }
    }

    _Prefix? liveProgress(_Context? context) {
      if (context == null) return null;
      final chunks = List.of(context.recorder.chunks);
      var bytes = context.base?.bytes ?? 0;
      for (final chunk in chunks) {
        bytes += chunk.length;
      }
      return _Prefix(
        bytes,
        context.base != null ? [...context.base!.chunks, ...chunks] : chunks,
      );
    }

    // Failing a piece ends acceleration for this stream, and the list can be as short as
    // one working address. One slow reply must not decide that, so the list is walked
    // again after a pause; node health and bans have changed by then.
    for (var round = 0; round < _pieceRounds; round += 1) {
      if (round > 0) {
        if (nowMs() - startedAt > _pieceRetryWindowMs) break;
        await pause(_roundPause(round), signal);
      }
      final candidates = _pieceCandidates(
        piece,
        resolver,
        preferredUrls,
        round,
      );
      final limit = math.min(8, candidates.length);
      final batchWidth = probe ? limit : 2;
      final tried = <String>{};
      while (tried.length < limit) {
        signal.throwIfCancelled();
        // A node banned while this piece was waiting is skipped, unless only banned
        // nodes are left.
        final untried = candidates
            .where((url) => !tried.contains(url))
            .toList();
        final open = untried.where(resolver.allows).toList();
        final pair = (open.isNotEmpty ? open : untried)
            .take(batchWidth)
            .toList();
        if (pair.isEmpty) break;
        tried.addAll(pair);
        final controllers = [for (final _ in pair) CancelToken(signal)];
        // A first copy that is refused at once (HTTP 403) should not leave the piece idle
        // for the rest of the hedge delay.
        final firstFailure = Completer<void>();
        final firstStraggler = Completer<void>();
        var firstStartedAt = 0.0;
        var deficitSamples = 0;
        void observeFirst(double bps, double? etaMs) {
          if (!hasDeadline || etaMs == null) return;
          final deadlineAt = deadlineNow();
          if (!deadlineAt.isFinite) return;
          final remainingToDeadline = deadlineAt - nowMs();
          final missesDeadline = etaMs >= math.max(0, remainingToDeadline);
          final slowerThanPeers =
              _connectionBps > 0 && bps < _connectionBps * 0.5 && etaMs >= 500;
          deficitSamples = etaMs - remainingToDeadline >= 250
              ? deficitSamples + 1
              : 0;
          // A clearly slow node is rescued immediately. If the whole route is slow, two
          // consecutive deficit samples may spend the same per-range rescue budget.
          if ((missesDeadline && slowerThanPeers) || deficitSamples >= 2) {
            if (!firstStraggler.isCompleted) firstStraggler.complete();
          }
        }

        final contexts = List<_Context?>.filled(pair.length, null);

        Future<void> waitForCopy(int pairIndex, String url) {
          final done = Completer<void>();
          Timer? timer;
          var settled = false, earlyClaimed = false;
          void Function()? detach;
          void finish([Object? error]) {
            if (settled) return;
            settled = true;
            timer?.cancel();
            detach?.call();
            if (error == null) {
              done.complete();
            } else {
              done.completeError(error);
            }
          }

          final measured = _hedgeDelayMs(settings);
          final delay = probe
              ? 0.0
              : startup
              ? math.min(hasDeadline ? 200.0 : 250.0, measured)
              : measured;
          double copyBps() => resolver.speed(url);
          // A playback-deadline request decides once its first copy has a connection
          // (see _hedgeDue); one without a deadline keeps the fixed hedge delay, counted
          // from the moment the piece asked, queue time included.
          void check() {
            if (settled) return;
            final first = contexts[0];
            if (first != null &&
                _hedgeDue(first, delay, deadlineNow(), copyBps(), earlyHedge)) {
              finish();
              return;
            }
            timer = Timer(const Duration(milliseconds: 50), check);
          }

          if (hasDeadline && !probe) {
            timer = Timer(Duration.zero, check);
          } else {
            timer = Timer(
              Duration(microseconds: (delay * 1000).round()),
              finish,
            );
          }
          firstStraggler.future.then((_) {
            if (settled || probe || earlyClaimed) return;
            if (earlyHedge == null || !earlyHedge.claimProgress()) return;
            earlyClaimed = true;
            timer?.cancel();
            final grace = math.max(0.0, 250 - (nowMs() - firstStartedAt));
            timer = Timer(
              Duration(microseconds: (grace * 1000).round()),
              finish,
            );
          });
          firstFailure.future.then((_) => finish());
          final controller = controllers[pairIndex];
          detach = controller.onCancel(() => finish(controller.reason));
          return done.future;
        }

        Future<PieceResult> copy(int pairIndex, String url) async {
          if (pairIndex > 0) await waitForCopy(pairIndex, url);
          // Resume from the longest prefix known when the request really starts: an
          // earlier failed attempt, or what the still-running first copy has received.
          _Prefix? base;
          final recorder = _Recorder();
          _Plan begin() {
            if (pairIndex == 0) firstStartedAt = nowMs();
            base = prefix != null && prefix!.bytes >= _resumeMinBytes
                ? prefix
                : null;
            if (pairIndex > 0) {
              final live = liveProgress(contexts[0]);
              if (live != null &&
                  live.bytes >= _resumeMinBytes &&
                  live.bytes > (base?.bytes ?? 0)) {
                base = live;
              }
            }
            if (base != null && base!.bytes >= piece.length) base = null;
            contexts[pairIndex] = _Context(
              base,
              recorder,
              nowMs(),
              piece.length - (base?.bytes ?? 0),
            );
            return _Plan(
              recorder,
              base != null
                  ? Piece(piece.index, piece.start + base!.bytes, piece.end)
                  : piece,
            );
          }

          try {
            final result = await _attempt(
              piece,
              url,
              controllers[pairIndex],
              resolver,
              priority: priority + (pairIndex > 0 ? 20 : 0),
              begin: begin,
              deadline: deadline,
              observe: pairIndex == 0 ? observeFirst : null,
              queueClass: probe
                  ? queueCritical
                  : startup
                  ? queueStartup
                  : queueOrdinary,
              allowShort: allowShort,
            );
            final kept = base;
            if (kept == null) return result;
            final length = kept.bytes + result.bytes.length;
            return PieceResult(
              concatChunks([...kept.chunks, result.bytes], length),
              result.total,
              result.url,
            );
          } catch (_) {
            keepProgress(base, recorder);
            if (pairIndex == 0 && !firstFailure.isCompleted) {
              firstFailure.complete();
            }
            rethrow;
          }
        }

        final attempts = [
          for (var index = 0; index < pair.length; index += 1)
            copy(index, pair[index]),
        ];
        try {
          final winner = await firstSuccess(attempts);
          for (final controller in controllers) {
            controller.cancel(const RipperAbort('并发副本已取消'));
          }
          if (settings.autoConcurrency) auto.delivered(winner.bytes.length);
          stats.useful += winner.bytes.length;
          return winner;
        } catch (error) {
          lastError = error;
          signal.throwIfCancelled();
        } finally {
          for (final controller in controllers) {
            controller.dispose();
          }
        }
      }
    }
    throw lastError ?? const RipperHttpError('没有可用 CDN');
  }

  // Which address each piece tries first. The fastest node gets the most pieces, and a
  // node measured at under a twelfth of the best is left out entirely. Its measurement
  // goes stale after a while, and the resolver's exploration slot then gives it another
  // try.
  int _assignTurn = 0;
  // Trials are counted per resolver: the video and the audio track take turns on this
  // downloader, and one shared count could leave a track without a trial for good.
  final Expando<_TrialState> _trialStates = Expando();

  List<String> _assignPrimaries(
    List<String> urls,
    CdnResolver resolver,
    int count,
  ) {
    if (urls.isEmpty || count <= 0) return [];
    if (urls.length == 1) return List.filled(count, urls.first);
    // Each range opens one node further on, so ranges in flight together do not all send
    // their first pieces to the same node.
    final turn = _assignTurn;
    _assignTurn = (_assignTurn + 1) % 4096;
    double measure(String url) => math.max(0, resolver.speed(url));
    var known = urls.map(measure).toList();
    if (!known.any((value) => value > 0)) {
      return [
        for (var index = 0; index < count; index += 1)
          urls[(index + turn) % urls.length],
      ];
    }
    final top = known.reduce(math.max);
    final eligible = [
      for (var index = 0; index < urls.length; index += 1)
        if (known[index] == 0 || known[index] >= top / 12) urls[index],
    ];
    if (eligible.isNotEmpty && eligible.length < urls.length) {
      urls = eligible;
      known = urls.map(measure).toList();
    }
    // A node without a measurement is a trial. It gets a piece or two from the end of
    // the range, which are needed last, enough to measure it and cheap when it turns out
    // to be slow. With very few pieces there is none to spare.
    final unknown = [
      for (var index = 0; index < urls.length; index += 1)
        if (known[index] == 0) urls[index],
    ];
    var trials = math.min(unknown.length * 2, count ~/ 4);
    final trialState = _trialStates[resolver] ??= _TrialState();
    // Small segments never have a piece to spare, and a node left out for being slow
    // would stay unmeasured for good. Every fourth such range gives up its last piece.
    if (trials == 0 && unknown.isNotEmpty && count >= 2) {
      trialState.waited += 1;
      if (trialState.waited >= 4) trials = 1;
    }
    if (trials > 0) trialState.waited = 0;
    if (unknown.isNotEmpty) {
      urls = [
        for (var index = 0; index < urls.length; index += 1)
          if (known[index] > 0) urls[index],
      ];
      known = urls.map(measure).toList();
      count -= trials;
    }
    final weights = [for (final value in known) math.max(value, top * 0.05)];
    final total = weights.fold<double>(0, (sum, value) => sum + value);
    // Handed out in turns (smooth weighted round-robin), not in one block per node.
    final primaries = <String>[];
    final credit = List<double>.filled(urls.length, 0);
    final order = [
      for (var index = 0; index < urls.length; index += 1)
        (index + turn) % urls.length,
    ];
    for (var index = 0; index < count; index += 1) {
      var best = order.first;
      for (final urlIndex in order) {
        credit[urlIndex] += weights[urlIndex];
        if (credit[urlIndex] > credit[best]) best = urlIndex;
      }
      credit[best] -= total;
      primaries.add(urls[best]);
    }
    for (var index = 0; index < trials; index += 1) {
      primaries.add(unknown[(index + trialState.cursor) % unknown.length]);
    }
    trialState.cursor = (trialState.cursor + trials) % 4096;
    return primaries;
  }

  static List<String> _preferredFor(String? primary, List<String> urls) =>
      primary != null
      ? [primary, ...urls.where((url) => url != primary)]
      : urls;

  static void _checkTotals(Iterable<int?> totals) {
    final known = totals.nonNulls.toSet();
    if (known.length > 1) throw const RipperHttpError('不同 CDN 返回的文件总长度不一致');
  }

  /// A start (the first media of a track, a seek, a retry): the head of the range is
  /// raced on every node at once, the rest is spread by the speeds that race measured.
  /// When [allowShort] the track's length is not known yet, and the range may run past
  /// the end of the file; it is cut at the end the head reports.
  Future<RangeResult> _downloadStartup(
    ByteRange range,
    CdnResolver resolver,
    CancelToken signal,
    String kind,
    OrderedChunk onOrderedChunk, {
    DeadlineFn? deadline,
    bool allowShort = false,
  }) async {
    final settings = _config();
    final concurrency = settings.concurrency;
    _semaphore.setLimit(concurrency);
    final candidateUrls = resolver.rangeCandidates().toSet().toList();
    final headLength = math.min(
      range.length,
      math.max(64 * 1024, settings.minChunkBytes),
    );
    final head = Piece(0, range.start, range.start + headLength - 1);
    final headResult = await _downloadPiece(
      head,
      resolver,
      signal,
      candidateUrls,
      startupMode: _Startup.probe,
      priority: 220,
      deadline: deadline,
      allowShort: allowShort,
    );
    await onOrderedChunk(headResult.bytes, head.start, headResult.total);
    final headEnd = head.start + headResult.bytes.length - 1;
    var end = range.end;
    if (headResult.total != null && end > headResult.total! - 1) {
      end = headResult.total! - 1;
    }
    if (headEnd >= end) {
      return RangeResult(
        headEnd - range.start + 1,
        headResult.total,
        {hostOf(headResult.url)},
      );
    }

    final rescueReserve = ((concurrency / 8).ceil()).clamp(1, 16);
    final mediaBudget = math.max(1, concurrency - rescueReserve);
    final audioBudget = math.max(
      1,
      math.min(mediaBudget, (concurrency / 8).ceil()),
    );
    final pieceBudget = kind == 'audio'
        ? audioBudget
        : math.max(1, mediaBudget - audioBudget);
    final pieces = [
      for (final piece in splitRange(
        headEnd + 1,
        end,
        pieceBudget,
        _adaptiveMinChunk(
          settings,
          end - headEnd,
          pieceBudget,
          candidateUrls.length,
        ),
      ))
        Piece(piece.index + 1, piece.start, piece.end),
    ];
    final rangeToken = CancelToken(signal);
    final delivery = _OrderedDelivery(
      [for (final piece in pieces) piece.start],
      onOrderedChunk,
    );
    // The probe measured at least its own winner, so the pieces spread over the nodes by
    // speed at once. Only the probe's winner and nodes with a speed measurement carry the
    // first segment: a node whose probe never finished would hold up the start.
    final provenUrls = candidateUrls
        .where((url) => url == headResult.url || resolver.speed(url) > 0)
        .toList();
    final primaries = _assignPrimaries(
      provenUrls.isNotEmpty ? provenUrls : [headResult.url],
      resolver,
      pieces.length,
    );
    final fallbacks = [
      headResult.url,
      ...candidateUrls.where((url) => url != headResult.url),
    ];
    final earlyHedge = _EarlyHedge(rescueReserve);
    try {
      final results = await Future.wait([
        for (var index = 0; index < pieces.length; index += 1)
          () async {
            final piece = pieces[index];
            final result = await _downloadPiece(
              piece,
              resolver,
              rangeToken,
              _preferredFor(primaries[index], fallbacks),
              startupMode: _Startup.startup,
              priority: 120.0 - math.min(30, piece.index),
              deadline: deadline,
              earlyHedge: earlyHedge,
            );
            await delivery.add(index, result);
            return result;
          }(),
      ], eagerError: true);
      await delivery.done();
      _checkTotals([headResult.total, ...results.map((e) => e.total)]);
      return RangeResult(end - range.start + 1, headResult.total, {
        hostOf(headResult.url),
        ...results.map((e) => hostOf(e.url)),
      });
    } catch (_) {
      rangeToken.cancel();
      rethrow;
    } finally {
      rangeToken.dispose();
    }
  }

  /// Downloads [range] of a track over many connections and hands it to [onOrderedChunk]
  /// piece by piece, in order. A [startup] range races its head first (a new track, a
  /// seek); the range that follows the last one delivered is an ordinary download.
  Future<RangeResult> downloadRange(
    ByteRange range,
    CdnResolver resolver, {
    required CancelToken signal,
    required OrderedChunk onOrderedChunk,
    String kind = 'video',
    bool startup = false,
    bool allowShort = false,
    double priority = 50,
    DeadlineFn? deadline,
  }) async {
    if (startup || allowShort) {
      return _downloadStartup(
        range,
        resolver,
        signal,
        kind,
        onOrderedChunk,
        deadline: deadline,
        allowShort: allowShort,
      );
    }
    final settings = _config();
    final preferredUrls = resolver.rangeCandidates();
    final concurrency = settings.concurrency;
    // Fewer primary pieces than slots is not a hard-reserved connection: it gives a
    // stalled piece's hedge room to start immediately while the other primaries run.
    _semaphore.setLimit(concurrency);
    final rescueReserve = concurrency >= 8
        ? math.min(8, math.max(1, (concurrency / 8).ceil()))
        : 0;
    final pieceConcurrency = math.max(1, concurrency - rescueReserve);
    final pieces = splitRange(
      range.start,
      range.end,
      pieceConcurrency,
      _adaptiveMinChunk(
        settings,
        range.length,
        pieceConcurrency,
        preferredUrls.length,
      ),
    );
    final primaries = _assignPrimaries(preferredUrls, resolver, pieces.length);
    final earlyHedge = _EarlyHedge(rescueReserve);
    final rangeToken = CancelToken(signal);
    final delivery = _OrderedDelivery(
      [for (final piece in pieces) piece.start],
      onOrderedChunk,
    );
    try {
      final results = await Future.wait([
        for (final piece in pieces)
          () async {
            final result = await _downloadPiece(
              piece,
              resolver,
              rangeToken,
              _preferredFor(
                primaries.elementAtOrNull(piece.index),
                preferredUrls,
              ),
              priority: priority - math.min(20, piece.index),
              deadline: deadline,
              earlyHedge: earlyHedge,
            );
            await delivery.add(piece.index, result);
            return result;
          }(),
      ], eagerError: true);
      await delivery.done();
      _checkTotals(results.map((e) => e.total));
      return RangeResult(
        range.length,
        results.firstOrNull?.total,
        {for (final result in results) hostOf(result.url)},
      );
    } catch (_) {
      rangeToken.cancel();
      rethrow;
    } finally {
      rangeToken.dispose();
    }
  }
}
