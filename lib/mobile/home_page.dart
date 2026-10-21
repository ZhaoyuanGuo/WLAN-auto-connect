import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../cloud/cloud_page.dart';
import '../services/debug_log.dart';
import '../services/portal_client.dart';
import '../services/portal_config.dart';
import 'android_wlan.dart';
import 'config_store.dart';
import 'diagnostics_report.dart';
import 'theme.dart';

enum MobileNetState {
  unknown,
  checking,
  online,
  needLogin,
  portalUnreachable,

  /// 门户主机可达，但 chkstatus 未返回可解析的 JSONP
  /// （最常见成因是「认证服务器」地址填错，与"未连接校园网"是两回事）
  portalBadResponse,
}

/// 运营商选项（value 为账号后缀）。
const _carriers = <String, String>{
  '校园用户': '',
  '校园电信': '@dx',
  '校园联通': '@lt',
  '校园移动': '',
};

/// 移动端主页：手机使用底部导航栏（NavigationBar），
/// 平板（最短边 >= 600dp）使用左侧导航栏（NavigationRail）+ 双栏内容，
/// 导航结构一致，均遵循 Material 3 与系统导航条 insets 避让规范。
class MobileHomePage extends StatefulWidget {
  const MobileHomePage({super.key});

  @override
  State<MobileHomePage> createState() => _MobileHomePageState();
}

class _MobileHomePageState extends State<MobileHomePage> {
  final _wlan = AndroidWlan();

  /// 门户客户端：host/eport 跟随 [_config]（设置页可修改），
  /// 配置变更后需调用 [_rebuildClient] 重建。
  late PortalClient _client = PortalClient();

  MobileConfig _config = MobileConfig();

  final _accountCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  String _carrier = '校园用户';
  String get _suffix => _carriers[_carrier] ?? '';
  bool _showPassword = false;

  int _tab = 0;
  MobileNetState _netState = MobileNetState.checking;
  bool _busyLogin = false;
  bool _busySave = false;
  bool _busyStar = false;

  /// 用户在"等待系统 WLAN 面板完成关联"期间点了取消。
  bool _cancelConnect = false;

  /// 当前是否正处于"等待系统 WLAN 面板完成关联"阶段（此时显示「取消」按钮）。
  bool _waitingWifi = false;

  /// 等待系统 WLAN 面板完成关联的最长秒数（期间按钮变为「取消」）。
  static const _wifiWaitSeconds = 90;

  List<AndroidWifiNetwork> _networks = [];
  bool _scanning = false;
  String _selectedSsid = '';
  String _currentSsid = '';

  /// 联网检测守护状态（设置页卡片）。
  PortalStatus? _portalStatus;

  /// 最近一次网络路由诊断：门户不可达时用来区分「地址填错」与
  /// 「流量被系统切到移动数据」，两者提示与解法完全不同。
  RouteDiag? _lastDiag;

  /// 最近一次「把流量钉到 WLAN」的结果码（ok / already / lost / denied /
  /// no_wifi / timeout / unsupported / error:…），空表示未尝试。
  /// 部分机型（如小米15Pro + 强制门户）系统会先交付再收回，绑定注定失败，
  /// 写进诊断导出后才能分清「没试」与「试了被系统拦下」。
  String _lastBindResult = '';

  final _logs = <String>[];
  final _logController = ScrollController();

  /// 日志版本号：每新增一条自增，供「运行日志」二级页实时刷新。
  final _logsVersion = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _client.dispose();
    _accountCtl.dispose();
    _passwordCtl.dispose();
    _logController.dispose();
    _logsVersion.dispose();
    super.dispose();
  }

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    setState(() => _logs.add('[$ts] $msg'));
    _logsVersion.value++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logController.hasClients) {
        _logController.jumpTo(_logController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _bootstrap() async {
    _config = await MobileConfig.load();
    _rebuildClient();
    if (mounted) setState(() {});
    await _ensurePortalOff();
    await _syncWidgetStatus();
    await _refreshNetState();
    await _scanNetworks();
  }

  /// 按当前配置重建门户客户端（host/eport 生效）。
  void _rebuildClient() {
    _client.dispose();
    _client = PortalClient(host: _config.host, eport: _config.eport);
  }

  /// 自动关闭系统联网检测（captive portal）：系统检测到门户认证会自动拉起
  /// 浏览器，与静默登录抢戏。需要 WRITE_SECURE_SETTINGS（adb 一次授权）。
  Future<void> _ensurePortalOff() async {
    final r = await _wlan.ensurePortalDetectionOff();
    switch (r) {
      case 'disabled':
        _log('已自动关闭系统联网检测，连接校园网后不再自动跳浏览器。');
        break;
      case 'already_off':
        break; // 本就关闭，静默
      case 'no_permission':
        _log('提示：未获得 WRITE_SECURE_SETTINGS，无法自动关闭系统联网检测'
            '（连接后可能自动跳浏览器）。可用 adb 授权一次：');
        _log('adb shell pm grant cn.lnpc.wlan_auto_connect '
            'android.permission.WRITE_SECURE_SETTINGS');
        break;
      default:
        _log('自动关闭系统联网检测失败：$r');
    }
    await _refreshPortalStatus();
  }

  /// 查询联网检测守护状态（设置页卡片渲染）。
  Future<void> _refreshPortalStatus() async {
    final s = await _wlan.portalStatus();
    if (mounted) setState(() => _portalStatus = s);
  }

  /// 复制方案一的 adb 授权命令。
  Future<void> _copyGrantCommand() async {
    await Clipboard.setData(const ClipboardData(
      text: 'adb shell pm grant cn.lnpc.wlan_auto_connect '
          'android.permission.WRITE_SECURE_SETTINGS',
    ));
    _snack('命令已复制，请在电脑 adb 中执行');
  }

  /// Shizuku 下载链：GitHub 为主链；国内直链为兜底（COS+CDN，本项目桶）。
  /// 直链固定 v13.5.4：13.6.0 的 UserService 在部分联发科 ROM 上创建失败
  /// （见 error:user_service_failed 分支），13.5.4 联发科/高通双平台可用。
  static const _shizukuGithubUrl =
      'https://github.com/RikkaApps/Shizuku/releases';
  static const _shizukuMirrorUrl =
      'https://dl.suspect.top/wlan/shizuku/shizuku-v13.5.4.apk';

  /// 官网地址：与 website/ 目录部署的 wlan.suspect.top 保持一致，
  /// 作为应用内「访问官网」入口，引导用户查看说明与下载最新版本。
  static const _websiteUrl = 'https://wlan.suspect.top';

  /// 打开官网；无可用浏览器时退化为复制链接（与 Shizuku 下载引导保持同一策略）。
  Future<void> _openWebsite() async {
    await _openDownloadUrl(_websiteUrl);
  }

  /// 打开 Shizuku 下载页；无可用浏览器时退化为复制链接。
  Future<void> _openDownloadUrl(String url) async {
    final ok = await _wlan.openUrl(url);
    if (!ok) {
      await Clipboard.setData(ClipboardData(text: url));
      _snack('未找到可用浏览器，链接已复制，可在电脑或文件管理器中打开下载');
    }
  }

  /// 方案三：通过 root（su）关闭联网检测。首次执行会弹 Magisk 授权窗，
  /// 用户在弹窗中拒绝则返回 denied。
  Future<void> _rootFix() async {
    _log('正在请求 root 权限：请在弹出的授权窗中允许（最长等待约 90 秒）...');
    final r = await _wlan.rootEnsurePortalOff();
    switch (r) {
      case 'disabled' || 'already_off':
        _log(r == 'already_off' ? '联网检测本就处于关闭状态。' : '已通过 root 关闭系统联网检测。');
        _snack('已通过 root 关闭联网检测');
      case 'no_su':
        _snack('未检测到 root（su）：本设备未获取 root 权限', error: true);
      case 'denied':
        _snack('root 授权被拒绝：请在弹窗中点「允许/授权」后重试', error: true);
      case 'error:timeout':
        _snack('root 授权窗长时间未响应，请重试', error: true);
      case 'error:not_applied':
        _snack('root 命令已执行但设置未生效：请检查 root 管理器的授权策略', error: true);
      default:
        _snack('root 执行失败：$r', error: true);
    }
    await _refreshPortalStatus();
  }

  /// 方案二：通过 Shizuku 关闭联网检测。
  ///
  /// 授权后会轮询等待授权生效并自动重试，不再要求用户手动再点一次；
  /// 失败时按返回码区分「未授权 / 服务未运行 / 用户服务建立失败（ROM 不兼容）/
  /// 命令执行失败」，避免把不同根因压成同一句 `error:timeout`。
  Future<void> _shizukuFix() async {
    var r = await _wlan.shizukuEnsurePortalOff();

    if (r == 'no_permission') {
      await _wlan.shizukuRequestPermission();
      // 轮询等待用户在 Shizuku 授权窗中确认（最长约 30 秒）
      for (var i = 0; i < 15; i++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final s = await _wlan.portalStatus();
        if (s?.shizukuPerm ?? false) {
          r = await _wlan.shizukuEnsurePortalOff();
          break;
        }
      }
      if (r == 'no_permission') {
        _snack('尚未收到 Shizuku 授权：请在授权窗中点击「允许」后重试', error: true);
        await _refreshPortalStatus();
        return;
      }
    }

    switch (r) {
      case 'disabled' || 'already_off':
        _log(r == 'already_off' ? '联网检测本就处于关闭状态。' : '已通过 Shizuku 关闭系统联网检测。');
        _snack('已通过 Shizuku 关闭联网检测');
      case 'not_running':
        _snack('未检测到 Shizuku：请先下载安装 Shizuku 并启动（无线调试或连接电脑激活）',
            error: true);
      case 'error:user_service_failed':
        // 本机实测过的联发科 ROM 缺陷：Shizuku 服务端已运行、应用也已授权，
        // 但其 UserService 辅助进程在 LoadedApk.makeApplication 处抛 NPE，
        // onServiceConnected 永不回调。
        _log('Shizuku 无法启动用户服务（UserService）：Shizuku 服务端在运行、'
            '本应用也已授权，但其用户服务进程创建失败。已知成因：部分 ROM'
            '（联发科机型 + Shizuku 13.6.0）在 LoadedApk.makeApplication 中调用 '
            'Application.getProcessName().equals()，而该方法在 Shizuku 辅助进程里返回 null。');
        _snack('Shizuku 用户服务启不来：请改用下方「国内高速直链」安装 13.5.4，或改用方案一/三',
            error: true);
      default:
        _snack('Shizuku 执行失败：$r', error: true);
    }
    await _refreshPortalStatus();
  }

  /// 还原系统联网检测（不再需要守护，或准备卸载应用时）。
  ///
  /// 关闭 `captive_portal_detection_enabled` / `captive_portal_mode` 是**系统级
  /// 全局设置**，卸载应用不会自动还原，故在应用内提供显式入口。
  Future<void> _restorePortal() async {
    var r = await _wlan.restorePortalDetection();
    var via = 'adb 授权';
    if (r == 'no_permission') {
      r = await _wlan.shizukuRestorePortalDetection();
      via = 'Shizuku';
    }
    if (r == 'no_permission' || r == 'not_running') {
      // 方案三兜底：root（首次执行会弹授权窗）
      r = await _wlan.rootRestorePortalDetection();
      via = 'root';
    }
    switch (r) {
      case 'restored':
        _log('已恢复系统联网检测（通过$via）。');
        _snack('已恢复系统联网检测');
      case 'already_on':
        _log('系统联网检测本就处于开启状态。');
        _snack('系统联网检测本就已开启');
      case 'no_su':
        _snack('无法还原：既无 adb 授权，Shizuku 不可用，也未检测到 root', error: true);
      case 'denied':
        _snack('root 授权被拒绝，无法还原', error: true);
      case 'not_running':
      case 'no_permission':
        _snack('无法还原：adb 授权、Shizuku、root 三条路径均不可用', error: true);
      case 'error:timeout':
        _snack('root 授权窗长时间未响应，还原超时', error: true);
      case 'error:user_service_failed':
        _snack('Shizuku 用户服务启不来，无法还原。可手动执行：'
            'adb shell settings put global captive_portal_detection_enabled 1',
            error: true);
      default:
        _snack('还原失败：$r', error: true);
    }
    await _refreshPortalStatus();
  }

  /// 读取原生小组件上次运行状态并反映到界面状态。
  Future<void> _syncWidgetStatus() async {
    try {
      final status = await MobileConfig.readStatus();
      if (status != null && status['online'] == true) {
        setState(() => _netState = MobileNetState.online);
      }
    } catch (_) {}
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final granted = await _wlan.requestPermissions();
    if (!granted) {
      _log('未授予 Wi-Fi 权限，无法扫描 WiFi / 识别当前连接'
          '（Android 13 及以上需同时授予「附近的设备」与「位置信息」，'
          'Android 12 及以下需「位置信息」）。');
      _snack('请授予「附近的设备」与「位置信息」权限（扫描 WiFi 缺一不可）', error: true);
      return false;
    }
    final serviceOn = await _wlan.isLocationServiceEnabled();
    if (!serviceOn) {
      // 扫描结果被系统视为位置数据，Android 13+ 定位服务关闭时同样扫不到
      _log('系统定位服务未开启：所有 Android 版本都会因此扫不到 WiFi / 读不到当前 SSID，'
          '请在系统设置中开启定位服务。');
    }
    return true;
  }

  // ---------------- WiFi 扫描 / 选择 / 保存 ----------------

  Future<void> _scanNetworks() async {
    if (!await _ensurePermissions()) {
      setState(() => _scanning = false);
      return;
    }
    setState(() => _scanning = true);
    List<AndroidWifiNetwork> nets;
    try {
      nets = await _wlan.scan(fresh: true);
      if (nets.isEmpty) {
        // 首次 startScan 后系统可能尚未返回新结果，稍候重试一次
        await Future.delayed(const Duration(seconds: 2));
        nets = await _wlan.scan();
      }
      _currentSsid = await _wlan.currentSsid();
    } catch (e) {
      nets = [];
      _log('扫描 WiFi 出错：$e');
    }
    setState(() {
      _networks = nets;
      _scanning = false;
    });
    if (nets.isEmpty) {
      _log('未扫描到任何 WiFi（请检查 WLAN 开关、定位服务与「位置信息」权限）。');
    } else {
      _log('扫描到 ${nets.length} 个 WiFi${_currentSsid.isEmpty ? '' : '，当前连接：$_currentSsid'}');
    }
  }

  void _selectNetwork(String ssid) {
    setState(() {
      _selectedSsid = ssid;
      final p = _config.profiles[ssid];
      _accountCtl.text = p?.account ?? '';
      _passwordCtl.clear();
      _carrier = _carriers.entries
          .firstWhere((e) => e.value == (p?.suffix ?? ''),
              orElse: () => const MapEntry('校园用户', ''))
          .key;
    });
    _log('已选择 WiFi：$ssid');
  }

  Future<void> _saveCurrentProfile() async {
    final ssid = _selectedSsid;
    final account = _accountCtl.text.trim();
    if (ssid.isEmpty) {
      _snack('请先在列表中选择要配置的 WiFi', error: true);
      return;
    }
    if (account.isEmpty) {
      _snack('请先输入该 WiFi 的账号', error: true);
      return;
    }
    setState(() => _busySave = true);
    final typedPassword = _passwordCtl.text;
    final old = _config.profiles[ssid];
    // 密码框在选中 WiFi 时被清空，只有用户重新输入才代表"改密码"。
    // 传 null 让 copyWith 保留旧密码，避免把已存密码覆盖成空串。
    final keepOldPassword = typedPassword.isEmpty && (old?.hasPassword ?? false);
    final updated = old?.copyWith(
            account: account,
            suffix: _suffix,
            password: typedPassword.isEmpty ? null : typedPassword) ??
        MobileProfile(
          ssid: ssid,
          account: account,
          suffix: _suffix,
          password: typedPassword,
        );
    _config.profiles[ssid] = updated;
    await _config.save();
    // 档案集合变化后同步系统网络建议（新增缺失、回收已删）
    await _wlan.syncNetworkSuggestions(_config.profiles.keys.toList());
    setState(() => _busySave = false);
    _log('已保存 WiFi「$ssid」的账号'
        '（${keepOldPassword ? '沿用已存密码' : (typedPassword.isEmpty ? '密码为空' : '密码已更新')}）');
    _snack('账号已保存');
  }

  Future<void> _setAutoLoginSsid(String ssid) async {
    final p = _config.profiles[ssid];
    if (p == null || p.account.isEmpty) {
      _snack('请先选择该 WiFi，填写账号密码并保存', error: true);
      return;
    }
    if (ssid == _config.autoLoginSsid) return;
    setState(() => _busyStar = true);
    _config.autoLoginSsid = ssid;
    await _config.save();
    setState(() => _busyStar = false);
    _log('开机自动认证 / 小组件默认 WiFi 已切换为「$ssid」。');
    _snack('自启 WiFi 已设为：$ssid');
  }

  // ---------------- 连接与认证 ----------------

  /// 一键连接目标 SSID：选中且已存档案 > 自启 WiFi > 唯一已存档案。
  MobileProfile? get _targetProfile {
    final sel = _config.profiles[_selectedSsid];
    if (sel != null && sel.account.isNotEmpty) return sel;
    final auto = _config.profiles[_config.autoLoginSsid];
    if (auto != null && auto.account.isNotEmpty) return auto;
    final saved = _config.profiles.values
        .where((p) => p.account.isNotEmpty && p.password.isNotEmpty)
        .toList();
    return saved.length == 1 ? saved.first : null;
  }

  Future<void> _connectNow() async {
    if (_busyLogin) return;
    final profile = _targetProfile;
    if (profile == null) {
      _snack('请先在「配置」页选择校园网 WiFi 并保存账号密码', error: true);
      setState(() => _tab = 1);
      return;
    }
    setState(() {
      _busyLogin = true;
      _cancelConnect = false;
      _netState = MobileNetState.checking;
      _selectedSsid = profile.ssid;
    });
    _log('开始一键连接（WiFi：${profile.ssid}，账号：${maskAccount(profile.account)}）...');
    await _saveStatus({'online': false, 'text': '正在连接...'});

    // 1. 尽量确保已连上目标 WiFi（Android 10+ 需系统面板确认）
    var connected = _currentSsid == profile.ssid;
    if (!connected && await _ensurePermissions()) {
      if (!mounted) return;
      _log('当前${_currentSsid.isEmpty ? '未连接 WiFi' : '连接的是「$_currentSsid」'}，'
          '正在弹出 WLAN 面板请求连接「${profile.ssid}」（最多等待 $_wifiWaitSeconds 秒，可点「取消」）...');
      // 只把"已配置档案"的 SSID 注册为系统建议，并回收已删档案的旧建议，
      // 避免用户删掉档案后系统仍继续自动连接
      await _wlan.syncNetworkSuggestions(_config.profiles.keys.toList());
      await _wlan.openWifiPanel();
      if (mounted) setState(() => _waitingWifi = true);
      connected = await _waitForWifi(profile.ssid);
      if (!mounted) return;
      setState(() => _waitingWifi = false);
    }

    if (_cancelConnect) {
      _log('已取消本次连接。');
      setState(() {
        _netState = MobileNetState.unknown;
        _busyLogin = false;
      });
      await _saveStatus({'online': false, 'text': '已取消'});
      return;
    }
    if (!connected) {
      // 只记录事实，不再对后续结果做臆测（真实原因由下面的探测给出）
      _log(_currentSsid.isEmpty
          ? '等待期间未检测到已连接「${profile.ssid}」。'
          : '仍连接在「$_currentSsid」，将直接尝试对「${profile.ssid}」的账号认证。');
    }

    // 2-5. 在线检测与静默登录（含「流量被切到移动数据」的兜底）
    await _authenticate(profile, connected);
  }

  /// 在线检测 → 会话参数 → 静默登录 → 确认上线。
  ///
  /// 门户是内网地址：校园网未认证时系统会判定 WLAN 无外网，只要移动数据可用，
  /// 默认网络就被切到蜂窝，门户请求必然超时（2026-10-21 小米15Pro 实测）。
  /// 因此不可达时先诊断，确认是被抢占就把本进程钉到 WLAN 重试一次；钉不住
  /// 才按「门户不可达」报出，并按诊断结果给出正确成因的文案。
  Future<void> _authenticate(MobileProfile profile, bool connected) async {
    var unbindAfterUse = false;
    try {
      var state = await _client.probeOnline();
      if (!mounted) return;
      if (state == PortalState.unreachable) {
        final diag = await _wlan.routeDiagnose();
        if (!mounted) return;
        _lastDiag = diag;
        if (diag != null && diag.shouldBindWifi) {
          _log('门户不可达，但诊断显示${diag.summary}：'
              '本应用的流量没走校园网 WiFi。正在尝试把流量钉到 WLAN...');
          final bind = await _wlan.routeBindWifi();
          if (!mounted) return;
          _lastBindResult = bind;
          if (bind == 'ok' || bind == 'already') {
            // 只由真正建立绑定的一方负责解绑
            unbindAfterUse = bind == 'ok';
            // 已建立的连接不受绑定影响，必须换一个新客户端才会走 WLAN
            _rebuildClient();
            final retry = await _client.probeOnline();
            if (!mounted) return;
            if (retry != PortalState.unreachable) {
              _log('已改走 WLAN，门户恢复可达。');
              state = retry;
            }
          } else {
            _log('系统未允许把流量钉到 WLAN（$bind），继续按当前路由判断。');
          }
        }
        // 钉不住时再试一次免授权的根治手段：关掉系统联网检测
        if (state == PortalState.unreachable &&
            (_lastDiag?.cellularPreempted ?? false)) {
          if (await _selfHealPortalDetection()) {
            if (!mounted) return;
            await Future.delayed(const Duration(seconds: 2));
            if (!mounted) return;
            final retry = await _client.probeOnline();
            if (!mounted) return;
            if (retry != PortalState.unreachable) {
              _log('关闭联网检测后 WLAN 已恢复为默认网络，门户重新可达。');
              _lastDiag = null;
              state = retry;
            }
          }
        }
      }

      if (state == PortalState.online) {
        _log('当前已在线，无需登录。');
        setState(() {
          _netState = MobileNetState.online;
          _busyLogin = false;
        });
        await _saveStatus({'online': true, 'text': '已联网'});
        return;
      }
      if (state == PortalState.unreachable) {
        // 区分三种成因：没连上 WiFi / 流量被切到移动数据 / 认证服务器地址填错
        final preempted = _lastDiag?.cellularPreempted ?? false;
        if (!connected) {
          _log('尚未连接校园网 WiFi，无法认证（本次在系统面板中等待 $_wifiWaitSeconds 秒'
              '未检测到「${profile.ssid}」）。');
        } else if (preempted) {
          _log('认证服务器不可达：已连「$_currentSsid」，但系统把本应用的流量切到了'
              '移动数据（校园网未认证时 Android 会判定 WLAN 无外网），'
              '内网门户 ${_config.host}:${_config.eport} 因此不通。'
              '临时办法：关掉移动数据再点一次；根治：在「设置 → 联网检测」里'
              '授权本应用关闭系统联网检测（或关掉手机的 WLAN+/移动数据加速）。');
        } else {
          _log('认证服务器不可达：已连「$_currentSsid」，但无法访问门户 '
              '${_config.host}:${_config.eport}。请确认「设置 → 认证服务器」地址是否正确。');
        }
        setState(() {
          _netState = MobileNetState.portalUnreachable;
          _busyLogin = false;
        });
        await _saveStatus({'online': false, 'text': '未连接校园网'});
        _snack(!connected
            ? '未连接校园网'
            : (preempted
                ? '流量被切到移动数据：请关移动数据或授权关闭联网检测'
                : '门户不可达，请检查认证服务器地址'), error: true);
        return;
      }
      if (state == PortalState.badResponse) {
        _log('门户响应异常：能连上 ${_config.host}:${_config.eport}，'
            '但 chkstatus 未返回可解析的 JSONP（常见原因：认证服务器地址填错，'
            '或门户协议已变更）。');
        setState(() {
          _netState = MobileNetState.portalBadResponse;
          _busyLogin = false;
        });
        await _saveStatus({'online': false, 'text': '门户响应异常'});
        _snack('门户响应异常，请检查认证服务器地址', error: true);
        return;
      }

      // 获取会话参数并静默登录
      _log('未认证，正在获取会话参数...');
      final session = await _client.captureHijackParams();
      if (!mounted) return;
      _log('获取到会话参数：${session.isEmpty ? '（空，使用本机 IP 登录）' : session.toString()}');
      _log('正在静默登录（账号：${maskAccount(profile.account)}${profile.suffix.isEmpty ? '' : ' ${profile.suffix}'}）...');
      final (ok, msg) = await _client.login(
          profile.account, profile.password, profile.suffix, session);
      if (!mounted) return;
      if (ok) {
        _log('登录请求成功（$msg），正在确认上线状态...');
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final verify = await _client.probeOnline();
        if (!mounted) return;
        if (verify == PortalState.online) {
          _log('认证完成，已连接互联网。');
          setState(() => _netState = MobileNetState.online);
          _snack('校园网登录成功');
          await _saveStatus({'online': true, 'text': '已联网'});
        } else {
          _log('登录请求已发送但状态未确认，请稍后重试。');
          setState(() => _netState = MobileNetState.needLogin);
          await _saveStatus({'online': false, 'text': '未确认'});
        }
      } else {
        _log('登录失败，门户返回：$msg（请检查账号密码、运营商选择是否正确）');
        setState(() => _netState = MobileNetState.needLogin);
        _snack('登录失败：$msg', error: true);
        await _saveStatus({'online': false, 'text': '登录失败'});
      }
      if (mounted) setState(() => _busyLogin = false);
    } finally {
      // 绑定期间小组件/云端同步等流量都被钉在没有外网的校园 WLAN 上，
      // 认证流程一结束就必须恢复系统默认路由。
      if (unbindAfterUse) {
        await _wlan.routeUnbind();
        _rebuildClient();
      }
    }
  }

  /// 无交互地关闭系统联网检测（captive portal），让校园 WLAN 重新被系统当作
  /// 正常网络（不再把流量切到蜂窝）。只在已具备免弹窗能力时执行：
  /// WRITE_SECURE_SETTINGS（adb 一次授权）或已授权的 Shizuku；root 会弹授权窗，
  /// 不放进自动流程。返回是否真的改动了系统设置。
  Future<bool> _selfHealPortalDetection() async {
    final st = await _wlan.portalStatus();
    if (st == null || st.off) return false; // 本就关闭，再改也没用
    if (st.writePerm) {
      final r = await _wlan.ensurePortalDetectionOff();
      _log('正在自动关闭系统联网检测（$r），等待系统重新校验网络...');
      return r == 'disabled';
    }
    if (st.shizukuRunning && st.shizukuPerm) {
      final r = await _wlan.shizukuEnsurePortalOff();
      _log('已通过 Shizuku 关闭系统联网检测（$r），等待系统重新校验网络...');
      return r == 'disabled';
    }
    return false;
  }

  /// 等待系统 WLAN 面板把设备关联到 [ssid]。
  ///
  /// 相比原来的「45 次 × 1 秒死等」：支持用户取消、每 10 秒回一行进度日志、
  /// 并且不再在超时后继续用自相矛盾的文案误导用户。
  Future<bool> _waitForWifi(String ssid) async {
    for (var i = 1; i <= _wifiWaitSeconds; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || _cancelConnect) return false;
      try {
        _currentSsid = await _wlan.currentSsid();
      } catch (_) {
        // 权限被撤销等：保持上一次已知值
      }
      if (_currentSsid == ssid) return true;
      if (i % 10 == 0) {
        _log('已等待 $i 秒，仍未连接到「$ssid」...');
      }
    }
    return _currentSsid == ssid;
  }

  /// 保存状态到小组件/磁贴，并同步刷新磁贴（清除「正在连接…」乐观态）。
  Future<void> _saveStatus(Map<String, dynamic> status) async {
    await MobileConfig.saveStatus({...status, 'time': _nowText()});
    await _wlan.refreshTile();
  }

  Future<void> _refreshNetState() async {
    setState(() => _netState = MobileNetState.checking);
    final state = await _client.probeOnline();
    if (!mounted) return;
    // 不可达时补一次路由诊断：状态条要能说清是「地址错」还是「流量走了移动数据」
    _lastDiag = state == PortalState.unreachable
        ? await _wlan.routeDiagnose()
        : null;
    if (!mounted) return;
    setState(() {
      _netState = switch (state) {
        PortalState.online => MobileNetState.online,
        PortalState.offline => MobileNetState.needLogin,
        PortalState.unreachable => MobileNetState.portalUnreachable,
        PortalState.badResponse => MobileNetState.portalBadResponse,
      };
    });
  }

  String _nowText() =>
      DateTime.now().toIso8601String().substring(11, 16);

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    final s = AppSemantic.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      // 成功提示用主题默认反色面板，仅失败时用 danger 强调
      backgroundColor: error ? s.danger : null,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  (String, Color, IconData) _stateInfo(BuildContext context) {
    final s = AppSemantic.of(context);
    switch (_netState) {
      case MobileNetState.online:
        return ('已联网', s.success, Icons.check_circle);
      case MobileNetState.needLogin:
        return ('校园网未认证', s.warning, Icons.portable_wifi_off);
      case MobileNetState.portalUnreachable:
        // 诊断确认是流量被移动数据抢走时，直说成因，别再让用户去改服务器地址
        return (_lastDiag?.cellularPreempted ?? false)
            ? ('流量走移动数据', s.danger, Icons.sim_card_alert)
            : ('未连接校园网', s.danger, Icons.wifi_off);
      case MobileNetState.portalBadResponse:
        return ('门户响应异常', s.danger, Icons.report_gmailerrorred);
      case MobileNetState.checking:
        return ('检测中...', s.textTertiary, Icons.sync);
      case MobileNetState.unknown:
        return ('未知', s.textTertiary, Icons.help_outline);
    }
  }

  IconData _signalIcon(int signal) {
    if (signal >= 80) return Icons.wifi;
    if (signal >= 60) return Icons.network_wifi_3_bar;
    if (signal >= 35) return Icons.network_wifi_2_bar;
    if (signal > 0) return Icons.network_wifi_1_bar;
    return Icons.signal_wifi_0_bar;
  }

  // ---------------- 布局骨架 ----------------

  bool get _isTablet => MediaQuery.sizeOf(context).shortestSide >= 600;

  @override
  Widget build(BuildContext context) {
    final body = _isTablet ? _buildTabletBody() : _buildPhoneBody();
    return Scaffold(
      body: body,
      bottomNavigationBar: _isTablet
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: '首页'),
                NavigationDestination(
                    icon: Icon(Icons.wifi_outlined),
                    selectedIcon: Icon(Icons.wifi),
                    label: '配置'),
                NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: '设置'),
              ],
            ),
    );
  }

  /// 手机：单列内容 + 底部导航栏。
  Widget _buildPhoneBody() => SafeArea(
        bottom: false, // 底部 inset 交给 NavigationBar 处理
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: IndexedStack(index: _tab, children: [
              _buildStatusPage(scrollable: true),
              _buildConfigPage(),
              _buildSettingsPage(),
            ])),
          ],
        ),
      );

  /// 平板：左侧 NavigationRail + 双栏内容。
  Widget _buildTabletBody() => SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor:
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                  child: Icon(Icons.wifi,
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
              destinations: const [
                NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: Text('首页')),
                NavigationRailDestination(
                    icon: Icon(Icons.wifi_outlined),
                    selectedIcon: Icon(Icons.wifi),
                    label: Text('配置')),
                NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('设置')),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(
                      child: IndexedStack(index: _tab, children: [
                    _buildStatusPage(scrollable: true),
                    _buildConfigPage(),
                    _buildSettingsPage(),
                  ])),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildHeader() {
    return Padding(
      padding: EdgeInsets.fromLTRB(_isTablet ? 20 : Ui.pagePad, 12, 8, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text('校园网自动登录',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            onPressed: _busyLogin ? null : _refreshNetState,
            tooltip: '刷新状态',
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
    );
  }

  // ---------------- 页面 1：首页（状态 + 一键连接） ----------------

  Widget _buildStatusPage({required bool scrollable}) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStateHero(),
        const SizedBox(height: Ui.groupGap),
        _buildQuickGroup(),
      ],
    );
    if (!scrollable) return content;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Ui.pagePad, 4, Ui.pagePad, 16),
      child: content,
    );
  }

  /// 首页主卡：全屏唯一主角——大字状态 + 通栏连接按钮。
  Widget _buildStateHero() {
    final (stateText, stateColor, stateIcon) = _stateInfo(context);
    final profile = _targetProfile;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Ui.cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Row(
                key: ValueKey(stateText),
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: stateColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(stateText,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(color: stateColor)),
                  ),
                  Icon(stateIcon, size: 22, color: stateColor),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _currentSsid.isEmpty
                  ? (profile == null ? '尚未配置账号' : '账号：${profile.account}')
                  : '$_currentSsid · '
                      '${profile == null ? '尚未配置账号' : '账号 ${profile.account}'}',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (_waitingWifi)
              OutlinedButton.icon(
                onPressed: () => setState(() => _cancelConnect = true),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
                icon: const Icon(Icons.close, size: 20),
                label: const Text('取消等待',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              )
            else
              FilledButton.icon(
                onPressed: _busyLogin ? null : _connectNow,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
                icon: _busyLogin
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onPrimary))
                    : const Icon(Icons.bolt, size: 22),
                label: Text(_busyLogin ? '正在连接...' : '一键连接校园网',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  /// 首页快捷组：开机自动认证开关 + 桌面小组件入口（详情进弹层）。
  Widget _buildQuickGroup() {
    final auto = _config.autoLoginSsid;
    final theme = Theme.of(context);
    return GroupCard(
      children: [
        ListTile(
          leading: const Icon(Icons.rocket_launch_outlined),
          title: const Text('开机自动认证'),
          subtitle: Text(auto.isEmpty ? '未指定自启 WiFi' : '自启：$auto',
              style: theme.textTheme.bodySmall),
          trailing: Switch(
            value: _config.bootAutoLogin && auto.isNotEmpty,
            onChanged: auto.isEmpty
                ? null
                : (v) async {
                    _config.bootAutoLogin = v;
                    await _config.save();
                    setState(() {});
                    _log(v ? '开机自动认证已开启。' : '开机自动认证已关闭。');
                  },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.widgets_outlined),
          title: const Text('桌面小组件 / 快捷按钮'),
          subtitle: Text('主屏或下拉控制中心，免打开应用认证',
              style: theme.textTheme.bodySmall),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showWidgetSheet,
        ),
      ],
    );
  }

  void _showWidgetSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ui.pagePad, 16, Ui.pagePad, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('桌面小组件 / 快捷按钮',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('添加到主屏或下拉控制中心，无需打开应用即可完成校园网认证。',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: _pinWidget,
                  icon: const Icon(Icons.add_home_outlined, size: 18),
                  label: const Text('添加小组件到桌面'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _addQsTile,
                  icon: const Icon(Icons.toggle_on_outlined, size: 18),
                  label: const Text('添加控制中心按钮'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pinWidget() async {
    // 部分国产 ROM（如 HyperOS）对 requestPinWidget 支持不稳定，
    // 无论能否自动弹出确认窗，都先给出手动添加引导。
    _snack('若未弹出确认窗：请在桌面长按空白处 → 添加小部件 → 找到「校园网自动登录」');
    try {
      final supported = await HomeWidget.isRequestPinWidgetSupported()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
      if (supported == true) {
        await HomeWidget.requestPinWidget(name: 'CampusWidgetProvider');
      }
    } catch (_) {}
  }

  Future<void> _addQsTile() async {
    // Android 13+ 弹系统确认窗（选择功能块尺寸）；HyperOS 下可能静默失败，
    // 与小组件一致：先给手动添加引导，再带超时尝试自动弹窗。
    _snack('若未弹出确认窗：下拉控制中心 → 编辑 → 添加「校园网一键连接」');
    try {
      await _wlan
          .requestAddTile()
          .timeout(const Duration(seconds: 3), onTimeout: () => false);
    } catch (_) {}
  }

  // ---------------- 页面 2：配置（WiFi 列表 + 表单） ----------------

  Widget _buildConfigPage() {
    if (_isTablet) {
      // 平板双栏：左侧列表、右侧表单
      return Padding(
        padding: const EdgeInsets.fromLTRB(Ui.pagePad, 4, Ui.pagePad, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: _buildWifiList()),
            const SizedBox(width: Ui.itemGap),
            Expanded(
                flex: 5,
                child: SingleChildScrollView(child: _buildFormCard())),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(Ui.pagePad, 4, Ui.pagePad, 16),
      children: [
        _buildWifiList(),
        const SizedBox(height: Ui.groupGap),
        _buildFormCard(),
      ],
    );
  }

  /// WiFi 列表：分组标题 + 扫描按钮，条目装进无边框分组卡。
  Widget _buildWifiList() {
    final nets = _displayNetworks;
    final s = AppSemantic.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'WiFi 网络',
          trailing: IconButton(
            onPressed: _scanning ? null : _scanNetworks,
            tooltip: '扫描 WiFi 列表',
            icon: _scanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.radar, size: 20),
          ),
        ),
        GroupCard(
          children: [
            ConstrainedBox(
              constraints:
                  BoxConstraints(maxHeight: _isTablet ? 480 : 320),
              child: nets.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 22),
                      child: Center(
                        child: Text(
                          _scanning ? '正在扫描...' : '未发现 WiFi，点右上角扫描',
                          style: TextStyle(color: s.textTertiary),
                        ),
                      ),
                    )
                  : ListView(shrinkWrap: true, children: [
                      for (final n in nets) _wifiRow(n),
                    ]),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Text('点条目选择配置，点星标设为自启（仅一个）',
              style: Theme.of(context).textTheme.labelSmall),
        ),
      ],
    );
  }

  List<AndroidWifiNetwork> get _displayNetworks {
    final list = List<AndroidWifiNetwork>.from(_networks);
    final visible = _networks.map((n) => n.ssid).toSet();
    for (final ssid in _config.profiles.keys) {
      if (!visible.contains(ssid)) {
        list.add(AndroidWifiNetwork(ssid: ssid, signal: 0));
      }
    }
    return list;
  }

  Widget _wifiRow(AndroidWifiNetwork n) {
    final p = _config.profiles[n.ssid];
    final isAuto = _config.autoLoginSsid == n.ssid;
    final isSelected = _selectedSsid == n.ssid;
    final connected = n.connected || _currentSsid == n.ssid;
    final theme = Theme.of(context);
    final s = AppSemantic.of(context);
    return InkWell(
      onTap: () => _selectNetwork(n.ssid),
      child: Container(
        color: isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              n.signal > 0 ? _signalIcon(n.signal) : Icons.wifi_off,
              size: 20,
              color: connected
                  ? theme.colorScheme.primary
                  : n.signal > 0
                      ? s.textSecondary
                      : s.textTertiary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                n.ssid,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: isAuto ? FontWeight.w600 : FontWeight.w400),
              ),
            ),
            if (p != null && p.account.isNotEmpty) ...[
              UiBadge('已存 ${p.account}', tone: BadgeTone.brand),
              const SizedBox(width: 6),
            ],
            if (connected) ...[
              const UiBadge('已连接', tone: BadgeTone.success),
              const SizedBox(width: 6),
            ],
            Tooltip(
              message: '设为开机自动认证 / 小组件默认 WiFi（仅允许一个）',
              child: IconButton(
                onPressed: _busyStar ? null : () => _setAutoLoginSsid(n.ssid),
                icon: Icon(
                  isAuto ? Icons.star : Icons.star_border_outlined,
                  size: 20,
                  color: isAuto ? s.warning : s.textTertiary,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormCard() {
    final hasSavedPw = _config.profiles[_selectedSsid]?.hasPassword ?? false;
    final s = AppSemantic.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Ui.cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('登录信息',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (_selectedSsid.isNotEmpty)
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: UiBadge('正在配置 $_selectedSsid',
                          tone: BadgeTone.brand),
                    ),
                  )
                else
                  Text('未选择 WiFi',
                      style: TextStyle(
                          fontSize: 11, color: s.textTertiary)),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _accountCtl,
              decoration: const InputDecoration(
                labelText: '学号 / 账号',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtl,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                labelText: hasSavedPw ? '密码（已保存，输入可更新）' : '密码',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(_showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                ),
              ),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '运营商',
                prefixIcon: Icon(Icons.sim_card_outlined),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _carrier,
                  isDense: true,
                  items: _carriers.keys
                      .map((k) => DropdownMenuItem(
                          value: k, child: Text(k)))
                      .toList(),
                  onChanged: (v) => setState(() => _carrier = v ?? '校园用户'),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_busySave || _selectedSsid.isEmpty)
                        ? null
                        : _saveCurrentProfile,
                    icon: _busySave
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存账号'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: (_busySave || _selectedSsid.isEmpty)
                        ? null
                        : () async {
                            await _saveCurrentProfile();
                            if (_config.autoLoginSsid.isEmpty) {
                              await _setAutoLoginSsid(_selectedSsid);
                            }
                          },
                    icon: const Icon(Icons.star_outline, size: 18),
                    label: const Text('保存并设为自启'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑认证服务器：支持手动输入与「自动探测」。
  Future<void> _editPortalServer() async {
    final hostCtl = TextEditingController(text: _config.host);
    final eportCtl = TextEditingController(text: '${_config.eport}');
    var probing = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('认证服务器'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '形如 http://<门户IP>:801/eportal/... 中的地址部分；不确定可点「自动探测」。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: hostCtl,
                decoration: const InputDecoration(
                  labelText: '门户地址（IP 或域名）',
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: eportCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '端口',
                  prefixIcon: Icon(Icons.numbers_outlined),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: probing
                    ? null
                    : () async {
                        setDlg(() => probing = true);
                        final r = await PortalClient.detectPortal();
                        setDlg(() => probing = false);
                        if (r == null) {
                          _snack('未探测到门户：请确认已连接校园网且尚未认证',
                              error: true);
                          return;
                        }
                        hostCtl.text = r.host;
                        eportCtl.text = '${r.eport}';
                        _log('自动探测到门户：${r.host}:${r.eport}');
                      },
                icon: probing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search, size: 18),
                label: const Text('自动探测'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final host = hostCtl.text.trim();
                final eport = int.tryParse(eportCtl.text.trim()) ?? 0;
                if (!PortalConfig.isValidHost(host)) {
                  _snack('门户地址格式不正确（不要带 http:// 或路径）',
                      error: true);
                  return;
                }
                if (!PortalConfig.isValidEport(eport)) {
                  _snack('端口需为 1-65535', error: true);
                  return;
                }
                _config.host = host;
                _config.eport = eport;
                await _config.save();
                _rebuildClient();
                if (mounted) setState(() {});
                _log('认证服务器已更新为 $host:$eport');
                _snack('认证服务器已保存');
                if (ctx.mounted) Navigator.pop(ctx);
                await _refreshNetState();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    hostCtl.dispose();
    eportCtl.dispose();
  }

  /// 守护方案折叠行：图标 + 短标题 + 一句话副标题 + 状态徽章，
  /// 展开后才显示具体步骤/按钮；图标统一中性色，颜色只留给徽章。
  Widget _wayTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget badge,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    final s = AppSemantic.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: s.outline),
        borderRadius: BorderRadius.circular(Ui.radiusButton),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(icon, color: s.textSecondary),
        title: Text(title, style: theme.textTheme.titleSmall),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [badge, const Icon(Icons.expand_more, size: 20)],
        ),
        children: children,
      ),
    );
  }

  /// 设置页：联网检测守护卡片。
  /// 头部只展示状态徽章；三种方案折叠为紧凑列表（图标+短标题+可用性徽章），
  /// 展开才见步骤/按钮，避免大段文字堆砧：
  /// 方案一 adb 授权（推荐）；方案二 Shizuku（附下载兜底链）；方案三 root。
  Widget _buildPortalGuardCard() {
    final st = _portalStatus;
    final off = st?.off ?? false;
    final writePerm = st?.writePerm ?? false;
    final shizukuRunning = st?.shizukuRunning ?? false;
    final rootAvail = st?.rootAvail ?? false;
    final theme = Theme.of(context);
    final s = AppSemantic.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Ui.cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined,
                    size: 20,
                    color: off ? s.success : s.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('联网检测守护', style: theme.textTheme.titleMedium),
                ),
                UiBadge(off ? '守护中' : '未开启',
                    tone: off ? BadgeTone.success : BadgeTone.neutral),
                IconButton(
                  onPressed: _refreshPortalStatus,
                  tooltip: '刷新状态',
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              off
                  ? '系统弹窗探测已关闭，认证由本应用静默完成。'
                  : '关闭系统探测后，连校园网不再自动跳浏览器，认证全程静默。',
              style: theme.textTheme.bodySmall,
            ),
            if (!off) ...[
              const SizedBox(height: 10),
              if (writePerm) ...[
                FilledButton.icon(
                  onPressed: () async {
                    final r = await _wlan.ensurePortalDetectionOff();
                    _log(r == 'disabled' ? '已关闭系统联网检测。' : '关闭结果：$r');
                    await _refreshPortalStatus();
                  },
                  icon: const Icon(Icons.bolt, size: 18),
                  label: const Text('一键开启守护'),
                ),
                const SizedBox(height: 10),
              ],
              // 方案列表始终展示：已授权时也可改用 Shizuku/root
              _wayTile(
                icon: Icons.usb_outlined,
                title: '方案一 · adb 授权（推荐）',
                subtitle: '一次授权重启不丢，之后每次启动自动维持',
                badge: UiBadge(writePerm ? '已授权' : '未授权',
                    tone: writePerm ? BadgeTone.success : BadgeTone.neutral),
                children: [
                  if (writePerm)
                    FilledButton.tonal(
                      onPressed: () async {
                        final r = await _wlan.ensurePortalDetectionOff();
                        _log(r == 'disabled' ? '已关闭系统联网检测。' : '关闭结果：$r');
                        await _refreshPortalStatus();
                      },
                      child: const Text('开启守护'),
                    )
                  else ...[
                    Text(
                      '① 手机开启「USB 调试」并连接电脑\n'
                      '② 电脑安装 adb（Android 平台工具）\n'
                      '③ 执行以下命令（点按钮复制后粘贴执行）：',
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'adb shell pm grant cn.lnpc.wlan_auto_connect '
                              'android.permission.WRITE_SECURE_SETTINGS',
                              style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: _copyGrantCommand,
                          tooltip: '复制命令',
                          icon: const Icon(Icons.copy, size: 18),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              _wayTile(
                icon: Icons.terminal,
                title: '方案二 · Shizuku（免电脑）',
                subtitle: '需 Shizuku 运行中，点一下即完成',
                badge: UiBadge(shizukuRunning ? '运行中' : '未运行',
                    tone:
                        shizukuRunning ? BadgeTone.success : BadgeTone.neutral),
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _shizukuFix,
                    icon: const Icon(Icons.bolt, size: 18),
                    label: const Text('开启守护'),
                  ),
                  const SizedBox(height: 4),
                  Text('还没有 Shizuku？', style: theme.textTheme.bodySmall),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => _openDownloadUrl(_shizukuGithubUrl),
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('GitHub 下载'),
                      ),
                      TextButton.icon(
                        onPressed: () => _openDownloadUrl(_shizukuMirrorUrl),
                        icon: const Icon(Icons.cloud_download_outlined, size: 16),
                        label: const Text('国内高速直链 v13.5.4'),
                      ),
                    ],
                  ),
                  Text(
                    '推荐 v13.5.4：联发科/高通均可用（13.6.0 在部分联发科机型无法启动服务）。',
                    style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _wayTile(
                icon: Icons.security,
                title: '方案三 · root',
                subtitle: '需已获取 root，首次使用弹窗授权',
                badge: UiBadge(rootAvail ? '已检测到 su' : '未检测到 root',
                    tone: rootAvail ? BadgeTone.success : BadgeTone.neutral),
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _rootFix,
                    icon: const Icon(Icons.bolt, size: 18),
                    label: const Text('开启守护'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '点击后会弹出 Magisk/授权管理器窗口，请选择「允许」。',
                    style: theme.textTheme.labelSmall?.copyWith(height: 1.4),
                  ),
                ],
              ),
            ],
            if (off) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '卸载应用不会自动还原，不再需要时请手动恢复。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _restorePortal,
                    child: const Text('恢复系统设置'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- 页面 3：设置 ----------------

  /// 设置页：iOS 式分组列表（分组标题 + 无边框分组容器）。
  Widget _buildSettingsPage() {
    final theme = Theme.of(context);
    final s = AppSemantic.of(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('连接与守护'),
        GroupCard(children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('认证服务器'),
            subtitle: Text('${_config.host}:${_config.eport}（Dr.COM / 哆点）',
                style: theme.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editPortalServer,
          ),
        ]),
        const SizedBox(height: Ui.itemGap),
        _buildPortalGuardCard(),
        const SizedBox(height: Ui.groupGap),
        const SectionHeader('账号'),
        const CloudCard(),
        const SizedBox(height: Ui.groupGap),
        const SectionHeader('外观'),
        GroupCard(children: [
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('深色模式'),
            subtitle: Text(switch (AppThemeMode.value.value) {
              'light' => '浅色',
              'dark' => '深色',
              _ => '跟随系统',
            }, style: theme.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickThemeMode,
          ),
        ]),
        const SizedBox(height: Ui.groupGap),
        const SectionHeader('关于与数据'),
        GroupCard(children: [
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: const Text('访问官网'),
            subtitle: Text('使用说明、更新日志与最新版本下载',
                style: theme.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openWebsite,
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('用户协议与隐私声明'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showAgreementAgain,
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('诊断日志'),
            subtitle: Text('查看运行日志或复制反馈问题',
                style: theme.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showDiagnosticsSheet,
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: s.danger),
            title: Text('清除全部数据', style: TextStyle(color: s.danger)),
            subtitle: Text('删除所有 WiFi 账号密码与配置',
                style: theme.textTheme.bodySmall),
            onTap: _confirmClear,
          ),
        ]),
        const SizedBox(height: Ui.groupGap),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '校园网自动登录 · 认证服务器 ${_config.host}:${_config.eport}',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall,
          ),
        ),
      ],
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Ui.pagePad, 4, Ui.pagePad, 16),
      child: content,
    );
  }

  Future<void> _pickThemeMode() async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('深色模式'),
        children: [
          RadioGroup<String>(
            groupValue: AppThemeMode.value.value,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (val, label) in const [
                  ('system', '跟随系统'),
                  ('light', '浅色'),
                  ('dark', '深色'),
                ])
                  RadioListTile<String>(
                    value: val,
                    title: Text(label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (v != null) {
      await AppThemeMode.apply(v);
      if (mounted) setState(() {});
    }
  }

  /// 诊断入口：运行日志升级为二级页，导出降为弹层里的一个动作。
  void _showDiagnosticsSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('查看运行日志'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => _LogPage(
                          logs: _logs,
                          version: _logsVersion,
                          controller: _logController,
                          onCleared: () => setState(_logs.clear),
                        )));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制诊断信息到剪贴板'),
              onTap: () {
                Navigator.pop(ctx);
                _exportDiagnostics();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAgreementAgain() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('用户协议与隐私声明'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Text(
              '本软件为面向使用 Dr.COM / 哆点认证的校园网的免费辅助登录工具。\n\n'
                  '· 您的账号、密码默认仅保存在手机本应用私有数据中，不共享；\n'
                  '· 仅当您主动登录并使用"云端同步"时，配置才加密上传到开发者自建服务器用于多设备备份，可随时删除；\n'
                  '· 软件不含统计、埋点或行为上报，不收集您的使用数据；\n'
                  '· 仅向校园网认证服务器（172.16.200.11）发送认证必需的请求；\n'
                  '· 扫描 WiFi 需要系统"位置信息"权限（Android 限制），软件不获取位置轨迹；\n'
                  '· 请勿将本软件用于登录他人账号或违反学校网络管理规定的行为。\n\n'
                  '完整条款以首次启动时展示的用户协议为准。',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(height: 1.7),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  /// 导出诊断日志：合并内存日志与磁盘日志，复制到剪贴板。
  ///
  /// 路由与联网检测状态都现拉一次：用户往往是「碰壁后马上导出」，
  /// 用陈旧的 _lastDiag 会把反馈引向错误的结论。文本拼装在
  /// DiagnosticsReport（纯函数，已单测）。
  Future<void> _exportDiagnostics() async {
    final diag = await _wlan.routeDiagnose() ?? _lastDiag;
    final guard = await _wlan.portalStatus();
    if (!mounted) return;
    final text = DiagnosticsReport.build(
      now: DateTime.now(),
      host: _config.host,
      eport: _config.eport,
      profileCount: _config.profiles.length,
      ssid: _currentSsid,
      diag: diag,
      bindResult: _lastBindResult,
      guard: guard,
      sessionLogs: _logs,
      diskLog: readLog(),
    );
    await Clipboard.setData(ClipboardData(text: text));
    _snack('诊断日志已复制到剪贴板');
    dlog('DIAG_EXPORT len=${text.length}');
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部数据'),
        content: const Text('将删除所有 WiFi 账号、密码与配置（含小组件状态），'
            '并回收已注册给系统的网络建议、还原系统联网检测设置。且无法恢复。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppSemantic.of(ctx).danger),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
    // 回收注册给系统的网络建议：否则清除数据后系统仍会自动连接这些 SSID，
    // 而此时应用已无对应档案，后台认证必然失败。
    await _wlan.syncNetworkSuggestions(const []);
    // 还原系统联网检测（该设置是系统级的，不属于应用数据，卸载不会自动还原）
    if (_portalStatus?.off ?? false) {
      var r = await _wlan.restorePortalDetection();
      if (r == 'no_permission') {
        r = await _wlan.shizukuRestorePortalDetection();
      }
      _log(r == 'restored'
          ? '已还原系统联网检测设置。'
          : '未能还原系统联网检测设置（$r），可稍后在设置页手动还原。');
    }
    await MobileConfig.clear();
    _config = MobileConfig(agreementAccepted: true, usageNoticed: true);
    await _config.save();
    _accountCtl.clear();
    _passwordCtl.clear();
    _selectedSsid = '';
    setState(() {
      _netState = MobileNetState.checking;
      _logs.clear();
    });
    _log('已清除全部数据。');
    _snack('已清除全部数据');
    await _refreshNetState();
  }
}

/// 「运行日志」二级页：实时监听日志版本刷新，容器用主题表面色而非硬编码深色。
class _LogPage extends StatefulWidget {
  const _LogPage({
    required this.logs,
    required this.version,
    required this.controller,
    this.onCleared,
  });

  final List<String> logs;
  final ValueListenable<int> version;
  final ScrollController controller;
  final VoidCallback? onCleared;

  @override
  State<_LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<_LogPage> {
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.controller.hasClients) {
        widget.controller.jumpTo(widget.controller.position.maxScrollExtent);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    widget.version.addListener(_scrollToEnd);
    _scrollToEnd();
  }

  @override
  void dispose() {
    widget.version.removeListener(_scrollToEnd);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = AppSemantic.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '清空日志',
            onPressed: () {
              setState(() => widget.logs.clear());
              widget.onCleared?.call();
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Ui.pagePad),
          child: Container(
            width: double.infinity,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Ui.radiusCard),
            ),
            padding: const EdgeInsets.all(12),
            child: ValueListenableBuilder<int>(
              valueListenable: widget.version,
              builder: (_, _, _) => widget.logs.isEmpty
                  ? Center(
                      child: Text('暂无日志',
                          style: TextStyle(color: s.textTertiary)))
                  : ListView.builder(
                      controller: widget.controller,
                      itemCount: widget.logs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          widget.logs[i],
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
