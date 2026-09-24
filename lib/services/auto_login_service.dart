import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// 负责与 AutoLogin.ps1 交互：
/// 释放脚本、保存账号（DPAPI 加密）、注册/注销任务计划、查询状态。
class AutoLoginService {
  static const _assetPath = 'assets/AutoLogin.ps1';
  static const taskName = 'CampusNetAutoLogin';

  static String get dir {
    final appdata = Platform.environment['APPDATA'] ?? r'C:\Users\Public';
    return '$appdata\\CampusNetAutoLogin';
  }

  static String get scriptPath => '$dir\\AutoLogin.ps1';
  static String get configPath => '$dir\\config.json';

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
    final proc = await Process.start(
      'powershell.exe',
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

    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill();
      return -1;
    });
    final outBytes = await outFuture;
    await errFuture;
    return (code, utf8.decode(outBytes.expand((b) => b).toList(), allowMalformed: true));
  }

  /// 解析脚本输出行 `[OK] xxx` / `[ERR] xxx` / `[INFO] xxx`。
  static (String level, String msg) parseLine(String line) {
    for (final lv in ['OK', 'ERR', 'INFO']) {
      if (line.startsWith('[$lv] ')) return (lv, line.substring(lv.length + 3));
    }
    return ('INFO', line);
  }

  /// 保存账号信息（密码用 Windows DPAPI 加密，仅当前用户可解密）。
  Future<(bool, String)> saveCredentials({
    required String account,
    required String password,
    required String suffix,
    String host = '172.16.200.11',
    int eport = 801,
  }) async {
    final payload = jsonEncode({
      'account': account,
      'password': password,
      'suffix': suffix,
      'host': host,
      'eport': eport,
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

  /// 读取已保存配置（不含密码）。返回 null 表示尚未配置。
  Future<Map<String, dynamic>?> readConfig() async {
    try {
      final text = await File(configPath).readAsString();
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
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
