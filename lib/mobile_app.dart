import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mobile/config_store.dart';
import 'mobile/home_page.dart';
import 'mobile/theme.dart';
import 'widgets/agreement_scaffold.dart';

/// Android 端启动引导：
/// 按金标联盟「统一导航条适配规范」（谷歌 Edge-to-Edge）适配：
/// - Android 15+：系统强制 edge-to-edge，只需透明系统栏 + insets 避让；
/// - Android <15：绘制到系统栏之下（edgeToEdge 模式）并把状态栏/导航栏设为透明，
///   内容由 Scaffold/SafeArea 自动避让 insets。
/// 系统栏图标亮度随主题亮度切换（见 MobileApp 的 AnnotatedRegion）。
Future<void> bootstrapMobile() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const MobileApp());
}

class MobileApp extends StatefulWidget {
  const MobileApp({super.key});

  @override
  State<MobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<MobileApp> {
  @override
  void initState() {
    super.initState();
    AppThemeMode.load();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppThemeMode.value,
      builder: (_, _, _) => MaterialApp(
        title: '校园网自动登录',
        debugShowCheckedModeBanner: false,
        themeMode: AppThemeMode.mode,
        theme: MobileThemes.light,
        darkTheme: MobileThemes.dark,
        builder: (context, child) {
          // 透色系统栏下，图标亮度跟随当前主题（浅色用深色图标）
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
            child: child!,
          );
        },
        home: const MobileGate(),
      ),
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

/// 用户协议页（移动端措辞）：复用 [AgreementScaffold] 的滚动门控逻辑，
/// 仅条款文本与边距为移动端定制。
class MobileAgreementPage extends StatelessWidget {
  const MobileAgreementPage({super.key, required this.onAgree});

  final VoidCallback onAgree;

  static const _sections = <AgreementSection>[
    AgreementSection(
      '一、协议的接受与修订',
      '欢迎使用校园网自动登录（以下简称"本软件"）。请您仔细阅读本协议，'
          '您点击"同意并继续"或实际使用本软件，'
          '即视为您已充分理解并接受本协议全部条款。'
          '若您不同意本协议任何内容，请退出并停止使用。'
          '本软件后续版本可能对本协议进行修订，修订内容随新版本一并发布，'
          '若您在协议修订后继续使用本软件，视为您已接受修订后的协议。',
    ),
    AgreementSection(
      '二、软件功能与用途',
      '本软件是面向使用 Dr.COM / 哆点认证的校园网的免费辅助登录工具，'
          '用于在连接校园网 WiFi 后自动完成网页认证，'
          '并提供桌面小组件一键认证、开机后自动认证等便捷功能。'
          '本软件完全在本地运行，不包含任何广告、推广或收费内容，'
          '也不隶属于校园网运营商或认证设备厂商。',
    ),
    AgreementSection(
      '三、数据与隐私保护',
      '本软件高度重视您的个人信息保护：\n'
          '1. 本地存储：您填写的校园网账号、密码及各 WiFi 配置，'
          '仅保存在手机本应用私有数据目录中（Android 应用沙箱隔离，'
          '其他应用无法读取），不共享；\n'
          '2. 可选云同步：默认不同步任何数据。仅当您主动登录并使用'
          '"云端同步"功能时，软件才将 WiFi 配置（含密码）上传至开发者'
          '自建服务器做加密备份（传输与落盘均加密），用于多设备恢复，'
          '您可随时删除云端备份或退出登录；\n'
          '3. 不收集数据：本软件不含统计、埋点或行为上报，'
          '不收集您的任何浏览记录或使用行为数据；\n'
          '4. 本地探测：软件通过系统 WLAN 接口在本机扫描可见 WiFi'
          '及读取当前连接状态，该信息仅用于界面展示，'
          '不会发送到任何外部服务器；\n'
          '5. 权限说明：扫描 WiFi 与识别当前连接需要"位置信息"权限，'
          '此为 Android 系统限制，软件不会获取您的地理位置轨迹。',
    ),
    AgreementSection(
      '四、网络请求范围',
      '本软件严格遵守最小联网原则：\n'
          '1. 校园网认证：仅向校园网认证服务器（校园内网）'
          '发送登录、在线状态查询等认证必需的请求；\n'
          '2. 除上述范围外，本软件不会主动发起任何网络连接。',
    ),
    AgreementSection(
      '五、账号安全与使用规范',
      '1. 请妥善保管您的校园网账号与密码，不要将已保存密码的手机交由他人使用；\n'
          '2. 请勿将本软件用于登录他人账号，或从事任何违反法律法规'
          '及学校网络管理规定的行为，由此产生的一切后果由您自行承担；\n'
          '3. 如需不再使用本软件，可先在"设置"中清除全部数据后卸载。',
    ),
    AgreementSection(
      '六、一键连接与自动认证说明',
      '桌面小组件的"一键连接"会在后台向校园网认证服务器发起静默认证，'
          '无需打开应用；开启"开机自动认证"后，手机开机联网时会'
          '自动对您指定的 WiFi（星标，仅一个）尝试静默认证。'
          '您可以随时在软件内更换或取消。',
    ),
    AgreementSection(
      '七、知识产权',
      '本软件的设计、代码及相关文档的知识产权归开发者所有。'
          '软件中提及的第三方名称、商标归其各自权利人所有，'
          '仅用于说明兼容对象。未经许可，请勿复制、修改、反编译'
          '或用于商业用途；欢迎在遵守学校规定的前提下校内自由分享使用。',
    ),
    AgreementSection(
      '八、免责声明与责任限制',
      '1. 本软件按"现状"提供，开发者不对软件的适用性、无错误或不中断作出担保；\n'
          '2. 因校园网认证服务器策略调整、网络故障、系统更新等非软件原因'
          '导致登录失败或使用异常的，开发者不承担责任；\n'
          '3. 在遵守本协议的前提下，对于因使用或无法使用本软件'
          '造成的直接损失，开发者承担责任上限以零为限（本软件为免费软件）；\n'
          '4. 您因违反本协议或学校规定使用本软件而产生的一切后果，由您自行承担。',
    ),
    AgreementSection(
      '九、协议的终止与其他',
      '1. 您可随时卸载本软件以终止使用，终止后本协议自动失效，'
          '但第五条中的保管义务不受影响；\n'
          '2. 本协议未尽事宜，依照中华人民共和国相关法律法规执行；\n'
          '3. 如对本协议有任何疑问或建议，欢迎通过软件发布页反馈。'
          '点击"同意并继续"即表示您已完整阅读并接受以上全部内容。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AgreementScaffold(
      sections: _sections,
      onAgree: onAgree,
      onDecline: () => exit(0),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      cardPadding: const EdgeInsets.all(18),
      useSafeArea: true,
    );
  }
}


/// 首次使用说明弹窗（仅弹一次，由配置标记保证）。
class _MobileUsageDialog extends StatelessWidget {
  const _MobileUsageDialog();

  Widget _point(BuildContext context, IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(body, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tips_and_updates_outlined),
          SizedBox(width: 8),
          Text('使用说明'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _point(
              context,
              Icons.lock_outline,
              '数据仅本地保存',
              '账号、密码等所有数据仅存储在手机应用私有数据中，不会上传到任何服务器。',
            ),
            _point(
              context,
              Icons.bolt_outlined,
              '一键连接',
              '在「配置」页选择校园网 WiFi 并保存账号后，「首页」的一键连接即可静默认证；'
                  '还可将小组件添加到桌面，无需打开应用即可一键认证。',
            ),
            _point(
              context,
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
          child: const Text('我知道了'),
        ),
      ],
    );
  }
}
