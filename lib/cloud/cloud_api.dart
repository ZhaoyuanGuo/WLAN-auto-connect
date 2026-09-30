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

  /// 过渡期端口直连（备案完成后切 HTTPS 域名）
  static const authBase = 'http://111.229.33.249:3010';
  static const syncBase = 'http://111.229.33.249:3013';
  static const appId = 'wlanconnect';

  static final _client = http.Client();
  static const _timeout = Duration(seconds: 15);

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
