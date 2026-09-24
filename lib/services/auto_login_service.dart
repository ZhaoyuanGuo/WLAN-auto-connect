import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'debug_log.dart';

/// 一个 WiFi（SSID）对应的登录档案：账号、运营商后缀。
/// 密码经 DPAPI 加密存在脚本侧 cred.json 中，Dart 端不持有明文；
/// [hasPassword] 来自配置标记，仅用于 UI 提示。
class WifiProfile {
  WifiProfile({
    required this.ssid,
    this.account = '',
    this.suffix = '',
    this.hasPassword = false,
  });

  final String ssid;
  final String account;
  final String suffix; // 运营商后缀，如 '' / '@dx' / '@lt'
  final bool hasPassword;

  WifiProfile copyWith({String? account, String? suffix, bool? hasPassword}) =>
      WifiProfile(
        ssid: ssid,
        account: account ?? this.account,
        suffix: suffix ?? this.suffix,
        hasPassword: hasPassword ?? this.hasPassword,
      );

  Map<String, dynamic> toJson() => {
        'ssid': ssid,
        'account': account,
        'suffix': suffix,
        'hasPassword': hasPassword,
      };

  static WifiProfile fromJson(Map<String, dynamic> j) => WifiProfile(
        ssid: (j['ssid'] ?? '') as String,
        account: (j['account'] ?? '') as String,
        suffix: (j['suffix'] ?? '') as String,
        hasPassword: (j['hasPassword'] ?? false) as bool,
      );
}

/// 负责与 AutoLogin.ps1 交互：
/// 释放脚本、按 WiFi 档案保存账号（DPAPI 加密）、注册/注销任务计划、查询状态。
/// 配置结构：config.json 保存 profiles（ssid -> 账号/后缀）与唯一的
/// autoLoginSsid（开机自动登录只对这一个 WiFi 生效）。
class AutoLoginService {
  static const _assetPath = 'assets/AutoLogin.ps1';
  static const taskName = 'CampusNetAutoLogin';

  static String get dir {
    final appdata = Platform.environment['APPDATA'] ?? r'C:\Users\Public';
    return '$appdata\\CampusNetAutoLogin';
  }

  static String get scriptPath => '$dir\\AutoLogin.ps1';
  static String get configPath => '$dir\\config.json';

  static String get _psExe {
    final sysroot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return '$sysroot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  }

  /// 把打包在应用内的 AutoLogin.ps1 释放到 %APPDATA%（每次启动覆盖，便于升级）。
  Future<void> ensureScriptInstalled() async {
    final source = await rootBundle.loadString(_assetPath);
    await Directory(dir).create(recursive: true);
    await File(scriptPath).writeAsString(source, flush: true);
  }

  /// 运行 AutoLogin.ps1 的某个模式，返回 (exitCode, stdout)。
  /// 脚本内部已将输出编码设为 UTF-8。
  Future<(int, String)> _runPs(List<String> psArgs,
      {String? stdin, Duration timeout = const Duration(seconds: 60)}) async {
    dlog('PS_START ${psArgs.join(' ')}');
    final List<int> outBytes;
    final int code;
    try {
      final proc = await Process.start(
        _psExe,
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptPath,
          ...psArgs,
        ],
        runInShell: false,
      );
      // 先挂上 stdout/stderr 读取，避免管道缓冲区满导致死锁
      final outFuture = proc.stdout.toList();
      final errFuture = proc.stderr.toList();
      if (stdin != null) {
        proc.stdin.add(utf8.encode(stdin));
        await proc.stdin.flush();
      }
      await proc.stdin.close();

      code = await proc.exitCode.timeout(timeout, onTimeout: () {
        proc.kill();
        dlog('PS_TIMEOUT ${psArgs.join(' ')}');
        return -1;
      });
      outBytes = (await outFuture).expand((b) => b).toList();
      await errFuture;
    } catch (e) {
      dlog('PS_SPAWN_FAIL ${psArgs.join(' ')} $e');
      return (-1, 'PS_LAUNCH_FAILED: $e');
    }
    final text =
        utf8.decode(outBytes, allowMalformed: true).trim();
    dlog('PS_DONE code=$code ${psArgs.join(' ')} out=${text.isEmpty ? '(empty)' : text.length > 200 ? '${text.substring(0, 200)}...' : text}');
    return (code, text);
  }

  /// 解析脚本输出行 `[OK] xxx` / `[ERR] xxx` / `[INFO] xxx`。
  static (String level, String msg) parseLine(String line) {
    for (final lv in ['OK', 'ERR', 'INFO']) {
      if (line.startsWith('[$lv] ')) return (lv, line.substring(lv.length + 3));
    }
    return ('INFO', line);
  }

  /// 保存全部 WiFi 档案并指定唯一的开机自动登录 WiFi。
  /// [passwords] 为 ssid -> 明文密码；留空串表示"沿用已保存的密码"，不覆盖。
  Future<(bool, String)> saveProfiles({
    required List<WifiProfile> profiles,
    required Map<String, String> passwords,
    required String autoLoginSsid,
    String host = '172.16.200.11',
    int eport = 801,
  }) async {
    final payload = jsonEncode({
      'host': host,
      'eport': eport,
      'autoLoginSsid': autoLoginSsid,
      'profiles': [
        for (final p in profiles)
          {
            'ssid': p.ssid,
            'account': p.account,
            'suffix': p.suffix,
            'password': passwords[p.ssid] ?? '',
          }
      ],
    });
    final r = await _runPs(['-Save'], stdin: payload);
    final text = r.$2.trim();
    final lines = text.isEmpty ? <String>[] : text.split('\n');
    if (lines.any((l) => l.startsWith('[OK]'))) return (true, 'SAVED');
    final err = lines.where((l) => l.startsWith('[ERR]')).toList();
    return (false, err.isEmpty ? 'SAVE_FAILED' : err.last);
  }

  /// 注册开机自启任务计划（当前用户登录时触发）。
  /// 非管理员时会弹出 UAC 提权确认窗口（任务本身仍以普通权限运行）。
  Future<(bool, String)> installTask() async {
    final r = await _runPs(['-Install'], timeout: const Duration(minutes: 5));
    final text = r.$2.trim();
    if (text.contains('[OK]')) return (true, 'TASK_REGISTERED');
    final i = text.indexOf('[ERR]');
    return (false, i >= 0 ? text.substring(i + 5).trim() : 'TASK_REGISTER_FAILED');
  }

  /// 注销开机自启任务计划。
  Future<bool> uninstallTask() async {
    final r = await _runPs(['-Uninstall'],
        timeout: const Duration(seconds: 45));
    return r.$2.contains('[OK]');
  }

  /// 读取已保存配置（不含密码明文）。返回 null 表示尚未配置。
  Future<Map<String, dynamic>?> readConfig() async {
    try {
      final text = await File(configPath).readAsString();
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// cred.json 的键集合（ssid -> 是否已存密码），读取失败返回空集。
  Future<Set<String>> readSavedPasswordSsids() async {
    try {
      final text = await File('$dir\\cred.json').readAsString();
      final obj = jsonDecode(text) as Map<String, dynamic>;
      return obj.keys.toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// 读取全部 WiFi 档案与自启 WiFi（hasPassword 依据 cred.json）。
  /// 尚未配置时返回 (空表, '')。
  Future<(Map<String, WifiProfile>, String)> readProfiles() async {
    final cfg = await readConfig();
    if (cfg == null) return (<String, WifiProfile>{}, '');
    final pwSsids = await readSavedPasswordSsids();
    final profiles = <String, WifiProfile>{};
    final raw = cfg['profiles'];
    if (raw is Map<String, dynamic>) {
      raw.forEach((ssid, v) {
        if (v is Map<String, dynamic>) {
          profiles[ssid] = WifiProfile.fromJson({
            ...v,
            'ssid': ssid,
            'hasPassword': pwSsids.contains(ssid),
          });
        }
      });
    }
    return (profiles, (cfg['autoLoginSsid'] ?? '') as String);
  }

  /// 单次静默登录（使用已保存账号）。
  Future<(bool, List<String>)> loginOnce() async {
    final r = await _runPs(['-Once'], timeout: const Duration(seconds: 90));
    final text = r.$2.trim();
    final lines = text.isEmpty ? <String>[] : text.split('\n');
    final ok = r.$1 == 0 && lines.any((l) => l.startsWith('[OK]'));
    return (ok, lines);
  }
}
