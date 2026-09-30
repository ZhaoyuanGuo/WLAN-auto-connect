import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'cloud/cloud_page.dart';
import 'services/auto_login_service.dart';
import 'services/debug_log.dart';
import 'services/portal_client.dart';
import 'services/wifi_service.dart';

/// Windows 端启动引导：窗口初始化后进入 Windows 版主页。
/// （自 main.dart 迁移而来，逻辑保持不变，仅类名 MyApp → WindowsApp。）
Future<void> bootstrapWindows() async {
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    title: '校园网自动登录',
    size: Size(920, 680),
    minimumSize: Size(760, 600),
    center: true,
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const WindowsApp());
}

class WindowsApp extends StatelessWidget {
  const WindowsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '校园网自动登录',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        // Segoe UI 不含中文字形，不指定时中文走引擎回退链，渲染发虚且粗细不均
        fontFamily: 'Microsoft YaHei UI',
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
      home: const LaunchGate(),
    );
  }
}

/// 「使用说明已看过」标记文件（存在 = 首次使用说明已展示过）。
String get _usageFlagPath => '${AutoLoginService.dir}\\usage_noticed.flag';

/// 「用户协议已同意」标记文件（存在 = 首次协议已同意，之后不再弹出）。
String get _agreementFlagPath =>
    '${AutoLoginService.dir}\\agreement_accepted.flag';

/// 启动闸门：首次使用先展示用户协议（同意后写标记，此后不再弹出），
/// 进入主页时若为首次使用（无标记文件）则弹出一次使用说明。
class LaunchGate extends StatefulWidget {
  const LaunchGate({super.key});

  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate> {
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    // 已同意过协议 → 直接进入主页，不再展示协议页
    try {
      _entered = File(_agreementFlagPath).existsSync();
    } catch (_) {
      _entered = false;
    }
    if (_entered) dlog('GATE_SKIP_AGREEMENT');
  }

  Future<void> _onAgreed() async {
    dlog('GATE_AGREED');
    setState(() => _entered = true);
    // 记录协议已同意，下次启动不再显示
    try {
      await Directory(AutoLoginService.dir).create(recursive: true);
      await File(_agreementFlagPath)
          .writeAsString(DateTime.now().toIso8601String());
    } catch (_) {}
    await WidgetsBinding.instance.endOfFrame; // 等主页完成一帧后再弹说明
    var noted = false;
    try {
      noted = File(_usageFlagPath).existsSync();
    } catch (_) {}
    if (!noted && mounted) {
      dlog('USAGE_DIALOG_SHOW');
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _UsageDialog(),
      );
      try {
        await Directory(AutoLoginService.dir).create(recursive: true);
        await File(_usageFlagPath)
            .writeAsString(DateTime.now().toIso8601String());
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return _entered
        ? const HomePage()
        : AgreementPage(
            onAgree: _onAgreed,
            onDecline: () => windowManager.destroy(),
          );
  }
}

/// 用户协议页：内容滚动到底部后才能点击「同意并继续」。
class AgreementPage extends StatefulWidget {
  const AgreementPage({super.key, required this.onAgree, required this.onDecline});

  final VoidCallback onAgree;
  final VoidCallback onDecline;

  @override
  State<AgreementPage> createState() => _AgreementPageState();
}

class _AgreementPageState extends State<AgreementPage> {
  final _scroll = ScrollController();
  bool _readComplete = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkRead);
    // 延迟两帧再判定，等布局稳定（避免首帧 maxScrollExtent 尚为 0 时
    // 把长内容误判为已读完）；内容确实不足一屏时仍会视为已读完
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkRead());
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _checkRead() {
    if (!mounted || !_scroll.hasClients || _readComplete) return;
    if (_scroll.position.maxScrollExtent - _scroll.offset <= 12) {
      setState(() => _readComplete = true);
    }
  }

  Widget _section(String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              body,
              style: TextStyle(
                  fontSize: 12.5, height: 1.6, color: Colors.grey.shade700),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.wifi, color: Color(0xFF3D5AFE), size: 26),
                const SizedBox(width: 10),
                const Text('用户协议与隐私声明',
                    style:
                        TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Card(
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _section(
                        '一、协议的接受与修订',
                        '欢迎使用校园网自动登录（以下简称"本软件"）。请您仔细阅读本协议，'
                            '您勾选同意、点击"同意并继续"或实际使用本软件，'
                            '即视为您已充分理解并接受本协议全部条款。'
                            '若您不同意本协议任何内容，请点击"退出应用"并立即停止使用。'
                            '本软件后续版本可能对本协议进行修订，修订内容随新版本一并发布，'
                            '请您留意更新说明；若您在协议修订后继续使用本软件，'
                            '视为您已接受修订后的协议。',
                      ),
                      _section(
                        '二、软件功能与用途',
                        '本软件是面向使用 Dr.COM / 哆点认证的校园网的免费辅助登录工具，'
                            '用于在连接校园网 WiFi 后自动完成网页认证，'
                            '并可选支持开机后对指定 WiFi 静默登录。'
                            '本软件完全在本地运行，不包含任何广告、推广或收费内容，'
                            '也不隶属于校园网运营商或认证设备厂商。',
                      ),
                      _section(
                        '三、数据与隐私保护',
                        '本软件高度重视您的个人信息保护：\n'
                            '1. 本地存储：您填写的校园网账号、密码及各 WiFi 配置，'
                            '仅保存在本机 %APPDATA%\\CampusNetAutoLogin\\ 目录中，不共享；\n'
                            '2. 加密保护：密码经 Windows DPAPI（数据保护接口）加密，'
                            '仅当前 Windows 账户可解密；\n'
                            '3. 可选云同步：默认不同步任何数据。仅当您主动登录并使用'
                            '"云端同步"功能时，软件才将 WiFi 配置（含密码）上传至开发者'
                            '自建服务器做加密备份（传输与落盘均加密），用于多设备恢复，'
                            '您可随时删除云端备份或退出登录；\n'
                            '4. 不收集数据：本软件不含统计、埋点或行为上报，'
                            '不收集您的任何浏览记录或使用行为数据；\n'
                            '5. 本地探测：软件通过 Windows 系统命令（netsh）在本机扫描可见 WiFi'
                            '及读取当前连接状态，该信息仅用于界面展示，不会发送到任何外部服务器。',
                      ),
                      _section(
                        '四、网络请求范围',
                        '本软件严格遵守最小联网原则：\n'
                            '1. 校园网认证：仅向校园网认证服务器（校园内网 172.16.200.11）'
                            '发送登录、在线状态查询等认证必需的请求；\n'
                            '2. 版本更新：仅在检查或更新软件版本时访问因特网（GitHub 等发布渠道），'
                            '不连接任何其他外部服务器；\n'
                            '3. 除上述范围外，本软件不会主动发起任何网络连接。',
                      ),
                      _section(
                        '五、账号安全与使用规范',
                        '1. 请妥善保管您的校园网账号与密码，不要将已保存密码的电脑交由他人使用；\n'
                            '2. 请勿将本软件用于登录他人账号，或从事任何违反法律法规'
                            '及学校网络管理规定的行为，由此产生的一切后果由您自行承担；\n'
                            '3. 如需更换电脑或不再使用本软件，建议先取消开机自动登录，'
                            '并删除上述目录中的配置与凭据文件（config.json、cred.json）。',
                      ),
                      _section(
                        '六、开机自动登录说明',
                        '当您为某个 WiFi 开启开机自动登录后，本软件会在 Windows 任务计划程序中'
                            '创建名为 CampusNetAutoLogin 的计划任务，'
                            '并在您登录 Windows 后自动尝试连接并认证该 WiFi（仅限您指定的一个 WiFi）。'
                            '您可以随时在软件内更换或取消，也可在任务计划程序中手动删除该任务。',
                      ),
                      _section(
                        '七、知识产权',
                        '本软件的设计、代码及相关文档的知识产权归开发者所有。'
                            '软件中提及的第三方名称、商标归其各自权利人所有，'
                            '仅用于说明兼容对象。未经许可，请勿复制、修改、反编译'
                            '或用于商业用途；欢迎在遵守学校规定的前提下校内自由分享使用。',
                      ),
                      _section(
                        '八、免责声明与责任限制',
                        '1. 本软件按"现状"提供，开发者不对软件的适用性、无错误或不中断作出担保；\n'
                            '2. 因校园网认证服务器策略调整、网络故障、系统更新等非软件原因'
                            '导致登录失败或使用异常的，开发者不承担责任；\n'
                            '3. 在遵守本协议的前提下，对于因使用或无法使用本软件'
                            '造成的直接损失，开发者承担责任上限以零为限（本软件为免费软件）；\n'
                            '4. 您因违反本协议或学校规定使用本软件而产生的一切后果，由您自行承担。',
                      ),
                      _section(
                        '九、协议的终止与其他',
                        '1. 您可随时删除本软件以终止使用，终止后本协议自动失效，'
                            '但第五条中的保管义务不受影响；\n'
                            '2. 本协议未尽事宜，依照中华人民共和国相关法律法规执行；\n'
                            '3. 如对本协议有任何疑问或建议，欢迎通过软件发布页反馈。'
                            '点击"同意并继续"即表示您已完整阅读并接受以上全部内容。',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _readComplete ? Icons.check_circle : Icons.arrow_downward,
                  size: 15,
                  color:
                      _readComplete ? const Color(0xFF2E7D32) : Colors.grey.shade500,
                ),
                const SizedBox(width: 5),
                Text(
                  _readComplete ? '已阅读完毕' : '请将协议滑动至底部后再同意',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        _readComplete ? const Color(0xFF2E7D32) : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: widget.onDecline,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('退出应用'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _readComplete ? widget.onAgree : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('同意并继续',
                        style: TextStyle(fontSize: 15)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 首次使用说明弹窗（仅弹一次，由标记文件保证）。
class _UsageDialog extends StatelessWidget {
  const _UsageDialog();

  Widget _point(IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: const Color(0xFF3D5AFE)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: Colors.grey.shade700)),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Row(
        children: [
          Icon(Icons.tips_and_updates_outlined, color: Color(0xFF3D5AFE)),
          SizedBox(width: 8),
          Text('使用说明', style: TextStyle(fontSize: 17)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _point(
            Icons.lock_outline,
            '数据仅本地保存',
            '账号、密码等所有数据仅存储在本机（密码经 Windows DPAPI 加密），'
                '不会上传到任何服务器。',
          ),
          _point(
            Icons.public_off_outlined,
            '联网范围',
            '除校园网认证必需的请求外，仅更新软件版本时会使用因特网。',
          ),
          _point(
            Icons.star_outline,
            '开机自动登录',
            '在 WiFi 列表中点击星标设置自启 WiFi（仅允许一个），'
                '开机后连接该 WiFi 时才会自动认证。',
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('我知道了'),
        ),
      ],
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
  final _wifi = WifiService();
  late final _client = PortalClient();

  final _accountCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  String _carrier = '校园用户';
  String get _suffix => _carriers[_carrier] ?? '';
  bool _showPassword = false;

  NetState _netState = NetState.checking;
  bool _busyLogin = false;
  bool _busyAutoStart = false;
  bool _busySave = false;
  bool _busyStar = false; // 正在切换自启 WiFi

  // WiFi 列表与多 WiFi 档案
  List<WifiNetwork> _networks = [];
  bool _scanning = false;
  String _selectedSsid = ''; // 正在配置的 WiFi
  Map<String, WifiProfile> _profiles = {};
  String _autoLoginSsid = ''; // 开机自动登录的唯一 WiFi

  bool _taskRegistered = false;
  bool _popupFixOn = false; // 是否已屏蔽系统强制门户自动弹浏览器
  bool _busyPopup = false;

  final _logs = <String>[];
  final _logController = ScrollController();

  @override
  void initState() {
    super.initState();
    dlog('HOME_INIT');
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
    dlog('BOOT_START');
    try {
      await _service.ensureScriptInstalled();
    } catch (e) {
      _log('初始化脚本失败：$e');
      dlog('SCRIPT_INSTALL_FAIL $e');
    }
    try {
      final (profiles, autoSsid) = await _service.readProfiles();
      _profiles = profiles;
      _autoLoginSsid = autoSsid;
      dlog(
          'CONFIG_LOADED profiles=${profiles.length} autoLoginSsid=$autoSsid');
    } catch (e) {
      dlog('READ_CONFIG_FAIL $e');
      _log('读取已保存配置失败：$e');
    }
    if (_autoLoginSsid.isNotEmpty) {
      _selectNetwork(_autoLoginSsid, refreshList: false);
      _log('已加载开机自启 WiFi：$_autoLoginSsid（账号：${_profiles[_autoLoginSsid]?.account}）');
    } else if (_profiles.isNotEmpty) {
      _log('已保存 ${_profiles.length} 个 WiFi 账号档案，尚未指定开机自启 WiFi。');
    }
    _taskRegistered = await _checkTaskRegistered();
    _popupFixOn = await _service.popupFixEnabled();
    if (mounted) setState(() {});
    await _scanNetworks();
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

  // ---------------- WiFi 扫描与档案 ----------------

  Future<void> _scanNetworks() async {
    setState(() => _scanning = true);
    List<WifiNetwork> nets;
    try {
      nets = await _wifi.scan();
    } catch (e) {
      nets = [];
      dlog('SCAN_EXCEPTION $e');
      _log('扫描 WiFi 出错：$e');
    }
    setState(() {
      _networks = nets;
      _scanning = false;
    });
    if (nets.isEmpty) {
      final err = _wifi.lastError;
      _log(err == null
          ? '未扫描到任何 WiFi（请检查无线网卡开关）。'
          : '未扫描到任何 WiFi：$err');
      dlog('SCAN_EMPTY lastError=${err ?? 'none'}');
    } else {
      final cur = nets.where((n) => n.connected).map((n) => n.ssid).join('、');
      _log('扫描到 ${nets.length} 个 WiFi${cur.isEmpty ? '' : '，当前连接：$cur'}');
      dlog(
          'SCAN_OK count=${nets.length} ssids=${nets.map((n) => n.ssid).take(8).join('|')}');
    }
  }

  /// 选中某个 WiFi 作为配置目标，并把已存账号填入表单。
  void _selectNetwork(String ssid, {bool refreshList = true}) {
    setState(() {
      _selectedSsid = ssid;
      final p = _profiles[ssid];
      _accountCtl.text = p?.account ?? '';
      _passwordCtl.clear();
      _carrier = _carriers.entries
          .firstWhere((e) => e.value == (p?.suffix ?? ''),
              orElse: () => const MapEntry('校园用户', ''))
          .key;
    });
    if (refreshList) _log('已选择 WiFi：$ssid');
  }

  /// 保存当前表单为 [_selectedSsid] 的档案（密码留空 = 沿用已保存密码）。
  Future<void> _saveCurrentProfile({String? overrideAutoLogin}) async {
    final ssid = _selectedSsid;
    final account = _accountCtl.text.trim();
    if (ssid.isEmpty) {
      _snack('请先在「WiFi 网络」列表中选择要配置的 WiFi', error: true);
      return;
    }
    if (account.isEmpty) {
      _snack('请先输入该 WiFi 的账号', error: true);
      return;
    }
    final password = _passwordCtl.text;
    final existed = _profiles[ssid];
    if (existed == null || !existed.hasPassword) {
      if (password.isEmpty && overrideAutoLogin != null) {
        _snack('该 WiFi 尚未保存过密码，请先输入密码', error: true);
        return;
      }
    }
    setState(() => _busySave = true);
    final updated = WifiProfile(
      ssid: ssid,
      account: account,
      suffix: _suffix,
      hasPassword: password.isNotEmpty || (existed?.hasPassword ?? false),
    );
    final all = [
      ..._profiles.values.where((p) => p.ssid != ssid),
      updated,
    ];
    final auto = overrideAutoLogin ?? _autoLoginSsid;
    final (ok, msg) = await _service.saveProfiles(
      profiles: all,
      passwords: {ssid: password}, // 空串 = 沿用旧密码
      autoLoginSsid: auto,
    );
    if (ok) {
      setState(() {
        _profiles[ssid] = updated;
        if (overrideAutoLogin != null) _autoLoginSsid = overrideAutoLogin;
      });
      _log('已保存 WiFi「$ssid」的账号（${password.isEmpty ? '沿用已存密码' : '密码已更新'}）');
      if (overrideAutoLogin != null) {
        _log('开机自动登录 WiFi 已设为「$ssid」。');
      }
      _snack(overrideAutoLogin != null ? '已保存并设为自启 WiFi' : '账号已保存');
    } else {
      _log('保存失败：$msg');
      _snack('保存失败：$msg', error: true);
    }
    setState(() => _busySave = false);
  }

  /// 把某个 WiFi 设为唯一的开机自动登录 WiFi。
  Future<void> _setAutoLoginSsid(String ssid) async {
    final p = _profiles[ssid];
    if (p == null || p.account.isEmpty) {
      _snack('请先在列表中选择该 WiFi，填写账号密码并保存', error: true);
      return;
    }
    if (ssid == _autoLoginSsid) return;
    setState(() => _busyStar = true);
    final (ok, msg) = await _service.saveProfiles(
      profiles: _profiles.values.toList(),
      passwords: const {}, // 全部沿用已存密码
      autoLoginSsid: ssid,
    );
    if (ok) {
      setState(() => _autoLoginSsid = ssid);
      _log('开机自动登录 WiFi 已切换为「$ssid」，任务将在下次登录/开机时使用其账号。');
      _snack('自启 WiFi 已设为：$ssid');
    } else {
      _log('设置自启 WiFi 失败：$msg');
      _snack('设置失败：$msg', error: true);
    }
    setState(() => _busyStar = false);
  }

  /// 尝试让 Windows 连接所选 WiFi（需系统已保存该网络）。
  Future<void> _connectWifi(WifiNetwork n) async {
    final ok = await _ensureConnectedTo(n.ssid);
    if (ok) {
      await _scanNetworks();
      await _refreshNetState();
    }
  }

  /// 确保已连接到指定 WiFi：未连接时发起连接请求并轮询等待（最长约 30 秒）。
  /// 返回 true 表示当前已连接到该 WiFi。
  Future<bool> _ensureConnectedTo(String ssid) async {
    if (ssid.isEmpty) return false;
    var cur = await _wifi.currentSsid();
    if (cur == ssid) return true;
    _log('当前${cur.isEmpty ? '未连接任何 WiFi' : '连接的是「$cur」'}，正在请求连接「$ssid」...');
    final ok = await _wifi.connect(ssid);
    if (!ok) {
      _log('连接请求失败（系统可能未保存「$ssid」的配置，请先在系统 WLAN 列表手动连接一次）。');
      return false;
    }
    for (var i = 1; i <= 30; i++) {
      await Future.delayed(const Duration(seconds: 1));
      cur = await _wifi.currentSsid();
      if (cur == ssid) {
        _log('已连接到「$cur」。');
        return true;
      }
    }
    _log('等待 30 秒仍未连上「$ssid」（信号太弱/密码已变/热点已关闭？）。');
    return false;
  }

  // ---------------- 网络状态 / 登录 ----------------

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

  /// 立即静默登录。
  /// 密码框为空时回退到该 WiFi 已保存的密码（DPAPI，经 PS 脚本解密登录），
  /// 避免每次重开应用都要重新输入密码。
  Future<void> _connectNow() async {
    final account = _accountCtl.text.trim();
    final password = _passwordCtl.text;
    final profile = _selectedSsid.isEmpty ? null : _profiles[_selectedSsid];
    final canUseSaved = profile != null &&
        profile.hasPassword &&
        (account.isEmpty || account == profile.account);
    final useSaved = password.isEmpty && canUseSaved;
    if ((account.isEmpty && !useSaved) || (password.isEmpty && !useSaved)) {
      _snack('请先输入账号和密码', error: true);
      return;
    }
    setState(() => _busyLogin = true);
    _log('开始检测网络状态...');
    // 先确保已连上所选 WiFi（未连接时自动发起连接并等待），再探测认证服务器
    if (_selectedSsid.isNotEmpty) {
      dlog('CONNECT_NOW selected=$_selectedSsid savedPw=$useSaved');
      final wifiOk = await _ensureConnectedTo(_selectedSsid);
      if (!wifiOk) {
        dlog('CONNECT_NOW WIFI_CONNECT_FAIL selected=$_selectedSsid');
        _log('无法连接到「$_selectedSsid」，已跳过认证检测。');
        setState(() {
          _netState = NetState.portalUnreachable;
          _busyLogin = false;
        });
        return;
      }
      await _scanNetworks();
    }
    if (useSaved) {
      _log('未输入密码，使用「$_selectedSsid」已保存的密码静默登录...');
      final (ok, lines) = await _service.loginOnceFor(_selectedSsid);
      for (final l in lines) {
        final (_, msg) = AutoLoginService.parseLine(l);
        _log(msg);
      }
      if (ok) {
        _log('认证完成，已连接互联网。');
        setState(() => _netState = NetState.online);
        _snack('校园网登录成功');
      } else {
        setState(() => _netState = NetState.needLogin);
        _snack('登录失败（已存密码可能已修改，请重新输入并保存）', error: true);
      }
      setState(() => _busyLogin = false);
      return;
    }
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
      final cur = await _wifi.currentSsid();
      dlog('PORTAL_UNREACHABLE current=$cur');
      _log(cur.isEmpty
          ? '认证服务器不可达（当前未连接任何 WiFi）。'
          : '认证服务器不可达（当前连接：「$cur」，这不是校园网或被其他网卡抢占了路由）。');
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
    if (_selectedSsid.isEmpty) {
      _snack('请先在「WiFi 网络」列表中选择开机要自动登录的 WiFi', error: true);
      return;
    }
    setState(() => _busyAutoStart = true);
    _log('正在保存「$_selectedSsid」的账号并设为自启 WiFi...');
    await _saveCurrentProfile(overrideAutoLogin: _selectedSsid);
    if (_autoLoginSsid != _selectedSsid) {
      // 保存失败，中止
      setState(() => _busyAutoStart = false);
      return;
    }
    _log('正在注册任务计划（如弹出 UAC 确认框，请点击「是」）...');
    final (okInstall, msgInstall) = await _service.installTask();
    if (okInstall) {
      _taskRegistered = true;
      _log('开机自动登录已开启：Windows 登录后连接「$_selectedSsid」将自动静默认证。');
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

  /// 开/关「阻止连接后自动弹出认证网页」（禁用/恢复 NCSI 主动探测，需 UAC）。
  Future<void> _togglePopupFix(bool on) async {
    setState(() => _busyPopup = true);
    _log(on
        ? '正在屏蔽系统强制门户自动弹浏览器（弹出 UAC 确认框，请点「是」）...'
        : '正在恢复系统默认网络探测（弹出 UAC 确认框，请点「是」）...');
    final (ok, msg) = on ? await _service.fixPopup() : await _service.undoPopup();
    if (ok) {
      _log(on
          ? '已屏蔽：连接校园网后不会再自动弹出浏览器（MSN/认证页）。'
          : '已恢复系统默认网络探测。');
    } else {
      _log('${on ? '屏蔽' : '恢复'}失败：$msg');
      _snack('${on ? '屏蔽' : '恢复'}失败：$msg', error: true);
    }
    _popupFixOn = await _service.popupFixEnabled();
    setState(() => _busyPopup = false);
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

  /// WiFi 列表的一行。
  Widget _wifiRow(WifiNetwork n) {
    final p = _profiles[n.ssid];
    final isAuto = _autoLoginSsid == n.ssid;
    final isSelected = _selectedSsid == n.ssid;
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
              n.visible ? _signalIcon(n.signal) : Icons.wifi_off,
              size: 17,
              color: n.connected
                  ? (isSelected ? const Color(0xFF3D5AFE) : Colors.grey.shade700)
                  : n.visible
                      ? Colors.grey.shade600
                      : Colors.grey.shade300,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                n.ssid,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isAuto ? FontWeight.w600 : FontWeight.w400,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            if (p != null && p.account.isNotEmpty)
              _badge('已存:${p.account}', const Color(0xFF1565C0),
                  const Color(0xFFE3F2FD)),
            const SizedBox(width: 4),
            if (n.connected) _badge('已连接', const Color(0xFF2E7D32), const Color(0xFFE8F5E9)),
            Tooltip(
              message: '连接此 WiFi（需系统已保存该网络）',
              child: IconButton(
                onPressed:
                    (n.visible && !n.connected) ? () => _connectWifi(n) : null,
                icon: const Icon(Icons.link, size: 16),
                color: Colors.grey.shade600,
                visualDensity: VisualDensity.compact,
              ),
            ),
            Tooltip(
              message: '设为开机自动登录 WiFi（仅允许一个）',
              child: IconButton(
                onPressed: _busyStar ? null : () => _setAutoLoginSsid(n.ssid),
                icon: Icon(
                  isAuto ? Icons.star : Icons.star_border_outlined,
                  size: 18,
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

  /// 列表数据 = 扫描到的网络 + 已保存但不在附近的档案。
  List<WifiNetwork> get _displayNetworks {
    final list = List<WifiNetwork>.from(_networks);
    final visible = _networks.map((n) => n.ssid).toSet();
    for (final ssid in _profiles.keys) {
      if (!visible.contains(ssid)) {
        list.add(WifiNetwork(ssid: ssid, signal: 0, visible: false));
      }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final (stateText, stateColor, stateIcon) = _stateInfo;
    final selectedProfile = _profiles[_selectedSsid];
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
                  // ---- 左列：WiFi 列表 + 账号表单 ----
                  Expanded(
                    flex: 5,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildWifiCard(),
                          const SizedBox(height: 12),
                          _buildLoginCard(selectedProfile),
                          const SizedBox(height: 12),
                          _buildAutoStartCard(),
                          const SizedBox(height: 12),
                          const CloudCard(),
                        ],
                      ),
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
                                              // Consolas 无中文，日志中文回退到雅黑
                                              fontFamilyFallback: [
                                                'Microsoft YaHei UI',
                                              ],
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

  // ---------------- 卡片 ----------------

  Widget _buildWifiCard() {
    final nets = _displayNetworks;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('WiFi 网络',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Text('点击选择，点星标设为开机自启（仅一个）',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                const Spacer(),
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
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
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

  Widget _buildLoginCard(WifiProfile? selectedProfile) {
    final hasSavedPw = selectedProfile?.hasPassword ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
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
                  _badge('正在配置：$_selectedSsid', const Color(0xFF3D5AFE),
                      const Color(0xFFE8EAF6))
                else
                  Text('未选择 WiFi（仅供手动登录）',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
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
              onSubmitted: (_) => _connectNow(),
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
                            value: k,
                            child: Text(k),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _carrier = v ?? '校园用户'),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_busySave || _selectedSsid.isEmpty)
                        ? null
                        : () => _saveCurrentProfile(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: _busySave
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined, size: 20),
                    label: const Text('保存此 WiFi 账号',
                        style: TextStyle(fontSize: 14.5)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
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
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutoStartCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('开机自动登录',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
            Text.rich(
              TextSpan(
                style: TextStyle(
                    fontSize: 12.5, color: Colors.grey.shade600, height: 1.5),
                children: [
                  const TextSpan(
                      text: '开机后仅对星标指定的 WiFi（'),
                  TextSpan(
                      text: _autoLoginSsid.isEmpty ? '未指定' : _autoLoginSsid,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFFFA000))),
                  const TextSpan(
                      text:
                          '）自动认证，其他 WiFi 不受影响。密码经 Windows DPAPI 加密保存，'
                          '通过任务计划程序在登录桌面时静默登录，全程无窗口。'),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // 强制门户弹窗屏蔽开关
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _popupFixOn,
              onChanged: _busyPopup ? null : _togglePopupFix,
              activeThumbColor: const Color(0xFF3D5AFE),
              title: Row(
                children: [
                  const Text('阻止自动弹出认证网页',
                      style: TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                  if (_busyPopup) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ],
              ),
              subtitle: Text(
                '屏蔽 Windows 强制门户检测，连接校园网后不再自动打开浏览器（MSN）。'
                '开启需管理员确认；任务栏网络图标可能显示"无Internet"，实际联网不受影响。',
                style:
                    TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed:
                        _busyAutoStart ? null : _enableAutoStart,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: _busyAutoStart
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.rocket_launch_outlined, size: 18),
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
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.power_settings_new, size: 18),
                    label: const Text('关闭自启'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
