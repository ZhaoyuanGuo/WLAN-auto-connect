import 'dart:io';

/// 日志级别（数值越大越严重，便于过滤）。
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warn(2, 'WARN'),
  error(3, 'ERROR');

  const LogLevel(this.value, this.label);
  final int value;
  final String label;
}

/// 轻量诊断日志：追加到应用日志目录下的 app_debug.log。
/// 仅记录关键事件与失败，用于排查打包后环境的静默故障；写入失败静默忽略。
/// 独立于 Flutter 依赖，供纯 Dart 服务（wifi_service 等）直接使用。
///
/// - 分级：默认 INFO，可通过 [level] 指定；低于 [minLevel] 的记录被丢弃。
/// - 轮转：文件超过 [maxBytes] 时清空重写（与 AutoLogin.ps1 的 256KB 策略一致）。
/// - 脱敏：账号/密码等敏感信息应先经 [maskAccount] / [maskSecret] 处理。
void dlog(String msg, {LogLevel level = LogLevel.info}) {
  if (level.value < minLevel.value) return;
  try {
    final dir = logDir;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File(logFilePath);
    // 轮转：超限则清空，避免日志无限增长
    if (f.existsSync() && f.lengthSync() > maxBytes) {
      f.writeAsStringSync('', flush: true);
    }
    f.writeAsStringSync(
        '${DateTime.now().toIso8601String()} [${level.label}] $msg\n',
        mode: FileMode.append);
  } catch (_) {}
}

/// 最低记录级别（默认 INFO：过滤 DEBUG 噪音）。
LogLevel minLevel = LogLevel.info;

/// 日志轮转阈值（256KB，与 PowerShell 侧一致）。
const int maxBytes = 256 * 1024;

/// 日志目录：Windows 用 %APPDATA%\CampusNetAutoLogin；
/// 其他平台（Android）用应用临时目录下的同名子目录。
Directory get logDir {
  if (Platform.isWindows) {
    final appdata = Platform.environment['APPDATA'] ?? r'C:\Users\Public';
    return Directory('$appdata\\CampusNetAutoLogin');
  }
  return Directory('${Directory.systemTemp.path}/CampusNetAutoConnect');
}

String get logFilePath => '${logDir.path}${Platform.pathSeparator}app_debug.log';

/// 读取当前日志内容（不存在返回空串），供导出诊断使用。
String readLog() {
  try {
    final f = File(logFilePath);
    return f.existsSync() ? f.readAsStringSync() : '';
  } catch (_) {
    return '';
  }
}

/// 账号脱敏：保留首尾各 2 位，中间以 * 替代（长度不足时全掩）。
/// 例：20210101 -> 20****01；ab -> **。
String maskAccount(String s) {
  final t = s.trim();
  if (t.isEmpty) return '';
  if (t.length <= 4) return '*' * t.length;
  return '${t.substring(0, 2)}${'*' * (t.length - 4)}${t.substring(t.length - 2)}';
}

/// 敏感串完全掩码（密码等），仅保留长度提示。
String maskSecret(String s) => s.isEmpty ? '' : '*' * s.length;

/// MAC 脱敏：保留前 3 段（OUI），其余掩码。例：aa:bb:cc:dd:ee:ff -> aa:bb:cc:**:**:**。
String maskMac(String mac) {
  final parts = mac.split(':');
  if (parts.length < 4) return maskSecret(mac);
  return [
    ...parts.take(3),
    ...List.filled(parts.length - 3, '**'),
  ].join(':');
}
