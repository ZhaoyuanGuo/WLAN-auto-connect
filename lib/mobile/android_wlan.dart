import 'package:flutter/services.dart';

/// 扫描到的 WiFi 网络（与 Windows 版 WifiNetwork 字段对齐）。
class AndroidWifiNetwork {
  AndroidWifiNetwork({
    required this.ssid,
    required this.signal, // 0-100
    this.connected = false,
  });

  final String ssid;
  final int signal;
  final bool connected;
}

/// Android 原生 WLAN 能力（MainActivity 中的 MethodChannel 提供）：
/// 扫描可见网络、读取当前连接 SSID、弹出系统 WLAN 面板、注册网络建议。
class AndroidWlan {
  static const _channel = MethodChannel('wlan_auto_connect/android');

  /// 扫描可见 WiFi（需定位权限）。[fresh] 为 true 时等待一次系统刷新扫描。
  /// 权限不足时抛 PlatformException(code: NO_PERMISSION)。
  Future<List<AndroidWifiNetwork>> scan({bool fresh = false}) async {
    final list = await _channel
        .invokeMethod<List<dynamic>>('scan', {'fresh': fresh});
    return [
      for (final item in list ?? const <dynamic>[])
        AndroidWifiNetwork(
          ssid: (item as Map)['ssid'] as String,
          signal: (item['signal'] as num).toInt(),
          connected: (item['connected'] as bool?) ?? false,
        )
    ];
  }

  /// 当前连接的 SSID；未连接或系统不可知时返回空串。
  Future<String> currentSsid() async {
    try {
      return await _channel.invokeMethod<String>('currentSsid') ?? '';
    } on PlatformException catch (e) {
      if (e.code == 'NO_PERMISSION') rethrow;
      return '';
    }
  }

  /// 打开系统 WLAN 设置面板（Android 10+ 后无法直接连网，由用户确认连接）。
  Future<void> openWifiPanel() => _channel.invokeMethod('openWifiPanel');

  /// 注册开放网络建议（帮助系统在校园网出现时自动连接）。
  Future<bool> suggestNetwork(String ssid) async {
    try {
      return await _channel
              .invokeMethod<bool>('suggestNetwork', {'ssid': ssid}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// 请求定位 /（Android 13+）附近设备权限。返回是否全部授予。
  Future<bool> requestPermissions() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermissions') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 系统定位服务是否开启（扫描 WiFi / 读取 SSID 需要它）。
  Future<bool> isLocationServiceEnabled() async {
    try {
      return await _channel
              .invokeMethod<bool>('isLocationServiceEnabled') ??
          true;
    } on PlatformException {
      return true;
    }
  }

  /// 自动关闭系统联网检测（captive portal），防止连接校园网后自动跳浏览器。
  /// 返回状态：already_off（本就关闭）/ disabled（本次关闭）/
  /// no_permission（缺 WRITE_SECURE_SETTINGS）/ error:信息。
  Future<String> ensurePortalDetectionOff() async {
    try {
      return await _channel
              .invokeMethod<String>('ensurePortalDetectionOff') ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    }
  }

  /// 联网检测状态 + 两条修复方案的可用性。
  Future<PortalStatus?> portalStatus() async {
    try {
      final m = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('portalStatus');
      if (m == null) return null;
      return PortalStatus(
        off: (m['off'] as bool?) ?? false,
        writePerm: (m['writePerm'] as bool?) ?? false,
        shizukuRunning: (m['shizukuRunning'] as bool?) ?? false,
        shizukuPerm: (m['shizukuPerm'] as bool?) ?? false,
      );
    } on PlatformException {
      return null;
    }
  }

  /// 方案二：通过 Shizuku 关闭联网检测。返回 already_off / disabled /
  /// not_running / no_permission / error:信息。
  Future<String> shizukuEnsurePortalOff() async {
    try {
      return await _channel
              .invokeMethod<String>('shizukuEnsurePortalOff') ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    }
  }

  /// 请求 Shizuku 授权（弹出 Shizuku 管理器确认窗）。
  Future<void> shizukuRequestPermission() async {
    try {
      await _channel.invokeMethod('shizukuRequestPermission');
    } on PlatformException {
      // 忽略：稍后由 portalStatus 反映真实状态
    }
  }

  /// 弹出系统「添加到快捷设置」确认窗（Android 13+）。返回 false 表示
  /// 系统不支持，由应用引导手动添加。
  Future<bool> requestAddTile() async {
    try {
      return await _channel.invokeMethod<bool>('requestAddTile') ?? false;
    } on PlatformException {
      return false;
    }
  }
}

/// 联网检测守护状态快照。
class PortalStatus {
  const PortalStatus({
    required this.off,
    required this.writePerm,
    required this.shizukuRunning,
    required this.shizukuPerm,
  });

  /// 两项检测设置是否均为关闭。
  final bool off;
  /// 是否持有 WRITE_SECURE_SETTINGS（方案一可用）。
  final bool writePerm;
  /// Shizuku 是否在运行。
  final bool shizukuRunning;
  /// 本应用是否已获 Shizuku 授权。
  final bool shizukuPerm;
}
