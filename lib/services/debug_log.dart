import 'dart:io';

/// 轻量诊断日志：追加到 %APPDATA%\CampusNetAutoLogin\app_debug.log。
/// 仅记录关键事件与失败，用于排查打包后环境的静默故障；写入失败静默忽略。
/// 独立于 Flutter 依赖，供纯 Dart 服务（wifi_service 等）直接使用。
void dlog(String msg) {
  try {
    final appdata =
        Platform.environment['APPDATA'] ?? r'C:\Users\Public';
    final dir = Directory('$appdata\\CampusNetAutoLogin');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}\\app_debug.log');
    f.writeAsStringSync('${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append);
  } catch (_) {}
}
