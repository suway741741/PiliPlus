import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:PiliPlus/services/thread_ripper/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// How one fake CDN node behaves.
enum Node { fast, normal, slow, refuse, hang, drop, wrongRange }

/// A fake Bilibili CDN: every host serves the same file, each in its own way.
class FakeCdn {
  FakeCdn(this.file, this.nodes);

  final Uint8List file;
  final Map<String, Node> nodes;
  final Map<String, int> requests = {};
  final Map<String, int> servedBytes = {};
  late HttpServer server;
  final List<HttpResponse> _hanging = [];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
  }

  Future<void> stop() async {
    for (final response in _hanging) {
      try {
        (await response.detachSocket()).destroy();
      } catch (_) {}
    }
    await server.close(force: true);
  }

  Uri rewrite(String url) {
    final uri = Uri.parse(url);
    return Uri.parse(
      'http://127.0.0.1:${server.port}/${uri.host}${uri.path}?${uri.query}',
    );
  }

  Future<void> _serve(HttpRequest request) async {
    final host = request.uri.pathSegments.first;
    requests[host] = (requests[host] ?? 0) + 1;
    final node = nodes[host] ?? Node.normal;
    final response = request.response;
    if (node == Node.refuse) {
      response.statusCode = 403;
      await response.close();
      return;
    }
    if (node == Node.hang) {
      _hanging.add(response);
      return;
    }
    final match = RegExp(
      r'bytes=(\d+)-(\d+)',
    ).firstMatch(request.headers.value('range') ?? '');
    if (match == null) {
      response.statusCode = 400;
      await response.close();
      return;
    }
    final start = int.parse(match[1]!);
    var end = int.parse(match[2]!);
    if (start >= file.length) {
      response
        ..statusCode = 416
        ..headers.set('content-range', 'bytes */${file.length}');
      await response.close();
      return;
    }
    end = math.min(end, file.length - 1);
    final shownStart = node == Node.wrongRange ? start + 1 : start;
    response
      ..statusCode = 206
      ..headers.set('content-range', 'bytes $shownStart-$end/${file.length}')
      ..contentLength = end - start + 1;
    final chunk = switch (node) {
      Node.slow => 8 * 1024,
      _ => 64 * 1024,
    };
    final delay = switch (node) {
      Node.slow => const Duration(milliseconds: 40),
      Node.normal => const Duration(milliseconds: 4),
      _ => Duration.zero,
    };
    try {
      var offset = start;
      while (offset <= end) {
        final to = math.min(end + 1, offset + chunk);
        if (node == Node.drop && offset - start > 100 * 1024) {
          (await response.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        response.add(Uint8List.sublistView(file, offset, to));
        await response.flush();
        servedBytes[host] = (servedBytes[host] ?? 0) + to - offset;
        offset = to;
        if (delay > Duration.zero) await Future.delayed(delay);
      }
      await response.close();
    } catch (_) {}
  }
}

class FakeTransport implements RipperTransport {
  FakeTransport(this.cdn)
    : inner = IoTransport(
        userAgent: 'test',
        referer: 'https://www.bilibili.com',
        rewrite: cdn.rewrite,
      );
  final FakeCdn cdn;
  final IoTransport inner;

  @override
  Future<RipperResponse> open(
    String url,
    int start,
    int end,
    CancelToken token,
  ) => inner.open(url, start, end, token);

  @override
  void close() => inner.close();
}

Uint8List makeFile(int length) {
  final random = math.Random(42);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

const _path =
    '/upgcxcode/42/00/123456/123456-1-30080.m4s?e=abc&deadline=9&upsig=x';

/// Reads a proxied address the way mpv does: `bytes=N-`, then on to the end.
Future<Uint8List> fetch(
  String url, {
  int start = 0,
  int? stopAfter,
  bool range = true,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    if (range) request.headers.set('range', 'bytes=$start-');
    final response = await request.close();
    expect(response.statusCode, range ? 206 : 200);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (stopAfter != null && builder.length >= stopAfter) break;
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('range core', () {
    test('parses ranges', () {
      expect(parseRangeHeader('bytes=10-'), (start: 10, end: null));
      expect(parseRangeHeader('bytes=10-20'), (start: 10, end: 20));
      expect(parseRangeHeader('bytes=20-10'), isNull);
      final range = parseContentRange('bytes 0-99/1000')!;
      expect((range.start, range.end, range.total), (0, 99, 1000));
      expect(parseContentRange('bytes 0-1000/1000'), isNull);
    });

    test('splits ranges evenly', () {
      final pieces = splitRange(0, 999999, 8, 64 * 1024);
      expect(pieces.length, 8);
      expect(pieces.first.start, 0);
      expect(pieces.last.end, 999999);
      for (var i = 1; i < pieces.length; i++) {
        expect(pieces[i].start, pieces[i - 1].end + 1);
      }
    });

    test('keeps custom hosts to Bilibili servers', () {
      expect(normalizeCdnHost('upos-sz-mirrorali.bilivideo.com'), isNotEmpty);
      expect(
        normalizeCdnHost('https://foo.akamaized.net/x'),
        'foo.akamaized.net',
      );
      expect(normalizeCdnHost('evil.example.com'), isEmpty);
    });
  });

  group('cdn resolver', () {
    test('spreads a signed address over the mainland nodes', () {
      final urls = representationUrls([
        'https://upos-sz-mirrorcos.bilivideo.com$_path',
        'https://cn-hk-eq-01-01.bilivideo.com$_path',
      ], RipperCdnMode.mainland);
      final hosts = urls.map(hostOf).toSet();
      expect(hosts, containsAll(mainlandHosts));
      expect(hosts.contains('cn-hk-eq-01-01.bilivideo.com'), isFalse);
      // The signature is kept byte for byte.
      expect(urls.every((url) => url.endsWith(_path)), isTrue);
    });

    test('overseas mode keeps overseas originals', () {
      final urls = representationUrls([
        'https://upos-sz-mirrorcos.bilivideo.com$_path',
        'https://upos-hz-mirrorakam.akamaized.net$_path',
      ], RipperCdnMode.overseas);
      final hosts = urls.map(hostOf).toSet();
      expect(hosts, containsAll(overseasHosts));
      expect(hosts.contains('upos-hz-mirrorakam.akamaized.net'), isTrue);
      expect(hosts.contains('upos-sz-mirrorcos.bilivideo.com'), isFalse);
    });

    test('relay-only tracks keep their relays', () {
      const relay =
          'https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/1/2-30080.m4s?os=mcdn';
      expect(representationUrls([relay], RipperCdnMode.mainland), [relay]);
    });

    test('drops non-media addresses', () {
      expect(
        representationUrls([
          'http://1.2.3.4:4483/v1/resource/x.m4s',
        ], .mainland),
        isEmpty,
      );
    });

    test('bans a node that refuses addresses others serve', () {
      final bans = BanList();
      const a = 'https://upos-sz-mirrorali.bilivideo.com$_path';
      const b = 'https://upos-sz-mirrorbos.bilivideo.com$_path';
      bans
        ..success(a)
        ..record(b, 0, const RipperHttpError('403', 403))
        ..record(b, 0, const RipperHttpError('403', 403));
      expect(bans.allows(b), isFalse);
      expect(bans.allows(a), isTrue);
    });
  });

  group('proxy', () {
    late FakeCdn cdn;
    late RangeProxy proxy;
    final file = makeFile(9 * 1024 * 1024 + 12345);
    var settings = RipperSettings(concurrency: 16, autoConcurrency: false);

    Future<void> setUp0(Map<String, Node> nodes) async {
      cdn = FakeCdn(file, nodes);
      await cdn.start();
      proxy = RangeProxy(
        transport: FakeTransport(cdn),
        settings: () => settings,
      );
      await proxy.ensureStarted();
    }

    tearDown(() async {
      await proxy.close();
      await cdn.stop();
    });

    test('streams a whole track from many nodes, byte for byte', () async {
      await setUp0({
        'upos-sz-mirrorali.bilivideo.com': Node.fast,
        'upos-sz-mirrorhw.bilivideo.com': Node.slow,
        'upos-sz-mirrorbos.bilivideo.com': Node.refuse,
        'upos-sz-mirror08c.bilivideo.com': Node.hang,
        'upos-sz-mirrorbd.bilivideo.com': Node.drop,
        'upos-sz-mirror14b.bilivideo.com': Node.wrongRange,
      });
      final session = proxy.openSession();
      final url = session.register(
        ['https://upos-sz-mirrorcos.bilivideo.com$_path'],
        kind: 'video',
        bandwidth: 8 * 1024 * 1024 * 8 ~/ 10,
      )!;
      // Playing with nothing buffered: every piece has a deadline.
      proxy.clock.update(ahead: 0, active: true);
      final watch = Stopwatch()..start();
      final bytes = await fetch(url);
      watch.stop();
      expect(bytes.length, file.length);
      expect(bytes, equals(file));
      final used = cdn.servedBytes.keys.toSet();
      // ignore: avoid_print
      print('served by ${cdn.servedBytes} in ${watch.elapsedMilliseconds} ms');
      expect(used.length, greaterThan(2));
      expect(cdn.servedBytes['upos-sz-mirrorbos.bilivideo.com'], isNull);
      session.close();
    });

    test('serves a seek and a HEAD, and repeats from the cache', () async {
      await setUp0({});
      final session = proxy.openSession();
      final url = session.register(
        ['https://upos-sz-mirrorcos.bilivideo.com$_path'],
        kind: 'audio',
      )!;
      // mpv opens, reads the head, then seeks.
      final head = await fetch(url, stopAfter: 300 * 1024);
      expect(head.sublist(0, 300 * 1024), file.sublist(0, 300 * 1024));
      const seek = 5 * 1024 * 1024 + 777;
      final tail = await fetch(url, start: seek);
      expect(tail, equals(file.sublist(seek)));

      final client = HttpClient();
      final request = await client.headUrl(Uri.parse(url));
      final response = await request.close();
      expect(response.headers.contentLength, file.length);
      await response.drain<void>();
      client.close(force: true);

      final served = cdn.servedBytes.values.fold<int>(0, (a, b) => a + b);
      final again = await fetch(url, start: seek);
      expect(again, equals(file.sublist(seek)));
      final servedAgain = cdn.servedBytes.values.fold<int>(0, (a, b) => a + b);
      // Most of it came out of the cache.
      expect(servedAgain - served, lessThan(file.length - seek));

      final whole = await fetch(url, range: false);
      expect(whole, equals(file));
      session.close();
    });

    test('falls back to the original address when every node fails', () async {
      await setUp0({
        for (final host in mainlandHosts) host: Node.refuse,
      });
      final session = proxy.openSession();
      final url = session.register(
        [
          'https://upos-sz-mirrorcos.bilivideo.com$_path',
          'https://cn-sh-ct-01-01.bilivideo.com$_path',
        ],
        kind: 'video',
      )!;
      final bytes = await fetch(url);
      expect(bytes, equals(file));
      expect(cdn.servedBytes.keys, contains('cn-sh-ct-01-01.bilivideo.com'));
      session.close();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stops downloading when the player goes away', () async {
      settings = RipperSettings(concurrency: 8, autoConcurrency: true);
      await setUp0({
        for (final host in mainlandHosts) host: Node.slow,
        'upos-sz-mirrorcos.bilivideo.com': Node.slow,
      });
      final session = proxy.openSession();
      final url = session.register(
        ['https://upos-sz-mirrorcos.bilivideo.com$_path'],
        kind: 'video',
        bandwidth: 2 * 1024 * 1024 * 8,
      )!;
      await fetch(url, stopAfter: 64 * 1024);
      await Future.delayed(const Duration(milliseconds: 500));
      final served = cdn.servedBytes.values.fold<int>(0, (a, b) => a + b);
      await Future.delayed(const Duration(seconds: 1));
      final later = cdn.servedBytes.values.fold<int>(0, (a, b) => a + b);
      // ignore: avoid_print
      print('served $served, then ${later - served} more');
      expect(later - served, lessThan(256 * 1024));
      expect(served, lessThan(file.length));
      session.close();
      // A closed session no longer serves.
      final client = HttpClient();
      final response = await (await client.getUrl(Uri.parse(url))).close();
      expect(response.statusCode, 404);
      await response.drain<void>();
      client.close(force: true);
    });
  });
}
