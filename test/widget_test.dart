import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/services/portal_client.dart';

void main() {
  test('PortalClient.parseJsonp 解析 JSONP 响应', () {
    final json = PortalClient.parseJsonp(
        'dr1({"result":1,"msg":"login success","ret_code":1})');
    expect(json, isNotNull);
    expect(json!['result'], 1);
    expect(json['ret_code'], 1);
  });

  test('PortalClient.parseJsonp 对非法输入返回 null', () {
    expect(PortalClient.parseJsonp('not jsonp'), isNull);
    expect(PortalClient.parseJsonp(''), isNull);
  });
}
