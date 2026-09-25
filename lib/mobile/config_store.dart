import 'dart:convert';

import 'package:home_widget/home_widget.dart';

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
        account: (j['account'] ?? '') as String,
        suffix: (j['suffix'] ?? '') as String,
        password: (j['password'] ?? '') as String,
      );
}

/// 移动端（Android）全局配置：存放在 home_widget 的共享偏好中，
/// 应用 UI 与小组件原生代码共用同一份 JSON（key = cnConfig）。
class MobileConfig {
  MobileConfig({
    this.host = '172.16.200.11',
    this.eport = 801,
    this.autoLoginSsid = '',
    this.bootAutoLogin = true,
    this.agreementAccepted = false,
    this.usageNoticed = false,
    Map<String, MobileProfile>? profiles,
  }) : profiles = profiles ?? {};

  static const _configKey = 'cnConfig';
  static const _statusKey = 'cnStatus';

  String host;
  int eport;
  String autoLoginSsid; // 开机自动认证 / 小组件默认使用的唯一 WiFi
  bool bootAutoLogin; // 开机后是否自动尝试认证
  bool agreementAccepted;
  bool usageNoticed;
  Map<String, MobileProfile> profiles;

  /// 从共享偏好读取；首次使用返回默认配置。
  static Future<MobileConfig> load() async {
    final raw = await HomeWidget.getWidgetData<String>(_configKey);
    if (raw == null || raw.isEmpty) return MobileConfig();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final profiles = <String, MobileProfile>{};
      final rawProfiles = j['profiles'];
      if (rawProfiles is Map<String, dynamic>) {
        rawProfiles.forEach((ssid, v) {
          if (v is Map<String, dynamic>) {
            profiles[ssid] = MobileProfile.fromJson(ssid, v);
          }
        });
      }
      return MobileConfig(
        host: (j['host'] ?? '172.16.200.11') as String,
        eport: (j['eport'] ?? 801) as int,
        autoLoginSsid: (j['autoLoginSsid'] ?? '') as String,
        bootAutoLogin: (j['bootAutoLogin'] ?? true) as bool,
        agreementAccepted: (j['agreementAccepted'] ?? false) as bool,
        usageNoticed: (j['usageNoticed'] ?? false) as bool,
        profiles: profiles,
      );
    } catch (_) {
      return MobileConfig();
    }
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'eport': eport,
        'autoLoginSsid': autoLoginSsid,
        'bootAutoLogin': bootAutoLogin,
        'agreementAccepted': agreementAccepted,
        'usageNoticed': usageNoticed,
        'profiles': profiles.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// 写回共享偏好并刷新桌面小组件。
  Future<void> save() async {
    await HomeWidget.saveWidgetData<String>(
        _configKey, jsonEncode(toJson()));
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
