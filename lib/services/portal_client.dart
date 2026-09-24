import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gbk_codec/gbk_codec.dart';

/// Dr.COM（哆点）eportal v4 认证协议客户端。
///
/// 协议要点（通过抓取门户页面 JS 分析得出）：
/// - 在线状态：`GET http://<host>/drcom/chkstatus?callback=dr1&jsVersion=4.X`
///   返回 JSONP，`result==1` 表示在线。
/// - 登录：`GET http://<host>:801/eportal/portal/login`，
///   `user_account = 账号 + 运营商后缀`（2026-09-24 实测：裸账号直接登录成功，
///   带 ",0," 前缀或运营商后缀反而返回"账号不存在"），
///   `login_method=1`，认证服务器按请求源 IP 识别用户。
/// - 未认证时，任意外网 HTTP 请求会被 AC 劫持（302 或 DNS 劫持）到门户页，
///   重定向 URL 中携带本会话的 `wlanusermac / wlanuserip / wlanacname / ssid`。
class PortalClient {
  PortalClient({
    this.host = '172.16.200.11',
    this.eport = 801,
    this.timeout = const Duration(seconds: 8),
  });

  final String host;
  final int eport;
  final Duration timeout;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// chkstatus 返回的 ss5（门户眼中本机 IP）/ ss1（本机 MAC），
  /// 作为登录会话参数的可靠来源（多网卡时本地猜 IP 会选错网卡）。
  String _chkIp = '';
  String _chkMac = '';

  /// 关闭底层连接。
  void dispose() => _http.close();

  /// 解析 JSONP 文本为 JSON 对象。
  static Map<String, dynamic>? parseJsonp(String text) {
    final s = text.indexOf('(');
    final e = text.lastIndexOf(')');
    if (s < 0 || e <= s) return null;
    try {
      final obj = jsonDecode(text.substring(s + 1, e));
      return obj is Map<String, dynamic> ? obj : null;
    } catch (_) {
      return null;
    }
  }

  /// GET 请求（禁止自动重定向），返回 `(statusCode, body, location)`，
  /// 失败时 statusCode 为 null。
  /// 响应解码 UTF-8 优先（2026-09-24 实测门户按 UTF-8 返回，GBK 直解
  /// 中文 msg 会变乱码），无效 UTF-8 时回退 GBK。
  Future<(int?, String, String)> _get(String url, {Duration? timeout}) async {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      req.followRedirects = false;
      req.maxRedirects = 0;
      final resp = await req.close().timeout(timeout ?? this.timeout);
      final bytes = await resp.fold<List<int>>(
          <int>[], (acc, chunk) => acc..addAll(chunk));
      String body;
      try {
        body = utf8.decode(bytes);
      } catch (_) {
        body = gbk.decode(bytes);
      }
      return (
        resp.statusCode,
        body,
        resp.headers.value(HttpHeaders.locationHeader) ?? ''
      );
    } catch (_) {
      return (null, '', '');
    }
  }

  /// 查询在线状态：true 在线 / false 未认证 / null 门户不可达。
  /// 顺带缓存 ss5/ss1（门户眼中本机 IP/MAC，即使 result=0 也会返回）。
  Future<bool?> checkOnline() async {
    final url = 'http://$host/drcom/chkstatus?callback=dr1&jsVersion=4.X';
    final (code, body, _) = await _get(url, timeout: const Duration(seconds: 5));
    if (code == null) return null;
    final json = parseJsonp(body);
    if (json == null) return null;
    final ss5 = json['ss5']?.toString() ?? '';
    final ss1 = json['ss1']?.toString() ?? '';
    if (ss5.isNotEmpty && ss5 != '-') _chkIp = ss5;
    if (ss1.isNotEmpty && ss1 != '-') _chkMac = ss1;
    return json['result']?.toString() == '1';
  }

  /// 从 AC 劫持响应中提取本会话参数（wlanusermac/ip/acname/ssid）。
  Future<Map<String, String>> captureHijackParams() async {
    final (code, body, location) = await _get(
        'http://www.msftconnecttest.com/connecttest.txt',
        timeout: const Duration(seconds: 6));
    if (code == null) return {};
    String? candidate;
    final locMatch =
        RegExp('a79\\.htm|${RegExp.escape(host)}').hasMatch(location);
    if (code >= 300 && code < 400 && location.isNotEmpty && locMatch) {
      candidate = location;
    } else {
      final m = RegExp('http://${RegExp.escape(host)}/[^\\s"\'<>]+')
          .firstMatch(body);
      if (m != null) candidate = m.group(0);
    }
    if (candidate == null) return {};

    final result = <String, String>{};
    for (final key in ['wlanusermac', 'wlanuserip', 'wlanacname', 'ssid']) {
      final m = RegExp('$key=([^&\\s]+)').firstMatch(candidate);
      if (m != null) result[key] = Uri.decodeComponent(m.group(1)!);
    }
    return result;
  }

  /// 发起登录请求。返回 `(ok, msg)`，msg 为门户返回码或成功标记。
  Future<(bool, String)> login(
    String account,
    String password,
    String suffix,
    Map<String, String> session,
  ) async {
    // 会话参数优先级：AC 劫持 > chkstatus 的 ss5/ss1 > 本机网卡。
    // 实测（2026-09-24）：插着有线网卡时劫持抓不到参数，localIPv4()
    // 会选错网卡，门户返回 ret_code=8「Portal协议认证超时」。
    final mac = session['wlanusermac'] ?? _chkMac;
    final ip = session['wlanuserip'] ?? (_chkIp.isNotEmpty ? _chkIp : await localIPv4() ?? '');
    final acname = session['wlanacname'] ?? '';
    // 实测裸账号可登录；",0," 前缀会被服务器判定为账号不存在。
    final userAccount = '$account$suffix';
    final v = 500 + DateTime.now().millisecondsSinceEpoch % 10000;
    final url = 'http://$host:$eport/eportal/portal/login'
        '?callback=dr1&login_method=1'
        '&user_account=${Uri.encodeComponent(userAccount)}'
        '&user_password=${Uri.encodeComponent(password)}'
        '&wlan_user_ip=${Uri.encodeComponent(ip)}'
        '&wlan_user_ipv6='
        '&wlan_user_mac=${Uri.encodeComponent(mac)}'
        '&wlan_ac_ip='
        '&wlan_ac_name=${Uri.encodeComponent(acname)}'
        '&jsVersion=4.X&v=$v&lang=zh';

    final (code, body, _) = await _get(url);
    if (code == null) return (false, 'PORTAL_UNREACHABLE');
    final json = parseJsonp(body);
    if (json == null) return (false, 'BAD_RESPONSE');
    final result = json['result']?.toString();
    if (result == '1' || result == 'ok') return (true, 'LOGIN_OK');
    if (json['ret_code']?.toString() == '2') return (true, 'ALREADY_ONLINE');
    final msg = json['msg']?.toString();
    return (false, (msg == null || msg.isEmpty) ? 'UNKNOWN_ERROR' : msg);
  }
}

/// 获取本机局域网 IPv4（排除回环与链路本地地址）。
/// 多网卡时优先 WLAN/Wi-Fi 适配器（本应用面向校园网 WiFi 场景），
/// 避免选中有线/虚拟网卡导致门户认证按错误源 IP 处理。
Future<String?> localIPv4() async {
  final interfaces = await NetworkInterface.list(
      includeLoopback: false, type: InternetAddressType.IPv4);
  String? firstAny;
  for (final it in interfaces) {
    for (final addr in it.addresses) {
      final s = addr.address;
      if (s.startsWith('169.254.') || s.startsWith('127.')) continue;
      if (RegExp(r'^(wlan|wi-?fi|无线)', caseSensitive: false)
          .hasMatch(it.name)) {
        return s;
      }
      firstAny ??= s;
    }
  }
  return firstAny;
}
