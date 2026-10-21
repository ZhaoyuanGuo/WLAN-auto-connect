import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/services/auto_login_service.dart';

void main() {
  group('AutoLoginService.parseLine', () {
    test('解析 [OK] 前缀行', () {
      final (level, msg) = AutoLoginService.parseLine('[OK] login success');
      expect(level, 'OK');
      expect(msg, 'login success');
    });

    test('解析 [ERR] 前缀行', () {
      final (level, msg) = AutoLoginService.parseLine('[ERR] timeout');
      expect(level, 'ERR');
      expect(msg, 'timeout');
    });

    test('解析 [INFO] 前缀行', () {
      final (level, msg) = AutoLoginService.parseLine('[INFO] connecting...');
      expect(level, 'INFO');
      expect(msg, 'connecting...');
    });

    test('无前缀行默认为 INFO', () {
      final (level, msg) = AutoLoginService.parseLine('raw output text');
      expect(level, 'INFO');
      expect(msg, 'raw output text');
    });

    test('空字符串返回 INFO + 空消息', () {
      final (level, msg) = AutoLoginService.parseLine('');
      expect(level, 'INFO');
      expect(msg, '');
    });

    test('前缀缺少空格时不匹配，视为 INFO', () {
      // 格式要求 "[OK] "（右括号后有空格），缺少空格不匹配
      final (level, msg) = AutoLoginService.parseLine('[OK]missing space');
      expect(level, 'INFO');
      expect(msg, '[OK]missing space');
    });

    test('未知前缀标签视为 INFO', () {
      final (level, msg) = AutoLoginService.parseLine('[WARN] something');
      expect(level, 'INFO');
      expect(msg, '[WARN] something');
    });

    test('消息中包含括号内容正确保留', () {
      final (level, msg) =
          AutoLoginService.parseLine('[OK] result=[INFO] nested');
      expect(level, 'OK');
      expect(msg, 'result=[INFO] nested');
    });
  });

  group('WifiProfile 序列化/反序列化', () {
    test('toJson/fromJson 往返一致（完整字段）', () {
      final original = WifiProfile(
        ssid: 'Campus-5G',
        account: '20210101',
        suffix: '@dx',
        hasPassword: true,
      );
      final restored = WifiProfile.fromJson(original.toJson());
      expect(restored.ssid, original.ssid);
      expect(restored.account, original.account);
      expect(restored.suffix, original.suffix);
      expect(restored.hasPassword, original.hasPassword);
    });

    test('toJson/fromJson 往返一致（默认空值）', () {
      final original = WifiProfile(ssid: 'OpenNet');
      final restored = WifiProfile.fromJson(original.toJson());
      expect(restored.ssid, 'OpenNet');
      expect(restored.account, '');
      expect(restored.suffix, '');
      expect(restored.hasPassword, false);
    });

    test('fromJson 对缺失字段使用默认值', () {
      final restored = WifiProfile.fromJson({'ssid': 'TestAP'});
      expect(restored.ssid, 'TestAP');
      expect(restored.account, '');
      expect(restored.suffix, '');
      expect(restored.hasPassword, false);
    });

    test('fromJson 对 null 值安全降级', () {
      final restored = WifiProfile.fromJson(<String, dynamic>{
        'ssid': null,
        'account': null,
        'suffix': null,
        'hasPassword': null,
      });
      expect(restored.ssid, '');
      expect(restored.account, '');
      expect(restored.suffix, '');
      expect(restored.hasPassword, false);
    });

    test('copyWith 保留未修改字段', () {
      final original =
          WifiProfile(ssid: 'AP1', account: 'acc', suffix: '@lt', hasPassword: true);
      final modified = original.copyWith(account: 'newacc');
      expect(modified.ssid, 'AP1');
      expect(modified.account, 'newacc');
      expect(modified.suffix, '@lt');
      expect(modified.hasPassword, true);
    });
  });

  group('WifiService netsh 输出解析', () {
    // 正则与 scan() 内嵌解析逻辑一致，验证核心匹配行为。
    final ssidRe = RegExp(r'^\s*SSID\s+\d+\s*:\s*(.*)$');
    final signalRe = RegExp(r'^\s*(?:信号|Signal)\s*:\s*(\d+)\s*%');

    test('匹配英文 SSID 行', () {
      final m = ssidRe.firstMatch('SSID 1 : LNPC-STU-5G');
      expect(m, isNotNull);
      expect(m!.group(1)!.trim(), 'LNPC-STU-5G');
    });

    test('匹配中文 SSID 行（含前导空格）', () {
      final m = ssidRe.firstMatch('    SSID 3 : 校园网');
      expect(m, isNotNull);
      expect(m!.group(1)!.trim(), '校园网');
    });

    test('隐藏网络 SSID 值为空', () {
      final m = ssidRe.firstMatch('SSID 2 : ');
      expect(m, isNotNull);
      expect(m!.group(1)!.trim(), '');
    });

    test('不匹配无编号 SSID 行（interfaces 格式）', () {
      // interfaces 输出为 "SSID : xxx"（无数字），不应被 scan 正则捕获
      final m = ssidRe.firstMatch('SSID : MyNetwork');
      expect(m, isNull);
    });

    test('匹配英文 Signal 行', () {
      final m = signalRe.firstMatch('Signal : 82%');
      expect(m, isNotNull);
      expect(int.tryParse(m!.group(1)!), 82);
    });

    test('匹配中文 信号 行', () {
      final m = signalRe.firstMatch('信号 : 75%');
      expect(m, isNotNull);
      expect(int.tryParse(m!.group(1)!), 75);
    });

    test('匹配含前导空格的信号行', () {
      final m = signalRe.firstMatch('        信号 : 100%');
      expect(m, isNotNull);
      expect(int.tryParse(m!.group(1)!), 100);
    });

    test('不匹配无效信号格式', () {
      expect(signalRe.firstMatch('Signal : %'), isNull);
      expect(signalRe.firstMatch('Signal : abc%'), isNull);
      expect(signalRe.firstMatch('No signal here'), isNull);
    });

    test('模拟完整 netsh 多 BSSID 解析取最大信号', () {
      // 模拟 scan() 核心解析逻辑：同一 SSID 多 BSSID 取最大信号
      const netshOutput = '''
SSID 1 : CampusWiFi
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : aa:bb:cc:dd:ee:01
         Signal             : 60%
         Radio type         : 802.11ac
    BSSID 2                 : aa:bb:cc:dd:ee:02
         Signal             : 85%
         Radio type         : 802.11ac
SSID 2 : CampusWiFi
    Network type            : Infrastructure
    Authentication          : WPA2-Personal
    Encryption              : CCMP
    BSSID 1                 : ff:00:11:22:33:44
         Signal             : 40%
         Radio type         : 802.11n
''';

      final result = <String, int>{};
      String current = '';
      int signal = 0;
      void flush() {
        if (current.isEmpty) return;
        final existing = result[current];
        if (existing == null || signal > existing) {
          result[current] = signal;
        }
      }

      for (final line in netshOutput.split(RegExp(r'\r?\n'))) {
        final ssidMatch = ssidRe.firstMatch(line);
        if (ssidMatch != null) {
          flush();
          current = ssidMatch.group(1)!.trim();
          signal = 0;
          continue;
        }
        final sigMatch = signalRe.firstMatch(line);
        if (sigMatch != null) {
          final v = int.tryParse(sigMatch.group(1)!) ?? 0;
          if (v > signal) signal = v;
        }
      }
      flush();

      // CampusWiFi 出现两次（SSID 1 和 SSID 2），应取最大信号 85
      expect(result['CampusWiFi'], 85);
    });

    test('CRLF 行分割兼容', () {
      const crlfText = 'SSID 1 : TestAP\r\n    Signal : 50%\r\n';
      final lines = crlfText.split(RegExp(r'\r?\n'));
      expect(lines.length, greaterThanOrEqualTo(2));
      expect(ssidRe.firstMatch(lines[0]), isNotNull);
    });
  });
}
