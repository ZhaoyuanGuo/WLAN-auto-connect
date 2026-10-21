import 'package:flutter/material.dart';

/// 用户协议中的一个条款（标题 + 正文）。
class AgreementSection {
  const AgreementSection(this.title, this.body);
  final String title;
  final String body;
}

/// 用户协议页通用骨架：滚动到底部后才允许点击「同意并继续」。
///
/// Windows 与 Android 双端复用，差异仅在于：
/// - 条款文本（由各自传入 [sections]）
/// - 底部按钮行为（[onAgree] / [onDecline]）
/// - 边距与 SafeArea（平板/手机需避让系统栏）
///
/// 提取自原先各自维护的 AgreementPage / MobileAgreementPage，
/// 消除约 200 行重复的滚动门控与布局逻辑。
class AgreementScaffold extends StatefulWidget {
  const AgreementScaffold({
    super.key,
    required this.sections,
    required this.onAgree,
    required this.onDecline,
    this.title = '用户协议与隐私声明',
    this.padding = const EdgeInsets.fromLTRB(28, 24, 28, 16),
    this.cardPadding = const EdgeInsets.all(20),
    this.useSafeArea = false,
  });

  final List<AgreementSection> sections;
  final VoidCallback onAgree;
  final VoidCallback onDecline;
  final String title;
  final EdgeInsets padding;
  final EdgeInsets cardPadding;

  /// 是否用 SafeArea 包裹（移动端避让状态栏/导航条）。
  final bool useSafeArea;

  @override
  State<AgreementScaffold> createState() => _AgreementScaffoldState();
}

class _AgreementScaffoldState extends State<AgreementScaffold> {
  final _scroll = ScrollController();
  bool _readComplete = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkRead);
    // 延迟两帧再判定，等布局稳定（避免首帧 maxScrollExtent 尚为 0 时
    // 把长内容误判为已读完）；内容确实不足一屏时仍会视为已读完。
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

  Widget _section(AgreementSection s) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.title,
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            s.body,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi, color: scheme.primary, size: 26),
              const SizedBox(width: 10),
              Text(widget.title,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Card(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: widget.cardPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: widget.sections.map(_section).toList(),
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
                color: _readComplete ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 5),
              Text(
                _readComplete ? '已阅读完毕' : '请将协议滑动至底部后再同意',
                style: TextStyle(
                  fontSize: 12,
                  color: _readComplete ? scheme.primary : scheme.outline,
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
    );
    return Scaffold(
      body: widget.useSafeArea ? SafeArea(child: body) : body,
    );
  }
}
