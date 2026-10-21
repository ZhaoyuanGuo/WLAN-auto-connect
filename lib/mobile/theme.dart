import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config_store.dart';

/// 移动端设计 Token：色板 / 字阶 / 间距的唯一来源。
///
/// 约定（页面代码必须遵守）：
/// - 禁止再出现 `Color(0xFF…)` 或 `Colors.grey.shadeN` 字面量，
///   一律取 [ColorScheme]（品牌/表面）或 [AppSemantic]（语义色/文字灰阶）；
/// - 字号只有 5 级：20（display）/ 16（title）/ 14（body）/ 12（caption）/ 11（label），
///   通过 Theme.of(context).textTheme 取，不再手写 fontSize；
/// - 间距四档：页边距 16、组间距 24、组内间隙 12、卡片内边距 16（见 [Ui]）。

/// 语义色与文字灰阶（Material ColorScheme 不覆盖"成功/警告/危险"语义）。
class AppSemantic extends ThemeExtension<AppSemantic> {
  const AppSemantic({
    required this.success,
    required this.warning,
    required this.danger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.outline,
  });

  final Color success;
  final Color warning;
  final Color danger;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color outline;

  static const light = AppSemantic(
    success: Color(0xFF22A06B),
    warning: Color(0xFFD97706),
    danger: Color(0xFFDC4C4C),
    textPrimary: Color(0xFF1D2129),
    textSecondary: Color(0xFF646A73),
    textTertiary: Color(0xFF8F959E),
    outline: Color(0xFFDEE0E3),
  );

  static const dark = AppSemantic(
    success: Color(0xFF3DBB82),
    warning: Color(0xFFE09B3D),
    danger: Color(0xFFE57373),
    textPrimary: Color(0xFFE8EAED),
    textSecondary: Color(0xFF9AA0A6),
    textTertiary: Color(0xFF6F757B),
    outline: Color(0xFF2C2F33),
  );

  static AppSemantic of(BuildContext context) =>
      Theme.of(context).extension<AppSemantic>()!;

  Color tone(BadgeTone t) => switch (t) {
        BadgeTone.success => success,
        BadgeTone.warning => warning,
        BadgeTone.danger => danger,
        BadgeTone.neutral => textSecondary,
        BadgeTone.brand => throw StateError('brand tone 需由 ColorScheme.primary 提供'),
      };

  @override
  AppSemantic copyWith({
    Color? success,
    Color? warning,
    Color? danger,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? outline,
  }) {
    return AppSemantic(
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      outline: outline ?? this.outline,
    );
  }

  @override
  AppSemantic lerp(covariant AppSemantic? other, double t) {
    if (other == null) return this;
    return AppSemantic(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
    );
  }
}

/// 徽章色调（[UiBadge] 用）。
enum BadgeTone { neutral, brand, success, warning, danger }

/// 间距栅格。
abstract final class Ui {
  static const pagePad = 16.0; // 页面左右边距
  static const groupGap = 24.0; // 分组之间
  static const itemGap = 12.0; // 组内/卡片之间
  static const cardPad = 16.0; // 卡片内边距
  static const radiusCard = 16.0;
  static const radiusButton = 12.0;
}

/// 语义徽章：10% 语义色底 + 语义色文字的小胶囊。
class UiBadge extends StatelessWidget {
  const UiBadge(this.text, {this.tone = BadgeTone.neutral, super.key});

  final String text;
  final BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final s = AppSemantic.of(context);
    final fg = tone == BadgeTone.brand
        ? Theme.of(context).colorScheme.primary
        : s.tone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w500, color: fg, height: 1.2)),
    );
  }
}

/// 分组标题：11px 灰字，iOS 设置风格。
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = AppSemantic.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 2, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1,
                    color: s.textTertiary)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 分组容器：一张无边框圆角表面卡，内部条目间自动加细分割线。
class GroupCard extends StatelessWidget {
  const GroupCard({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = AppSemantic.of(context);
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        items.add(Divider(
            height: 1, thickness: 0.7, indent: 16, endIndent: 0, color: s.outline));
      }
      items.add(children[i]);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Ui.radiusCard),
      child: ColoredBox(
        color: scheme.surface,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items),
      ),
    );
  }
}

/// 外观模式（跟随系统/浅色/深色）：全局 ValueNotifier，
/// MobileApp 监听重建；[apply] 负责持久化到 [MobileConfig]。
abstract final class AppThemeMode {
  static final value = ValueNotifier<String>('system');

  static ThemeMode get mode => switch (value.value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static Future<void> apply(String v) async {
    value.value = v;
    final cfg = await MobileConfig.load()..themeMode = v;
    await cfg.save();
  }

  static Future<void> load() async {
    final cfg = await MobileConfig.load();
    value.value = cfg.themeMode;
  }
}

/// 构建移动端主题（light/dark 共用一套规则，只差 ColorScheme 与语义色）。
ThemeData buildMobileTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3D5AFE),
    brightness: brightness,
  ).copyWith(
    surface: isDark ? const Color(0xFF1B1D21) : Colors.white,
  );
  final semantic = isDark ? AppSemantic.dark : AppSemantic.light;
  final bg = isDark ? const Color(0xFF111316) : const Color(0xFFF7F8FA);

  const rCard = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(Ui.radiusCard)));
  const rBtn =
      RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)));

  final textTheme = TextTheme(
    // 5 级字阶：display 20 / title 16 / body 14 / caption 12 / label 11
    headlineSmall: TextStyle(
        fontSize: 20, fontWeight: FontWeight.w600, color: semantic.textPrimary),
    titleLarge: const TextStyle(
        fontSize: 17, fontWeight: FontWeight.w600), // 弹窗/页面标题
    titleMedium: TextStyle(
        fontSize: 16, fontWeight: FontWeight.w600, color: semantic.textPrimary),
    titleSmall: TextStyle(
        fontSize: 14, fontWeight: FontWeight.w600, color: semantic.textPrimary),
    bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: semantic.textPrimary),
    bodySmall: TextStyle(fontSize: 12, height: 1.5, color: semantic.textSecondary),
    labelSmall: TextStyle(
        fontSize: 11, fontWeight: FontWeight.w500, color: semantic.textTertiary),
    labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
  );

    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(Ui.radiusButton),
        borderSide: BorderSide(color: c, width: w));

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    extensions: [semantic],
    textTheme: textTheme,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: rCard,
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: rBtn,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: rBtn,
        textStyle: textTheme.labelLarge,
        side: BorderSide(color: semantic.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: rBtn, textStyle: textTheme.labelLarge),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : const Color(0xFFF7F8FA),
      border: border(semantic.outline),
      enabledBorder: border(semantic.outline),
      focusedBorder: border(scheme.primary, 1.6),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    dialogTheme: DialogThemeData(
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20))),
      titleTextStyle: textTheme.titleLarge?.copyWith(color: semantic.textPrimary),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: null,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      systemOverlayStyle:
          isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : semantic.textSecondary,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: semantic.textSecondary),
      selectedLabelTextStyle:
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary),
      unselectedLabelTextStyle: TextStyle(fontSize: 12, color: semantic.textSecondary),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: semantic.textSecondary,
      titleTextStyle: textTheme.titleSmall,
      subtitleTextStyle: textTheme.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    dividerTheme: DividerThemeData(color: semantic.outline, thickness: 0.7),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: rBtn,
      contentTextStyle: textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : semantic.textTertiary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary.withValues(alpha: 0.35)
            : semantic.outline,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
  );
}

/// 浅色 + 深色两套（由 MaterialApp.themeMode 决定生效哪套）。
class MobileThemes {
  static final light = buildMobileTheme(Brightness.light);
  static final dark = buildMobileTheme(Brightness.dark);
}
