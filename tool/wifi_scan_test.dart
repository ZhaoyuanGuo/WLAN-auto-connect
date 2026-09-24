// WiFi 扫描解析真实环境验证（脱离 Flutter 运行）。
// 用法：& "<flutter>\bin\cache\dart-sdk\bin\dart.exe" run tool/wifi_scan_test.dart
// ignore_for_file: avoid_print
import 'package:wlan_auto_connect/services/wifi_service.dart';

Future<void> main() async {
  final s = WifiService();
  final nets = await s.scan();
  print('scan count=${nets.length} lastError=${s.lastError}');
  for (final n in nets) {
    print('  - ${n.ssid} signal=${n.signal}% connected=${n.connected}');
  }
  print('currentSsid=${await s.currentSsid()}');
}
