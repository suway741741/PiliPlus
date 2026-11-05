// Ported from Bilibili 线程撕裂者 (https://github.com/MrTangLuyao/Bilibili-thread-ripper,
// MIT), src/cdn-resolver.js.

import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:collection/collection.dart' show mergeSort;

const List<String> mainlandHosts = [
  'upos-sz-mirrorali.bilivideo.com',
  'upos-sz-mirrorhw.bilivideo.com',
  'upos-sz-mirrorbos.bilivideo.com',
  'upos-sz-mirror08c.bilivideo.com',
  'upos-sz-mirrorbd.bilivideo.com',
  'upos-sz-mirror14b.bilivideo.com',
  'upos-sz-estgoss.bilivideo.com',
  'upos-sz-mirrorcos.bilivideo.com',
  'upos-sz-mirrorcoso1.bilivideo.com',
];

const List<String> overseasHosts = [
  'upos-sz-mirrorcosov.bilivideo.com',
  'upos-sz-mirroraliov.bilivideo.com',
  'cn-hk-eq-01-01.bilivideo.com',
  'cn-hk-eq-01-03.bilivideo.com',
];

String hostOf(String value) => Uri.tryParse(value)?.host.toLowerCase() ?? '';

/// The signed address without its node: the same address can be asked of any node.
String addressOf(String value) {
  final url = Uri.tryParse(value);
  if (url == null) return '';
  return url.hasQuery ? '${url.path}?${url.query}' : url.path;
}

bool isAkamaiUrl(String value) => hostOf(value).endsWith('.akamaized.net');

/// A P2P or edge-cache relay (an mcdn node, or the mountaintoys.cn caches beside them)
/// wraps the file in its own path and signature. Its address works only on relays: every
/// ordinary node refuses it.
bool isRelayUrl(String value) {
  final url = Uri.tryParse(value);
  if (url == null) return false;
  return RegExp(r'(?:^|\.)mcdn\.', caseSensitive: false).hasMatch(url.host) ||
      RegExp(r'^/v1/resource/', caseSensitive: false).hasMatch(url.path) ||
      (url.queryParameters['os'] ?? '').toLowerCase() == 'mcdn';
}

String? safeMediaUrl(String? value) {
  if (value == null || value.isEmpty) return null;
  // The address is kept byte for byte: the signature covers it.
  return isBilibiliMediaUrl(value) ? value : null;
}

/// Moves a signed address onto another node. Only the authority changes; the path and
/// the query are kept byte for byte, since the signature covers them.
String? swapOrdinaryHost(
  String rawUrl,
  String targetHost, {
  bool allowAkamai = false,
}) {
  if (!allowAkamai && isAkamaiUrl(rawUrl)) return null;
  final host = targetHost.toLowerCase();
  if (normalizeCdnHost(host) != host) return null;
  if (!rawUrl.startsWith('https://')) return null;
  // Setting only the host name would keep a non-standard port, such as a peer CDN's
  // :4483, so the whole authority (and with it the port) is replaced.
  final slash = rawUrl.indexOf('/', 8);
  if (slash < 0) return null;
  return 'https://$host${rawUrl.substring(slash)}';
}

List<String> _unique(Iterable<String> values) {
  final seen = <String>{};
  return values.where(seen.add).toList();
}

/// The custom mode uses only the servers picked in the settings. Without any, it uses the
/// mainland node list.
List<String> _customServers(RipperCdnMode mode, List<String> customHosts) =>
    mode == RipperCdnMode.custom
    ? customHosts.map(normalizeCdnHost).where((e) => e.isNotEmpty).toList()
    : const [];

/// Every address a track can be downloaded from, in the given mode. [originals] are the
/// addresses Bilibili handed out: the base URL first, then the backups.
List<String> representationUrls(
  List<String> originalUrls,
  RipperCdnMode mode, [
  List<String> customHosts = const [],
]) {
  final originals = _unique(originalUrls.map(safeMediaUrl).nonNulls);
  final custom = _customServers(mode, customHosts);
  final hosts = custom.isNotEmpty
      ? custom
      : mode == RipperCdnMode.overseas
      ? overseasHosts
      : mainlandHosts;
  // A relay address moved to an ordinary node is refused there, so only ordinary addresses
  // are moved to the other nodes.
  final ordinary = originals.where((url) => !isRelayUrl(url)).toList();
  final donor = ordinary.where((url) => !isAkamaiUrl(url)).firstOrNull;
  // Some overseas accounts are given nothing but akamaized.net addresses. The nodes accept
  // those signatures too, so only in that case the akamaized.net addresses are the donors.
  // Bilibili may hand out an address that every node refuses (HTTP 403) next to one that
  // works, so each of them is tried; the ban list drops the refused one. Node-major order
  // puts every address in the first few requests.
  final synthetic =
      (donor != null
              ? hosts.map((host) => swapOrdinaryHost(donor, host))
              : hosts.expand(
                  (host) => ordinary.map(
                    (url) => swapOrdinaryHost(url, host, allowAkamai: true),
                  ),
                ))
          .map(safeMediaUrl)
          .nonNulls;
  final allowedOriginals = custom.isNotEmpty
      ? originals.where((url) => custom.contains(hostOf(url)))
      : mode == RipperCdnMode.overseas
      ? originals.where((url) => !mainlandHosts.contains(hostOf(url)))
      : originals.where((url) => mainlandHosts.contains(hostOf(url)));
  // Bilibili sometimes hands a track out only through relays. No other node can serve it
  // then, so the relays are used whatever the mode, rather than giving the video up.
  final relays = ordinary.isNotEmpty ? const <String>[] : originals;
  return _unique([...allowedOriginals, ...synthetic, ...relays]);
}

typedef BanListener = void Function(
  String target,
  int strikes,
  Object? error,
  String kind,
);

/// A CDN node that twice fails without sending a single byte is skipped for the rest of
/// the current video.
///
/// HTTP 4xx means the node answered and refused the signed address, and either side can be
/// at fault: a node may lack the file, or Bilibili may have handed out an address that
/// every node refuses. What has delivered data decides it. Refused by a node that serves
/// other addresses, the address is dropped; refused where other nodes serve it, the node
/// is. With neither known yet, the reply counts against nobody until one of them delivers.
class BanList {
  BanList({int limit = 2, this.onBan}) : limit = limit < 1 ? 1 : limit;

  final int limit;
  final BanListener? onBan;
  final Map<String, int> _emptyReplies = {};
  final Set<String> _goodNodes = {};
  final Set<String> _goodAddresses = {};
  final Set<String> _reported = {};
  Set<String> _banned = {};

  bool _judge(String url, Object? error) {
    final strikes = <String, int>{};
    _emptyReplies.forEach((key, count) {
      final parts = key.split('\n');
      final node = parts[0], address = parts[1], refused = parts[2];
      // A node that serves other addresses and refuses one that other nodes serve loses only
      // that pair; it is often the fastest node for the addresses it does serve.
      final String blamed;
      if (refused.isEmpty) {
        blamed = 'node:$node';
      } else if (_goodNodes.contains(node)) {
        blamed = _goodAddresses.contains(address)
            ? 'pair:$node $address'
            : 'address:$address';
      } else {
        blamed = _goodAddresses.contains(address) ? 'node:$node' : '';
      }
      if (blamed.isNotEmpty) strikes[blamed] = (strikes[blamed] ?? 0) + count;
    });
    _banned = {
      for (final entry in strikes.entries)
        if (entry.value >= limit) entry.key,
    };
    var added = false;
    for (final key in _banned) {
      if (!_reported.add(key)) continue;
      added = true;
      final isNode = key.startsWith('node:');
      try {
        onBan?.call(
          isNode ? key.substring(5) : hostOf(url),
          strikes[key]!,
          error,
          isNode ? 'node' : 'address',
        );
      } catch (_) {}
    }
    return added;
  }

  bool record(String url, int receivedBytes, Object? error) {
    if (isAbort(error) || receivedBytes > 0) return false;
    final node = hostOf(url);
    if (node.isEmpty) return false;
    final status = error is RipperHttpError ? error.status : 0;
    final key =
        '$node\n${addressOf(url)}\n${status >= 400 && status < 500 ? 'refused' : ''}';
    _emptyReplies[key] = (_emptyReplies[key] ?? 0) + 1;
    return _judge(url, error);
  }

  void success(String url) {
    final node = hostOf(url);
    final address = addressOf(url);
    if (node.isEmpty ||
        (_goodNodes.contains(node) && _goodAddresses.contains(address))) {
      return;
    }
    _goodNodes.add(node);
    _goodAddresses.add(address);
    _judge(url, null);
  }

  bool allows(String url) =>
      !_banned.contains('node:${hostOf(url)}') &&
      !_banned.contains('address:${addressOf(url)}') &&
      !_banned.contains('pair:${hostOf(url)} ${addressOf(url)}');
  bool allowsNode(String url) => !_banned.contains('node:${hostOf(url)}');
  bool allowsAddress(String url) =>
      !_banned.contains('address:${addressOf(url)}');
  List<String> get bannedHosts => [
    for (final key in _banned)
      if (key.startsWith('node:')) key.substring(5),
  ];

  void reset() {
    _emptyReplies.clear();
    _goodNodes.clear();
    _goodAddresses.clear();
    _reported.clear();
    _banned = {};
  }
}

/// How long a measured speed counts. A node in use is measured again with every segment;
/// one that was left out for being slow goes back to the untested ones after this, and
/// gets another try through the exploration slot.
const double measurementTtlMs = 90000;

class _Health {
  _Health({this.lastSuccessAt = 0});
  int failures = 0;
  double blockedUntil = 0;
  double lastSuccessAt;
}

class _Route {
  _Route({this.lastSuccessAt = 0, this.lastMeasuredAt = 0, this.bps = 0});
  double lastSuccessAt;
  double lastMeasuredAt;
  double bps;
}

class NodeStatus {
  const NodeStatus(this.host, this.state, this.bps);
  final String host;

  /// banned / blocked / healthy / untested
  final String state;
  final double bps;
}

/// Picks and orders the addresses of one track, learning each node's speed as it goes.
class CdnResolver {
  CdnResolver(
    this.originals,
    this.getSettings, [
    this.bans,
  ]);

  /// The addresses Bilibili handed out: base URL first, then the backups.
  final List<String> originals;
  final RipperSettings Function() getSettings;
  final BanList? bans;

  final Map<String, _Health> _health = {};
  // What is known about a node's speed, per node and file, without the query. An address
  // with a fresh signature is the same route, so it starts with what its predecessor
  // measured. Failures are not kept here: those belong to the address they happened on.
  final Map<String, _Route> _routes = {};
  final Map<String, String> _routeKeys = {};
  int _cursor = 0;
  int _mediaRangeCount = 0;
  int _rangeCursor = 0;

  String _routeOf(String url) {
    var key = _routeKeys[url];
    if (key == null) {
      final parsed = Uri.tryParse(url);
      key = parsed == null ? url : '${parsed.authority}${parsed.path}';
      if (_routeKeys.length > 512) _routeKeys.clear();
      _routeKeys[url] = key;
    }
    return key;
  }

  _Route? _measurement(String url) => _routes[_routeOf(url)];

  // Only a transfer long enough to measure a speed renews it. The short tail of a resumed
  // piece proves the node works, and must not keep an old speed alive for ever.
  bool _measuredNow(String url, [double? now]) {
    final item = _measurement(url);
    now ??= nowMs();
    return item != null &&
        item.lastMeasuredAt > 0 &&
        now - item.lastMeasuredAt < measurementTtlMs;
  }

  int _bySpeed(String a, String b) {
    final am = _measurement(a);
    final bm = _measurement(b);
    final aSuccess = (am?.lastSuccessAt ?? 0) > 0 ? 1 : 0;
    final bSuccess = (bm?.lastSuccessAt ?? 0) > 0 ? 1 : 0;
    if (bSuccess != aSuccess) return bSuccess - aSuccess;
    return (bm?.bps ?? 0).compareTo(am?.bps ?? 0);
  }

  double _blockedUntil(String url) => _health[url]?.blockedUntil ?? 0;

  List<String> _allUrls() {
    final settings = getSettings();
    return representationUrls(originals, settings.mode, settings.customHosts);
  }

  // Banned nodes, addresses and node/address pairs are left out. If everything is banned,
  // keep using the full list rather than leaving the video with no download address.
  List<String> _unbanned(List<String> list) {
    final bans = this.bans;
    if (bans == null) return list;
    final allowed = list.where(bans.allows).toList();
    return allowed.isNotEmpty ? allowed : list;
  }

  List<String> urls() => _unbanned(_allUrls());

  List<String> ordered([int pieceIndex = 0, Set<String> exclude = const {}]) {
    final now = nowMs();
    final candidates = urls().where((url) => !exclude.contains(url)).toList();
    final available = candidates
        .where((url) => _blockedUntil(url) <= now)
        .toList();
    final pool = available.isNotEmpty ? available : candidates;
    if (pool.isEmpty) return [];
    final offset = (_cursor + pieceIndex) % pool.length;
    final rotated = [...pool.sublist(offset), ...pool.sublist(0, offset)];
    _cursor = (_cursor + 1) % pool.length;
    return rotated;
  }

  List<String> rangeCandidates() {
    final now = nowMs();
    final pool = urls().where((url) => _blockedUntil(url) <= now).toList();
    // Stable, like the original's Array.prototype.sort.
    mergeSort(pool, compare: _bySpeed);
    if (pool.isEmpty) return urls();
    final firstRange = _mediaRangeCount == 0;
    final width = firstRange
        ? pool.length
        : (pool.length < 6 ? pool.length : 6);
    List<String> selected;
    final warmupRanges = getSettings().mode == RipperCdnMode.mainland ? 1 : 4;
    if (_mediaRangeCount < warmupRanges) {
      selected = pool.sublist(0, width);
      _rangeCursor = width % pool.length;
    } else {
      // After the warm-up the measured nodes carry the segments in speed order; the
      // downloader gives the fast ones the larger share. One other node rides along per
      // segment: one that never answered, or one whose measurement has gone stale because
      // it was too slow to be used. Routes change, so a slow node is not slow for good.
      final measured = pool.where((url) => _measuredNow(url, now)).toList();
      final rest = pool.where((url) => !_measuredNow(url, now)).toList();
      final want = width - measured.length < 1 ? 1 : width - measured.length;
      final places = rest.length < want ? rest.length : want;
      final explore = [
        for (var index = 0; index < places; index += 1)
          rest[(_rangeCursor + index) % rest.length],
      ];
      _rangeCursor = (_rangeCursor + places) % (pool.isEmpty ? 1 : pool.length);
      final keep = width - explore.length;
      selected = [
        ...measured.take(keep < 0 ? 0 : keep),
        ...explore,
      ];
      final minimum = pool.length < 3 ? pool.length : 3;
      for (final url in pool) {
        if (selected.length >= minimum) break;
        if (!selected.contains(url)) selected.add(url);
      }
    }
    _mediaRangeCount += 1;
    return selected;
  }

  List<String> startupCandidates() {
    final now = nowMs();
    final settings = getSettings();
    // The first request also races the addresses Bilibili handed out, except in the custom
    // mode, which keeps to the picked servers.
    final own = _customServers(settings.mode, settings.customHosts).isNotEmpty
        ? const <String>[]
        : originals.map(safeMediaUrl).nonNulls;
    final candidates = _unbanned(
      _unique([...own, ..._allUrls()]),
    ).where((url) => _blockedUntil(url) <= now).toList();
    return candidates.take(8).toList();
  }

  List<String> rescueCandidates() {
    final now = nowMs();
    final pool = urls().where((url) => _blockedUntil(url) <= now).toList();
    mergeSort(pool, compare: _bySpeed);
    return pool;
  }

  void success(String url, double bps) {
    bans?.success(url);
    final old = _measurement(url);
    final now = nowMs();
    final measured = bps > 0;
    _health[url] = _Health(lastSuccessAt: now);
    _routes[_routeOf(url)] = _Route(
      lastSuccessAt: now,
      // No speed comes with a transfer too short to measure one; the last one stays, and
      // keeps its age.
      lastMeasuredAt: measured ? now : (old?.lastMeasuredAt ?? 0),
      bps: !measured
          ? (old?.bps ?? 0)
          : (old != null && old.bps > 0)
          ? old.bps * 0.65 + bps * 0.35
          : bps,
    );
  }

  /// The speed of a transfer that was cut off before its end. It says how fast the node
  /// is and nothing more: the address has not proven itself, and earlier failures stay.
  void sample(String url, double bps) {
    if (!(bps > 0)) return;
    final old = _measurement(url);
    _routes[_routeOf(url)] = _Route(
      lastSuccessAt: old?.lastSuccessAt ?? 0,
      lastMeasuredAt: nowMs(),
      bps: (old != null && old.bps > 0) ? old.bps * 0.65 + bps * 0.35 : bps,
    );
  }

  void failure(String url, Object? error, [int receivedBytes = 0]) {
    if (isAbort(error)) return;
    bans?.record(url, receivedBytes, error);
    final old = _health[url] ?? _Health();
    final failures = old.failures + 1;
    final backoff = 3000 * (1 << (failures < 4 ? failures : 4));
    old
      ..failures = failures
      ..blockedUntil = nowMs() + (backoff < 60000 ? backoff : 60000);
    _health[url] = old;
  }

  List<NodeStatus> status() {
    final now = nowMs();
    // A refused address says nothing about its node, so it is left out of the node list.
    final all = _allUrls();
    final usable = bans == null ? all : all.where(bans!.allowsAddress).toList();
    final list = usable.isNotEmpty ? usable : all;
    final seen = <String>{};
    return [
      for (final url in list)
        if (seen.add(hostOf(url)))
          NodeStatus(
            hostOf(url),
            bans != null && !bans!.allowsNode(url)
                ? 'banned'
                : _blockedUntil(url) > now
                ? 'blocked'
                : (_measurement(url)?.lastSuccessAt ?? 0) > 0
                ? 'healthy'
                : 'untested',
            _measurement(url)?.bps ?? 0,
          ),
    ];
  }

  bool allows(String url) => bans == null || bans!.allows(url);

  /// The measured download speed of an address, for weighting piece assignments. 0 when
  /// there is none or it has gone stale.
  double speed(String url) =>
      _measuredNow(url) ? (_measurement(url)?.bps ?? 0) : 0;
}
