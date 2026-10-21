import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gbk_codec/gbk_codec.dart';

import 'portal_config.dart';

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
    this.host = PortalConfig.defaultHost,
    this.eport = PortalConfig.defaultEport,
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

  /// 查询在线状态，并区分失败原因（供界面给出准确提示）。
  /// 顺带缓存 ss5/ss1（门户眼中本机 IP/MAC，即使 result=0 也会返回）。
  Future<PortalState> probeOnline() async {
    final url = 'http://$host/drcom/chkstatus?callback=dr1&jsVersion=4.X';
    final (code, body, _) = await _get(url, timeout: const Duration(seconds: 5));
    // 连接层失败：DNS/超时/连接被拒，或 host 本身非法
    if (code == null) return PortalState.unreachable;
    final json = parseJsonp(body);
    // 拿到了响应但不是可解析的 JSONP（门户返回 HTML 跳转页 / 裸 JSON / 5xx）。
    // 这与"连不上门户"是两回事，最常见的成因是「认证服务器地址填错」。
    if (json == null) return PortalState.badResponse;
    final ss5 = json['ss5']?.toString() ?? '';
    final ss1 = json['ss1']?.toString() ?? '';
    if (ss5.isNotEmpty && ss5 != '-') _chkIp = ss5;
    if (ss1.isNotEmpty && ss1 != '-') _chkMac = ss1;
    return json['result']?.toString() == '1'
        ? PortalState.online
        : PortalState.offline;
  }

  /// 旧调用方（Windows 端）使用的布尔视图：
  /// true 在线 / false 未认证 / null 其它异常。
  Future<bool?> checkOnline() async => switch (await probeOnline()) {
        PortalState.online => true,
        PortalState.offline => false,
        PortalState.unreachable || PortalState.badResponse => null,
      };

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

  /// 自动探测认证门户地址（host / eport）。
  ///
  /// 原理：未认证时任意外网 HTTP 请求会被 AC 劫持（302 或 DNS 劫持）到门户页，
  /// 从重定向 Location（或响应体中的门户链接）即可推导门户 host 与端口。
  /// 返回 null 表示未能探测到（未连接校园网 / 已被认证 / 非 Dr.COM 门户）。
  ///
  /// 供「认证服务器」设置页的"自动探测"按钮使用，避免用户手填 IP。
  static Future<({String host, int eport})?> detectPortal() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse(PortalConfig.hijackProbeUrl));
      req.followRedirects = false;
      req.maxRedirects = 0;
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final bytes = await resp.fold<List<int>>(
          <int>[], (acc, chunk) => acc..addAll(chunk));
      String body;
      try {
        body = utf8.decode(bytes);
      } catch (_) {
        body = gbk.decode(bytes);
      }
      final location = resp.headers.value(HttpHeaders.locationHeader) ?? '';

      // 候选 URL：优先重定向 Location，其次响应体中的门户链接
      String? candidate;
      if (location.isNotEmpty) {
        candidate = location;
      } else {
        final m = RegExp('http://[^\\s"\'<>]+(?:eportal|a79\\.htm)[^\\s"\'<>]*')
            .firstMatch(body);
        if (m != null) candidate = m.group(0);
      }
      if (candidate == null) return null;

      final uri = Uri.tryParse(candidate);
      if (uri == null || uri.host.isEmpty) return null;
      // 仅接受 IP 或内网主机（门户必为校园内网地址，排除外网跳转）
      final isIp = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(uri.host);
      if (!isIp && !uri.host.contains('.')) return null;
      final eport = uri.hasPort ? uri.port : PortalConfig.defaultEport;
      if (!PortalConfig.isValidEport(eport)) return null;
      return (host: uri.host, eport: eport);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 会话参数优先级：AC 劫持 > chkstatus 的 ss5/ss1 > 本机网卡 IP。
  /// 实测（2026-09-24）：插着有线网卡时劫持抓不到参数，localIPv4()
  /// 会选错网卡，门户返回 ret_code=8「Portal协议认证超时」。
  /// 抽为纯函数便于单元测试（见 test/portal_client_test.dart）。
  static LoginSession resolveSession({
    required Map<String, String> hijack,
    String chkIp = '',
    String chkMac = '',
    String localIp = '',
  }) {
    final mac = hijack['wlanusermac'] ?? chkMac;
    final ip = hijack['wlanuserip'] ?? (chkIp.isNotEmpty ? chkIp : localIp);
    final acname = hijack['wlanacname'] ?? '';
    return LoginSession(ip: ip, mac: mac, acName: acname);
  }

  /// 拼装 eportal v4 登录请求 URL。
  /// 实测裸账号可登录；",0," 前缀会被服务器判定为账号不存在。
  /// [v] 由调用方传入（时间戳派生），便于测试时固定取值。
  static Uri buildLoginUri({
    required String host,
    required int eport,
    required String account,
    required String password,
    required String suffix,
    required LoginSession session,
    required int v,
  }) {
    final userAccount = '$account$suffix';
    return Uri.parse('http://$host:$eport/eportal/portal/login'
        '?callback=dr1&login_method=1'
        '&user_account=${Uri.encodeComponent(userAccount)}'
        '&user_password=${Uri.encodeComponent(password)}'
        '&wlan_user_ip=${Uri.encodeComponent(session.ip)}'
        '&wlan_user_ipv6='
        '&wlan_user_mac=${Uri.encodeComponent(session.mac)}'
        '&wlan_ac_ip='
        '&wlan_ac_name=${Uri.encodeComponent(session.acName)}'
        '&jsVersion=4.X&v=$v&lang=zh');
  }

  /// 解析登录响应：`result=1/ok` 或 `ret_code=2` 视为成功。
  /// 返回 `(ok, msg)`，msg 为门户返回文案或内部标记。
  static (bool, String) parseLoginResult(Map<String, dynamic>? json) {
    if (json == null) return (false, 'BAD_RESPONSE');
    final result = json['result']?.toString();
    if (result == '1' || result == 'ok') return (true, 'LOGIN_OK');
    if (json['ret_code']?.toString() == '2') return (true, 'ALREADY_ONLINE');
    final msg = json['msg']?.toString();
    return (false, (msg == null || msg.isEmpty) ? 'UNKNOWN_ERROR' : msg);
  }

  /// 发起登录请求。返回 `(ok, msg)`，msg 为门户返回码或成功标记。
  Future<(bool, String)> login(
    String account,
    String password,
    String suffix,
    Map<String, String> session,
  ) async {
    // 仅当劫持与 chkstatus 都拿不到 IP 时才探测本机网卡，避免多余调用。
    final needLocal = !session.containsKey('wlanuserip') && _chkIp.isEmpty;
    final localIp = needLocal ? (await localIPv4() ?? '') : '';
    final resolved = resolveSession(
      hijack: session,
      chkIp: _chkIp,
      chkMac: _chkMac,
      localIp: localIp,
    );
    final v = 500 + DateTime.now().millisecondsSinceEpoch % 10000;
    final url = buildLoginUri(
      host: host,
      eport: eport,
      account: account,
      password: password,
      suffix: suffix,
      session: resolved,
      v: v,
    ).toString();

    final (code, body, _) = await _get(url);
    if (code == null) return (false, 'PORTAL_UNREACHABLE');
    return parseLoginResult(parseJsonp(body));
  }
}

/// 门户在线状态探测结果。区分「不可达」与「响应不可解析」，
/// 避免把「认证服务器地址填错」误报成「未连接校园网」。
enum PortalState {
  /// 已通过认证（chkstatus result==1）
  online,

  /// 门户可达但本机未认证（result==0）
  offline,

  /// 门户不可达：连接超时 / DNS 失败 / 连接被拒 / host 非法
  unreachable,

  /// 门户可达，但响应不是可解析的 JSONP（HTML 跳转页、裸 JSON、5xx 错误页）
  badResponse,
}

/// 登录请求使用的会话参数（已按优先级解析完成）。
class LoginSession {
  const LoginSession({this.ip = '', this.mac = '', this.acName = ''});

  final String ip;
  final String mac;
  final String acName;
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
