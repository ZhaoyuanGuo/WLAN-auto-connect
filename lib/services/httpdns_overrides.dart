import 'dart:io';

import 'httpdns_config.dart';
import 'httpdns_service.dart';

/// 全局 HTTP 客户端工厂：为白名单域名按 IP 直连 + 手动 TLS 升级，
/// 其他域名走与 Dart 默认等价的路径。
///
/// 关键坑（对应 spec）：
/// - 坑 #1：`connectionFactory` 一旦被设置，Dart 内部对"直连 + https"**不再自动
///   TLS 升级**。我们必须自己 `Socket.connect(ip)` → `SecureSocket.secure(tcp, host: 域名)`
///   → `ConnectionTask.fromSocket`。因此 [createHttpClient] 里 fallback 分支也需要
///   手动做同样的事，否则 https 请求会失败。
/// - 坑 #2：`SecureSocket.secure(host:)` 只做 SNI + 证书名校验，不查 DNS；
///   所以按 IP connect 不会证书不匹配。
/// - 坑 #3：被固定的域名上 `client.badCertificateCallback` 不再被调用（预期行为）。
class HttpDnsOverrides extends HttpOverrides {
  HttpDnsOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory =
        _buildFactory(context ?? SecurityContext(withTrustedRoots: true));
    return client;
  }

  /// 生成一个 connectionFactory 闭包。
  ///
  /// 语义：
  /// - 有代理：走 `Socket.startConnect(proxyHost, proxyPort)`，让 HTTP 层的
  ///   CONNECT 隧道 + 后续 TLS 升级按 Dart 默认逻辑跑。
  /// - 无代理 + 域名不在白名单 / 已是 IP 字面量 / resolve 返回 null：
  ///   http 直连 → `Socket.startConnect`；https → `SecureSocket.startConnect`。
  /// - 无代理 + 命中缓存：按第一个 IP `Socket.startConnect` → https 场景下
  ///   `SecureSocket.secure(tcp, host: hostname)` 手动升级。
  _ConnectionFactory _buildFactory(SecurityContext ctx) {
    return (Uri uri, String? proxyHost, int? proxyPort) async {
      // 1. 代理：直接连代理服务器（默认行为），保持 CONNECT 隧道逻辑不变。
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
      }

      final host = uri.host;
      final port = uri.port;
      final isSecure = uri.scheme == 'https';

      // 2. 全局禁用 / 非白名单 / IP 字面量 → 与 Dart 默认路径等价。
      if (!HttpDnsConfig.enable ||
          HttpDnsService.isIpLiteral(host) ||
          !HttpDnsService.instance.isAccelerated(host)) {
        return _defaultConnect(host, port, isSecure, ctx);
      }

      // 3. 白名单域名：触发一次 resolve（内部包含缓存 / 单飞 / 入口轮转）。
      // resolve 返回 null 表示应回退 LocalDNS（DoH 挂 / 全入口挂 / 冷静期）。
      final ips = await HttpDnsService.instance.resolve(host);
      if (ips == null || ips.isEmpty) {
        return _defaultConnect(host, port, isSecure, ctx);
      }
      final ip = ips.first;

      // 4. 按 IP connect + 手动 TLS 升级（关键坑 #1）。
      final tcpTask =
          await Socket.startConnect(InternetAddress(ip), port);
      if (!isSecure) {
        return tcpTask;
      }
      final Future<Socket> secureFut = tcpTask.socket.then<Socket>(
        (tcp) => SecureSocket.secure(
          tcp,
          host: host, // 仅 SNI + 证书名校验，不查 DNS（坑 #2）
          context: ctx,
        ),
      );
      return ConnectionTask.fromSocket<Socket>(secureFut, tcpTask.cancel);
    };
  }

  /// 与 Dart 默认行为一致的非拦截路径。
  ///
  /// 注意：badCertificateCallback 由于 Dart 内部只在未设 connectionFactory 时
  /// 传给 SecureSocket.startConnect，本拦截路径无法透传（坑 #3）。本项目未使用
  /// badCertificateCallback，故可接受；如需支持自签证书，请在业务侧改为
  /// 自定义 `SecurityContext`。
  Future<ConnectionTask<Socket>> _defaultConnect(
      String host, int port, bool isSecure, SecurityContext ctx) {
    if (isSecure) {
      return SecureSocket.startConnect(host, port, context: ctx);
    }
    return Socket.startConnect(host, port);
  }
}

/// connectionFactory 的类型别名，保持签名与 dart:io 一致。
typedef _ConnectionFactory = Future<ConnectionTask<Socket>> Function(
  Uri url,
  String? proxyHost,
  int? proxyPort,
);
