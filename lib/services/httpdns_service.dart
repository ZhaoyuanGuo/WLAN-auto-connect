import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'httpdns_config.dart';

/// 单条解析缓存。空 [ips] 表示负缓存（DoH 返回错误 / 无 Answer / 全入口挂）。
class _CacheEntry {
  _CacheEntry(this.ips, this.expireAt);
  final List<String> ips;
  final DateTime expireAt;
  bool get isNegative => ips.isEmpty;
}

/// DoH 底层查询函数签名（endpoint IP + 待解析域名 → 原始 JSON 响应体）。
///
/// 抽出为可注入函数便于测试 mock，避免走真实网络。
typedef DohQueryFn = Future<String> Function(String endpointIp, String host);

/// HTTPDNS 解析核心：缓存 + 单飞 + 入口轮转 + 冷静期回退。
///
/// 关键约束：
/// - 解析层内部 HttpClient 必须走独立 `connectionFactory`（[resolve] 中通过
///   [_queryOnce] 直连 DoH IP 完成 TLS 升级），否则会回调进 [HttpOverrides]
///   造成自锁（坑 #4）。
/// - 单飞表清理必须用代码块形式的 `.whenComplete(() { _pending.remove(h); })`，
///   箭头写法会把 remove() 返回的 Future（正是当前链）透传给 whenComplete 去
///   await → 永久死锁（坑 #6）。
/// - IP 字面量判定用字符串规则，不使用 `InternetAddress.tryParse`（阻塞 getaddrinfo，
///   坑 #5）。
class HttpDnsService {
  HttpDnsService();

  static final HttpDnsService instance = HttpDnsService();

  final Map<String, _CacheEntry> _cache = {};
  final Map<String, Future<void>> _pending = {};
  final Map<String, DateTime> _endpointBlacklist = {};
  DateTime? _allEndpointsCoolingUntil;
  int _rotation = 0;

  /// 测试注入点：替换真实 DoH 查询。
  @visibleForTesting
  DohQueryFn? queryOverride;

  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _pending.clear();
    _endpointBlacklist.clear();
    _allEndpointsCoolingUntil = null;
    _rotation = 0;
    queryOverride = null;
  }

  /// 仅用于测试：手工塞入缓存条目，观察 getCached 行为。
  @visibleForTesting
  void primeCache(String host, List<String> ips, DateTime expireAt) {
    _cache[host] = _CacheEntry(ips, expireAt);
  }

  /// 判断 [host] 是否为 IP 字面量（IPv4 点分十进制 或 含 `:` 的 IPv6）。
  ///
  /// **不能**用 `InternetAddress.tryParse`：它对 host 字符串会同步走 getaddrinfo
  /// 造成事件循环阻塞（坑 #5）。
  static bool isIpLiteral(String host) {
    if (host.contains(':')) return true; // IPv6
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
  }

  /// 域名是否在 HTTPDNS 加速白名单内。
  bool isAccelerated(String host) =>
      HttpDnsConfig.acceleratedHosts.contains(host.toLowerCase());

  /// 只读缓存查询；返回 null 表示无有效缓存（不存在或已过期）。
  ///
  /// 注意：命中负缓存也返回 null（ips 为空），但 [resolve] 内部靠
  /// [_hasFreshEntry] 区分"无记录"与"有负缓存"两种 null，避免重复发查询。
  List<String>? getCached(String host) {
    final e = _cache[host];
    if (e == null) return null;
    if (DateTime.now().isAfter(e.expireAt)) {
      _cache.remove(host);
      return null;
    }
    if (e.isNegative) return null;
    return e.ips;
  }

  /// 是否存在未过期的缓存条目（含负缓存）。resolve 用它抑制负缓存期间的重复查询。
  bool _hasFreshEntry(String host) {
    final e = _cache[host];
    if (e == null) return false;
    if (DateTime.now().isAfter(e.expireAt)) {
      _cache.remove(host);
      return false;
    }
    return true;
  }

  /// 主入口：给定 host 返回可使用的 IP 列表；返回 null 表示上层应回退 LocalDNS。
  Future<List<String>?> resolve(String host) async {
    if (!HttpDnsConfig.enable) return null;
    if (host.isEmpty) return null;
    if (isIpLiteral(host)) return null;
    if (!isAccelerated(host)) return null;

    final cached = getCached(host);
    if (cached != null) return cached;

    // 负缓存命中：刚查过且返回空/失败，短期内不再重复发起 DoH 请求。
    if (_hasFreshEntry(host)) return null;

    // 全入口冷静期：直接返回 null，让上层走本地 DNS。
    final cool = _allEndpointsCoolingUntil;
    if (cool != null && DateTime.now().isBefore(cool)) return null;

    // 单飞：同一 host 并发只发一次真实查询。
    var p = _pending[host];
    if (p == null) {
      // ⚠️ 坑 #6：whenComplete 必须写代码块，不能写箭头形式
      // `.whenComplete(() => _pending.remove(host))`。箭头会返回 remove() 的
      // Future（正是当前链自身），whenComplete 去 await 它 → 永久死锁。
      p = _doQuery(host).whenComplete(() {
        _pending.remove(host);
      });
      _pending[host] = p;
    }
    await p;
    return getCached(host);
  }

  Future<void> _doQuery(String host) async {
    final endpoints = _availableEndpoints();
    if (endpoints.isEmpty) {
      _enterGlobalCooldown();
      _negCache(host);
      return;
    }
    for (var i = 0; i < endpoints.length; i++) {
      final idx = (_rotation + i) % endpoints.length;
      final ip = endpoints[idx];
      try {
        final body = queryOverride != null
            ? await queryOverride!(ip, host)
            : await _queryOnce(ip, host);
        final entry = _parseResponse(body);
        _cache[host] = entry;
        // 成功入口作为下一次起点：轮转位置指向下一个候选，分散负载。
        _rotation = (idx + 1) % endpoints.length;
        return;
      } catch (_) {
        _endpointBlacklist[ip] = DateTime.now().add(
          const Duration(seconds: HttpDnsConfig.badEndpointCooldownSeconds),
        );
      }
    }
    // 全部入口失败：进入冷静期 + 短期负缓存。
    _enterGlobalCooldown();
    _negCache(host);
  }

  List<String> _availableEndpoints() {
    final now = DateTime.now();
    return HttpDnsConfig.dohEndpoints.where((ip) {
      final b = _endpointBlacklist[ip];
      return b == null || !now.isBefore(b);
    }).toList();
  }

  void _enterGlobalCooldown() {
    _allEndpointsCoolingUntil = DateTime.now().add(
      const Duration(seconds: HttpDnsConfig.allEndpointsCooldownSeconds),
    );
  }

  void _negCache(String host) {
    _cache[host] = _CacheEntry(
      const [],
      DateTime.now().add(
        const Duration(seconds: HttpDnsConfig.negativeTtlSeconds),
      ),
    );
  }

  /// 解析 DoH JSON 响应。
  ///
  /// 顶层格式：`{"Status":0,"Answer":[{"name","type","TTL","data"}]}`；
  /// 顶层**没有** TTL，取所有 Answer 条目 TTL 的最小值再 clamp（坑 #9）。
  /// 只保留 `type == 1`(A) 或 `type == 28`(AAAA)。
  _CacheEntry _parseResponse(String body) {
    final Map<String, dynamic> obj;
    try {
      obj = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return _CacheEntry(
        const [],
        DateTime.now().add(
          const Duration(seconds: HttpDnsConfig.negativeTtlSeconds),
        ),
      );
    }
    final status = (obj['Status'] as num?)?.toInt() ?? -1;
    if (status != 0) {
      return _CacheEntry(
        const [],
        DateTime.now().add(
          const Duration(seconds: HttpDnsConfig.negativeTtlSeconds),
        ),
      );
    }
    final answers = obj['Answer'];
    if (answers is! List || answers.isEmpty) {
      return _CacheEntry(
        const [],
        DateTime.now().add(
          const Duration(seconds: HttpDnsConfig.negativeTtlSeconds),
        ),
      );
    }
    final ips = <String>[];
    var minTtl = HttpDnsConfig.maxTtlSeconds;
    for (final raw in answers) {
      if (raw is! Map) continue;
      final type = (raw['type'] as num?)?.toInt() ?? 0;
      if (type != 1 && type != 28) continue;
      final data = raw['data'];
      if (data is! String || data.isEmpty) continue;
      final ttl = (raw['TTL'] as num?)?.toInt() ?? HttpDnsConfig.minTtlSeconds;
      if (ttl < minTtl) minTtl = ttl;
      ips.add(data);
    }
    if (ips.isEmpty) {
      return _CacheEntry(
        const [],
        DateTime.now().add(
          const Duration(seconds: HttpDnsConfig.negativeTtlSeconds),
        ),
      );
    }
    final clamped = minTtl.clamp(
      HttpDnsConfig.minTtlSeconds,
      HttpDnsConfig.maxTtlSeconds,
    );
    return _CacheEntry(
      List.unmodifiable(ips),
      DateTime.now().add(Duration(seconds: clamped)),
    );
  }

  /// 真实 DoH 请求：走独立 HttpClient，其 connectionFactory 按 IP 直连 + SNI
  /// 升级 TLS，绝不回调进 [HttpDnsOverrides]（否则会自锁，坑 #4）。
  Future<String> _queryOnce(String endpointIp, String host) async {
    final client = _buildRawClient();
    final timeout =
        const Duration(seconds: HttpDnsConfig.requestTimeoutSeconds);
    try {
      // 内部 client 的 connectionFactory：按 DoH 入口 IP 直连 + 手动 TLS 升级。
      // 关键点：这里的 factory 不再调用 resolve()，因此不会与本类的 outer
      // HttpOverrides 形成回环（坑 #4）。
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        final connectPort = proxyPort ?? uri.port;
        final tcpTask = await Socket.startConnect(
            InternetAddress(endpointIp), connectPort);
        final isSecure = uri.scheme == 'https';
        final Future<Socket> sockFut = tcpTask.socket.then<Socket>(
          (tcp) => isSecure
              ? SecureSocket.secure(
                  tcp,
                  host: HttpDnsConfig.dohSniHost,
                  // context=null → 使用系统信任库；host=doh.pub → SNI + 证书名校验
                  // 不查 DNS（坑 #2）
                )
              : tcp,
        );
        // tcpTask.cancel 透传：上层若取消请求，能中断底层 connect。
        return ConnectionTask.fromSocket<Socket>(sockFut, tcpTask.cancel);
      };
      client.findProxy = (_) => 'DIRECT';
      client.connectionTimeout = timeout;

      final uri = Uri.https(HttpDnsConfig.dohSniHost, HttpDnsConfig.dohPath,
          {'name': host, 'type': 'A'});
      final req = await client.openUrl('GET', uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      req.headers.set(HttpHeaders.hostHeader, HttpDnsConfig.dohSniHost);
      final resp = await req.close().timeout(timeout);
      final bodyStr =
          await resp.transform(utf8.decoder).join().timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('DoH status ${resp.statusCode}', uri: uri);
      }
      return bodyStr;
    } finally {
      client.close(force: true);
    }
  }

  /// 通过继承一个空的 [HttpOverrides] 并调用其基类 `createHttpClient`，
  /// 拿到一个不受当前全局 HttpOverrides 影响的原始 HttpClient。
  /// （否则我们会在自己的 overrides 里再套自己 → 自锁。）
  HttpClient _buildRawClient() => _RawBypassOverrides().createHttpClient(null);
}

/// 空实现，专用于绕过 [HttpOverrides.global]，
/// 让 [HttpDnsService] 内部 DoH 请求拿到"裸"的 HttpClient 实例。
class _RawBypassOverrides extends HttpOverrides {}
