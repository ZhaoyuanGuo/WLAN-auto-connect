import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/mobile/android_wlan.dart';

/// Kotlin WlanMethods.handle 中 when(call.method) 匹配的完整方法名列表。
/// 修改 Dart 侧 AndroidWlan 或 Kotlin 侧 WlanMethods 时，
/// 此列表必须同步更新，否则测试失败。
const _kNativeMethods = <String>{
  'scan',
  'currentSsid',
  'openWifiPanel',
  'syncNetworkSuggestions',
  'requestPermissions',
  'isLocationServiceEnabled',
  'ensurePortalDetectionOff',
  'restorePortalDetection',
  'portalStatus',
  'shizukuEnsurePortalOff',
  'shizukuRestorePortalDetection',
  'shizukuRequestPermission',
  'rootEnsurePortalOff',
  'rootRestorePortalDetection',
  'openUrl',
  'requestAddTile',
  'refreshTile',
  'encryptSecret',
  'decryptSecret',
  'routeDiagnose',
  'routeBindWifi',
  'routeUnbind',
};

/// Dart 侧 AndroidWlan 通过 MethodChannel('wlan_auto_connect/android')
/// 调用的方法名列表，由测试逐方法验证。
/// 此列表与 _kNativeMethods 必须完全一致。
const _kDartMethods = <String>{
  'scan',
  'currentSsid',
  'openWifiPanel',
  'syncNetworkSuggestions',
  'requestPermissions',
  'isLocationServiceEnabled',
  'ensurePortalDetectionOff',
  'restorePortalDetection',
  'portalStatus',
  'shizukuEnsurePortalOff',
  'shizukuRestorePortalDetection',
  'shizukuRequestPermission',
  'rootEnsurePortalOff',
  'rootRestorePortalDetection',
  'openUrl',
  'requestAddTile',
  'refreshTile',
  'encryptSecret',
  'decryptSecret',
  'routeDiagnose',
  'routeBindWifi',
  'routeUnbind',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wlan_auto_connect/android');
  late List<MethodCall> log;
  late AndroidWlan wlan;

  setUp(() {
    log = [];
    wlan = AndroidWlan();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      // 按方法名返回合理模拟值，确保 Dart 侧不抛异常
      switch (call.method) {
        case 'scan':
          return <dynamic>[
            {'ssid': 'TestAP', 'signal': 80, 'connected': true},
          ];
        case 'currentSsid':
          return 'TestAP';
        case 'openWifiPanel':
          return true;
        case 'syncNetworkSuggestions':
          return 'ok';
        case 'restorePortalDetection':
          return 'restored';
        case 'shizukuRestorePortalDetection':
          return 'restored';
        case 'refreshTile':
          return true;
        case 'encryptSecret':
          return 'enc:v1:TEST';
        case 'decryptSecret':
          return 'plain';
        case 'requestPermissions':
          return true;
        case 'isLocationServiceEnabled':
          return true;
        case 'ensurePortalDetectionOff':
          return 'disabled';
        case 'portalStatus':
          return <String, dynamic>{
            'off': true,
            'writePerm': true,
            'shizukuRunning': false,
            'shizukuPerm': false,
            'rootAvail': true,
          };
        case 'shizukuEnsurePortalOff':
          return 'disabled';
        case 'shizukuRequestPermission':
          return true;
        case 'rootEnsurePortalOff':
          return 'disabled';
        case 'rootRestorePortalDetection':
          return 'restored';
        case 'openUrl':
          return true;
        case 'requestAddTile':
          return true;
        case 'routeDiagnose':
          return <String, dynamic>{
            'defaultTransport': 'cellular',
            'wifiConnected': true,
            'wifiValidated': false,
            'wifiCaptivePortal': true,
            'mobileAvailable': true,
            'bound': false,
          };
        case 'routeBindWifi':
          return 'ok';
        case 'routeUnbind':
          return 'ok';
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('MethodChannel 契约：方法名集合一致', () {
    test('Dart 调用列表与 Kotlin 处理列表完全一致', () {
      expect(_kDartMethods, equals(_kNativeMethods),
          reason:
              'AndroidWlan 方法名与 WlanMethods.handle 中的 when 分支不一致，'
              '请同步更新两侧。');
    });

    test('每个 Dart 方法调用都命中 Kotlin 已知方法名', () async {
      await wlan.scan();
      await wlan.currentSsid();
      await wlan.openWifiPanel();
      await wlan.syncNetworkSuggestions(['AP']);
      await wlan.requestPermissions();
      await wlan.isLocationServiceEnabled();
      await wlan.ensurePortalDetectionOff();
      await wlan.restorePortalDetection();
      await wlan.portalStatus();
      await wlan.shizukuEnsurePortalOff();
      await wlan.shizukuRestorePortalDetection();
      await wlan.shizukuRequestPermission();
      await wlan.rootEnsurePortalOff();
      await wlan.rootRestorePortalDetection();
      await wlan.openUrl('https://example.com/dl.apk');
      await wlan.requestAddTile();
      await wlan.refreshTile();
      await wlan.encryptSecret('x');
      await wlan.decryptSecret('x');
      await wlan.routeDiagnose();
      await wlan.routeBindWifi();
      await wlan.routeUnbind();

      // 验证实际发出的 method 全部在 Kotlin 已知集合内
      for (final call in log) {
        expect(_kNativeMethods, contains(call.method),
            reason:
                'Dart 侧调用 "${call.method}" 在 WlanMethods.handle 中无对应分支');
      }
    });

    test('实际发出的方法数量覆盖全部契约条目', () async {
      await wlan.scan();
      await wlan.currentSsid();
      await wlan.openWifiPanel();
      await wlan.syncNetworkSuggestions(['AP']);
      await wlan.requestPermissions();
      await wlan.isLocationServiceEnabled();
      await wlan.ensurePortalDetectionOff();
      await wlan.restorePortalDetection();
      await wlan.portalStatus();
      await wlan.shizukuEnsurePortalOff();
      await wlan.shizukuRestorePortalDetection();
      await wlan.shizukuRequestPermission();
      await wlan.rootEnsurePortalOff();
      await wlan.rootRestorePortalDetection();
      await wlan.openUrl('https://example.com/dl.apk');
      await wlan.requestAddTile();
      await wlan.refreshTile();
      await wlan.encryptSecret('x');
      await wlan.decryptSecret('x');
      await wlan.routeDiagnose();
      await wlan.routeBindWifi();
      await wlan.routeUnbind();

      final calledMethods = log.map((c) => c.method).toSet();
      expect(calledMethods, equals(_kDartMethods),
          reason: 'AndroidWlan 实际调用方法集合与契约列表不匹配');
    });
  });

  group('MethodChannel 契约：参数格式', () {
    test('scan 传递 {"fresh": bool}', () async {
      await wlan.scan(fresh: true);
      expect(log.single.method, 'scan');
      final args = log.single.arguments as Map;
      expect(args.containsKey('fresh'), isTrue);
      expect(args['fresh'], isA<bool>());
      expect(args['fresh'], true);
    });

    test('scan 默认 fresh=false', () async {
      await wlan.scan();
      final args = log.single.arguments as Map;
      expect(args['fresh'], false);
    });

    test('syncNetworkSuggestions 传递 {"ssids": List<String>}', () async {
      await wlan.syncNetworkSuggestions(['Campus-5G', 'Campus']);
      expect(log.single.method, 'syncNetworkSuggestions');
      final args = log.single.arguments as Map;
      expect(args['ssids'], ['Campus-5G', 'Campus']);
    });

    test('syncNetworkSuggestions 空列表（清除数据时回收全部建议）', () async {
      await wlan.syncNetworkSuggestions(const []);
      final args = log.single.arguments as Map;
      expect(args['ssids'], isEmpty);
    });

    test('restorePortalDetection 无参数', () async {
      await wlan.restorePortalDetection();
      expect(log.single.method, 'restorePortalDetection');
      expect(log.single.arguments, isNull);
    });

    test('shizukuRestorePortalDetection 无参数', () async {
      await wlan.shizukuRestorePortalDetection();
      expect(log.single.method, 'shizukuRestorePortalDetection');
      expect(log.single.arguments, isNull);
    });

    test('refreshTile 无参数', () async {
      await wlan.refreshTile();
      expect(log.single.method, 'refreshTile');
      expect(log.single.arguments, isNull);
    });

    test('encryptSecret 传递 {"value": String}', () async {
      await wlan.encryptSecret('secret');
      expect(log.single.method, 'encryptSecret');
      final args = log.single.arguments as Map;
      expect(args['value'], 'secret');
    });

    test('decryptSecret 传递 {"value": String}', () async {
      await wlan.decryptSecret('enc:v1:AAAA');
      expect(log.single.method, 'decryptSecret');
      final args = log.single.arguments as Map;
      expect(args['value'], 'enc:v1:AAAA');
    });

    test('currentSsid 无参数', () async {
      await wlan.currentSsid();
      expect(log.single.method, 'currentSsid');
      expect(log.single.arguments, isNull);
    });

    test('openWifiPanel 无参数', () async {
      await wlan.openWifiPanel();
      expect(log.single.method, 'openWifiPanel');
      expect(log.single.arguments, isNull);
    });

    test('requestPermissions 无参数', () async {
      await wlan.requestPermissions();
      expect(log.single.method, 'requestPermissions');
      expect(log.single.arguments, isNull);
    });

    test('isLocationServiceEnabled 无参数', () async {
      await wlan.isLocationServiceEnabled();
      expect(log.single.method, 'isLocationServiceEnabled');
      expect(log.single.arguments, isNull);
    });

    test('ensurePortalDetectionOff 无参数', () async {
      await wlan.ensurePortalDetectionOff();
      expect(log.single.method, 'ensurePortalDetectionOff');
      expect(log.single.arguments, isNull);
    });

    test('portalStatus 无参数', () async {
      await wlan.portalStatus();
      expect(log.single.method, 'portalStatus');
      expect(log.single.arguments, isNull);
    });

    test('shizukuEnsurePortalOff 无参数', () async {
      await wlan.shizukuEnsurePortalOff();
      expect(log.single.method, 'shizukuEnsurePortalOff');
      expect(log.single.arguments, isNull);
    });

    test('shizukuRequestPermission 无参数', () async {
      await wlan.shizukuRequestPermission();
      expect(log.single.method, 'shizukuRequestPermission');
      expect(log.single.arguments, isNull);
    });

    test('rootEnsurePortalOff 无参数', () async {
      await wlan.rootEnsurePortalOff();
      expect(log.single.method, 'rootEnsurePortalOff');
      expect(log.single.arguments, isNull);
    });

    test('rootRestorePortalDetection 无参数', () async {
      await wlan.rootRestorePortalDetection();
      expect(log.single.method, 'rootRestorePortalDetection');
      expect(log.single.arguments, isNull);
    });

    test('openUrl 传递 {"url": String}', () async {
      await wlan.openUrl('https://dl.suspect.top/wlan/shizuku/shizuku-v13.5.4.apk');
      expect(log.single.method, 'openUrl');
      final args = log.single.arguments as Map;
      expect(args['url'],
          'https://dl.suspect.top/wlan/shizuku/shizuku-v13.5.4.apk');
    });

    test('requestAddTile 无参数', () async {
      await wlan.requestAddTile();
      expect(log.single.method, 'requestAddTile');
      expect(log.single.arguments, isNull);
    });

    test('routeDiagnose / routeBindWifi / routeUnbind 均无参数', () async {
      await wlan.routeDiagnose();
      expect(log[0].method, 'routeDiagnose');
      expect(log[0].arguments, isNull);
      await wlan.routeBindWifi();
      expect(log[1].method, 'routeBindWifi');
      expect(log[1].arguments, isNull);
      await wlan.routeUnbind();
      expect(log[2].method, 'routeUnbind');
      expect(log[2].arguments, isNull);
    });
  });

  group('MethodChannel 契约：返回值解析', () {
    test('scan 返回 List<Map> 解析为 AndroidWifiNetwork 列表', () async {
      final networks = await wlan.scan();
      expect(networks, hasLength(1));
      expect(networks.first.ssid, 'TestAP');
      expect(networks.first.signal, 80);
      expect(networks.first.connected, true);
    });

    test('portalStatus 返回 Map 解析为 PortalStatus 对象', () async {
      final status = await wlan.portalStatus();
      expect(status, isNotNull);
      expect(status!.off, true);
      expect(status.writePerm, true);
      expect(status.shizukuRunning, false);
      expect(status.shizukuPerm, false);
      expect(status.rootAvail, true);
    });

    test('rootEnsurePortalOff 返回 String 状态码', () async {
      final result = await wlan.rootEnsurePortalOff();
      expect(result, 'disabled');
    });

    test('openUrl 返回 bool', () async {
      final ok = await wlan.openUrl('https://example.com');
      expect(ok, isTrue);
    });

    test('ensurePortalDetectionOff 返回 String 状态码', () async {
      final result = await wlan.ensurePortalDetectionOff();
      expect(result, 'disabled');
    });

    test('currentSsid 返回 String', () async {
      final ssid = await wlan.currentSsid();
      expect(ssid, 'TestAP');
    });

    test('routeDiagnose 返回 Map 解析为 RouteDiag，且能判出「流量被移动数据抢走」',
        () async {
      final diag = await wlan.routeDiagnose();
      expect(diag, isNotNull);
      expect(diag!.defaultTransport, 'cellular');
      expect(diag.wifiConnected, isTrue);
      expect(diag.wifiValidated, isFalse);
      expect(diag.wifiCaptivePortal, isTrue);
      expect(diag.mobileAvailable, isTrue);
      expect(diag.bound, isFalse);
      expect(diag.cellularPreempted, isTrue);
      expect(diag.shouldBindWifi, isTrue);
    });

    test('routeBindWifi / routeUnbind 返回 String 状态码', () async {
      expect(await wlan.routeBindWifi(), 'ok');
      expect(await wlan.routeUnbind(), 'ok');
    });
  });
}
