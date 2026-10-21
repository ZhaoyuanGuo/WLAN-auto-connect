// HTTPDNS 通道现状核验脚本（脱离 Flutter 运行）。
//
// 用法：
//   dart run tool/httpdns_probe.dart
//   dart run tool/httpdns_probe.dart --host auth.suspect.top
//
// 依次探测三种通道对目标域名的解析结果与耗时，输出对比表格：
//   1) 明文 /d         —— http://119.29.29.98/d?host=<h>&account=8859
//   2) HTTPS + token   —— https://119.29.29.99/...?token=<TOKEN>
//      （不带 --token 时该项跳过；本项目走 DoH，不注入 token）
//   3) DoH JSON        —— https://doh.pub/dns-query?name=<h>&type=A
//      分别按 IP 1.12.12.12 / 120.53.53.53 直连 + SNI 升级 TLS。
//
// 新项目第一件事就是跑本脚本确认通道现状（spec 一/决策前提）。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _plainTextD = 'http://119.29.29.98/d';
const _httpsTokenD = 'https://119.29.29.99/s';
const _dohEndpoints = ['1.12.12.12', '120.53.53.53'];
const _dohHost = 'doh.pub';
const _accountId = '8859';
const _timeout = Duration(seconds: 6);

Future<void> main(List<String> args) async {
  final host = _argOr(args, '--host', 'auth.suspect.top');
  final token = _argOrNull(args, '--token');
  print('== HTTPDNS 通道核验 ==');
  print('目标域名: $host');
  print('时间: ${DateTime.now().toIso8601String()}');
  print('');

  final results = <ProbeResult>[];

  // 通道 1：明文 /d
  results.add(await _probePlainTextD(host));

  // 通道 2：HTTPS + token（可选）
  if (token != null && token.isNotEmpty) {
    results.add(await _probeHttpsToken(host, token));
  } else {
    results.add(ProbeResult(
        channel: 'HTTPS /s?token=',
        note: '跳过（未传 --token；本项目走 DoH 时永远不需要）',
        ips: const [],
        elapsed: Duration.zero));
  }

  // 通道 3：DoH JSON（两个入口 IP 各测一次）
  for (final ip in _dohEndpoints) {
    results.add(await _probeDoh(host, ip));
  }

  _printTable(results);

  // 附：LocalDNS 参考耗时
  final sw = Stopwatch()..start();
  try {
    final addrs = await InternetAddress.lookup(host)
        .timeout(_timeout, onTimeout: () => throw TimeoutException(''));
    sw.stop();
    print('\n参考 LocalDNS（InternetAddress.lookup）: '
        '${addrs.map((a) => a.address).join(",")}  耗时 ${sw.elapsedMilliseconds}ms');
  } catch (e) {
    sw.stop();
    print('\n参考 LocalDNS: 查询失败（$e）  耗时 ${sw.elapsedMilliseconds}ms');
  }
}

String _argOr(List<String> args, String name, String dft) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return dft;
  return args[i + 1];
}

String? _argOrNull(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

class ProbeResult {
  ProbeResult({
    required this.channel,
    required this.ips,
    required this.elapsed,
    this.note,
    this.status,
  });
  final String channel;
  final List<String> ips;
  final Duration elapsed;
  final String? note;
  final Object? status;
}

Future<ProbeResult> _probePlainTextD(String host) async {
  final sw = Stopwatch()..start();
  try {
    final url = Uri.parse('$_plainTextD?host=$host&account=$_accountId');
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.openUrl('GET', url).timeout(_timeout);
      final resp = await req.close().timeout(_timeout);
      final body =
          await resp.transform(utf8.decoder).join().timeout(_timeout);
      sw.stop();
      client.close(force: true);
      final ips = _splitIps(body);
      return ProbeResult(
        channel: '明文 /d',
        ips: ips,
        elapsed: sw.elapsed,
        status: 'HTTP ${resp.statusCode}',
        note: ips.isEmpty ? '空体（spec 实测结论）' : null,
      );
    } finally {
      client.close(force: true);
    }
  } catch (e) {
    sw.stop();
    return ProbeResult(
        channel: '明文 /d',
        ips: const [],
        elapsed: sw.elapsed,
        status: 'ERR',
        note: '$e');
  }
}

Future<ProbeResult> _probeHttpsToken(String host, String token) async {
  final sw = Stopwatch()..start();
  try {
    final url =
        Uri.parse('$_httpsTokenD?host=$host&clientIP=1.1.1.1&ttl=1&account=$_accountId&token=$token');
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.openUrl('GET', url).timeout(_timeout);
      final resp = await req.close().timeout(_timeout);
      final body =
          await resp.transform(utf8.decoder).join().timeout(_timeout);
      sw.stop();
      final ips = _splitIps(body);
      return ProbeResult(
        channel: 'HTTPS /s?token=',
        ips: ips,
        elapsed: sw.elapsed,
        status: 'HTTP ${resp.statusCode}',
        note: ips.isEmpty ? '空体或鉴权失败' : null,
      );
    } finally {
      client.close(force: true);
    }
  } catch (e) {
    sw.stop();
    return ProbeResult(
        channel: 'HTTPS /s?token=',
        ips: const [],
        elapsed: sw.elapsed,
        status: 'ERR',
        note: '$e');
  }
}

Future<ProbeResult> _probeDoh(String host, String endpointIp) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    // 关键：按 IP 直连 + SNI 升级 TLS（对齐 lib/services/httpdns_service.dart）。
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final port = proxyPort ?? uri.port;
      final tcpTask =
          await Socket.startConnect(InternetAddress(endpointIp), port);
      final isSecure = uri.scheme == 'https';
      final Future<Socket> sockFut = tcpTask.socket.then<Socket>(
        (tcp) => isSecure
            ? SecureSocket.secure(tcp, host: _dohHost)
            : tcp,
      );
      return ConnectionTask.fromSocket<Socket>(sockFut, tcpTask.cancel);
    };
    client.findProxy = (_) => 'DIRECT';

    final uri = Uri.https(_dohHost, '/dns-query', {'name': host, 'type': 'A'});
    final req = await client.openUrl('GET', uri).timeout(_timeout);
    req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
    req.headers.set(HttpHeaders.hostHeader, _dohHost);
    final resp = await req.close().timeout(_timeout);
    final body = await resp.transform(utf8.decoder).join().timeout(_timeout);
    sw.stop();
    if (resp.statusCode != 200) {
      return ProbeResult(
        channel: 'DoH JSON @ $endpointIp',
        ips: const [],
        elapsed: sw.elapsed,
        status: 'HTTP ${resp.statusCode}',
        note: body.length > 120 ? '${body.substring(0, 120)}…' : body,
      );
    }
    final (ips, ttl) = _parseDohJson(body);
    return ProbeResult(
      channel: 'DoH JSON @ $endpointIp',
      ips: ips,
      elapsed: sw.elapsed,
      status: 'OK${ttl != null ? " ttl=${ttl}s" : ""}',
      note: ips.isEmpty ? '无 A 记录' : null,
    );
  } catch (e) {
    sw.stop();
    return ProbeResult(
        channel: 'DoH JSON @ $endpointIp',
        ips: const [],
        elapsed: sw.elapsed,
        status: 'ERR',
        note: '$e');
  } finally {
    client.close(force: true);
  }
}

(List<String>, int?) _parseDohJson(String body) {
  try {
    final obj = jsonDecode(body) as Map<String, dynamic>;
    final status = (obj['Status'] as num?)?.toInt() ?? -1;
    if (status != 0) return (const [], null);
    final answers = obj['Answer'];
    if (answers is! List) return (const [], null);
    final ips = <String>[];
    int? minTtl;
    for (final raw in answers) {
      if (raw is! Map) continue;
      final type = (raw['type'] as num?)?.toInt() ?? 0;
      if (type != 1 && type != 28) continue;
      final data = raw['data'];
      if (data is! String) continue;
      final ttl = (raw['TTL'] as num?)?.toInt();
      if (ttl != null && (minTtl == null || ttl < minTtl)) minTtl = ttl;
      ips.add(data);
    }
    return (ips, minTtl);
  } catch (_) {
    return (const [], null);
  }
}

List<String> _splitIps(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return const [];
  return trimmed
      .split(RegExp(r'[,\s]+'))
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

void _printTable(List<ProbeResult> results) {
  print('┌──────────────────────────┬──────────────────────────┬──────────┬──────────────────────────────┐');
  print('│ 通道                     │ IP                       │ 耗时(ms) │ 状态/备注                    │');
  print('├──────────────────────────┼──────────────────────────┼──────────┼──────────────────────────────┤');
  for (final r in results) {
    print('| ${r.channel.padRight(24)} '
        '| ${r.ips.join(",").padRight(24)} '
        '| ${r.elapsed.inMilliseconds.toString().padLeft(6)} '
        '| ${(r.status?.toString() ?? "-") + "  ${(r.note ?? "")}".padRight(30).substring(0, 30)} |');
  }
  print('└──────────────────────────┴──────────────────────────┴──────────┴──────────────────────────────┘');
}
