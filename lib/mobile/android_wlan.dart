import 'dart:async';

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

  /// 扫描可见 WiFi（需「附近的设备」+ 位置权限，且系统定位服务开启）。
  /// [fresh] 为 true 时等待一次系统刷新扫描。
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

  /// 把「已配置档案的 SSID 集合」同步为系统的开放网络建议：新增缺失的、移除多余的。
  ///
  /// 只注册开放网络（无 PSK）—— 用户档案里没有 Wi-Fi 密码字段；调用方应只在
  /// 目标确认是开放校园网时依赖它。返回 ok / unsupported / error:信息。
  Future<String> syncNetworkSuggestions(List<String> ssids) async {
    try {
      return await _channel.invokeMethod<String>(
              'syncNetworkSuggestions', {'ssids': ssids}) ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    }
  }

  /// 请求 Wi-Fi 权限：Android 13+ 为「附近的设备」+「位置信息」（扫描两者
  /// 缺一不可，系统不会把扫描结果当作 NEARBY 放行），12 及以下为「位置信息」。
  /// 返回是否已授予。
  ///
  /// 原生侧会让并发调用共享同一次系统弹窗（见 WlanMethods.kt），因此不会因重入
  /// 而永久挂起；此处的超时仅兜底「Activity 被销毁 / 回调被系统丢弃」的极端情况，
  /// 避免调用方（如 _connectNow）的 `_busyLogin` 永远无法复位。
  Future<bool> requestPermissions() async {
    try {
      return await _channel
              .invokeMethod<bool>('requestPermissions')
              .timeout(const Duration(minutes: 3)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 系统定位服务是否开启（所有 Android 版本扫描 WiFi / 读取 SSID 都依赖它，
  /// 含 Android 13+：扫描结果被视为位置数据，定位服务关闭时同样扫不到）。
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

  /// 方案一：恢复系统联网检测（需 WRITE_SECURE_SETTINGS）。
  /// 返回 already_on / restored / no_permission / error:信息。
  Future<String> restorePortalDetection() async {
    try {
      return await _channel.invokeMethod<String>('restorePortalDetection') ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    }
  }

  /// 联网检测状态 + 三条修复方案的可用性。
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
        rootAvail: (m['rootAvail'] as bool?) ?? false,
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

  /// 方案二：通过 Shizuku 恢复系统联网检测。返回码同 [shizukuEnsurePortalOff]。
  Future<String> shizukuRestorePortalDetection() async {
    try {
      return await _channel
              .invokeMethod<String>('shizukuRestorePortalDetection') ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    }
  }

  /// 方案三：通过 root（su）关闭联网检测。首次执行会弹 Magisk 授权窗，
  /// 最长阻塞约 90 秒。返回 already_off / disabled / no_su / denied /
  /// error:timeout / error:not_applied / error:信息。
  Future<String> rootEnsurePortalOff() async {
    try {
      return await _channel
              .invokeMethod<String>('rootEnsurePortalOff')
              .timeout(const Duration(seconds: 120)) ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    } on TimeoutException {
      return 'error:timeout';
    }
  }

  /// 方案三：通过 root 恢复系统联网检测。返回码同 [rootEnsurePortalOff]
  /// （成功为 restored / already_on）。
  Future<String> rootRestorePortalDetection() async {
    try {
      return await _channel
              .invokeMethod<String>('rootRestorePortalDetection')
              .timeout(const Duration(seconds: 120)) ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    } on TimeoutException {
      return 'error:timeout';
    }
  }

  /// 用系统浏览器打开 http(s) 链接（Shizuku 下载引导）。返回 false 表示
  /// 无可用浏览器或 URL 非 http(s)。
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// 前台写入认证状态后同步控制中心磁贴（清除「正在连接…」乐观态并刷新）。
  Future<void> refreshTile() async {
    try {
      await _channel.invokeMethod('refreshTile');
    } on PlatformException {
      // 磁贴未添加时无副作用，忽略
    }
  }

  /// 用 AndroidKeyStore 中的 AES-GCM 密钥加密敏感字段（校园网密码）。
  /// 明文原样返回空串/空值场景；失败返回 null。
  Future<String?> encryptSecret(String plain) async {
    try {
      return await _channel
          .invokeMethod<String>('encryptSecret', {'value': plain});
    } on PlatformException {
      return null;
    }
  }

  /// 解密敏感字段。历史明文（无 enc: 前缀）由原生侧原样返回；
  /// 解密失败（密钥丢失/换机/数据损坏）返回 null，调用方应视为"需重新输入"。
  Future<String?> decryptSecret(String stored) async {
    try {
      return await _channel
          .invokeMethod<String>('decryptSecret', {'value': stored});
    } on PlatformException {
      return null;
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

  /// 系统网络路由快照（门户不可达时用来区分「地址填错」与「流量走了移动数据」）。
  /// 原生不可用时返回 null，调用方按「无诊断信息」处理。
  Future<RouteDiag?> routeDiagnose() async {
    try {
      final m = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('routeDiagnose');
      if (m == null) return null;
      return RouteDiag.fromMap(m);
    } on PlatformException {
      return null;
    }
  }

  /// 把本进程流量钉到 WLAN。返回 ok / already / unsupported /
  /// no_wifi / timeout / denied / error:信息。
  ///
  /// 用于校园网未认证、系统把默认网络切到蜂窝时仍能访问内网门户。
  /// 用完必须 [routeUnbind]，否则其他流量会留在没有外网的校园 WLAN 上。
  Future<String> routeBindWifi() async {
    try {
      return await _channel.invokeMethod<String>('routeBindWifi') ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    }
  }

  /// 解除 WLAN 绑定，恢复系统默认网络选择。返回 ok / none / error:信息。
  Future<String> routeUnbind() async {
    try {
      return await _channel.invokeMethod<String>('routeUnbind') ??
          'error:no_result';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    }
  }
}

/// 系统网络路由快照（原生 NetRoute.diagnose 的 Dart 视图）。
class RouteDiag {
  const RouteDiag({
    required this.defaultTransport,
    required this.wifiConnected,
    required this.wifiValidated,
    required this.wifiCaptivePortal,
    required this.mobileAvailable,
    this.bound = false,
  });

  factory RouteDiag.fromMap(Map<dynamic, dynamic> m) => RouteDiag(
        defaultTransport: (m['defaultTransport'] as String?) ?? 'none',
        wifiConnected: (m['wifiConnected'] as bool?) ?? false,
        wifiValidated: (m['wifiValidated'] as bool?) ?? false,
        wifiCaptivePortal: (m['wifiCaptivePortal'] as bool?) ?? false,
        mobileAvailable: (m['mobileAvailable'] as bool?) ?? false,
        bound: (m['bound'] as bool?) ?? false,
      );

  /// 系统默认网络归属：wifi / cellular / ethernet / other / none。
  final String defaultTransport;

  /// 存在可用的 WLAN 网络（已连上 AP，不代表能上外网）。
  final bool wifiConnected;

  /// WLAN 已通过系统联网校验。
  final bool wifiValidated;

  /// WLAN 被系统判定为强制门户（未认证时被劫持）。
  final bool wifiCaptivePortal;

  /// 存在已验证可用的蜂窝网络（移动数据开着且能上外网）。
  final bool mobileAvailable;

  /// 本进程当前是否已被钉到 WLAN（[AndroidWlan.routeBindWifi] 生效中）。
  final bool bound;

  /// 「流量被移动数据抢走」：连着 WLAN 但系统默认网络不是它。
  ///
  /// 校园网未认证时的典型状态，也是门户（内网地址）不可达的头号成因；
  /// 与「认证服务器地址填错」是两回事，提示文案必须区分。
  bool get cellularPreempted =>
      wifiConnected && defaultTransport != 'wifi' && !bound;

  /// 是否值得尝试把进程钉到 WLAN：只有在「WiFi 在、默认网络不是 WiFi」时才有意义，
  /// 且需要蜂窝可用作为被切走的对手（没开移动数据时默认网络不会离开 WiFi）。
  bool get shouldBindWifi => cellularPreempted && mobileAvailable;

  /// 供日志展示的一句话诊断。
  String get summary {
    final parts = <String>['默认网络=$defaultTransport'];
    if (wifiConnected) {
      parts.add(wifiValidated
          ? 'WLAN 已验证'
          : 'WLAN 未验证${wifiCaptivePortal ? '（系统判定为强制门户）' : ''}');
    } else {
      parts.add('WLAN 未连接');
    }
    parts.add(mobileAvailable ? '移动数据可用' : '移动数据不可用');
    if (bound) parts.add('已钉在 WLAN');
    return parts.join('，');
  }

  /// 一句话判读：直接给出「是不是路由被抢走」的结论。
  ///
  /// 写进诊断日志导出，让用户反馈「门户不可达」时能一眼分辨是地址填错
  /// 还是系统把流量切到了移动数据，不用再来回猜。
  String get verdict {
    if (bound) return '本进程已钉在 WLAN，门户请求走校园网 WiFi。';
    if (!wifiConnected) return '未连接任何 WLAN，门户不可达属于「没连上校园网」。';
    if (defaultTransport != 'wifi') {
      return '连着 WLAN 但系统默认网络是 $defaultTransport：门户请求被'
          '${defaultTransport == 'cellular' ? '移动数据' : '其他网络'}带走，'
          '属路由抢占，不是认证服务器地址填错。';
    }
    if (!wifiValidated) {
      return 'WLAN 已是默认网络但未通过系统联网校验（captive portal 判定），'
          '部分机型会限制应用在未验证网络上的流量。';
    }
    return 'WLAN 为默认网络且已验证，若门户仍不可达，需核对认证服务器地址与连通性。';
  }
}

/// 联网检测守护状态快照。
class PortalStatus {
  const PortalStatus({
    required this.off,
    required this.writePerm,
    required this.shizukuRunning,
    required this.shizukuPerm,
    required this.rootAvail,
  });

  /// 两项检测设置是否均为关闭。
  final bool off;
  /// 是否持有 WRITE_SECURE_SETTINGS（方案一可用）。
  final bool writePerm;
  /// Shizuku 是否在运行。
  final bool shizukuRunning;
  /// 本应用是否已获 Shizuku 授权。
  final bool shizukuPerm;
  /// 是否检测到 su 二进制（方案三可用；未执行 su，不代表已授权）。
  final bool rootAvail;
}
