// 线程撕裂者 (Bilibili thread ripper) for PiliPlus: the app-wide entry point.
//
// A port of https://github.com/MrTangLuyao/Bilibili-thread-ripper (MIT) for the app's mpv
// player. Video and audio tracks are played through a local proxy that downloads every
// range over many connections and CDN nodes at once.

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

export 'package:PiliPlus/services/thread_ripper/range_proxy.dart'
    show RipperSession;

/// One track as the API gave it: the base URL first, then the backups.
class RipperSource {
  const RipperSource(this.urls, {this.bandwidth, this.mimeType});
  final List<String> urls;

  /// Bits per second, from the DASH representation.
  final int? bandwidth;
  final String? mimeType;
}

abstract final class ThreadRipper {
  static RipperSettings _settings = _load();
  static RipperSettings get settings => _settings;

  static bool enabled = Pref.threadRipperEnabled;

  static RipperSettings _load() => RipperSettings(
    concurrency: Pref.threadRipperConcurrency,
    autoConcurrency: Pref.threadRipperAutoConcurrency,
    mode: RipperCdnMode.values.firstWhere(
      (e) => e.name == Pref.threadRipperMode,
      orElse: () => RipperCdnMode.mainland,
    ),
    customHosts: Pref.threadRipperCustomHosts,
  );

  /// Call after the stored settings changed.
  static void reload() {
    enabled = Pref.threadRipperEnabled;
    _settings = _load();
    _proxy?.downloader.applySettings();
  }

  static RangeProxy? _proxy;
  static RangeProxy get proxy => _proxy ??= createRangeProxy(
    userAgent: BrowserUa.pc,
    referer: '${HttpString.baseUrl}/',
    settings: () => _settings,
  );

  /// The proxy is running (it has been used in this run of the app).
  static RangeProxy? get running => _proxy;

  /// Starts a playback session with [video] and, if given, [audio]. Returns the session
  /// and the local addresses to play; an address is null when that track cannot be
  /// accelerated and is to be played from its original URL.
  static Future<(RipperSession, String?, String?)> open(
    RipperSource video,
    RipperSource? audio,
  ) async {
    final proxy = ThreadRipper.proxy;
    await proxy.ensureStarted();
    final session = proxy.openSession();
    final videoUrl = session.register(
      video.urls,
      kind: 'video',
      bandwidth: video.bandwidth,
      mimeType: video.mimeType,
    );
    final audioUrl = audio == null
        ? null
        : session.register(
            audio.urls,
            kind: 'audio',
            bandwidth: audio.bandwidth,
            mimeType: audio.mimeType,
          );
    return (session, videoUrl, audioUrl);
  }

  /// The app is in the foreground again.
  static Future<void> onResume() async {
    try {
      await _proxy?.heal();
    } catch (_) {}
  }

  /// The player's state, a few times a second: the buffer ahead of the playhead and
  /// whether it plays.
  static void onPlayback({
    required double aheadSeconds,
    required bool playing,
    required double rate,
  }) {
    final proxy = _proxy;
    if (proxy == null) return;
    proxy.clock.update(ahead: aheadSeconds, active: playing, rate: rate);
    if (_settings.autoConcurrency) {
      proxy.downloader.auto.buffer(aheadSeconds, playing);
    }
  }

  /// The player stopped to wait for data while playing.
  static void onStall() {
    final proxy = _proxy;
    if (proxy == null || !_settings.autoConcurrency) return;
    proxy.downloader.auto.stall();
  }

  /// A short report for the settings page.
  static String status() {
    final proxy = _proxy;
    if (proxy == null) return '尚未播放过视频';
    final downloader = proxy.downloader;
    final buffer = StringBuffer()
      ..writeln(
        '线程数：${downloader.concurrency}'
        '${_settings.autoConcurrency ? '（自动：${downloader.auto.reason}）' : ''}',
      )
      ..writeln('目前总线程：${downloader.activeConnections}')
      ..writeln('排队请求：${downloader.queuedRequests}')
      ..writeln('下载速度：${_formatSpeed(downloader.stats.speed)}')
      ..writeln(
        '累计下载：${(downloader.stats.bytes / 1024 / 1024).toStringAsFixed(1)} MB'
        '${downloader.stats.bytes > 0 ? '（并发副本占 ${(100 - downloader.stats.useful * 100 / downloader.stats.bytes).clamp(0, 100).toStringAsFixed(0)}%）' : ''}',
      );
    final session = proxy.lastActive;
    if (session != null && !session.isClosed) {
      for (final track in session.tracks) {
        buffer.writeln(
          '\n${track.kind == 'audio' ? '音频' : '视频'}节点'
          '${track.fallbacks > 0 ? '（直连兜底 ${track.fallbacks} 次）' : ''}：',
        );
        for (final node in track.resolver.status()) {
          buffer.writeln(
            '${_stateName(node.state)} ${node.host}'
            '${node.bps > 0 ? '  ${_formatSpeed(node.bps)}' : ''}',
          );
        }
      }
    }
    return buffer.toString().trim();
  }

  static String _stateName(String state) => switch (state) {
    'healthy' => '✅',
    'blocked' => '⏸',
    'banned' => '⛔',
    _ => '⚪',
  };

  static String _formatSpeed(double bps) {
    final mbps = bps * 8 / 1000 / 1000;
    return mbps >= 1
        ? '${mbps.toStringAsFixed(1)} Mbps'
        : '${(bps / 1024).toStringAsFixed(0)} KB/s';
  }

  /// The hosts offered in the custom CDN mode.
  static List<String> get knownHosts => [...mainlandHosts, ...overseasHosts];
}
