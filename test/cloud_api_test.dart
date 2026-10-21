import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/cloud/cloud_api.dart';

void main() {
  group('CloudApi 基址安全配置', () {
    test('默认基址为 HTTPS 域名（HTTPDNS + LE 泛域名证书接管）', () {
      expect(CloudApi.authBase, isNotEmpty);
      expect(CloudApi.syncBase, isNotEmpty);
      expect(CloudApi.authBase, startsWith('https://'));
      expect(CloudApi.syncBase, startsWith('https://'));
    });

    test('appId 与后端约定一致', () {
      expect(CloudApi.appId, 'wlanconnect');
    });

    test('默认禁止明文，旧 IP 直连回退需显式 dart-define', () {
      // 切 HTTPS 域名后，默认不允许明文；过渡回退需开发侧显式传：
      //   --dart-define=ALLOW_INSECURE_CLOUD=true \
      //   --dart-define=CLOUD_AUTH_BASE=http://111.229.33.249:3010
      expect(CloudApi.allowInsecureCloud, isFalse);
    });
  });
}
