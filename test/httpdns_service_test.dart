import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/services/httpdns_config.dart';
import 'package:wlan_auto_connect/services/httpdns_service.dart';

/// HTTPDNS 服务层单元测试。
///
/// 全部走 `queryOverride` mock DoH 响应，不真发网络。
void main() {
  late HttpDnsService svc;

  setUp(() {
    svc = HttpDnsService.instance;
    svc.resetForTest();
  });

  group('isIpLiteral（字符串判定，不用 InternetAddress.tryParse）', () {
    test('IPv4 点分十进制', () {
      expect(HttpDnsService.isIpLiteral('1.2.3.4'), isTrue);
      expect(HttpDnsService.isIpLiteral('192.168.0.1'), isTrue);
    });
    test('IPv6（含冒号）', () {
      expect(HttpDnsService.isIpLiteral('::1'), isTrue);
      expect(HttpDnsService.isIpLiteral('2001:db8::1'), isTrue);
    });
    test('域名不算 IP', () {
      expect(HttpDnsService.isIpLiteral('example.com'), isFalse);
      expect(HttpDnsService.isIpLiteral('a.b.c'), isFalse);
      expect(HttpDnsService.isIpLiteral('1.2.3.4.example.com'), isFalse);
    });
  });

  group('resolve 前置门：白名单 / IP 字面量', () {
    test('非白名单域名直接返回 null，不触发 DoH', () async {
      var called = 0;
      svc.queryOverride = (ip, host) async {
        called++;
        return '{"Status":0,"Answer":[]}';
      };
      final ips = await svc.resolve('example.com');
      expect(ips, isNull);
      expect(called, 0);
    });

    test('IP 字面量走 isIpLiteral 早退，不查 DoH', () async {
      var called = 0;
      svc.queryOverride = (ip, host) async {
        called++;
        return '{"Status":0,"Answer":[]}';
      };
      final ips = await svc.resolve('8.8.8.8');
      expect(ips, isNull);
      expect(called, 0);
    });

    test('编译期开关默认开启', () {
      expect(HttpDnsConfig.enable, isTrue);
    });
  });

  group('resolve 正向解析：DoH JSON 提取 + TTL clamp', () {
    test('两个 A 记录，返回全部 IP', () async {
      final body = jsonEncode({
        'Status': 0,
        'Answer': [
          {'name': 'auth.suspect.top', 'type': 1, 'TTL': 30, 'data': '111.1.1.1'},
          {'name': 'auth.suspect.top', 'type': 1, 'TTL': 120, 'data': '111.1.1.2'},
        ],
      });
      svc.queryOverride = (ip, host) async => body;

      final ips = await svc.resolve('auth.suspect.top');
      expect(ips, isNotNull);
      expect(ips!.length, 2);
      expect(ips, containsAll(['111.1.1.1', '111.1.1.2']));
      // TTL=30 clamp 到下限 60s：此时 getCached 仍应命中（未过期）
      expect(svc.getCached('auth.suspect.top'), isNotNull);
    });

    test('TTL 超大时 clamp 到 30 分钟上限', () async {
      final body = jsonEncode({
        'Status': 0,
        'Answer': [
          {'name': 'x', 'type': 1, 'TTL': 999999, 'data': '111.1.1.1'},
        ],
      });
      svc.queryOverride = (ip, host) async => body;
      final ips = await svc.resolve('auth.suspect.top');
      expect(ips, ['111.1.1.1']);
    });

    test('只保留 type=1(A) 与 type=28(AAAA)，其他忽略', () async {
      final body = jsonEncode({
        'Status': 0,
        'Answer': [
          {'name': 'x', 'type': 1, 'TTL': 300, 'data': '1.1.1.1'},
          {'name': 'x', 'type': 5, 'TTL': 300, 'data': 'cname.example'},
          {'name': 'x', 'type': 28, 'TTL': 300, 'data': '2001:db8::1'},
        ],
      });
      svc.queryOverride = (ip, host) async => body;
      final ips = await svc.resolve('auth.suspect.top');
      expect(ips, isNotNull);
      expect(ips!.contains('1.1.1.1'), isTrue);
      expect(ips.contains('2001:db8::1'), isTrue);
      expect(ips.any((s) => s.contains('cname')), isFalse);
    });
  });

  group('负缓存', () {
    test('Status != 0 时缓存空结果，短期不重查', () async {
      var calls = 0;
      svc.queryOverride = (ip, host) async {
        calls++;
        return '{"Status":2,"Answer":[]}';
      };
      final r1 = await svc.resolve('auth.suspect.top');
      expect(r1, isNull);
      expect(calls, 1);

      final r2 = await svc.resolve('auth.suspect.top');
      expect(r2, isNull);
      expect(calls, 1);
    });

    test('Answer 为空数组视为负缓存', () async {
      var calls = 0;
      svc.queryOverride = (ip, host) async {
        calls++;
        return '{"Status":0,"Answer":[]}';
      };
      await svc.resolve('auth.suspect.top');
      await svc.resolve('auth.suspect.top');
      expect(calls, 1);
    });

    test('非法 JSON 视为负缓存', () async {
      var calls = 0;
      svc.queryOverride = (ip, host) async {
        calls++;
        return 'not a json';
      };
      final r = await svc.resolve('auth.suspect.top');
      expect(r, isNull);
      await svc.resolve('auth.suspect.top');
      expect(calls, 1);
    });

    test('缓存条目过期后重新查询', () async {
      var calls = 0;
      svc.queryOverride = (ip, host) async {
        calls++;
        return jsonEncode({
          'Status': 0,
          'Answer': [
            {'name': 'x', 'type': 1, 'TTL': 300, 'data': '1.1.1.$calls'},
          ],
        });
      };
      await svc.resolve('auth.suspect.top');
      expect(calls, 1);
      // 手动让缓存过期
      svc.primeCache(
        'auth.suspect.top',
        const ['1.1.1.1'],
        DateTime.now().subtract(const Duration(seconds: 1)),
      );
      final r = await svc.resolve('auth.suspect.top');
      expect(calls, 2);
      expect(r, isNotNull);
    });
  });

  group('单飞（并发去重）', () {
    test('并发 N 次同 host 只发 1 次真实查询', () async {
      var calls = 0;
      final gate = Completer<void>();
      svc.queryOverride = (ip, host) async {
        calls++;
        await gate.future;
        return jsonEncode({
          'Status': 0,
          'Answer': [
            {'name': 'x', 'type': 1, 'TTL': 300, 'data': '9.9.9.9'},
          ],
        });
      };

      final futures =
          List.generate(10, (_) => svc.resolve('auth.suspect.top'));
      // 让 microtask 队列转一圈，确保单飞表已登记后再放行
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      final results = await Future.wait(futures);

      expect(calls, 1);
      for (final r in results) {
        expect(r, ['9.9.9.9']);
      }
    });

    test('不同 host 并发各自独立查询', () async {
      var calls = 0;
      svc.queryOverride = (ip, host) async {
        calls++;
        return jsonEncode({
          'Status': 0,
          'Answer': [
            {'name': host, 'type': 1, 'TTL': 300, 'data': '10.0.0.$calls'},
          ],
        });
      };
      final r = await Future.wait([
        svc.resolve('auth.suspect.top'),
        svc.resolve('wlan-sync.suspect.top'),
      ]);
      expect(calls, 2);
      expect(r[0], isNotNull);
      expect(r[1], isNotNull);
    });
  });

  group('入口轮转 + 拉黑', () {
    test('第一个入口抛异常，第二个成功', () async {
      final hits = <String>[];
      svc.queryOverride = (ip, host) async {
        hits.add(ip);
        if (hits.length == 1) {
          throw Exception('timeout');
        }
        return jsonEncode({
          'Status': 0,
          'Answer': [
            {'name': 'x', 'type': 1, 'TTL': 300, 'data': '1.1.1.1'},
          ],
        });
      };

      final ips = await svc.resolve('auth.suspect.top');
      expect(ips, ['1.1.1.1']);
      expect(hits.length, 2);
      expect(hits[0], HttpDnsConfig.dohEndpoints[0]);
      expect(hits[1], HttpDnsConfig.dohEndpoints[1]);
    });
  });

  group('全入口挂 → 冷静期回退', () {
    test('两入口都抛异常后，resolve 返回 null 且短期内不再发查询', () async {
      var calls = 0;
      svc.queryOverride = (ip, host) async {
        calls++;
        throw Exception('all down');
      };

      final r1 = await svc.resolve('auth.suspect.top');
      expect(r1, isNull);
      final callsAfterFirst = calls;
      expect(callsAfterFirst, HttpDnsConfig.dohEndpoints.length);

      // 全入口挂进入 global cooldown，期内另一 host 的 resolve 也不应发查询。
      final r2 = await svc.resolve('wlan-sync.suspect.top');
      expect(r2, isNull);
      expect(calls, callsAfterFirst,
          reason: 'global cooldown 期间 resolve 应直接返回 null');
    });
  });
}
