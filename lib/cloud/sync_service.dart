import 'dart:convert';
import 'dart:io';

import '../mobile/config_store.dart';
import '../services/auto_login_service.dart';
import '../services/debug_log.dart';
import 'cloud_api.dart';
import 'token_manager.dart';

/// 多设备配置同步服务：把本机全部 WiFi 档案（含密码）备份到云端 / 从云端恢复。
///
/// 云端 blob（wlan-backend /v1/sync，服务端按用户 AES-256-GCM 加密落盘）：
///   { "v": 1, "host", "eport", "autoLoginSsid",
///     "profiles": [ { "ssid", "account", "suffix", "password" } ] }
class CloudSyncService {
  CloudSyncService._();

  /// 收集本机配置 → 云端 blob
  static Future<Map<String, dynamic>> gather() async {
    if (Platform.isWindows) {
      final svc = AutoLoginService();
      final cfg = await svc.readConfig() ?? const {};
      final (profiles, autoLoginSsid) = await svc.readProfiles();
      final passwords = await svc.exportPasswords();
      return {
        'v': 1,
        'host': cfg['host'] ?? '172.16.200.11',
        'eport': cfg['eport'] ?? 801,
        'autoLoginSsid': autoLoginSsid,
        'profiles': [
          for (final p in profiles.values)
            {
              'ssid': p.ssid,
              'account': p.account,
              'suffix': p.suffix,
              'password': passwords[p.ssid] ?? '',
            }
        ],
      };
    }
    // Android（其他平台无本地配置，返回空档案）
    final c = await MobileConfig.load();
    return {
      'v': 1,
      'host': c.host,
      'eport': c.eport,
      'autoLoginSsid': c.autoLoginSsid,
      'profiles': [
        for (final p in c.profiles.values)
          {
            'ssid': p.ssid,
            'account': p.account,
            'suffix': p.suffix,
            'password': p.password,
          }
      ],
    };
  }

  /// 用云端 blob 覆盖本机配置（Windows 全量覆盖，Android 合并进现有配置）
  static Future<void> restore(Map<String, dynamic> blob) async {
    final profiles = (blob['profiles'] as List?) ?? const [];
    final items = <({String ssid, String account, String suffix, String password})>[
      for (final raw in profiles)
        if (raw is Map<String, dynamic> &&
            ((raw['ssid'] as String?) ?? '').isNotEmpty)
          (
            ssid: raw['ssid'] as String,
            account: raw['account'] as String? ?? '',
            suffix: raw['suffix'] as String? ?? '',
            password: raw['password'] as String? ?? '',
          ),
    ];
    if (items.isEmpty) throw ApiException(-1, '云端备份为空，无可恢复内容');

    if (Platform.isWindows) {
      final svc = AutoLoginService();
      final cfg = await svc.readConfig() ?? const {};
      final ssidSet = items.map((e) => e.ssid).toSet();
      var autoSsid = (blob['autoLoginSsid'] ?? '') as String;
      if (!ssidSet.contains(autoSsid)) autoSsid = items.first.ssid;
      final (ok, msg) = await svc.saveProfiles(
        profiles: [
          for (final e in items)
            WifiProfile(ssid: e.ssid, account: e.account, suffix: e.suffix),
        ],
        passwords: {for (final e in items) e.ssid: e.password},
        autoLoginSsid: autoSsid,
        host: (blob['host'] ?? cfg['host'] ?? '172.16.200.11') as String,
        eport: ((blob['eport'] ?? cfg['eport'] ?? 801) as num).toInt(),
      );
      if (!ok) throw ApiException(-1, '恢复写入失败：$msg');
      return;
    }

    // Android：合并进现有配置（云端同 ssid 覆盖，本机多出的档案保留）
    final c = await MobileConfig.load();
    c.host = (blob['host'] ?? c.host) as String;
    c.eport = ((blob['eport'] ?? c.eport) as num?)?.toInt() ?? c.eport;
    for (final e in items) {
      c.profiles[e.ssid] = MobileProfile(
        ssid: e.ssid,
        account: e.account,
        suffix: e.suffix,
        password: e.password,
      );
    }
    final autoSsid = (blob['autoLoginSsid'] ?? '') as String;
    if (autoSsid.isNotEmpty && c.profiles.containsKey(autoSsid)) {
      c.autoLoginSsid = autoSsid;
    } else if (c.profiles.isNotEmpty && !c.profiles.containsKey(c.autoLoginSsid)) {
      c.autoLoginSsid = c.profiles.keys.first;
    }
    await c.save();
  }

  /// 备份本机配置到云端（整体覆盖），返回 updated_at
  static Future<String> upload() async {
    final blob = await gather();
    final updated = await CloudApi.putSync(blob);
    await TokenManager.setLastSyncAt(DateTime.now());
    dlog('CLOUD_UPLOAD ok size=${jsonEncode(blob).length}');
    return updated;
  }

  /// 从云端恢复本机配置，返回云端 updated_at
  static Future<String?> download() async {
    final (blob, updatedAt) = await CloudApi.getSync();
    if (blob == null) throw ApiException(-1, '云端暂无备份，请先在其他设备上传');
    await restore(blob);
    await TokenManager.setLastSyncAt(DateTime.now());
    dlog('CLOUD_DOWNLOAD ok updated_at=$updatedAt');
    return updatedAt;
  }
}
