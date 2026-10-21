import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/services/debug_log.dart';

void main() {
  group('脱敏工具', () {
    test('maskAccount 保留首尾各 2 位', () {
      expect(maskAccount('20210101'), '20****01');
      expect(maskAccount('123456'), '12**56');
    });

    test('maskAccount 长度不足时全掩', () {
      expect(maskAccount('ab'), '**');
      expect(maskAccount('abcd'), '****');
    });

    test('maskAccount 空串返回空串', () {
      expect(maskAccount(''), '');
      expect(maskAccount('   '), '');
    });

    test('maskSecret 全掩但保留长度', () {
      expect(maskSecret('secret'), '******');
      expect(maskSecret(''), '');
    });

    test('maskMac 保留前 3 段 OUI', () {
      expect(maskMac('aa:bb:cc:dd:ee:ff'), 'aa:bb:cc:**:**:**');
    });

    test('maskMac 段数不足时退化为全掩', () {
      expect(maskMac('aa:bb'), '*****');
    });
  });

  group('日志级别', () {
    test('级别数值递增', () {
      expect(LogLevel.debug.value, lessThan(LogLevel.info.value));
      expect(LogLevel.info.value, lessThan(LogLevel.warn.value));
      expect(LogLevel.warn.value, lessThan(LogLevel.error.value));
    });

    test('级别标签', () {
      expect(LogLevel.debug.label, 'DEBUG');
      expect(LogLevel.info.label, 'INFO');
      expect(LogLevel.warn.label, 'WARN');
      expect(LogLevel.error.label, 'ERROR');
    });

    test('默认最低级别为 INFO', () {
      expect(minLevel, LogLevel.info);
    });
  });

  group('轮转阈值', () {
    test('阈值与 PowerShell 侧一致（256KB）', () {
      expect(maxBytes, 256 * 1024);
    });
  });
}
