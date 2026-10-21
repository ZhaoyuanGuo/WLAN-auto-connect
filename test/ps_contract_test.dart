import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows 侧跨语言契约：Dart（AutoLoginService）通过命令行参数驱动
/// assets/AutoLogin.ps1。任一侧新增/改名参数而不同步时，只能在运行时以
/// 退出码或空输出失败。本测试静态解析两侧并断言一致性。
///
/// - 脚本侧权威来源：AutoLogin.ps1 的 param(...) 声明
/// - Dart 侧来源：lib/services/auto_login_service.dart 中的 '-Xxx' 字面量
void main() {
  /// powershell.exe 自身的启动参数，不属于脚本参数，需排除。
  const psExeArgs = {'-NoProfile', '-ExecutionPolicy', '-Bypass', '-File'};

  late String psSource;
  late String dartSource;

  setUpAll(() {
    // flutter test 的工作目录为项目根
    psSource = File('assets/AutoLogin.ps1').readAsStringSync();
    dartSource =
        File('lib/services/auto_login_service.dart').readAsStringSync();
  });

  /// 解析脚本 param(...) 块中声明的全部参数名（不含前导 -）。
  Set<String> parseScriptParams(String source) {
    final start = source.indexOf('param(');
    expect(start, greaterThanOrEqualTo(0), reason: 'AutoLogin.ps1 缺少 param 块');
    // 取 param( 后到第一个独立 ")" 行之前的区间即可覆盖声明
    final end = source.indexOf('\n)', start);
    expect(end, greaterThan(start), reason: 'param 块未正常闭合');
    final block = source.substring(start, end);
    final re = RegExp(r'\[\s*(?:switch|string|int|bool)\s*\]\s*\$(\w+)');
    return re.allMatches(block).map((m) => m.group(1)!).toSet();
  }

  /// 提取 Dart 源码中出现的所有 '-Xxx' 命令行字面量（去重，去掉前导 -）。
  Set<String> parseDartArgs(String source) {
    final re = RegExp(r"'(-[A-Za-z]\w*)'");
    return re
        .allMatches(source)
        .map((m) => m.group(1)!)
        .where((a) => !psExeArgs.contains(a))
        .map((a) => a.substring(1))
        .toSet();
  }

  test('AutoLogin.ps1 声明了核心模式参数', () {
    final params = parseScriptParams(psSource);
    // 这些是 Dart 侧实际驱动脚本用到的模式，缺失即契约破坏
    expect(params, containsAll(<String>[
      'Once',
      'Save',
      'Export',
      'Install',
      'Uninstall',
      'Ssid',
      'FixPopup',
      'UndoPopup',
    ]));
  });

  test('Dart 侧使用的每个脚本参数都在 AutoLogin.ps1 中声明', () {
    final scriptParams = parseScriptParams(psSource);
    final dartArgs = parseDartArgs(dartSource);
    expect(dartArgs, isNotEmpty, reason: '未从 Dart 源码解析到任何脚本参数');
    for (final arg in dartArgs) {
      expect(scriptParams, contains(arg),
          reason: 'Dart 调用了脚本参数 -$arg，但 AutoLogin.ps1 的 param 块未声明');
    }
  });

  test('Dart 侧解析到的参数集合符合预期（防止解析失效而假通过）', () {
    final dartArgs = parseDartArgs(dartSource);
    expect(dartArgs, containsAll(<String>[
      'Save',
      'Export',
      'Install',
      'Uninstall',
      'Once',
      'Ssid',
      'FixPopup',
      'UndoPopup',
    ]));
  });
}
