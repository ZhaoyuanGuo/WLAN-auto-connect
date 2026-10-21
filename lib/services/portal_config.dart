/// Dr.COM / 哆点 eportal v4 认证协议的权威常量定义。
///
/// 三端（Dart / Kotlin / PowerShell）各自实现同一协议，此文件为 Dart 侧的
/// 单一常量源；Kotlin 与 PS 侧对应的常量位置见各自文件顶部注释：
/// - Android：android/.../CampusLogin.kt（DEFAULT_HOST / DEFAULT_EPORT）
/// - Windows：assets/AutoLogin.ps1（$script:Host_ / $script:EPort）
///
/// 协议变更时必须同步三处，并更新 test/portal_client_test.dart 的断言。
class PortalConfig {
  PortalConfig._();

  /// 默认认证门户 IP（各校不同，可在应用内设置页修改）。
  static const defaultHost = '172.16.200.11';

  /// 默认 eportal 服务端口。
  static const defaultEport = 801;

  /// 门户在线状态查询路径（JSONP，result==1 表示在线）。
  static const chkStatusPath = '/drcom/chkstatus';

  /// eportal v4 登录路径。
  static const loginPath = '/eportal/portal/login';

  /// 用于触发 AC 劫持、抓取会话参数的探测地址。
  static const hijackProbeUrl =
      'http://www.msftconnecttest.com/connecttest.txt';

  /// 校验用户输入的 host 是否合法（IPv4 或域名，不含协议与路径）。
  static bool isValidHost(String host) {
    final h = host.trim();
    if (h.isEmpty || h.contains('/') || h.contains(' ')) return false;
    if (h.contains(':')) return false; // 端口需单独填写
    // IPv4 或域名
    final ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    if (ipv4.hasMatch(h)) {
      return h.split('.').every((p) {
        final n = int.tryParse(p);
        return n != null && n >= 0 && n <= 255;
      });
    }
    return RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$').hasMatch(h);
  }

  /// 校验端口是否合法（1-65535）。
  static bool isValidEport(int eport) => eport >= 1 && eport <= 65535;
}
