import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/services/portal_config.dart';

void main() {
  group('PortalConfig.isValidHost', () {
    test('合法 IPv4', () {
      expect(PortalConfig.isValidHost('172.16.200.11'), isTrue);
      expect(PortalConfig.isValidHost('10.0.0.1'), isTrue);
      expect(PortalConfig.isValidHost('255.255.255.255'), isTrue);
    });

    test('IPv4 段越界判为非法', () {
      expect(PortalConfig.isValidHost('172.16.200.256'), isFalse);
      expect(PortalConfig.isValidHost('999.1.1.1'), isFalse);
    });

    test('合法域名', () {
      expect(PortalConfig.isValidHost('portal.example.edu.cn'), isTrue);
      expect(PortalConfig.isValidHost('a-b.example.com'), isTrue);
    });

    test('含协议/路径/空格/端口判为非法', () {
      expect(PortalConfig.isValidHost('http://172.16.200.11'), isFalse);
      expect(PortalConfig.isValidHost('172.16.200.11/eportal'), isFalse);
      expect(PortalConfig.isValidHost('172.16.200.11:801'), isFalse);
      expect(PortalConfig.isValidHost('  '), isFalse);
      expect(PortalConfig.isValidHost('has space'), isFalse);
    });

    test('空串判为非法', () {
      expect(PortalConfig.isValidHost(''), isFalse);
    });
  });

  group('PortalConfig.isValidEport', () {
    test('1-65535 合法', () {
      expect(PortalConfig.isValidEport(1), isTrue);
      expect(PortalConfig.isValidEport(801), isTrue);
      expect(PortalConfig.isValidEport(65535), isTrue);
    });

    test('越界或非正数非法', () {
      expect(PortalConfig.isValidEport(0), isFalse);
      expect(PortalConfig.isValidEport(-1), isFalse);
      expect(PortalConfig.isValidEport(65536), isFalse);
    });
  });

  group('PortalConfig 默认值', () {
    test('默认 host/eport 与历史行为一致', () {
      expect(PortalConfig.defaultHost, '172.16.200.11');
      expect(PortalConfig.defaultEport, 801);
    });

    test('协议路径常量', () {
      expect(PortalConfig.chkStatusPath, '/drcom/chkstatus');
      expect(PortalConfig.loginPath, '/eportal/portal/login');
    });
  });
}
