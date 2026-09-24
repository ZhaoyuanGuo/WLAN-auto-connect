import 'dart:convert';
import 'dart:io';

import 'package:gbk_codec/gbk_codec.dart';

import 'debug_log.dart';

/// 扫描到的 WiFi 网络。
class WifiNetwork {
  WifiNetwork({
    required this.ssid,
    required this.signal,
    this.connected = false,
    this.visible = true,
  });

  final String ssid;
  final int signal; // 0-100
  final bool connected; // 是否为当前已连接的网络
  final bool visible; // false = 已保存但当前扫描不到

  bool get hidden => ssid.isEmpty;
}

/// 通过 Windows 自带的 netsh wlan 命令操作 WLAN：
/// 扫描可见网络列表、获取当前连接的 SSID、连接已保存的网络。
/// netsh 输出编码随系统控制台代码页而定（UTF-8 或 GBK），解码自动适配；
/// 关键字（SSID/Signal 等）不做本地化，值部分按中英双标签兼容解析。
class WifiService {
  /// 上次 _run 的失败原因（用于 UI 日志显示），null = 正常。
  String? lastError;

  String get _netsh {
    final sysroot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return '$sysroot\\System32\\netsh.exe';
  }

  /// 按 UTF-8 优先解码；无效 UTF-8（中文 GBK 系统）回退 GBK。
  String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return gbk.decode(bytes);
    }
  }

  /// 运行 netsh 并解码输出，失败返回空串并记录 lastError。
  Future<String> _run(List<String> args) async {
    lastError = null;
    try {
      final proc = await Process.start(_netsh, args, runInShell: false);
      final out = await proc.stdout.fold<List<int>>(
          <int>[], (acc, chunk) => acc..addAll(chunk));
      await proc.stderr.drain<void>();
      final code = await proc.exitCode;
      if (code != 0 && out.isEmpty) {
        lastError = 'netsh exit=$code';
        dlog('NETSH_FAIL args=$args ${lastError!}');
        return '';
      }
      return _decode(out); // 解码器对坏字节自动降级，不会抛异常
    } catch (e) {
      lastError = 'netsh 启动失败: $e';
      dlog('NETSH_SPAWN_FAIL args=$args $e');
      return '';
    }
  }

  /// 按行拆分（兼容 CRLF：netsh 输出为 \r\n，残留的 \r 会破坏行级正则）。
  List<String> _lines(String text) => text.split(RegExp(r'\r?\n'));

  /// 扫描可见 WiFi 列表（按信号强度降序）。
  Future<List<WifiNetwork>> scan() async {
    final text = await _run(['wlan', 'show', 'networks', 'mode=bssid']);
    final result = <String, WifiNetwork>{};

    // SSID 行形如 "SSID 1 : LNPC-STU-5G"（隐藏网络值为空）。
    // 信号行形如 "信号 : 82%" / "Signal : 82%"（每个 BSSID 一行，取最大值）。
    String current = '';
    int signal = 0;
    void flush() {
      if (current.isEmpty) return; // 跳过隐藏网络
      final existing = result[current];
      if (existing == null || signal > existing.signal) {
        result[current] = WifiNetwork(ssid: current, signal: signal);
      }
    }

    for (final line in _lines(text)) {
      final ssid =
          RegExp(r'^\s*SSID\s+\d+\s*:\s*(.*)$').firstMatch(line);
      if (ssid != null) {
        flush();
        current = ssid.group(1)!.trim();
        signal = 0;
        continue;
      }
      final sig = RegExp(r'^\s*(?:信号|Signal)\s*:\s*(\d+)\s*%')
          .firstMatch(line);
      if (sig != null) {
        final v = int.tryParse(sig.group(1)!) ?? 0;
        if (v > signal) signal = v;
      }
    }
    flush();

    // 标记当前已连接的网络
    final cur = await currentSsid();
    if (cur.isNotEmpty && result.containsKey(cur)) {
      result[cur] =
          WifiNetwork(ssid: cur, signal: result[cur]!.signal, connected: true);
    }
    final list = result.values.toList()
      ..sort((a, b) {
        if (a.connected != b.connected) return a.connected ? -1 : 1;
        return b.signal.compareTo(a.signal);
      });
    return list;
  }

  /// 当前已连接的 WiFi SSID，未连接返回空串。
  Future<String> currentSsid() async {
    final text = await _run(['wlan', 'show', 'interfaces']);
    for (final line in _lines(text)) {
      // interfaces 输出中为 "SSID : xxx"（无编号）；"BSSID" 不会被此正则命中。
      final m = RegExp(r'^\s*SSID\s*:\s*(.+?)\s*$').firstMatch(line);
      if (m != null) return m.group(1)!;
    }
    return '';
  }

  /// 请求连接指定 WiFi（要求 Windows 已保存该网络的配置文件）。
  /// 返回连接请求是否被系统接受（实际连接结果需轮询 currentSsid 确认）。
  Future<bool> connect(String ssid) async {
    if (ssid.isEmpty) return false;
    final text = await _run(['wlan', 'connect', 'name=$ssid']);
    // 成功时输出"已成功完成连接请求"/"Connection request was completed successfully"
    return text.contains('成功') || text.toLowerCase().contains('successfully');
  }
}
