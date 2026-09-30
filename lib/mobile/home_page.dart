import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../cloud/cloud_page.dart';
import '../services/portal_client.dart';
import 'android_wlan.dart';
import 'config_store.dart';

enum MobileNetState { unknown, checking, online, needLogin, portalUnreachable }

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
  late final _client = PortalClient();

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

  List<AndroidWifiNetwork> _networks = [];
  bool _scanning = false;
  String _selectedSsid = '';
  String _currentSsid = '';

  /// 联网检测守护状态（设置页卡片）。
  PortalStatus? _portalStatus;

  final _logs = <String>[];
  final _logController = ScrollController();

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
    super.dispose();
  }

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    setState(() => _logs.add('[$ts] $msg'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logController.hasClients) {
        _logController.jumpTo(_logController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _bootstrap() async {
    _config = await MobileConfig.load();
    if (mounted) setState(() {});
    await _ensurePortalOff();
    await _syncWidgetStatus();
    await _refreshNetState();
    await _scanNetworks();
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

  /// 方案二：通过 Shizuku 关闭联网检测。
  Future<void> _shizukuFix() async {
    var r = await _wlan.shizukuEnsurePortalOff();
    if (r == 'no_permission') {
      // 触发 Shizuku 授权窗，等用户确认后重试一次
      await _wlan.shizukuRequestPermission();
      _snack('请在 Shizuku 授权窗中点击「允许」，然后重试');
      return;
    }
    switch (r) {
      case 'disabled' || 'already_off':
        _log(r == 'already_off' ? '联网检测本就处于关闭状态。' : '已通过 Shizuku 关闭系统联网检测。');
        _snack('已通过 Shizuku 关闭联网检测');
      case 'not_running':
        _snack('未检测到 Shizuku：请先安装 Shizuku 并启动（无线调试或连接电脑激活）',
            error: true);
      default:
        _snack('Shizuku 执行失败：$r', error: true);
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
      _log('未授予"位置信息"权限，无法扫描 WiFi / 识别当前连接（Android 系统限制）。');
      _snack('请在系统设置中授予"位置信息"权限', error: true);
      return false;
    }
    final serviceOn = await _wlan.isLocationServiceEnabled();
    if (!serviceOn) {
      _log('系统定位服务未开启，扫描 WiFi 与识别当前连接将不可用（可先手动连接校园网）。');
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
      _log('未扫描到任何 WiFi（请检查 WLAN 开关与定位服务）。');
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
    final old = _config.profiles[ssid];
    final updated = old?.copyWith(
            account: account, suffix: _suffix, password: _passwordCtl.text) ??
        MobileProfile(
          ssid: ssid,
          account: account,
          suffix: _suffix,
          password: _passwordCtl.text,
        );
    _config.profiles[ssid] = updated;
    await _config.save();
    setState(() => _busySave = false);
    _log('已保存 WiFi「$ssid」的账号（${_passwordCtl.text.isEmpty ? '沿用已存密码' : '密码已更新'}）');
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
      _netState = MobileNetState.checking;
      _selectedSsid = profile.ssid;
    });
    _log('开始一键连接（WiFi：${profile.ssid}，账号：${profile.account}）...');
    await MobileConfig.saveStatus(
        {'online': false, 'text': '正在连接...', 'time': _nowText()});

    // 1. 尽量确保已连上目标 WiFi（Android 10+ 需系统面板确认）
    var connected = _currentSsid == profile.ssid;
    if (!connected && await _ensurePermissions()) {
      _log('当前${_currentSsid.isEmpty ? '未连接 WiFi' : '连接的是「$_currentSsid」'}，'
          '正在弹出 WLAN 面板请求连接「${profile.ssid}」...');
      await _wlan.suggestNetwork(profile.ssid);
      await _wlan.openWifiPanel();
      for (var i = 1; i <= 45; i++) {
        await Future.delayed(const Duration(seconds: 1));
        try {
          _currentSsid = await _wlan.currentSsid();
        } catch (_) {}
        if (_currentSsid == profile.ssid) break;
      }
      connected = _currentSsid == profile.ssid;
    }
    if (!connected) {
      _log(_currentSsid.isEmpty
          ? '未连接「${profile.ssid}」。请先在系统 WLAN 中连接校园网，再一键认证。'
          : '仍连接在「$_currentSsid」，已直接尝试对「${profile.ssid}」的账号认证。');
    }

    // 2. 在线检测
    var online = await _client.checkOnline();
    if (online == true) {
      _log('当前已在线，无需登录。');
      setState(() {
        _netState = MobileNetState.online;
        _busyLogin = false;
      });
      await MobileConfig.saveStatus(
          {'online': true, 'text': '已联网', 'time': _nowText()});
      return;
    }
    if (online == null) {
      _log('认证服务器不可达（当前未连接校园网，或信号太弱）。');
      setState(() {
        _netState = MobileNetState.portalUnreachable;
        _busyLogin = false;
      });
      await MobileConfig.saveStatus(
          {'online': false, 'text': '未连接校园网', 'time': _nowText()});
      _snack('未连接校园网', error: true);
      return;
    }

    // 3. 获取会话参数并静默登录
    _log('未认证，正在获取会话参数...');
    final session = await _client.captureHijackParams();
    _log('获取到会话参数：${session.isEmpty ? '（空，使用本机 IP 登录）' : session.toString()}');
    _log('正在静默登录（账号：${profile.account}${profile.suffix.isEmpty ? '' : ' ${profile.suffix}'}）...');
    final (ok, msg) = await _client.login(
        profile.account, profile.password, profile.suffix, session);
    if (ok) {
      _log('登录请求成功（$msg），正在确认上线状态...');
      await Future.delayed(const Duration(seconds: 2));
      online = await _client.checkOnline();
      if (online == true) {
        _log('认证完成，已连接互联网。');
        setState(() => _netState = MobileNetState.online);
        _snack('校园网登录成功');
        await MobileConfig.saveStatus(
            {'online': true, 'text': '已联网', 'time': _nowText()});
      } else {
        _log('登录请求已发送但状态未确认，请稍后重试。');
        setState(() => _netState = MobileNetState.needLogin);
        await MobileConfig.saveStatus(
            {'online': false, 'text': '未确认', 'time': _nowText()});
      }
    } else {
      _log('登录失败，门户返回：$msg（请检查账号密码、运营商选择是否正确）');
      setState(() => _netState = MobileNetState.needLogin);
      _snack('登录失败：$msg', error: true);
      await MobileConfig.saveStatus(
          {'online': false, 'text': '登录失败', 'time': _nowText()});
    }
    setState(() => _busyLogin = false);
  }

  Future<void> _refreshNetState() async {
    setState(() => _netState = MobileNetState.checking);
    final state = await _client.checkOnline();
    if (!mounted) return;
    setState(() {
      _netState = state == true
          ? MobileNetState.online
          : state == false
              ? MobileNetState.needLogin
              : MobileNetState.portalUnreachable;
    });
  }

  String _nowText() =>
      DateTime.now().toIso8601String().substring(11, 16);

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? const Color(0xFFD32F2F) : const Color(0xFF2E7D32),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  (String, Color, IconData) get _stateInfo {
    switch (_netState) {
      case MobileNetState.online:
        return ('已联网', const Color(0xFF2E7D32), Icons.check_circle);
      case MobileNetState.needLogin:
        return ('校园网未认证', const Color(0xFFEF6C00), Icons.portable_wifi_off);
      case MobileNetState.portalUnreachable:
        return ('未连接校园网', const Color(0xFFB71C1C), Icons.wifi_off);
      case MobileNetState.checking:
        return ('检测中...', Colors.grey.shade700, Icons.sync);
      case MobileNetState.unknown:
        return ('未知', Colors.grey.shade700, Icons.help_outline);
    }
  }

  IconData _signalIcon(int signal) {
    if (signal >= 80) return Icons.wifi;
    if (signal >= 60) return Icons.network_wifi_3_bar;
    if (signal >= 35) return Icons.network_wifi_2_bar;
    if (signal > 0) return Icons.network_wifi_1_bar;
    return Icons.signal_wifi_0_bar;
  }

  Widget _badge(String text, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 10.5, color: fg)),
      );

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
                  backgroundColor: const Color(0xFFE8EAF6),
                  child:
                      Icon(Icons.wifi, color: const Color(0xFF3D5AFE)),
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
    final (stateText, stateColor, stateIcon) = _stateInfo;
    return Padding(
      padding: EdgeInsets.fromLTRB(_isTablet ? 20 : 16, 12, 8, 8),
      child: Row(
        children: [
          const Text('校园网自动登录',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          Icon(stateIcon, color: stateColor, size: 16),
          const SizedBox(width: 4),
          Flexible(
            child: Text(stateText,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: stateColor, fontSize: 13)),
          ),
          const Spacer(),
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
        const SizedBox(height: 12),
        _buildAutoCard(),
        const SizedBox(height: 12),
        _buildWidgetTipsCard(),
      ],
    );
    if (!scrollable) return content;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: content,
    );
  }

  /// 首页主卡：状态 + 一键连接大按钮。
  Widget _buildStateHero() {
    final (_, stateColor, stateIcon) = _stateInfo;
    final profile = _targetProfile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(stateIcon, color: stateColor, size: 30),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_currentSsid.isEmpty
                          ? '校园网认证'
                          : '当前连接：$_currentSsid',
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.grey.shade600)),
                      const SizedBox(height: 2),
                      Text(
                        profile == null ? '尚未配置账号' : '账号：${profile.account}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busyLogin ? null : _connectNow,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: _busyLogin
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.bolt, size: 22),
              label: Text(_busyLogin ? '正在连接...' : '一键连接校园网',
                  style: const TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutoCard() {
    final auto = _config.autoLoginSsid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.rocket_launch_outlined,
                    size: 20, color: Color(0xFF3D5AFE)),
                const SizedBox(width: 8),
                const Text('开机自动认证',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                Switch(
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
              ],
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                style: TextStyle(
                    fontSize: 12.5, color: Colors.grey.shade600, height: 1.5),
                children: [
                  const TextSpan(text: '开机联网后自动认证星标 WiFi（'),
                  TextSpan(
                      text: auto.isEmpty ? '未指定' : auto,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFFFA000))),
                  const TextSpan(text: '，仅允许一个）。'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWidgetTipsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.widgets_outlined,
                    size: 20, color: Color(0xFF3D5AFE)),
                SizedBox(width: 8),
                Text('桌面小组件 / 快捷按钮',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '把「一键连接」添加到手机主屏幕或下拉控制中心，无需打开应用即可完成校园网认证。',
              style: TextStyle(
                  fontSize: 12.5, color: Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _pinWidget,
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.add_home_outlined, size: 18),
                  label: const Text('添加小组件到桌面'),
                ),
                OutlinedButton.icon(
                  onPressed: _addQsTile,
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.toggle_on_outlined, size: 18),
                  label: const Text('添加控制中心按钮'),
                ),
              ],
            ),
          ],
        ),
      ),
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: _buildWifiListCard()),
            const SizedBox(width: 12),
            Expanded(flex: 5, child: SingleChildScrollView(child: _buildFormCard())),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        _buildWifiListCard(),
        const SizedBox(height: 12),
        _buildFormCard(),
      ],
    );
  }

  Widget _buildWifiListCard() {
    final nets = _displayNetworks;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('WiFi 网络',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('点击选择配置，点星标设为自启（仅一个）',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade500)),
                ),
                IconButton(
                  onPressed: _scanning ? null : _scanNetworks,
                  tooltip: '扫描 WiFi 列表',
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.radar, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: _isTablet ? 480 : 260),
              child: nets.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: Text(
                          _scanning ? '正在扫描...' : '未发现 WiFi，点击右上角扫描',
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                      ),
                    )
                  : ListView(shrinkWrap: true, children: [
                      for (final n in nets) _wifiRow(n),
                    ]),
            ),
          ],
        ),
      ),
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
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectNetwork(n.ssid),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected ? const Color(0xFFE8EAF6) : null,
        ),
        child: Row(
          children: [
            Icon(
              n.signal > 0 ? _signalIcon(n.signal) : Icons.wifi_off,
              size: 18,
              color: connected
                  ? const Color(0xFF3D5AFE)
                  : n.signal > 0
                      ? Colors.grey.shade600
                      : Colors.grey.shade300,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                n.ssid,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: isAuto ? FontWeight.w600 : FontWeight.w400,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            if (p != null && p.account.isNotEmpty)
              _badge('已存:${p.account}', const Color(0xFF1565C0),
                  const Color(0xFFE3F2FD)),
            const SizedBox(width: 4),
            if (connected)
              _badge('已连接', const Color(0xFF2E7D32), const Color(0xFFE8F5E9)),
            Tooltip(
              message: '设为开机自动认证 / 小组件默认 WiFi（仅允许一个）',
              child: IconButton(
                onPressed: _busyStar ? null : () => _setAutoLoginSsid(n.ssid),
                icon: Icon(
                  isAuto ? Icons.star : Icons.star_border_outlined,
                  size: 19,
                ),
                color: isAuto ? const Color(0xFFFFA000) : Colors.grey.shade400,
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('登录信息',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (_selectedSsid.isNotEmpty)
                  Expanded(
                    child: _badge('正在配置：$_selectedSsid', const Color(0xFF3D5AFE),
                        const Color(0xFFE8EAF6)),
                  )
                else
                  Text('未选择 WiFi',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.grey.shade500)),
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
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
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
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
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

  /// 设置页：联网检测守护卡片。
  /// 方案一（推荐）：adb 授权 WRITE_SECURE_SETTINGS，一次授权重启不丢，
  /// app 每次启动自动维持；方案二：Shizuku（shell 权限，免电脑）。
  Widget _buildPortalGuardCard() {
    final s = _portalStatus;
    final off = s?.off ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield_outlined,
                    size: 20, color: Color(0xFF2E7D32)),
                const SizedBox(width: 8),
                const Text('联网检测守护',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  onPressed: _refreshPortalStatus,
                  tooltip: '刷新状态',
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '系统联网检测会在连接校园网后自动拉起浏览器；关闭后由本应用静默完成认证。',
              style: TextStyle(
                  fontSize: 12.5, color: Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                    off
                        ? Icons.check_circle
                        : Icons.warning_amber_rounded,
                    size: 16,
                    color: off
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFEF6C00)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    off
                        ? '已开启守护：系统检测处于关闭状态'
                        : '未开启：连接校园网后可能自动跳浏览器',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: off
                            ? const Color(0xFF2E7D32)
                            : const Color(0xFFEF6C00)),
                  ),
                ),
              ],
            ),
            if (!off) ...[
              if (s?.writePerm ?? false) ...[
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: () async {
                    final r = await _wlan.ensurePortalDetectionOff();
                    _log(r == 'disabled' ? '已关闭系统联网检测。' : '关闭结果：$r');
                    await _refreshPortalStatus();
                  },
                  child: const Text('一键关闭（已具备权限）'),
                ),
              ],
              const SizedBox(height: 12),
              const Text('方案一（推荐）：adb 一次授权，重启不丢',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '① 手机开启「USB 调试」并连接电脑\n'
                '② 电脑安装 adb（Android 平台工具）\n'
                '③ 执行以下命令（点按钮复制后粘贴执行）：',
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    height: 1.5),
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
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'adb shell pm grant cn.lnpc.wlan_auto_connect '
                        'android.permission.WRITE_SECURE_SETTINGS',
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10.5,
                            color: Color(0xFFD4D4D4)),
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
              const SizedBox(height: 12),
              const Text('方案二：Shizuku（免电脑，需 Shizuku 运行中）',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _shizukuFix,
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.terminal, size: 18),
                label: Text(s?.shizukuRunning ?? false
                    ? '通过 Shizuku 关闭检测'
                    : '通过 Shizuku 关闭检测（需先启动 Shizuku）'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- 页面 3：设置 ----------------

  Widget _buildSettingsPage() {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildWidgetTipsCard(),
        const SizedBox(height: 12),
        _buildAutoCard(),
        const SizedBox(height: 12),
        _buildPortalGuardCard(),
        const SizedBox(height: 12),
        const CloudCard(),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.description_outlined,
                color: Color(0xFF3D5AFE)),
            title: const Text('用户协议与隐私声明'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showAgreementAgain,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.delete_outline, color: Color(0xFFD32F2F)),
            title: const Text('清除全部数据'),
            subtitle: Text('删除所有 WiFi 账号密码与配置',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            onTap: _confirmClear,
          ),
        ),
        const SizedBox(height: 12),
        _buildLogCard(),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '认证服务器：${_config.host}（Dr.COM / 哆点）',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
          ),
        ),
      ],
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: content,
    );
  }

  void _showAgreementAgain() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
              style: TextStyle(
                  fontSize: 12.5, height: 1.7, color: Colors.grey.shade700),
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

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('清除全部数据'),
        content: const Text('将删除所有 WiFi 账号、密码与配置（含小组件状态），且无法恢复。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD32F2F)),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
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

  Widget _buildLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('运行日志',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  onPressed: () => setState(_logs.clear),
                  tooltip: '清空日志',
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              height: _isTablet ? 280 : 180,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.all(12),
              child: _logs.isEmpty
                  ? Center(
                      child: Text('暂无日志',
                          style: TextStyle(color: Colors.grey.shade600)))
                  : ListView.builder(
                      controller: _logController,
                      itemCount: _logs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          _logs[i],
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Color(0xFFD4D4D4),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
