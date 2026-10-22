import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.1 相对亮度与对比度，与 tool/contrast.ps1 同一算法。
double _linear(num v) =>
    v / 255 <= 0.03928 ? v / 255 / 12.92 : pow((v / 255 + 0.055) / 1.055, 2.4).toDouble();

double _lum(String hex) {
  final r = int.parse(hex.substring(1, 3), radix: 16);
  final g = int.parse(hex.substring(3, 5), radix: 16);
  final b = int.parse(hex.substring(5, 7), radix: 16);
  return 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b);
}

double contrast(String fg, String bg) {
  final a = _lum(fg), b = _lum(bg);
  return (max(a, b) + 0.05) / (min(a, b) + 0.05);
}

/// 已知的「文字/背景对比低于 AA 正文 4.5」组合，按「文字色 on 背景色」登记。
/// 这是一份只应该越改越短的清单：每修一处就从这里删一条。
const weakPairsBaseline = <String>[
  // 主色按钮白字：#FFF 压在 #3B82F6 上只有 3.68。改成 --primary-dark 底可达标，
  // 但会改变 CTA 主视觉，需先看效果（DESIGN.md 债务 V-10）。
  '#FFFFFF on #3B82F6',
  // 图标不是文字，适用 3:1 而非 4.5：#3B82F6 在 #EFF6FF 底上为 3.38，达标。
  '#3B82F6 on #EFF6FF',
];

/// 官网（website/）的静态约定契约。
///
/// 官网是纯静态手写 HTML/CSS，任何回归都只能在真机浏览器里靠肉眼发现；而最容易坏
/// 的偏偏是那些"看不见"的东西：截图被改名导致线上 404、发新版忘了同步直链版本号、
/// 改版时把备案号 / Shizuku 固定版本这类实测结论顺手弄丢、有人"方便起见"加了个统计。
/// 这些都能静态检查，所以写成断言，不靠 review 时的感觉。
///
/// 断言分两类（分工见 website/DESIGN.md §8）：
/// - **绝对断言**：任何时候破了都是回归。
/// - **棘轮断言**：基线冻结的是*现状*而非推荐值，只许减不许增；减完请同步下调基线，
///   并更新 website/DESIGN.md §7 的债务表。
///
/// 这些检查覆盖的是文件层面的证据，不等于渲染出来的真实体验。上线前仍须按
/// website/DESIGN.md §8 的人工验收清单在手机与真浏览器上过一遍。
void main() {
  const siteRoot = 'website';
  const pages = ['index.html', 'help.html', 'share.html', 'share-code.html'];

  /// 逐文件 scp 上传到站点根的产物集合。新增文件必须显式归类，否则等于把
  /// "哪些文件会上线"这件事又变回只有作者知道。
  const deployEntries = {
    'favicon.svg',
    'help-assets',
    'help.html',
    'help.md',
    'index.html',
    'share-code.html',
    'share.html',
    'style.css',
  };

  /// 仓库内专用文档：给改官网的人（和 AI）看，**不上传服务器**。
  const repoOnlyEntries = {'DESIGN.md', 'PRODUCT.md'};

  /// 允许出现在官网里的外部主机。新增一条即意味着"引入了第三方"，
  /// 必须先核对 PRODUCT.md 的隐私红线（无统计无埋点 / 敏感页零第三方）再登记。
  const allowedHosts = {
    'beian.miit.gov.cn',
    'beian.mps.gov.cn',
    'dl.suspect.top',
    'github.com',
    'trtc.io', // Knocket 在线客服 SDK，仅首页
    'www.icloud.com',
    'wlan.suspect.top',
  };

  /// 只在服务器根存在、仓库里没有的文件（整目录同步会删掉它，故单列白名单）。
  const serverOnlyRefs = {'/ga_beian.png'};

  // ---- 棘轮基线（现状，不是推荐值；债务修完就往下调）----
  const inlineStyleBaseline = {
    'help.html': 5,
    'index.html': 22,
    'share-code.html': 5,
    'share.html': 2,
  };
  const fontSizesBaseline = {
    '11', '12', '13', '14', '14.5', '15', '16', '17', '17.5', '18',
    '21', '22', '25', '26', '27', '28', '30', '36', '40', '42',
  }; // DESIGN.md §3 的推荐集比这里窄
  const radiusPxBaseline = {'3', '4', '5', '10', '12', '15', '16', '18', '20', '999'};

  late final Map<String, String> src; // 页面名 -> 源码
  late final String css;
  late final String all; // css + 全部页面，供全局扫描
  late final Map<String, String> colorTokens; // :root 里的颜色 token

  setUpAll(() {
    // flutter test 的工作目录为项目根
    css = File('$siteRoot/style.css').readAsStringSync();
    src = {for (final p in pages) p: File('$siteRoot/$p').readAsStringSync()};
    all = [css, ...src.values].join('\n');
    final rootBlock = RegExp(r':root\s*\{([^}]*)\}').firstMatch(css)!.group(1)!;
    colorTokens = {
      for (final m in RegExp(r'(--[a-z0-9-]+)\s*:\s*(#[0-9A-Fa-f]{3,8})\s*;')
          .allMatches(rootBlock))
        m.group(1)!: m.group(2)!,
    };
  });

  String baseName(String path) => path.replaceAll(r'\', '/').split('/').last;

  /// 收集全部 src/href 属性值，附带所在页面。
  List<(String, String)> collectRefs() {
    final re = RegExp(r'(?:src|href)\s*=\s*"([^"]+)"');
    return [
      for (final e in src.entries)
        for (final m in re.allMatches(e.value)) (e.key, m.group(1)!),
    ];
  }

  /// 解析为「相对 siteRoot 的本地路径」；外链 / 锚点 / 根绝对路径返回 null。
  String? asLocalPath(String raw) {
    if (raw.startsWith('#') || raw.startsWith('/')) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://') || raw.startsWith('//')) return null;
    if (raw.startsWith('mailto:') || raw.startsWith('javascript:')) return null;
    return raw.split('#').first.split('?').first;
  }

  /// 把 var(--x) 解成 token 里的色值；不能归约为单一十六进制的（渐变、rgba、
  /// currentColor、inherit）一律返回 null 跳过。
  String? resolveColor(String value) {
    var v = value.trim();
    final m = RegExp(r'^var\(\s*(--[a-z0-9-]+)\s*(?:,[^)]*)?\)$').firstMatch(v);
    if (m != null) v = colorTokens[m.group(1)] ?? '';
    if (RegExp(r'^#[0-9A-Fa-f]{3}$').hasMatch(v)) {
      v = '#${v[1]}${v[1]}${v[2]}${v[2]}${v[3]}${v[3]}';
    }
    return RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(v) ? v.toUpperCase() : null;
  }

  /// 扫描 style.css 与各页 <style> 里的规则块，产出 (规则块, 文字色, 背色) 三元组。
  /// 只解 :root token；局部变量（如 help.html 的 --accent）与渐变归人工核对。
  List<(String, String, String)> textOnColorPairs() {
    final out = <(String, String, String)>[];
    for (final e in <(String, String)>[
      ('style.css', css),
      for (final p in src.entries) (p.key, p.value),
    ]) {
      final style = RegExp(r'<style>([\s\S]*?)</style>').allMatches(e.$2);
      final bodies = style.isEmpty ? [e.$2] : style.map((m) => m.group(1)!).toList();
      for (final body in bodies) {
        for (final rule in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(body)) {
          final selector = rule.group(1)!.trim().split('\n').last.trim();
          final decls = rule.group(2)!;
          final fg = RegExp(r'(?<![\w-])color:\s*([^;]+);').firstMatch(decls);
          final bg = RegExp(r'background(?:-color)?:\s*([^;]+);').firstMatch(decls);
          if (fg == null || bg == null) continue;
          final f = resolveColor(fg.group(1)!), b = resolveColor(bg.group(1)!);
          if (f == null || b == null) continue;
          out.add(('${e.$1} › $selector', f, b));
        }
      }
    }
    return out;
  }

  group('结构：哪些文件会上线', () {
    test('website/ 根目录条目必须已归类为部署集合或仓库内文档', () {
      final entries = Directory(siteRoot)
          .listSync()
          .map((e) => baseName(e.path))
          .toSet();
      final unknown = entries.difference(deployEntries.union(repoOnlyEntries));
      expect(unknown, isEmpty,
          reason: '新增文件未归类：$unknown。请加入 deployEntries（会上传）或 '
              'repoOnlyEntries（仅仓库），别让部署清单只存在于脑子里');
      expect(entries, containsAll(<String>['index.html', 'style.css', 'help-assets']));
    });

    test('index.html 与 share.html 同层且都存在（部署硬约束）', () {
      expect(File('$siteRoot/index.html').existsSync(), isTrue);
      expect(File('$siteRoot/share.html').existsSync(), isTrue);
    });

    test('产品事实与设计系统两份文档存在且分工不混', () {
      final product = File('$siteRoot/PRODUCT.md').readAsStringSync();
      final design = File('$siteRoot/DESIGN.md').readAsStringSync();
      expect(product.length, greaterThan(2000), reason: 'PRODUCT.md 被清空或截断');
      expect(design.length, greaterThan(2000), reason: 'DESIGN.md 被清空或截断');
      // 分工：视觉写法不进 PRODUCT.md，分发事实不进 DESIGN.md
      expect(product, isNot(contains('font-family')));
      expect(product, isNot(matches(RegExp(r'#[0-9A-Fa-f]{6}'))));
      expect(design, isNot(contains('.apk')));
      expect(design, isNot(contains('-setup.exe')));
    });

    test('无构建步骤：官网内不存在 package.json / node_modules', () {
      expect(File('$siteRoot/package.json').existsSync(), isFalse);
      expect(Directory('$siteRoot/node_modules').existsSync(), isFalse);
    });
  });

  group('引用完整性：改版最容易踩的 404', () {
    test('所有本地引用都真实存在', () {
      final missing = <String>[];
      for (final (_, raw) in collectRefs()) {
        final local = asLocalPath(raw);
        if (local == null) continue;
        if (FileSystemEntity.typeSync('$siteRoot/$local') ==
            FileSystemEntityType.notFound) {
          missing.add(raw);
        }
      }
      expect(missing, isEmpty, reason: '以下本地引用指向的文件不存在');
    });

    test('根绝对路径只允许服务器侧那两个仓库外资产', () {
      final rootAbs = collectRefs().map((r) => r.$2).where((v) => v.startsWith('/')).toSet();
      expect(rootAbs, isNotEmpty, reason: '应至少命中 /ga_beian.png，解析可能失效');
      expect(rootAbs.difference(serverOnlyRefs), isEmpty,
          reason: '除 /ga_beian.png 与 /dl/ 外，站点根不该有仓库外的依赖');
    });

    test('页内锚点指向的 id 存在', () {
      var checked = 0;
      for (final e in src.entries) {
        for (final m in RegExp(r'href="#([^"]+)"').allMatches(e.value)) {
          checked++;
          expect(e.value, contains('id="${m.group(1)}"'),
              reason: '${e.key} 里的锚点 #${m.group(1)} 没有对应元素');
        }
      }
      expect(checked, greaterThanOrEqualTo(1), reason: '锚点解析异常，上面的检查会假通过');
    });

    test('help-assets 截图与页面引用一一对应（无孤儿、无空引用）', () {
      final files = Directory('$siteRoot/help-assets')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) {
            final p = f.path.replaceAll(r'\', '/');
            return p.substring(p.indexOf('help-assets/'));
          })
          .toSet();
      final refs = collectRefs()
          .map((r) => r.$2)
          .where((v) => v.startsWith('help-assets/'))
          .toSet();
      expect(files.length, greaterThanOrEqualTo(20), reason: '截图目录解析异常');
      expect(files.difference(refs), isEmpty,
          reason: '这些截图没人引用，白占分发体积：删掉或放进页面');
      expect(refs.difference(files), isEmpty, reason: '页面引用了不存在的截图（线上 404）');
    });

    test('外部主机全部已登记（新增第三方＝重新核对隐私红线）', () {
      final hosts = <String>{};
      for (final (_, raw) in collectRefs()) {
        final uri = Uri.tryParse(raw);
        if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
        hosts.add(uri.host);
      }
      expect(hosts, isNotEmpty, reason: '外链解析异常，下面的对比会假通过');
      expect(hosts.difference(allowedHosts), isEmpty);
    });
  });

  group('分发一致性：版本号与直链', () {
    late final Map<String, String> declared; // 平台 -> 卡片声明的版本
    late final Set<String> exeVersions;
    late final Set<String> apkVersions;

    setUpAll(() {
      final index = src['index.html']!;
      declared = {
        for (final m in RegExp(
          r'<h3>(Windows|Android)</h3>\s*<span class="platform-version">v(\d+\.\d+\.\d+)</span>',
        ).allMatches(index))
          m.group(1)!: m.group(2)!,
      };
      exeVersions = RegExp(r'wlan-auto-connect-v(\d+\.\d+\.\d+)-setup\.exe')
          .allMatches(index)
          .map((m) => m.group(1)!)
          .toSet();
      apkVersions = RegExp(r'wlan-auto-connect-v(\d+\.\d+\.\d+)(?:-(arm64-v8a|armeabi-v7a))?\.apk')
          .allMatches(index)
          .map((m) => m.group(1)!)
          .toSet();
    });

    test('卡片标头版本与下载直链文件名版本一致', () {
      expect(declared.length, 2,
          reason: '未解析到 Windows / Android 版本卡片：DOM 被改版了，请同步本测试');
      expect(exeVersions, {declared['Windows']!}, reason: 'Windows 直链与卡片声明不一致');
      expect(apkVersions, {declared['Android']!},
          reason: 'Android 三个包 / UA 脚本硬链与卡片声明不一致');
    });

    test('Android 站点版本与 pubspec 同源（发版流程不漏官网）', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final v = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true)
          .firstMatch(pubspec)!
          .group(1)!;
      expect(apkVersions, {v}, reason: '官网 Android 版本 $apkVersions 与 pubspec $v 不一致');
    });

    test('Android 三架构入口齐备（分 ABI 分发策略）', () {
      final index = src['index.html']!;
      expect(index, contains('-arm64-v8a.apk'));
      expect(index, contains('-armeabi-v7a.apk'));
      expect(index, matches(RegExp(r'wlan-auto-connect-v\d+\.\d+\.\d+\.apk')),
          reason: '全架构通用包入口丢失');
      expect(index, contains('不确定就选「64 位」'), reason: 'D2 决策：让用户选，而不是猜');
    });

    test('Shizuku 固定推荐版本 + 校验值 + 不可升级原因都在', () {
      final index = src['index.html']!;
      expect(index, contains('shizuku-v13.5.4.apk'));
      expect(index, contains('13.6.0'), reason: '这条实测结论是"为什么钉在 13.5.4"的依据');
      expect(index, contains('联发科'));
      expect(RegExp(r'SHA-256[\s\S]{0,200}?<code[^>]*>\s*([0-9A-F]{64})\s*</code>')
          .hasMatch(index), isTrue, reason: '缺少 64 位大写十六进制 SHA-256 校验值');
      expect(index, contains('dl.suspect.top'), reason: 'GitHub 过慢时的兜底直链');
    });
  });

  group('合规与隐私红线', () {
    test('备案号与公安备案在主要页面上，且可被核对', () {
      for (final p in ['index.html', 'help.html']) {
        expect(src[p], contains('辽ICP备2026022980号'), reason: '$p 缺 ICP 备案号');
        expect(src[p], contains('辽公网安备21020302000662号'), reason: '$p 缺公安备案号');
        expect(src[p], contains('code=21020302000662'));
      }
    });

    test('四页都有使用免责句', () {
      for (final p in pages) {
        expect(src[p], contains('请遵守所在学校/单位的网络管理规定'), reason: '$p 缺免责句');
      }
    });

    test('全站零统计埋点脚本', () {
      final spy = RegExp(
        r'gtag|googletagmanager|google-analytics|_hmt|hm\.baidu|cnzz|umeng|'
        r'plausible|matomo|sensorsdata|clarity\.ms|segment\.',
        caseSensitive: false,
      );
      for (final e in src.entries) {
        expect(spy.hasMatch(e.value), isFalse, reason: '${e.key} 引入了统计/埋点脚本');
      }
    });

    test('第三方脚本只有首页的在线客服组件', () {
      final withScript = <String>{};
      for (final e in src.entries) {
        for (final m in RegExp(r'<script[^>]+src="(https?://[^"]+)"').allMatches(e.value)) {
          expect(m.group(1), startsWith('https://trtc.io/knocket-sdk/'),
              reason: '${e.key} 引入了白名单外的外部脚本');
          withScript.add(e.key);
        }
      }
      expect(withScript, {'index.html'});
    });

    test('涉及账号密码的页面：noindex、零外部脚本、写明凭证不出本机', () {
      for (final p in ['share.html', 'share-code.html']) {
        final body = src[p]!;
        expect(body, matches(RegExp(r'<meta\s+name="robots"\s+content="noindex"')),
            reason: '$p 内容可推导出凭证，必须 noindex');
        expect(RegExp(r'<script[^>]+src="https?://').hasMatch(body), isFalse,
            reason: '$p 不得接入任何第三方脚本');
        expect(body, matches(RegExp('不上传|不经过任何服务器')),
            reason: '$p 必须把"凭证不出本机"讲清楚');
      }
    });
  });

  group('做过的决定不被顺手弄丢（对应 PRODUCT.md / DESIGN.md 的决策记录）', () {
    test('D1 · UA 智能主按钮：三平台判定齐备且有不识别时的回落', () {
      final index = src['index.html']!;
      expect(index, contains('id="heroDl"'));
      expect(index, contains('/Android/i'));
      expect(index, contains('/iPhone|iPod/i'));
      expect(index, contains('/Windows/i'));
      expect(index, contains('href="#download-section"'), reason: '识别不了时回落到三平台下载区');
      expect(index, contains('iosBtn.style.display'), reason: '主按钮已改写为对应平台，重复入口要收起');
    });

    test('D-F3/F4 · 教程页三平台主题色、sticky 标签页与横屏矮视口适配', () {
      final help = src['help.html']!;
      for (final p in ['windows', 'android', 'ios']) {
        expect(help, matches(RegExp('#$p\\s*\\{\\s*--accent:')), reason: '$p 缺 --accent 主题约定');
      }
      expect(help, contains('position: sticky'));
      expect(help, contains('(orientation: landscape)'), reason: '横放的手机是主场景之一');
      expect(help, contains('max-height: 560px'));
    });

    test('D4 · 截图三档宽度类（桌面 / 平板 / 手机）定义在', () {
      final help = src['help.html']!;
      for (final c in ['img.win', 'img.pad', 'img.phone']) {
        expect(help, contains(c), reason: '截图宽度类 $c 被删，长图会撑破版面');
      }
    });
  });

  group('颜色对比（同一规则块内同时写了文字色与背色）', () {
    test('对比度函数与 tool/contrast.ps1 一致（抽查已知值）', () {
      expect(contrast('#FFFFFF', '#3B82F6'), closeTo(3.68, 0.01));
      expect(contrast('#6B7280', '#FFFFFF'), closeTo(4.83, 0.01));
      expect(contrast('#9CA3AF', '#FFFFFF'), closeTo(2.54, 0.01));
      expect(contrast('#FFFFFF', '#EFF6FF'), closeTo(1.09, 0.01));
    });

    test('不存在文字与背景几乎同色的规则块', () {
      final pairs = textOnColorPairs();
      expect(pairs.length, greaterThanOrEqualTo(10), reason: '规则块解析异常，下面的对比会假通过');
      final report = <String>[];
      final invisible = <String>[];
      final subAA = <String>[];
      for (final p in pairs) {
        final c = contrast(p.$2, p.$3);
        final line = '${p.$1}  ${p.$2} on ${p.$3} = ${c.toStringAsFixed(2)}';
        report.add(line);
        if (c < 2.5) invisible.add(line);
        if (c < 4.5) subAA.add(line);
      }
      stderr.writeln('文字/背景对比度全量清单：\n${report.toSet().join('\n')}');
      expect(invisible, isEmpty, reason: '这些块的文字在背景上读不出来');
      // 低于 AA 正文线的组合全部显式登记在 weakPairsBaseline 里，新增即失败
      for (final line in subAA.toSet()) {
        expect(weakPairsBaseline.any((w) => line.contains(w)), isTrue,
            reason: '新增一个低于 AA 正文对比的文字/背景组合：$line\n'
                '请改成达标的色值；若背景不能变，就把这条加进 weakPairsBaseline 并说明代价');
      }
    });
  });

  group('可读性与热区下限', () {
    test('颜色 token 要么对白底达 AA 正文，要么被显式豁免（V-1 永久化）', () {
      // 豁免项只能是“不做正文色”的底色/图形色；新增文字色请走已达标的 token
      const graphicOnly = {
        '--primary', // 3.68：仅按钮底色、描边、图标与大字号
        '--primary-light',
        '--primary-lighter',
        '--bg',
        '--surface',
        '--surface-muted',
        '--border',
      };
      final weak = <String>[];
      for (final e in colorTokens.entries) {
        if (graphicOnly.contains(e.key)) continue;
        final c = contrast(e.value.toUpperCase(), '#FFFFFF');
        if (c < 4.5) weak.add('${e.key} ${e.value} = ${c.toStringAsFixed(2)}');
      }
      expect(weak, isEmpty,
          reason: '这些 token 做正文色时读不出来；若确实只用于图形，请加进 graphicOnly');
      expect(graphicOnly.every(colorTokens.containsKey), isTrue,
          reason: '豁免名单里有已经不存在的 token，请清理');
    });

    test('已撑够 44px 热区的选择器不得退化（V-3）', () {
      String esc(String s) => s.replaceAllMapped(
          RegExp(r'[.*+?()\[\]{}|^$\\]'), (m) => '\\${m[0]}');
      final targets = <(String, String)>[
        ('style.css', '.btn-nav-github'),
        ('index.html', '.btn-nav-help'),
        ('index.html', '.help-banner .hb-btn'),
        ('index.html', '.dlg-close'),
        ('help.html', '.ttab'),
        ('help.html', '.back-home'),
        ('share.html', '.back-link'),
        ('share-code.html', '.pwd-toggle button'),
        ('share-code.html', '.back-link'),
      ];
      for (final t in targets) {
        final body = t.$1 == 'style.css' ? css : src[t.$1]!;
        final rule = RegExp('${esc(t.$2)}\\s*\\{([^}]*)\\}').firstMatch(body);
        expect(rule, isNotNull, reason: '${t.$1} 里找不到了 ${t.$2}，热区约定需同步');
        expect(rule!.group(1), contains('min-height: 44px'),
            reason: '${t.$1} › ${t.$2} 的可点高度不再保证 44px');
      }
    });

    test('prefers-reduced-motion 退化规则在（V-7）', () {
      expect(css, contains('@media (prefers-reduced-motion: reduce)'));
      // 该规则用通配选择器，覆盖各页 <style> 里的动画
      expect(css, contains('animation-duration'));
    });
  });

  group('解析器自检（防止正则失效让上面的检查假通过）', () {
    test('各解析正则对样例输入给出正确结果', () {
      expect(RegExp(r'style="').allMatches('a style="x" b style="y"').length, 2);
      expect(
        RegExp(r'font-size:\s*([\d.]+)px', caseSensitive: false)
            .allMatches('font-size:13px; FONT-SIZE: 14.5px; line-height:1.8')
            .map((m) => m.group(1)!)
            .toSet(),
        {'13', '14.5'},
      );
      expect(
        RegExp(r'border-radius:\s*([\d.]+)px', caseSensitive: false)
            .allMatches('border-radius: 8px; --radius-lg: 12px; BORDER-RADIUS:999px')
            .map((m) => m.group(1)!)
            .toSet(),
        {'8', '999'},
      );
      expect(RegExp(r'(--[a-z0-9-]+)\s*:')
          .allMatches('--bg: #F7F7F8; --text-muted: #9CA3AF;')
          .map((m) => m.group(1)!)
          .toSet(),
        {'--bg', '--text-muted'});
      // var() 的两种写法都要命中：无回退与带回退
      expect(RegExp(r'var\(\s*--bg[,)]').hasMatch('background: var(--bg);'), isTrue);
      expect(RegExp(r'var\(\s*--bg[,)]').hasMatch('color: var(--bg,#fff);'), isTrue);
      expect(RegExp(r'var\(\s*--bg[,)]').hasMatch('color: var(--bg-x);'), isFalse);
      // 本地/外链分类
      expect(asLocalPath('help-assets/ios/ios-01-site.png'), 'help-assets/ios/ios-01-site.png');
      expect(asLocalPath('share.html#top'), 'share.html');
      expect(asLocalPath('/ga_beian.png'), isNull);
      expect(asLocalPath('https://github.com/x'), isNull);
      expect(asLocalPath('#download-section'), isNull);
    });

    test('对真实页面确实解析到了内容（不是空匹配）', () {
      final refs = collectRefs();
      expect(refs.length, greaterThanOrEqualTo(40), reason: 'src/href 解析异常');
      final inline = src.values
          .map((s) => RegExp(r'style="').allMatches(s).length)
          .fold(0, (a, b) => a + b);
      expect(inline, greaterThanOrEqualTo(20), reason: '内联样式解析异常');
      expect(RegExp(r'font-size:\s*([\d.]+)px', caseSensitive: false)
              .allMatches(all)
              .length, greaterThanOrEqualTo(60));
    });
  });

  group('棘轮：只减不增', () {
    test('内联 style 数量不超过基线（V-8）', () {
      for (final e in src.entries) {
        final n = RegExp(r'style="').allMatches(e.value).length;
        expect(n, lessThanOrEqualTo(inlineStyleBaseline[e.key]!),
            reason: '${e.key} 内联样式上限 ${inlineStyleBaseline[e.key]}，实测 $n；'
                '新增请改用 class + token');
      }
    });

    test('不新增字号取值（V-5）', () {
      final found = RegExp(r'font-size:\s*([\d.]+)px', caseSensitive: false)
          .allMatches(all)
          .map((m) => m.group(1)!)
          .toSet();
      expect(found.length, greaterThanOrEqualTo(15), reason: '字号解析异常，下面的对比会假通过');
      expect(found.difference(fontSizesBaseline), isEmpty,
          reason: '出现了新字号值，请从 DESIGN.md §3 的角色表里选');
    });

    test('不新增裸圆角取值（V-5，应使用 --radius* token）', () {
      final found = RegExp(r'border-radius:\s*([\d.]+)px', caseSensitive: false)
          .allMatches(all)
          .map((m) => m.group(1)!)
          .toSet();
      expect(found.length, greaterThanOrEqualTo(6), reason: '圆角解析异常，下面的对比会假通过');
      expect(found.difference(radiusPxBaseline), isEmpty,
          reason: '新增了裸圆角值，请用 var(--radius / --radius-lg / --radius-xl / --radius-full)');
    });

    test(':root 里定义的 token 必须真的被引用（不留死变量）', () {
      final rootBlock = RegExp(r':root\s*\{([^}]*)\}').firstMatch(css)!.group(1)!;
      final defs = RegExp(r'(--[a-z0-9-]+)\s*:').allMatches(rootBlock).map((m) => m.group(1)!).toSet();
      expect(defs.length, greaterThanOrEqualTo(15), reason: 'token 解析异常，下面的对比会假通过');
      final dead = defs.where((t) => !RegExp('var\\(\\s*$t[,)]').hasMatch(all)).toSet();
      expect(dead, isEmpty, reason: '定义了却没人用的 token 会误导后来人：删掉或把它用起来');
    });
  });
}
