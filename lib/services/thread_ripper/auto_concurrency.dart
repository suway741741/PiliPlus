// Ported from Bilibili 线程撕裂者 (https://github.com/MrTangLuyao/Bilibili-thread-ripper,
// MIT), src/idm-downloader.js, createAutoConcurrency.
//
// 自动线程数. One controller for the whole app: the thread count starts at 8 and climbs a
// ladder towards 64 on every sign that the download is not keeping up with playback (the
// player stalls; a low buffer stops growing while bytes keep arriving; a connection waits
// too long for its first byte while every slot is busy). Every step up is a trial: ten
// seconds later the bytes per second must have grown, otherwise the step is taken back
// and that level rests for a while. A server refusing the load (412, 429) steps it back
// too, and nothing climbs past a refused level until it has rested.
//
// Each start (a new video, a seek) opens with at least 16 threads. Once the buffer is well
// ahead, the count steps back down to the level from before.

import 'package:PiliPlus/services/thread_ripper/range_core.dart';

const List<int> autoLadder = [8, 12, 16, 24, 32, 48, 64];
const int _startupLevel = 2;
const double _startupComfortSeconds = 15;
const double _startupMaxMs = 30000;
const double _stepCooldownMs = 2500;
const double _trialMs = 10000;
const double _windowMs = 5000;
const double _bucketMs = 250;
const double _restMs = 90000;
const double _pushbackRestMs = 180000;
const double _lowBufferSeconds = 6;
const double _pressureMs = 1000;
const double _activityMs = 1500;

class _Rest {
  _Rest(this.until, this.hard);
  final double until;
  final bool hard;
}

class _Trial {
  _Trial(this.from, this.level, this.at, this.baseline);
  final int from;
  final int level;
  final double at;
  final double baseline;
  bool stalled = false;
}

class _Span {
  _Span(this.from, this.to);
  final double from;
  final double to;
}

class _Sample {
  _Sample(this.at, this.value);
  final double at;
  double value;
}

class _Startup {
  _Startup(this.base, this.until);
  final int base;
  final double until;
}

class AutoConcurrency {
  AutoConcurrency({double Function()? now}) : _now = now ?? nowMs;

  final double Function() _now;
  final Set<void Function(int threads, int previous, String reason)>
  _listeners = {};

  int _level = 0;
  double _changedAt = 0;
  String reason = '起步';
  int steps = 0;
  _Trial? _trial;
  // level index -> rest: hard rests (refusals) also cap every level above.
  final Map<int, _Rest> _resting = {};
  final List<_Sample> _buckets = [];
  double _lastActivityAt = double.negativeInfinity;
  // Time the connections spent saturated: intervals within the window.
  bool _saturated = false;
  double _saturatedSince = 0;
  final List<_Span> _saturatedSpans = [];
  final List<_Sample> _aheadSamples = [];
  double _pressureSince = 0;
  // The start of a session while it runs above the base level.
  _Startup? _startup;

  int get threads => autoLadder[_level];

  void Function() subscribe(
    void Function(int threads, int previous, String reason) listener,
  ) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _pruneBuckets(double at) {
    while (_buckets.isNotEmpty && at - _buckets.first.at > _windowMs) {
      _buckets.removeAt(0);
    }
  }

  /// Bytes per second over the window, from completed pieces only: a hedge copy that lost
  /// its race is not delivery.
  double throughput([double? at]) {
    at ??= _now();
    _pruneBuckets(at);
    if (_buckets.isEmpty) return 0;
    final bytes = _buckets.fold<double>(0, (sum, item) => sum + item.value);
    final span = _buckets.last.at - _buckets.first.at + _bucketMs;
    return bytes * 1000 / (span < 1000 ? 1000 : span);
  }

  /// The share of the window during which every slot was busy and pieces were queued.
  double saturation([double? at]) {
    at ??= _now();
    final from = at - _windowMs;
    _saturatedSpans.removeWhere((span) => span.to <= from);
    var busy = 0.0;
    for (final span in _saturatedSpans) {
      final start = span.from > from ? span.from : from;
      if (span.to > start) busy += span.to - start;
    }
    if (_saturated) {
      final start = _saturatedSince > from ? _saturatedSince : from;
      if (at > start) busy += at - start;
    }
    final share = busy / _windowMs;
    return share > 1 ? 1 : share;
  }

  _Rest? _restingAt(int level, double at) {
    final rest = _resting[level];
    if (rest == null) return null;
    if (rest.until <= at) {
      _resting.remove(level);
      return null;
    }
    return rest;
  }

  void _setLevel(int level, String reason, [_Trial? trial]) {
    final previous = threads;
    _level = level;
    _changedAt = _now();
    this.reason = reason;
    steps += 1;
    _trial = trial;
    _pressureSince = 0;
    for (final listener in List.of(_listeners)) {
      try {
        listener(threads, previous, reason);
      } catch (_) {}
    }
  }

  // Up one level. A level resting after a refusal caps the climb; one resting after a
  // fruitless trial is skipped only by a strong signal (a stall), not by pressure.
  bool _stepUp(String reason, bool strong) {
    final at = _now();
    if (at - _changedAt < _stepCooldownMs) return false;
    if (_restingAt(_level, at)?.hard == true) return false;
    var next = _level + 1;
    while (next < autoLadder.length) {
      final rest = _restingAt(next, at);
      if (rest == null) break;
      if (rest.hard || !strong) return false;
      next += 1;
    }
    if (next >= autoLadder.length) return false;
    _setLevel(next, reason, _Trial(_level, next, at, throughput(at)));
    // Not keeping up even with the start's threads: the start ends at this level.
    _startup = null;
    return true;
  }

  // How high a start may go: up to 16 threads, but not onto or past a level the server
  // refused.
  int _startupLevelAt(double at) {
    if (_restingAt(_level, at)?.hard == true) return _level;
    var level = _level;
    while (level < _startupLevel && _restingAt(level + 1, at)?.hard != true) {
      level += 1;
    }
    return level;
  }

  bool _stepDown(
    int target,
    int restLevel,
    String reason,
    double restMs,
    bool hard,
  ) {
    _resting[restLevel] = _Rest(_now() + restMs, hard);
    if (target >= _level) return false;
    _setLevel(target, reason);
    return true;
  }

  // A step up has had its time: did the extra connections deliver? Only judged when the
  // connections were busy meanwhile; an idle download (buffer full) proves nothing, and so
  // does a stall in between. Without any gain the step goes back to where it started.
  void _judgeTrial(double at) {
    final trial = _trial;
    if (trial == null || at - trial.at < _trialMs) return;
    _trial = null;
    if (trial.stalled || saturation(at) < 0.6 || trial.baseline <= 0) return;
    if (throughput(at) < trial.baseline) {
      _stepDown(
        trial.from,
        trial.level,
        '${autoLadder[trial.level]} 线程没有比 ${autoLadder[trial.from]} 线程更快',
        _restMs,
        false,
      );
    }
  }

  /// A piece arrived whole.
  void delivered(int bytes, [double? at]) {
    at ??= _now();
    final last = _buckets.lastOrNull;
    if (last != null && at - last.at < _bucketMs) {
      last.value += bytes;
    } else {
      _buckets.add(_Sample(at, bytes.toDouble()));
    }
    _pruneBuckets(at);
    _judgeTrial(at);
  }

  /// Bytes are flowing on some connection right now.
  void activity([double? at]) {
    _lastActivityAt = at ?? _now();
  }

  /// The connections' state whenever it changes.
  void demand(int active, int limit, int queued, [double? at]) {
    at ??= _now();
    final saturated = active >= limit && queued > 0;
    if (saturated == _saturated) return;
    if (_saturated) _saturatedSpans.add(_Span(_saturatedSince, at));
    _saturated = saturated;
    _saturatedSince = at;
    saturation(at);
  }

  /// The player stalled: more threads at once.
  bool stall([String reason = '播放卡了一下']) {
    _trial?.stalled = true;
    return _stepUp(reason, true);
  }

  /// The buffer ahead of the playhead, a few times a second while playing. A low buffer
  /// that has not grown over the last second although bytes keep arriving, for a whole
  /// second, means the connections are too few.
  bool buffer(double ahead, bool playing, [double? at]) {
    at ??= _now();
    _aheadSamples.add(_Sample(at, ahead));
    while (_aheadSamples.isNotEmpty &&
        at - _aheadSamples.first.at > _pressureMs + _bucketMs) {
      _aheadSamples.removeAt(0);
    }
    // The start: once well ahead, one step back down per cooldown towards the base level.
    final start = _startup;
    if (start != null && at >= start.until) {
      _startup = null;
    } else if (start != null &&
        ahead >= _startupComfortSeconds &&
        at - _changedAt >= _stepCooldownMs) {
      if (_level > start.base) {
        _setLevel(_level - 1, '开头已经跟上，线程数降到 ${autoLadder[_level - 1]}');
      }
      if (_level <= start.base) _startup = null;
    }
    final earlier = _aheadSamples
        .where((item) => at! - item.at >= _pressureMs)
        .firstOrNull;
    final downloading = at - _lastActivityAt < _activityMs;
    final pressed =
        playing &&
        downloading &&
        ahead < _lowBufferSeconds &&
        earlier != null &&
        ahead <= earlier.value + 0.05;
    if (!pressed) {
      _pressureSince = 0;
      return false;
    }
    if (_pressureSince == 0) {
      _pressureSince = at;
      return false;
    }
    if (at - _pressureSince < _pressureMs) return false;
    _pressureSince = 0;
    return _stepUp('缓冲跟不上播放', false);
  }

  /// A connection waited too long for its first byte while every slot was busy.
  bool slow() => saturation() >= 0.6 && _stepUp('连接排队等太久', false);

  /// The server refused the load: back one level, and nothing climbs past this one for a
  /// while.
  bool pushback(int status) => _stepDown(
    _level > 0 ? _level - 1 : 0,
    _level,
    '服务器返回 $status',
    _pushbackRestMs,
    true,
  );

  /// A new playback session: what the buffer did before means nothing now, and the start
  /// runs with more threads.
  void newSession() {
    final at = _now();
    _aheadSamples.clear();
    _pressureSince = 0;
    _trial = null;
    _buckets.clear();
    _saturatedSpans.clear();
    if (_saturated) _saturatedSince = at;
    final base = _startup?.base ?? _level;
    final target = _startupLevelAt(at);
    if (target > _level) {
      _setLevel(target, '开头先用 ${autoLadder[target]} 线程');
    }
    _startup = _level > base ? _Startup(base, at + _startupMaxMs) : null;
  }

  void reset() {
    _level = 0;
    _changedAt = 0;
    reason = '起步';
    steps = 0;
    _trial = null;
    _resting.clear();
    _buckets.clear();
    _lastActivityAt = double.negativeInfinity;
    _saturated = false;
    _saturatedSince = 0;
    _saturatedSpans.clear();
    _aheadSamples.clear();
    _pressureSince = 0;
    _startup = null;
  }
}
