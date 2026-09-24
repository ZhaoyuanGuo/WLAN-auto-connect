import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/auto_login_service.dart';
import 'services/portal_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    title: '校园网自动登录',
    size: Size(880, 640),
    minimumSize: Size(720, 560),
    center: true,
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '校园网自动登录',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3D5AFE),
          brightness: Brightness.light,
          surface: const Color(0xFFF5F6F8),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F6F8),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF7F8FA),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF3D5AFE), width: 1.6),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
      home: const HomePage(),
    );
  }
}

enum NetState { unknown, checking, online, needLogin, portalUnreachable }

/// 运营商选项（来自门户配置：value 为账号后缀）。
const _carriers = <String, String>{
  '校园用户': '',
  '校园电信': '@dx',
  '校园联通': '@lt',
  '校园移动': '',
};

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _service = AutoLoginService();
  late final _client = PortalClient();

  final _accountCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  String _carrier = '校园用户';
  String get _suffix => _carriers[_carrier] ?? '';
  bool _showPassword = false;

  NetState _netState = NetState.checking;
  bool _busyLogin = false;
  bool _busyAutoStart = false;

  bool _hasSavedCred = false;
  bool _taskRegistered = false;

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
    try {
      await _service.ensureScriptInstalled();
    } catch (e) {
      _log('初始化脚本失败：$e');
    }
    final cfg = await _service.readConfig();
    if (cfg != null) {
      _accountCtl.text = (cfg['account'] ?? '') as String;
      final savedSuffix = (cfg['suffix'] ?? '') as String;
      _carrier = _carriers.entries
          .firstWhere((e) => e.value == savedSuffix,
              orElse: () => const MapEntry('校园用户', ''))
          .key;
      _log('已加载保存的账号：${_accountCtl.text}');
    }
    _hasSavedCred = File('${AutoLoginService.dir}\\cred.bin').existsSync();
    _taskRegistered = await _checkTaskRegistered();
    setState(() {});
    await _refreshNetState();
  }

  Future<bool> _checkTaskRegistered() async {
    try {
      final r = await Process.run('schtasks', ['/Query', '/TN', AutoLoginService.taskName]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshNetState() async {
    setState(() => _netState = NetState.checking);
    final state = await _client.checkOnline();
    setState(() {
      _netState = state == true
          ? NetState.online
          : state == false
              ? NetState.needLogin
              : NetState.portalUnreachable;
    });
  }

  /// 立即静默登录（Dart 原生实现，无浏览器、无窗口）。
  Future<void> _connectNow() async {
    final account = _accountCtl.text.trim();
    final password = _passwordCtl.text;
    if (account.isEmpty || password.isEmpty) {
      _snack('请先输入账号和密码', error: true);
      return;
    }
    setState(() => _busyLogin = true);
    _log('开始检测网络状态...');
    var online = await _client.checkOnline();
    if (online == true) {
      _log('当前已在线，无需登录。');
      setState(() {
        _netState = NetState.online;
        _busyLogin = false;
      });
      return;
    }
    if (online == null) {
      _log('认证服务器不可达，请检查是否已连接校园网（WiFi：LNPC-STU-5G）。');
      setState(() {
        _netState = NetState.portalUnreachable;
        _busyLogin = false;
      });
      return;
    }
    _log('未认证，正在获取会话参数...');
    final session = await _client.captureHijackParams();
    _log('获取到会话参数：${session.isEmpty ? '（空，使用本机 IP 登录）' : session.toString()}');
    _log('正在静默登录（账号：$account${_suffix.isEmpty ? '' : ' $_suffix'}）...');
    final (ok, msg) = await _client.login(account, password, _suffix, session);
    if (ok) {
      _log('登录请求成功（$msg），正在确认上线状态...');
      await Future.delayed(const Duration(seconds: 2));
      online = await _client.checkOnline();
      if (online == true) {
        _log('认证完成，已连接互联网。');
        setState(() => _netState = NetState.online);
        _snack('校园网登录成功');
      } else {
        _log('登录请求已发送但状态未确认，请稍后重试。');
        setState(() => _netState = NetState.needLogin);
      }
    } else {
      _log('登录失败，门户返回：$msg（请检查账号密码、运营商选择是否正确）');
      setState(() => _netState = NetState.needLogin);
      _snack('登录失败：$msg', error: true);
    }
    setState(() => _busyLogin = false);
  }

  /// 保存账号并注册开机自启任务计划。
  Future<void> _enableAutoStart() async {
    final account = _accountCtl.text.trim();
    final password = _passwordCtl.text;
    if (account.isEmpty || password.isEmpty) {
      _snack('请先输入账号和密码', error: true);
      return;
    }
    setState(() => _busyAutoStart = true);
    _log('正在保存账号信息（密码经 Windows DPAPI 加密，仅本机当前用户可解密）...');
    final (okSave, msgSave) = await _service.saveCredentials(
      account: account,
      password: password,
      suffix: _suffix,
    );
    if (!okSave) {
      _log('保存失败：$msgSave');
      _snack('保存失败：$msgSave', error: true);
      setState(() => _busyAutoStart = false);
      return;
    }
    _log('账号已保存，正在注册任务计划（如弹出 UAC 确认框，请点击「是」）...');
    final (okInstall, msgInstall) = await _service.installTask();
    if (okInstall) {
      _taskRegistered = true;
      _hasSavedCred = true;
      _log('开机自动登录已开启：Windows 登录后将自动静默认证，无需打开浏览器。');
      _snack('开机自动登录已开启');
    } else {
      _log('任务计划注册失败：$msgInstall');
      _snack('注册失败：$msgInstall', error: true);
    }
    setState(() => _busyAutoStart = false);
  }

  Future<void> _disableAutoStart() async {
    setState(() => _busyAutoStart = true);
    final ok = await _service.uninstallTask();
    _taskRegistered = false;
    _log(ok ? '开机自动登录已关闭。' : '任务计划不存在或已移除。');
    setState(() => _busyAutoStart = false);
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? const Color(0xFFD32F2F) : const Color(0xFF2E7D32),
      behavior: SnackBarBehavior.floating,
      width: 420,
      duration: const Duration(seconds: 3),
    ));
  }

  (String, Color, IconData) get _stateInfo {
    switch (_netState) {
      case NetState.online:
        return ('已联网', const Color(0xFF2E7D32), Icons.check_circle);
      case NetState.needLogin:
        return ('校园网未认证', const Color(0xFFEF6C00), Icons.portable_wifi_off);
      case NetState.portalUnreachable:
        return ('未连接校园网', const Color(0xFFB71C1C), Icons.wifi_off);
      case NetState.checking:
        return ('检测中...', Colors.grey.shade700, Icons.sync);
      case NetState.unknown:
        return ('未知', Colors.grey.shade700, Icons.help_outline);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (stateText, stateColor, stateIcon) = _stateInfo;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- 顶栏 ----
            Row(
              children: [
                const Icon(Icons.wifi, color: Color(0xFF3D5AFE), size: 28),
                const SizedBox(width: 10),
                const Text('校园网自动登录',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const Spacer(),
                Icon(stateIcon, color: stateColor, size: 18),
                const SizedBox(width: 6),
                Text(stateText, style: TextStyle(color: stateColor, fontSize: 14)),
                IconButton(
                  onPressed: _busyLogin ? null : _refreshNetState,
                  tooltip: '刷新状态',
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ---- 左列：账号表单 ----
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text('登录信息',
                                    style: TextStyle(
                                        fontSize: 15, fontWeight: FontWeight.w600)),
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
                                  onSubmitted: (_) => _connectNow(),
                                  decoration: InputDecoration(
                                    labelText: _hasSavedCred
                                        ? '密码（已保存，输入可更新）'
                                        : '密码',
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
                                                value: k,
                                                child: Text(k),
                                              ))
                                          .toList(),
                                      onChanged: (v) =>
                                          setState(() => _carrier = v ?? '校园用户'),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                FilledButton.icon(
                                  onPressed: _busyLogin ? null : _connectNow,
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10)),
                                  ),
                                  icon: _busyLogin
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2, color: Colors.white))
                                      : const Icon(Icons.bolt, size: 20),
                                  label: Text(_busyLogin ? '正在连接...' : '立即连接',
                                      style: const TextStyle(fontSize: 15)),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    const Text('开机自动登录',
                                        style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600)),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _taskRegistered
                                            ? const Color(0xFFE8F5E9)
                                            : const Color(0xFFEEEEEE),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        _taskRegistered ? '已开启' : '未开启',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: _taskRegistered
                                              ? const Color(0xFF2E7D32)
                                              : Colors.grey.shade600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '开启后自动写入 PowerShell 登录脚本（密码经 Windows DPAPI 加密保存，仅当前用户可解密），'
                                  '并通过 Windows 任务计划程序在每次登录桌面时静默认证，全程无窗口、无浏览器。',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.grey.shade600,
                                      height: 1.5),
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.tonalIcon(
                                        onPressed: _busyAutoStart
                                            ? null
                                            : _enableAutoStart,
                                        style: FilledButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 12),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10)),
                                        ),
                                        icon: _busyAutoStart
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2))
                                            : const Icon(Icons.rocket_launch_outlined,
                                                size: 18),
                                        label: const Text('保存并开启'),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: (_busyAutoStart || !_taskRegistered)
                                            ? null
                                            : _disableAutoStart,
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 12),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10)),
                                        ),
                                        icon: const Icon(Icons.power_settings_new,
                                            size: 18),
                                        label: const Text('关闭自启'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // ---- 右列：运行日志 ----
                  Expanded(
                    flex: 4,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const Text('运行日志',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                                const Spacer(),
                                IconButton(
                                  onPressed: () => setState(_logs.clear),
                                  tooltip: '清空日志',
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: _logs.isEmpty
                                  ? Center(
                                      child: Text('暂无日志',
                                          style: TextStyle(
                                              color: Colors.grey.shade400)))
                                  : Container(
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1E1E1E),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      padding: const EdgeInsets.all(12),
                                      child: ListView.builder(
                                        controller: _logController,
                                        itemCount: _logs.length,
                                        itemBuilder: (_, i) => Padding(
                                          padding:
                                              const EdgeInsets.symmetric(vertical: 2),
                                          child: Text(
                                            _logs[i],
                                            style: const TextStyle(
                                              fontFamily: 'Consolas',
                                              fontSize: 12,
                                              color: Color(0xFFD4D4D4),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '认证服务器：172.16.200.11（Dr.COM / 哆点） · 脚本位置：${AutoLoginService.dir}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
