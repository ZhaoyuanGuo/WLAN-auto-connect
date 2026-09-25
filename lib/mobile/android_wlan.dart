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
}
