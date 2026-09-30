import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 云端登录凭证存储（access/refresh token + 用户信息）。
///
/// Android: EncryptedSharedPreferences（AES256-GCM，硬件 Keystore 派生密钥）；
/// Windows: DPAPI 加密文件。对齐 trae-signin TokenManager.kt 的键名与语义。
class TokenManager {
  TokenManager._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kUserId = 'user_id';
  static const _kPhone = 'phone_masked';
  static const _kExpiresAt = 'access_expires_at';
  static const _kLastSyncAt = 'last_sync_at';

  static Future<bool> isLoggedIn() async {
    final a = await accessToken();
    final r = await refreshToken();
    return (a != null && a.isNotEmpty) && (r != null && r.isNotEmpty);
  }

  static Future<String?> accessToken() => _storage.read(key: _kAccess);

  static Future<String?> refreshToken() => _storage.read(key: _kRefresh);

  static Future<int> userId() async =>
      int.tryParse(await _storage.read(key: _kUserId) ?? '') ?? 0;

  static Future<String?> phoneMasked() => _storage.read(key: _kPhone);

  /// 上次与云端同步（备份/恢复）的时刻，null = 从未同步
  static Future<DateTime?> lastSyncAt() async {
    final ms = int.tryParse(await _storage.read(key: _kLastSyncAt) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> setLastSyncAt(DateTime t) =>
      _storage.write(key: _kLastSyncAt, value: t.millisecondsSinceEpoch.toString());

  /// 登录成功落库（POST /v1/login 的 data）
  static Future<void> saveLogin(Map<String, dynamic> data) async {
    final user = (data['user'] as Map<String, dynamic>?) ?? const {};
    await _storage.write(key: _kAccess, value: data['access_token'] as String? ?? '');
    await _storage.write(key: _kRefresh, value: data['refresh_token'] as String? ?? '');
    await _storage.write(key: _kUserId, value: '${user['id'] ?? 0}');
    await _storage.write(key: _kPhone, value: user['phone_masked'] as String? ?? '');
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 0;
    await _storage.write(
      key: _kExpiresAt,
      value: (DateTime.now().millisecondsSinceEpoch + expiresIn * 1000).toString(),
    );
  }

  /// 刷新轮换后更新 token 对（保持用户信息不变）
  static Future<void> updateTokens(Map<String, dynamic> data) async {
    await _storage.write(key: _kAccess, value: data['access_token'] as String? ?? '');
    await _storage.write(key: _kRefresh, value: data['refresh_token'] as String? ?? '');
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 0;
    await _storage.write(
      key: _kExpiresAt,
      value: (DateTime.now().millisecondsSinceEpoch + expiresIn * 1000).toString(),
    );
  }

  static Future<void> clear() async {
    for (final k in [_kAccess, _kRefresh, _kUserId, _kPhone, _kExpiresAt]) {
      await _storage.delete(key: k);
    }
  }
}
