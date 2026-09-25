import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mobile/config_store.dart';
import 'mobile/home_page.dart';

/// Android 端启动引导：
/// 按金标联盟「统一导航条适配规范」（谷歌 Edge-to-Edge）适配：
/// - Android 15+：系统强制 edge-to-edge，只需透明系统栏 + insets 避让；
/// - Android <15：绘制到系统栏之下（edgeToEdge 模式）并把状态栏/导航栏设为透明，
///   内容由 Scaffold/SafeArea 自动避让 insets。
Future<void> bootstrapMobile() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarIconBrightness:
        Brightness.dark, // 浅色界面下导航条图标用深色（对比度足够）
  ));
  runApp(const MobileApp());
}

class MobileApp extends StatelessWidget {
  const MobileApp({super.key});

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
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFFE8EAF6),
          elevation: 0,
        ),
      ),
      home: const MobileGate(),
    );
  }
}

/// 移动端启动闸门：首次使用先展示用户协议（滚动到底才能同意），
/// 同意后写标记；进入主页时若为首次使用则弹出一次使用说明。
class MobileGate extends StatefulWidget {
  const MobileGate({super.key});

  @override
  State<MobileGate> createState() => _MobileGateState();
}

class _MobileGateState extends State<MobileGate> {
  bool _entered = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cfg = await MobileConfig.load();
    setState(() {
      _entered = cfg.agreementAccepted;
      _loaded = true;
    });
  }

  Future<void> _onAgreed() async {
    final cfg = await MobileConfig.load()
      ..agreementAccepted = true;
    await cfg.save();
    setState(() => _entered = true);
    await WidgetsBinding.instance.endOfFrame;
    final check = await MobileConfig.load();
    if (!check.usageNoticed && mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _MobileUsageDialog(),
      );
      final cfg2 = await MobileConfig.load()..usageNoticed = true;
      await cfg2.save();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _entered
        ? const MobileHomePage()
        : MobileAgreementPage(onAgree: _onAgreed);
  }
}

/// 用户协议页（移动端措辞）：滚动到底部后才能点击「同意并继续」。
class MobileAgreementPage extends StatefulWidget {
  const MobileAgreementPage({super.key, required this.onAgree});

  final VoidCallback onAgree;

  @override
  State<MobileAgreementPage> createState() => _MobileAgreementPageState();
}

class _MobileAgreementPageState extends State<MobileAgreementPage> {
  final _scroll = ScrollController();
  bool _readComplete = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkRead);
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.wifi, color: Color(0xFF3D5AFE), size: 26),
                  const SizedBox(width: 10),
                  const Text('用户协议与隐私声明',
                      style: TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Card(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _section(
                          '一、协议的接受与修订',
                          '欢迎使用校园网自动登录（以下简称"本软件"）。请您仔细阅读本协议，'
                              '您点击"同意并继续"或实际使用本软件，'
                              '即视为您已充分理解并接受本协议全部条款。'
                              '若您不同意本协议任何内容，请退出并停止使用。'
                              '本软件后续版本可能对本协议进行修订，修订内容随新版本一并发布，'
                              '若您在协议修订后继续使用本软件，视为您已接受修订后的协议。',
                        ),
                        _section(
                          '二、软件功能与用途',
                          '本软件是面向辽宁警察学院校园网（Dr.COM / 哆点认证）的免费辅助登录工具，'
                              '用于在连接校园网 WiFi 后自动完成网页认证，'
                              '并提供桌面小组件一键认证、开机后自动认证等便捷功能。'
                              '本软件完全在本地运行，不包含任何广告、推广或收费内容，'
                              '也不隶属于校园网运营商或认证设备厂商。',
                        ),
                        _section(
                          '三、数据与隐私保护',
                          '本软件高度重视您的个人信息保护：\n'
                              '1. 本地存储：您填写的校园网账号、密码及各 WiFi 配置，'
                              '仅保存在手机本应用私有数据目录中（Android 应用沙箱隔离，'
                              '其他应用无法读取），不上传、不同步、不共享；\n'
                              '2. 不收集数据：本软件不含统计、埋点、上报或云端同步功能，'
                              '不收集您的任何浏览记录、个人身份信息或使用行为数据；\n'
                              '3. 本地探测：软件通过系统 WLAN 接口在本机扫描可见 WiFi'
                              '及读取当前连接状态，该信息仅用于界面展示，'
                              '不会发送到任何外部服务器；\n'
                              '4. 权限说明：扫描 WiFi 与识别当前连接需要"位置信息"权限，'
                              '此为 Android 系统限制，软件不会获取您的地理位置轨迹。',
                        ),
                        _section(
                          '四、网络请求范围',
                          '本软件严格遵守最小联网原则：\n'
                              '1. 校园网认证：仅向校园网认证服务器（校园内网 172.16.200.11）'
                              '发送登录、在线状态查询等认证必需的请求；\n'
                              '2. 除上述范围外，本软件不会主动发起任何网络连接。',
                        ),
                        _section(
                          '五、账号安全与使用规范',
                          '1. 请妥善保管您的校园网账号与密码，不要将已保存密码的手机交由他人使用；\n'
                              '2. 请勿将本软件用于登录他人账号，或从事任何违反法律法规'
                              '及学校网络管理规定的行为，由此产生的一切后果由您自行承担；\n'
                              '3. 如需不再使用本软件，可先在"设置"中清除全部数据后卸载。',
                        ),
                        _section(
                          '六、一键连接与自动认证说明',
                          '桌面小组件的"一键连接"会在后台向校园网认证服务器发起静默认证，'
                              '无需打开应用；开启"开机自动认证"后，手机开机联网时会'
                              '自动对您指定的 WiFi（星标，仅一个）尝试静默认证。'
                              '您可以随时在软件内更换或取消。',
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
                          '1. 您可随时卸载本软件以终止使用，终止后本协议自动失效，'
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
                    color: _readComplete
                        ? const Color(0xFF2E7D32)
                        : Colors.grey.shade500,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _readComplete ? '已阅读完毕' : '请将协议滑动至底部后再同意',
                    style: TextStyle(
                      fontSize: 12,
                      color: _readComplete
                          ? const Color(0xFF2E7D32)
                          : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => exit(0),
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
                      child:
                          const Text('同意并继续', style: TextStyle(fontSize: 15)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首次使用说明弹窗（仅弹一次，由配置标记保证）。
class _MobileUsageDialog extends StatelessWidget {
  const _MobileUsageDialog();

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Row(
        children: [
          Icon(Icons.tips_and_updates_outlined, color: Color(0xFF3D5AFE)),
          SizedBox(width: 8),
          Text('使用说明', style: TextStyle(fontSize: 17)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _point(
              Icons.lock_outline,
              '数据仅本地保存',
              '账号、密码等所有数据仅存储在手机应用私有数据中，不会上传到任何服务器。',
            ),
            _point(
              Icons.bolt_outlined,
              '一键连接',
              '在「配置」页选择校园网 WiFi 并保存账号后，「首页」的一键连接即可静默认证；'
                  '还可将小组件添加到桌面，无需打开应用即可一键认证。',
            ),
            _point(
              Icons.star_outline,
              '开机自动认证',
              '在 WiFi 列表中点击星标设置自启 WiFi（仅允许一个），'
                  '开机联网后将自动完成认证。',
            ),
          ],
        ),
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
