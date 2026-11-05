import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/thread_ripper/range_core.dart';

/// The headers of one ranged GET, with its body still to come.
class RipperResponse {
  RipperResponse({
    required this.status,
    required this.contentRange,
    required this.body,
    required this.abort,
    required this.release,
  });

  final int status;
  final String? contentRange;
  final Stream<List<int>> body;

  /// Stops the transfer and drops its connection.
  final void Function() abort;

  /// The body was read to its end: stop watching the token, keep the connection.
  final void Function() release;
}

/// Where the downloader's requests go. The app uses [IoTransport]; tests put a fake CDN
/// behind it.
abstract class RipperTransport {
  /// Opens `GET url` with `Range: bytes=start-end`; completes once the headers are in.
  /// Cancelling [token] aborts the request.
  Future<RipperResponse> open(
    String url,
    int start,
    int end,
    CancelToken token,
  );

  void close();
}

class IoTransport implements RipperTransport {
  IoTransport({
    required this.userAgent,
    required this.referer,
    this.rewrite,
  }) : _client = HttpClient()
         ..autoUncompress = false
         ..idleTimeout = const Duration(seconds: 15)
         ..connectionTimeout = const Duration(seconds: 8);

  final String userAgent;
  final String referer;

  /// Maps an address to the one actually requested (tests only).
  final Uri Function(String url)? rewrite;
  final HttpClient _client;

  @override
  Future<RipperResponse> open(
    String url,
    int start,
    int end,
    CancelToken token,
  ) async {
    token.throwIfCancelled();
    final uri = rewrite?.call(url) ?? Uri.parse(url);
    final pending = _client.getUrl(uri);
    // The connection itself cannot be interrupted: a request that arrives after the token
    // was cancelled is aborted straight away.
    final request = await Future.any<HttpClientRequest?>([
      pending,
      token.whenCancelled.then((_) => null),
    ]);
    if (request == null) {
      pending.then((r) => r.abort(), onError: (_) {});
      throw token.reason;
    }
    request
      ..followRedirects = true
      ..maxRedirects = 5
      ..persistentConnection = true;
    request.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=$start-$end')
      ..set(HttpHeaders.userAgentHeader, userAgent)
      ..set(HttpHeaders.refererHeader, referer)
      ..set(HttpHeaders.acceptEncodingHeader, 'identity')
      ..set(HttpHeaders.acceptHeader, '*/*');
    final detach = token.onCancel(() => request.abort(token.reason));
    try {
      final response = await request.close();
      return RipperResponse(
        status: response.statusCode,
        contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
        body: response,
        abort: () {
          detach();
          request.abort();
        },
        release: detach,
      );
    } catch (error) {
      detach();
      if (token.isCancelled) throw token.reason;
      rethrow;
    }
  }

  @override
  void close() => _client.close(force: true);
}
