// Local-only integration test: real mpv and ffmpeg play DASH media through the proxy
// from a throttled fake CDN. Needs mpv/ffmpeg and RIPPER_MEDIA=<dir with video.m4s,
// audio.m4s>; skipped otherwise.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:PiliPlus/services/thread_ripper/transport.dart';
import 'package:flutter_test/flutter_test.dart';

class ThrottledCdn {
  ThrottledCdn(this.files);
  final Map<String, Uint8List> files;
  final Map<String, int> served = {};
  int requests = 0;
  late HttpServer server;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
  }

  Uri rewrite(String url) {
    final uri = Uri.parse(url);
    return Uri.parse(
      'http://127.0.0.1:${server.port}/${uri.host}${uri.path}?${uri.query}',
    );
  }

  Future<void> _serve(HttpRequest request) async {
    requests++;
    final host = request.uri.pathSegments.first;
    final name = request.uri.pathSegments.last.contains('30280')
        ? 'audio'
        : 'video';
    final file = files[name]!;
    final match = RegExp(
      r'bytes=(\d+)-(\d+)',
    ).firstMatch(request.headers.value('range') ?? '')!;
    final start = int.parse(match[1]!);
    final end = math.min(int.parse(match[2]!), file.length - 1);
    final response = request.response;
    // Round trip of an overseas route.
    await Future.delayed(const Duration(milliseconds: 120));
    if (start >= file.length) {
      response.statusCode = 416;
      await response.close();
      return;
    }
    response
      ..statusCode = 206
      ..headers.set('content-range', 'bytes $start-$end/${file.length}')
      ..contentLength = end - start + 1;
    // About 1.5 MB/s per connection.
    try {
      var offset = start;
      while (offset <= end) {
        final to = math.min(end + 1, offset + 16 * 1024);
        response.add(Uint8List.sublistView(file, offset, to));
        await response.flush();
        served[host] = (served[host] ?? 0) + to - offset;
        offset = to;
        await Future.delayed(const Duration(milliseconds: 10));
      }
      await response.close();
    } catch (_) {}
  }
}

class _Transport implements RipperTransport {
  _Transport(this.cdn)
    : inner = IoTransport(userAgent: 't', referer: 'r', rewrite: cdn.rewrite);
  final ThrottledCdn cdn;
  final IoTransport inner;
  @override
  Future<RipperResponse> open(String url, int s, int e, CancelToken t) =>
      inner.open(url, s, e, t);
  @override
  void close() => inner.close();
}

void main() {
  final dir = Platform.environment['RIPPER_MEDIA'];
  final skip = dir == null ? 'RIPPER_MEDIA not set' : null;
  late ThrottledCdn cdn;
  late RangeProxy proxy;
  late String videoUrl, audioUrl;

  setUpAll(() async {
    if (dir == null) return;
    cdn = ThrottledCdn({
      'video': File('$dir/video.m4s').readAsBytesSync(),
      'audio': File('$dir/audio.m4s').readAsBytesSync(),
    });
    await cdn.start();
    proxy = RangeProxy(
      transport: _Transport(cdn),
      settings: () => RipperSettings(autoConcurrency: true),
    );
    await proxy.ensureStarted();
  });

  setUp(() {
    if (dir == null) return;
    final session = proxy.openSession();
    videoUrl = session.register(
      [
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-30080.m4s?deadline=1&upsig=a',
      ],
      kind: 'video',
      bandwidth: 6000000,
    )!;
    audioUrl = session.register(
      [
        'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/3-1-30280.m4s?deadline=1&upsig=a',
      ],
      kind: 'audio',
      bandwidth: 192000,
    )!;
  });

  // What PiliPlus hands mpv: one EDL with both tracks.
  String edl() =>
      'edl://!no_chapters;%${videoUrl.length}%$videoUrl;'
      '!new_stream;!no_chapters;%${audioUrl.length}%$audioUrl';

  Future<ProcessResult> mpv(List<String> args, {String? script}) async {
    final scriptFile = script == null
        ? null
        : (File('${Directory.systemTemp.path}/ripper_${args.hashCode}.lua')
            ..writeAsStringSync(script));
    final result = await Process.run('mpv', [
      '--no-config',
      '--vo=null',
      '--ao=null',
      '--msg-level=all=info',
      '--cache=yes',
      '--cache-secs=20',
      '--demuxer-max-bytes=${8 * 1024 * 1024}',
      '--demuxer-max-back-bytes=${8 * 1024 * 1024}',
      '--user-agent=Mozilla/5.0',
      '--referrer=https://www.bilibili.com',
      if (scriptFile != null) '--script=${scriptFile.path}',
      ...args,
      edl(),
    ]);
    // ignore: avoid_print
    print(
      'mpv exit ${result.exitCode}\n${result.stdout}\n${result.stderr}\n'
      'served ${cdn.served.values.fold<int>(0, (a, b) => a + b)} bytes, '
      'received ${proxy.downloader.stats.bytes} useful ${proxy.downloader.stats.useful}',
    );
    return result;
  }

  test(
    'ffmpeg decodes the whole video track',
    () async {
      final watch = Stopwatch()..start();
      final result = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-i',
        videoUrl,
        '-f',
        'null',
        '-',
      ]);
      // ignore: avoid_print
      print(
        'ffmpeg ${watch.elapsedMilliseconds} ms, exit ${result.exitCode}: ${result.stderr}\n'
        'served ${cdn.served} over ${cdn.requests} requests',
      );
      expect(result.exitCode, 0);
      expect((result.stderr as String).trim(), isEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'mpv plays both tracks from the start',
    () async {
      final result = await mpv(['--length=6']);
      expect(result.exitCode, 0);
      final out = '${result.stdout}${result.stderr}';
      expect(out, contains('(+) Video'));
      expect(out, contains('(+) Audio'));
      expect(out, isNot(contains('Failed')));
      expect(out, isNot(contains('error')));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'mpv starts in the middle and seeks back and forth',
    () async {
      final result = await mpv(
        ['--start=12'],
        script: '''
local t = 0
mp.add_timeout(2.5, function() mp.commandv("seek", "33", "absolute") end)
mp.add_timeout(5, function() mp.commandv("seek", "4", "absolute") end)
mp.add_timeout(7.5, function() mp.commandv("seek", "20", "absolute") end)
mp.add_timeout(10, function()
  print("POS " .. tostring(mp.get_property_number("time-pos")))
  mp.command("quit")
end)
''',
      );
      expect(result.exitCode, 0);
      final out = '${result.stdout}${result.stderr}';
      final pos = double.parse(RegExp(r'POS ([\d.]+)').firstMatch(out)![1]!);
      // Seeked to 20 s and played on for about two and a half seconds.
      expect(pos, greaterThan(20.5));
      expect(pos, lessThan(24));
      expect(out, isNot(contains('Failed')));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
