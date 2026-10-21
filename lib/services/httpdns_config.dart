/// HTTPDNS（腾讯云 DoH JSON 通道）配置中心。
///
/// 决策前提：本项目是纯 Dart/Flutter，不引原生 AAR/pod，因此只走 DoH JSON：
/// `https://doh.pub/dns-query?name=<host>&type=A`，按 IP `1.12.12.12` /
/// `120.53.53.53` 直连 + SNI 证书名校验（`CN=*.doh.pub`），零凭证。
///
/// 明文 `/d` 通道（`http://119.29.29.98/d`）已实测返回 200 空体，不再挂载；
/// HTTPS Token 通道需 `token=` 参数且未带 token 也返回 401，不引 SDK 时不用。
class HttpDnsConfig {
  HttpDnsConfig._();

  /// 编译期开关：CI / 调试可通过 `--dart-define=HTTPDNS_ENABLE=false` 关闭，
  /// 关闭后所有白名单域名回退到 LocalDNS。
  static const enable =
      bool.fromEnvironment('HTTPDNS_ENABLE', defaultValue: true);

  /// DoH 入口 IP（主、备交替使用）。
  static const dohEndpoints = <String>['1.12.12.12', '120.53.53.53'];

  /// 上述 IP 对应的 TLS SNI + 证书名校验域名。
  ///
  /// 关键：`SecureSocket.secure(host:)` 只做 SNI 与证书名校验，不查 DNS，
  /// 因此按 IP connect 后仍能匹配 `*.doh.pub` 证书（坑 #2）。
  static const dohSniHost = 'doh.pub';

  /// DoH JSON 查询路径。
  static const dohPath = '/dns-query';

  /// 腾讯云 AccountId：仅原生 SDK 通道需要，DoH 路径不使用。此处保留作文档说明。
  static const accountId = '8859';

  /// HTTPS Token 仅当未来引原生 SDK 时才需要。**绝不写进仓库**，
  /// 只允许 `--dart-define=HTTPDNS_TOKEN=<TOKEN>` 注入；本项目走 DoH，此常量始终为空。
  static const httpsToken =
      String.fromEnvironment('HTTPDNS_TOKEN', defaultValue: '');

  /// 需要 HTTPDNS 加速的域名集合（不在其中的域名一律走 LocalDNS 直连）。
  static const acceleratedHosts = <String>{
    'auth.suspect.top',
    'wlan-sync.suspect.top',
  };

  /// 正向缓存 TTL 下限（秒）。
  static const minTtlSeconds = 60;

  /// 正向缓存 TTL 上限（秒），30 分钟。
  static const maxTtlSeconds = 30 * 60;

  /// 负缓存时长（秒）：DoH 返回空/异常时短期不重查。
  static const negativeTtlSeconds = 15;

  /// 单个 DoH 入口连续失败后的拉黑时长（秒）。
  static const badEndpointCooldownSeconds = 30;

  /// 全入口失败后的冷静期（秒），期间 resolve 直接返回 null 让上层走 LocalDNS。
  static const allEndpointsCooldownSeconds = 60;

  /// DoH 单次请求超时。
  static const requestTimeoutSeconds = 5;
}
