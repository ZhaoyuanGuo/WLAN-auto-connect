import 'dart:convert';
import 'dart:io' show Platform;

import 'package:home_widget/home_widget.dart';

import '../services/debug_log.dart';
import '../services/portal_config.dart';
import 'android_wlan.dart';

/// 敏感字段（密码）的加解密：走原生 AndroidKeyStore（见 SecretStore.kt）。
///
/// 失败时**降级为明文并留痕**：这是一个登录工具，加密不可用就完全无法保存密码
/// 会让应用不可用；但静默降级又会让用户误以为已加密，故同时写入诊断日志
/// （设置页「导出诊断日志」可见）。
Future<String> encryptSecretOrPlain(String plain) async {
  if (plain.isEmpty || !Platform.isAndroid) return plain;
  final encrypted = await AndroidWlan().encryptSecret(plain);
  if (encrypted == null || encrypted.isEmpty) {
    dlog('MobileConfig: 密码加密失败，本次以明文保存（请检查系统密钥库是否可用）');
    return plain;
  }
  return encrypted;
}

/// 解密；失败返回空串（该档案的密码需要用户重新输入）。
Future<String> decryptSecretOrEmpty(String stored) async {
  if (stored.isEmpty || !Platform.isAndroid) return stored;
  final plain = await AndroidWlan().decryptSecret(stored);
  if (plain == null) {
    dlog('MobileConfig: 密码解密失败（密钥丢失、换机或数据损坏），该档案需重新输入密码');
    return '';
  }
  return plain;
}

/// 一个 WiFi（SSID）对应的登录档案：账号、运营商后缀、密码。
/// 移动端无 DPAPI，密码保存在应用私有存储（home_widget 的
/// HomeWidgetPreferences）中，仅本应用可读写，供小组件后台认证使用。
class MobileProfile {
  MobileProfile({
    required this.ssid,
    this.account = '',
    this.suffix = '',
    this.password = '',
  });

  final String ssid;
  final String account;
  final String suffix; // 运营商后缀，如 '' / '@dx' / '@lt'
  final String password;

  bool get hasPassword => password.isNotEmpty;

  MobileProfile copyWith({String? account, String? suffix, String? password}) =>
      MobileProfile(
        ssid: ssid,
        account: account ?? this.account,
        suffix: suffix ?? this.suffix,
        password: password ?? this.password,
      );

  Map<String, dynamic> toJson() => {
        'account': account,
        'suffix': suffix,
        'password': password,
      };

  static MobileProfile fromJson(String ssid, Map<String, dynamic> j) =>
      MobileProfile(
        ssid: ssid,
        account: _asString(j['account']),
        suffix: _asString(j['suffix']),
        password: _asString(j['password']),
      );

  static String _asString(Object? v) => v is String ? v : '';
}

/// 移动端（Android）全局配置：存放在 home_widget 的共享偏好中，
/// 应用 UI 与小组件原生代码共用同一份 JSON（key = cnConfig）。
class MobileConfig {
  MobileConfig({
    this.host = PortalConfig.defaultHost,
    this.eport = PortalConfig.defaultEport,
    this.autoLoginSsid = '',
    this.bootAutoLogin = true,
    this.agreementAccepted = false,
    this.usageNoticed = false,
    this.themeMode = 'system',
    Map<String, MobileProfile>? profiles,
  }) : profiles = profiles ?? {};

  static const _configKey = 'cnConfig';
  static const _statusKey = 'cnStatus';

  /// JSON 整体损坏时，原始内容备份到这个 key，便于事后人工恢复。
  static const _corruptBackupKey = 'cnConfigCorruptBackup';

  String host;
  int eport;
  String autoLoginSsid; // 开机自动认证 / 小组件默认使用的唯一 WiFi
  bool bootAutoLogin; // 开机后是否自动尝试认证
  bool agreementAccepted;
  bool usageNoticed;
  String themeMode; // 'system' | 'light' | 'dark'（外观设置）
  Map<String, MobileProfile> profiles;

  /// 从共享偏好读取；首次使用返回默认配置。
  ///
  /// **逐字段容错**：单个字段类型异常只影响该字段，不再整体回落到默认配置。
  /// 原实现里任一字段解析失败就 `catch` 后返回 `MobileConfig()`，界面会显示
  /// "尚未配置账号"，用户此时若重新保存，就会把仍然完好的其它档案一并覆盖掉。
  /// 只有 JSON 整体无法解析时才回落到默认值，并把原始串备份留档。
  static Future<MobileConfig> load() async {
    final raw = await HomeWidget.getWidgetData<String>(_configKey);
    if (raw == null || raw.isEmpty) return MobileConfig();

    Map<String, dynamic> j;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await _backupCorrupt(raw, '顶层不是 JSON 对象');
        return MobileConfig();
      }
      j = decoded;
    } catch (e) {
      await _backupCorrupt(raw, '$e');
      return MobileConfig();
    }

    final profiles = <String, MobileProfile>{};
    final rawProfiles = j['profiles'];
    if (rawProfiles is Map) {
      rawProfiles.forEach((ssid, v) {
        if (ssid is! String || v is! Map) return;
        profiles[ssid] = MobileProfile.fromJson(
            ssid, Map<String, dynamic>.from(v));
      });
    }

    for (final ssid in profiles.keys.toList()) {
      final p = profiles[ssid]!;
      if (p.password.isEmpty) continue;
      // 密文（enc:v1:）解密；历史明文原样保留
      profiles[ssid] =
          p.copyWith(password: await decryptSecretOrEmpty(p.password));
    }

    return MobileConfig(
      host: _asString(j['host'], PortalConfig.defaultHost),
      eport: _asInt(j['eport'], PortalConfig.defaultEport),
      autoLoginSsid: _asString(j['autoLoginSsid'], ''),
      bootAutoLogin: _asBool(j['bootAutoLogin'], true),
      agreementAccepted: _asBool(j['agreementAccepted'], false),
      usageNoticed: _asBool(j['usageNoticed'], false),
      themeMode: _asThemeMode(j['themeMode']),
      profiles: profiles,
    );
  }

  static Future<void> _backupCorrupt(String raw, String reason) async {
    try {
      await HomeWidget.saveWidgetData<String>(_corruptBackupKey, raw);
      dlog('MobileConfig: cnConfig 解析失败（$reason），原始内容已备份到 '
          '$_corruptBackupKey');
    } catch (_) {
      // 备份失败不影响启动
    }
  }

  static String _asString(Object? v, String fallback) =>
      v is String && v.isNotEmpty ? v : fallback;

  static int _asInt(Object? v, int fallback) =>
      v is int ? v : (v is num ? v.toInt() : fallback);

  static bool _asBool(Object? v, bool fallback) => v is bool ? v : fallback;

  static String _asThemeMode(Object? v) =>
      v == 'light' || v == 'dark' ? v as String : 'system';

  /// 序列化为 JSON。**注意：密码为明文**，仅用于内存内传递；
  /// 落盘请用 [save]，它会先加密密码。
  Map<String, dynamic> toJson() => {
        'host': host,
        'eport': eport,
        'autoLoginSsid': autoLoginSsid,
        'bootAutoLogin': bootAutoLogin,
        'agreementAccepted': agreementAccepted,
        'usageNoticed': usageNoticed,
        'themeMode': themeMode,
        'profiles': profiles.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// 写回共享偏好并刷新桌面小组件。
  /// 密码字段先经 AndroidKeyStore 加密（见 [encryptSecretOrPlain]），
  /// 避免明文出现在 HomeWidgetPreferences.xml 中。
  Future<void> save() async {
    final data = toJson();
    final encoded = <String, dynamic>{};
    for (final entry in profiles.entries) {
      final p = entry.value;
      encoded[entry.key] = {
        'account': p.account,
        'suffix': p.suffix,
        'password': await encryptSecretOrPlain(p.password),
      };
    }
    data['profiles'] = encoded;
    await HomeWidget.saveWidgetData<String>(_configKey, jsonEncode(data));
    await HomeWidget.updateWidget(name: 'CampusWidgetProvider');
  }

  /// 写入小组件运行状态（原生 LoginWorker 也写这个 key）。
  static Future<void> saveStatus(Map<String, dynamic> status) async {
    await HomeWidget.saveWidgetData<String>(_statusKey, jsonEncode(status));
    await HomeWidget.updateWidget(name: 'CampusWidgetProvider');
  }

  /// 读取小组件运行状态（原生写入）。
  static Future<Map<String, dynamic>?> readStatus() async {
    final raw = await HomeWidget.getWidgetData<String>(_statusKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 清空全部配置（含小组件状态）。
  static Future<void> clear() async {
    await HomeWidget.saveWidgetData<String>(_configKey, null);
    await HomeWidget.saveWidgetData<String>(_statusKey, null);
    await HomeWidget.updateWidget(name: 'CampusWidgetProvider');
  }
}
