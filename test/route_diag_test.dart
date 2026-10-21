import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/mobile/android_wlan.dart';

/// RouteDiag 的判定逻辑（纯函数，不碰 MethodChannel）。
///
/// 背景：校园网未认证时系统把默认网络切到蜂窝，门户（内网地址）请求从移动数据
/// 发出必然超时，界面误报「门户不可达」。这里锁定「什么才算被抢占 / 什么时候才
/// 值得去钉 WLAN」，避免把「认证服务器地址填错」也当成路由问题。
void main() {
  RouteDiag diag({
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

  group('cellularPreempted：连着 WLAN 但默认网络不是它', () {
    test('正向：未认证校园网 + 移动数据为默认网络 → 判定被抢占', () {
      final d = diag(
        defaultTransport: 'cellular',
        wifiValidated: false,
        wifiCaptivePortal: true,
      );
      expect(d.cellularPreempted, isTrue);
      expect(d.shouldBindWifi, isTrue);
    });

    test('异常：默认网络就是 WLAN（正常校园网）→ 不算抢占', () {
      expect(diag().cellularPreempted, isFalse);
      expect(diag().shouldBindWifi, isFalse);
    });

    test('异常：根本没连 WLAN → 不算抢占（是真没连校园网）', () {
      final d = diag(defaultTransport: 'cellular', wifiConnected: false);
      expect(d.cellularPreempted, isFalse);
    });

    test('异常：已经钉在 WLAN 上 → 不再重复判定为抢占', () {
      final d = diag(defaultTransport: 'cellular', bound: true);
      expect(d.cellularPreempted, isFalse);
      expect(d.shouldBindWifi, isFalse);
    });

    test('异常：默认网络被 VPN/以太网抢走 → 算抢占但不值得钉 WLAN', () {
      final d = diag(
          defaultTransport: 'ethernet',
          wifiValidated: false,
          mobileAvailable: false);
      expect(d.cellularPreempted, isTrue);
      expect(d.shouldBindWifi, isFalse);
    });
  });

  group('fromMap：原生字段缺失或类型异常', () {
    test('空 Map 退化为「无信息」而不是抛异常', () {
      final d = RouteDiag.fromMap({});
      expect(d.defaultTransport, 'none');
      expect(d.wifiConnected, isFalse);
      expect(d.cellularPreempted, isFalse);
    });

    test('完整 Map 逐字段落地', () {
      final d = RouteDiag.fromMap({
        'defaultTransport': 'cellular',
        'wifiConnected': true,
        'wifiValidated': false,
        'wifiCaptivePortal': true,
        'mobileAvailable': true,
        'bound': true,
      });
      expect(d.defaultTransport, 'cellular');
      expect(d.wifiCaptivePortal, isTrue);
      expect(d.bound, isTrue);
    });
  });

  group('summary：日志里要能一眼看出成因', () {
    test('未验证 + 强制门户 + 移动数据可用都要出现', () {
      final s = diag(
        defaultTransport: 'cellular',
        wifiValidated: false,
        wifiCaptivePortal: true,
      ).summary;
      expect(s, contains('默认网络=cellular'));
      expect(s, contains('WLAN 未验证'));
      expect(s, contains('强制门户'));
      expect(s, contains('移动数据可用'));
      expect(s, isNot(contains('已钉在 WLAN')));
    });

    test('未连 WiFi 与已绑定时给出对应描述', () {
      expect(diag(wifiConnected: false).summary, contains('WLAN 未连接'));
      expect(diag(bound: true).summary, contains('已钉在 WLAN'));
    });
  });

  group('verdict：诊断导出里的一句话结论', () {
    test('路由被移动数据抢走 → 明说不是地址填错', () {
      final v = diag(defaultTransport: 'cellular', wifiValidated: false)
          .verdict;
      expect(v, contains('默认网络是 cellular'));
      expect(v, contains('移动数据'));
      expect(v, contains('不是认证服务器地址填错'));
    });

    test('未连 WLAN → 归为「没连上校园网」', () {
      expect(diag(wifiConnected: false).verdict, contains('没连上校园网'));
    });

    test('已钉在 WLAN → 优先说明已改走校园网', () {
      expect(
          diag(defaultTransport: 'cellular', bound: true).verdict,
          contains('已钉在 WLAN'));
    });

    test('默认网络就是已验证的 WLAN → 才指向地址/连通性问题', () {
      expect(diag().verdict, contains('需核对认证服务器地址'));
    });

    test('WLAN 为默认但未通过校验 → 提示 captive portal 限制', () {
      final v = diag(wifiValidated: false, wifiCaptivePortal: true).verdict;
      expect(v, contains('captive portal'));
      expect(v, isNot(contains('不是认证服务器地址填错')));
    });

    test('被非蜂窝网络（如 VPN）抢走 → 说「其他网络」而非移动数据', () {
      final v = diag(defaultTransport: 'other').verdict;
      expect(v, contains('其他网络'));
      expect(v, isNot(contains('移动数据')));
    });
  });
}
