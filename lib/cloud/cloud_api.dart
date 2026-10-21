import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'token_manager.dart';

/// 业务错误（服务端返回非 0 code）
class ApiException implements Exception {
  ApiException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => message;
}

/// 登录态彻底失效（刷新也失败），需重新登录
class AuthExpired implements Exception {
  AuthExpired(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 云端 API 客户端（模式对齐 trae-signin CloudApi.kt）。
///
/// 统一响应包：成功 {code:0, data}；失败 {code:非0, message}（HTTP 401 = token 失效）。
/// 业务接口自动携带 Bearer access_token；401 时刷新轮换一次并重放，仍失败抛 AuthExpired。
class CloudApi {
  CloudApi._();

  /// 服务端基址。默认指向 HTTPS 域名（已由 nginx 反代 + LE 泛域名证书接管），
  /// 具体解析交由 HTTPDNS DoH 白名单加速（见 lib/services/httpdns_config.dart）。
  /// 旧客户端仍可通过 --dart-define 回退 IP 直连：
  ///   flutter build apk --dart-define=CLOUD_AUTH_BASE=http://111.229.33.249:3010 \
  ///                     --dart-define=CLOUD_SYNC_BASE=http://111.229.33.249:3013 \
  ///                     --dart-define=ALLOW_INSECURE_CLOUD=true
  static const authBase = String.fromEnvironment(
    'CLOUD_AUTH_BASE',
    defaultValue: 'https://auth.suspect.top',
  );
  static const syncBase = String.fromEnvironment(
    'CLOUD_SYNC_BASE',
    defaultValue: 'https://wlan-sync.suspect.top',
  );

  /// 安全网开关：默认关闭（false），仅当开发者显式传
  /// `--dart-define=ALLOW_INSECURE_CLOUD=true` 才允许非 HTTPS 基址，
  /// 便于过渡期旧 IP 直连的回退验证。
  static const allowInsecureCloud =
      bool.fromEnvironment('ALLOW_INSECURE_CLOUD', defaultValue: false);

  static const appId = 'wlanconnect';

  static final _client = http.Client();
  static const _timeout = Duration(seconds: 15);

  /// 校验云服务基址安全性：非 HTTPS 且未显式允许时拒绝发送（防止密码明文外传）。
  /// 仅在首次使用时检查一次。
  static bool _checkedSecure = false;

  static void _ensureSecureBase(String url) {
    if (_checkedSecure) return;
    if (url.startsWith('https://')) {
      _checkedSecure = true;
      return;
    }
    if (!allowInsecureCloud) {
      throw StateError(
        '云同步基址必须为 HTTPS（当前：$url）。'
        '请通过 --dart-define=CLOUD_AUTH_BASE / CLOUD_SYNC_BASE 指定 HTTPS 地址，'
        '或显式设置 ALLOW_INSECURE_CLOUD=true 以在过渡期继续使用明文传输。',
      );
    }
    _checkedSecure = true;
  }


  // ================= 账号中心 =================

  /// 注册（成功返回 user_id，失败抛 ApiException）
  static Future<int> register(String phone, String password) async {
    final resp = await _send(
      _postJson('$authBase/v1/register', {
        'phone': phone,
        'password': password,
        'app_id': appId,
      }),
    );
    return (resp['data'] as Map<String, dynamic>?)?['user_id'] as int? ?? 0;
  }

  /// 登录（成功后 token 落库 TokenManager）
  static Future<void> login(String phone, String password) async {
    final resp = await _send(
      _postJson('$authBase/v1/login', {
        'phone': phone,
        'password': password,
        'app_id': appId,
      }),
    );
    final data = resp['data'] as Map<String, dynamic>?;
    if (data == null) throw ApiException(-1, '登录响应缺少 data');
    await TokenManager.saveLogin(data);
  }

  /// 登出（吊销服务端 refresh token 并清空本地）
  static Future<void> logout() async {
    try {
      final rt = await TokenManager.refreshToken();
      if (rt != null && rt.isNotEmpty) {
        await _send(_postJson('$authBase/v1/logout', {'refresh_token': rt}),
            authed: false);
      }
    } catch (_) {
      // 本地登出不受网络影响
    } finally {
      await TokenManager.clear();
    }
  }

  // ================= 配置同步（wlan-backend） =================

  /// 拉取云端配置。data 为 null 表示云端暂无备份。
  /// 返回 (data, updatedAt)
  static Future<(Map<String, dynamic>?, String?)> getSync() async {
    final resp = await _send(http.Request('GET', Uri.parse('$syncBase/v1/sync')));
    final data = resp['data'] as Map<String, dynamic>? ?? {};
    final blob = data['data'] as Map<String, dynamic>?;
    return (blob, data['updated_at'] as String?);
  }

  /// 上传/整体覆盖云端配置，返回 updated_at
  static Future<String> putSync(Map<String, dynamic> blob) async {
    final resp = await _send(
      http.Request('PUT', Uri.parse('$syncBase/v1/sync'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(blob),
    );
    final data = resp['data'] as Map<String, dynamic>? ?? {};
    return data['updated_at'] as String? ?? '';
  }

  /// 删除云端备份
  static Future<void> deleteSync() async {
    await _send(http.Request('DELETE', Uri.parse('$syncBase/v1/sync')));
  }

  // ================= 内部 =================

  static http.Request _postJson(String url, Map<String, dynamic> body) =>
      http.Request('POST', Uri.parse(url))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);

  /// 带 Bearer 的请求执行：401 → 刷新轮换一次 → 重放一次；仍失败抛 AuthExpired
  static Future<Map<String, dynamic>> _send(http.Request request,
      {bool authed = true}) async {
    // 发送前校验基址安全性：release 下若未显式允许明文则拒绝外发（含密码）。
    _ensureSecureBase(request.url.toString());
    if (authed) {
      final token = await TokenManager.accessToken();
      if (token == null || token.isEmpty) throw AuthExpired('未登录');
      request.headers['Authorization'] = 'Bearer $token';
    }
    var streamed =
        await _client.send(request).timeout(_timeout);
    var body = await streamed.stream.bytesToString().timeout(_timeout);

    // 401：刷新一次并重放一次（仅业务接口）
    if (streamed.statusCode == 401 && authed) {
      if (!await refreshOnce()) {
        await TokenManager.clear();
        throw AuthExpired('登录已过期，请重新登录');
      }
      final retry = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      retry.headers['Authorization'] =
          'Bearer ${await TokenManager.accessToken() ?? ''}';
      streamed = await _client.send(retry).timeout(_timeout);
      body = await streamed.stream.bytesToString().timeout(_timeout);
      if (streamed.statusCode == 401) {
        await TokenManager.clear();
        throw AuthExpired('登录已过期，请重新登录');
      }
    }

    final Map<String, dynamic> obj;
    try {
      obj = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(-1, '服务器响应异常（HTTP ${streamed.statusCode}）');
    }
    final code = (obj['code'] as num?)?.toInt() ?? -1;
    if (code != 0) throw ApiException(code, obj['message'] as String? ?? '请求失败');
    return obj;
  }

  /// 刷新轮换一次（单飞：并发请求共享同一次刷新）。成功返回 true
  static Future<bool>? _refreshing;

  static Future<bool> refreshOnce() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  static Future<bool> _doRefresh() async {
    final rt = await TokenManager.refreshToken();
    if (rt == null || rt.isEmpty) return false;
    try {
      final resp = await _send(
        _postJson('$authBase/v1/refresh', {'refresh_token': rt}),
        authed: false,
      );
      final data = resp['data'] as Map<String, dynamic>?;
      if (data == null) return false;
      await TokenManager.updateTokens(data);
      return true;
    } catch (_) {
      return false;
    }
  }
}
