import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/mobile/android_wlan.dart';
import 'package:wlan_auto_connect/mobile/diagnostics_report.dart';

/// 诊断报告文本的分支覆盖：这份文本是用户反馈「门户不可达」时的唯一线索，
/// 判读写反会把人引去改认证服务器地址（真正成因往往是流量走了移动数据）。
void main() {
  final now = DateTime(2026, 10, 22, 7, 30);

  RouteDiag route({
    String defaultTransport = 'wifi',
    bool wifiConnected = true,
    bool wifiValidated = true,
    bool wifiCaptivePortal = false,
    bool mobileAvailable = true,
    bool bound = false,
  }) =>
      RouteDiag(
        defaultTransport: defaultTransport,
        wifiConnected: wifiConnected,
        wifiValidated: wifiValidated,
        wifiCaptivePortal: wifiCaptivePortal,
        mobileAvailable: mobileAvailable,
        bound: bound,
      );

  PortalStatus guard({
    bool off = false,
    bool writePerm = false,
    bool shizukuRunning = false,
    bool shizukuPerm = false,
    bool rootAvail = false,
  }) =>
      PortalStatus(
        off: off,
        writePerm: writePerm,
        shizukuRunning: shizukuRunning,
        shizukuPerm: shizukuPerm,
        rootAvail: rootAvail,
      );

  String build({
    RouteDiag? diag = const RouteDiag(
      defaultTransport: 'wifi',
      wifiConnected: true,
      wifiValidated: true,
      wifiCaptivePortal: false,
      mobileAvailable: true,
    ),
    String bindResult = '',
    PortalStatus? guard = const PortalStatus(
      off: true,
      writePerm: true,
      shizukuRunning: false,
      shizukuPerm: false,
      rootAvail: false,
    ),
    List<String> logs = const ['[07:30:01] 开始一键连接'],
    String diskLog = 'DISK',
  }) =>
      DiagnosticsReport.build(
        now: now,
        host: '172.16.200.11',
        eport: 801,
        profileCount: 1,
        ssid: 'LNPC-STU-5G',
        diag: diag,
        bindResult: bindResult,
        guard: guard,
        sessionLogs: logs,
        diskLog: diskLog,
      );

  group('正向：路由被移动数据抢走的现场', () {
    test('判读、绑定结果、守护状态三段都要出现且指向正确成因', () {
      final text = build(
        diag: route(
            defaultTransport: 'cellular',
            wifiValidated: false,
            wifiCaptivePortal: true),
        bindResult: 'lost',
        guard: guard(),
      );
      expect(text, contains('--- 网络路由诊断 ---'));
      expect(text, contains('默认网络=cellular'));
      expect(text, contains('强制门户'));
      expect(text, contains('属路由抢占，不是认证服务器地址填错'));
      expect(text, contains('钉 WLAN 结果：lost'));
      expect(text, contains('联网检测守护：未开启'));
      expect(text, contains('adb 授权=未授予'));
      expect(text, contains('Shizuku=未运行'));
      expect(text, contains('root=未检测到'));
    });

    test('未尝试绑定时写「未尝试」而不是空白', () {
      expect(build(bindResult: ''), contains('钉 WLAN 结果：未尝试'));
    });

    test('守护已关闭且 adb 已授予时如实标注', () {
      final text = build(guard: guard(off: true, writePerm: true));
      expect(text, contains('联网检测守护：已关闭'));
      expect(text, contains('adb 授权=已授予'));
    });
  });

  group('降级：原生信息缺失', () {
    test('diag 为 null 时不拼判读，改说明系统不支持', () {
      final text = build(diag: null);
      expect(text, contains('（原生未返回诊断，可能是系统不支持）'));
      expect(text, isNot(contains('判读：')));
    });

    test('guard 为 null 时标注未知且不输出可用方案行', () {
      final text = build(guard: null);
      expect(text, contains('联网检测守护：（未知）'));
      expect(text, isNot(contains('可用修复方案')));
    });

    test('日志为空时两段都填「(无)」', () {
      final text = build(logs: const [], diskLog: '');
      expect('(无)'.allMatches(text).length, 2);
      expect(text, contains('--- 本次会话日志 ---\n(无)'));
    });
  });

  group('安全：报告不得含凭据', () {
    test('只输出档案数，不出现账号/密码内容', () {
      final text = build();
      expect(text, contains('WiFi 档案数：1（账号已脱敏）'));
      expect(text, isNot(contains('password')));
      expect(text, isNot(contains('2503150108')));
    });
  });

  group('结构：抬头字段齐全', () {
    test('包含服务器、当前连接与两段日志分隔', () {
      final text = build();
      expect(text, contains('认证服务器：172.16.200.11:801'));
      expect(text, contains('当前连接：LNPC-STU-5G'));
      expect(text, contains('--- 本次会话日志 ---'));
      expect(text, contains('--- 磁盘日志 ---'));
      expect(text, contains('DISK'));
    });

    test('未连接 WiFi 时当前连接显示 (无)', () {
      final text = DiagnosticsReport.build(
        now: now,
        host: '172.16.200.11',
        eport: 801,
        profileCount: 0,
        ssid: '',
        diag: route(wifiConnected: false, defaultTransport: 'cellular'),
        bindResult: 'no_wifi',
        guard: guard(),
        sessionLogs: const [],
        diskLog: '',
      );
      expect(text, contains('当前连接：(无)'));
      expect(text, contains('没连上校园网'));
    });
  });
}
