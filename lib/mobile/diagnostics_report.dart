import 'android_wlan.dart';

/// 诊断报告文本生成（纯函数）。
///
/// 单独成文件是为了能脱离 MethodChannel 与真机做单元测试：用户反馈
/// 「门户不可达」时，这份文本要能一眼分辨是「认证服务器地址填错」还是
/// 「系统把流量切到了移动数据」，写错一个分支就会把排查引向歧路。
///
/// 安全约束：只输出档案数量，绝不输出账号与密码。
class DiagnosticsReport {
  DiagnosticsReport._();

  static String build({
    required DateTime now,
    required String host,
    required int eport,
    required int profileCount,
    required String ssid,
    required RouteDiag? diag,
    required String bindResult,
    required PortalStatus? guard,
    required List<String> sessionLogs,
    required String diskLog,
  }) {
    final buf = StringBuffer()
      ..writeln('=== 校园网自动登录 · 诊断日志（Android）===')
      ..writeln('导出时间：${now.toIso8601String()}')
      ..writeln('认证服务器：$host:$eport')
      ..writeln('WiFi 档案数：$profileCount（账号已脱敏）')
      ..writeln('当前连接：${ssid.isEmpty ? '(无)' : ssid}')
      ..writeln('--- 网络路由诊断 ---')
      ..writeln(diag == null
          ? '（原生未返回诊断，可能是系统不支持）'
          : '${diag.summary}\n'
              '判读：${diag.verdict}\n'
              '钉 WLAN 结果：${bindResult.isEmpty ? '未尝试' : bindResult}')
      ..writeln('联网检测守护：${guard == null ? '（未知）' : (guard.off ? '已关闭（认证不会被系统抢跑）' : '未开启')}')
      ..writeln(guard == null
          ? ''
          : '可用修复方案：adb 授权=${guard.writePerm ? '已授予' : '未授予'}，'
              'Shizuku=${guard.shizukuRunning ? (guard.shizukuPerm ? '运行中已授权' : '运行中未授权') : '未运行'}，'
              'root=${guard.rootAvail ? '已检测到 su' : '未检测到'}')
      ..writeln('--- 本次会话日志 ---')
      ..writeln(sessionLogs.isEmpty ? '(无)' : sessionLogs.join('\n'))
      ..writeln('--- 磁盘日志 ---')
      ..writeln(diskLog.isEmpty ? '(无)' : diskLog);
    return buf.toString();
  }
}
