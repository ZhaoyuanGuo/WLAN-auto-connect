import 'package:flutter/material.dart';

import 'cloud_api.dart';
import 'sync_service.dart';
import 'token_manager.dart';

/// 云端同步入口卡片（Windows / Android 双端复用）。
/// 未登录 → 引导登录；已登录 → 显示账号与上次同步时间，点击进入同步页。
class CloudCard extends StatefulWidget {
  const CloudCard({super.key});

  @override
  State<CloudCard> createState() => _CloudCardState();
}

class _CloudCardState extends State<CloudCard> {
  bool _loggedIn = false;
  String _phone = '';
  DateTime? _lastSync;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final loggedIn = await TokenManager.isLoggedIn();
    final phone = await TokenManager.phoneMasked() ?? '';
    final last = await TokenManager.lastSyncAt();
    if (!mounted) return;
    setState(() {
      _loggedIn = loggedIn;
      _phone = phone;
      _lastSync = last;
      _loading = false;
    });
  }

  String get _syncText {
    final t = _lastSync;
    if (t == null) return '从未同步';
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_loading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    return Card(
      child: ListTile(
        leading: Icon(
          _loggedIn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
          color: _loggedIn ? scheme.primary : scheme.outline,
        ),
        title: Text(
          _loggedIn ? '云端同步已开启' : '云端同步（多设备备份恢复）',
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          _loggedIn ? '友爱账号 $_phone · 上次同步 $_syncText' : '登录友爱账号（Uniai）后可多设备备份恢复',
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CloudPage()),
          );
          _reload();
        },
      ),
    );
  }
}

/// 云端同步页：登录 / 注册 / 备份 / 恢复 / 退出。
class CloudPage extends StatefulWidget {
  const CloudPage({super.key});

  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  final _phoneCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();

  bool _isLogin = true; // true=登录 tab，false=注册 tab
  bool _busy = false;
  bool _loggedIn = false;
  String _phone = '';
  DateTime? _lastSync;
  bool _cloudEmpty = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final loggedIn = await TokenManager.isLoggedIn();
    final phone = await TokenManager.phoneMasked() ?? '';
    final last = await TokenManager.lastSyncAt();
    var empty = false;
    if (loggedIn) {
      try {
        final (blob, _) = await CloudApi.getSync();
        empty = blob == null;
      } catch (_) {
        // 网络异常不阻塞页面展示
      }
    }
    if (!mounted) return;
    setState(() {
      _loggedIn = loggedIn;
      _phone = phone;
      _lastSync = last;
      _cloudEmpty = empty;
    });
  }

  String? _validate() {
    final phone = _phoneCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) return '请输入 11 位手机号';
    if (pwd.length < 8 || pwd.length > 64) return '密码需为 8-64 位';
    return null;
  }

  Future<void> _run(Future<void> Function() task, String successMsg) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(successMsg)));
      await _reload();
    } on AuthExpired catch (e) {
      if (!mounted) return;
      setState(() => _loggedIn = false);
      _toast(e.message);
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('网络异常，请稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirm(String title, String content) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content, style: Theme.of(ctx).textTheme.bodyMedium),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) return _toast(err);
    final phone = _phoneCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    await _run(() async {
      if (_isLogin) {
        await CloudApi.login(phone, pwd);
      } else {
        await CloudApi.register(phone, pwd);
        await CloudApi.login(phone, pwd);
      }
    }, _isLogin ? '登录成功' : '注册并登录成功');
  }

  Future<void> _upload() async {
    final ok = await _confirm(
      '备份到云端',
      '将把本机全部 WiFi 档案（含账号密码）整体覆盖上传到云端备份，继续？',
    );
    if (!ok) return;
    await _run(
      () async {
        await CloudSyncService.upload();
      },
      '已备份到云端',
    );
  }

  Future<void> _download() async {
    final ok = await _confirm(
      '从云端恢复',
      '将用云端备份覆盖本机全部 WiFi 档案（本机多出的档案会被删除），继续？',
    );
    if (!ok) return;
    await _run(
      () async {
        await CloudSyncService.download();
      },
      '已从云端恢复',
    );
  }

  Future<void> _deleteCloud() async {
    final ok = await _confirm(
      '删除云端备份',
      '将删除云端保存的全部配置，本机数据不受影响。继续？',
    );
    if (!ok) return;
    await _run(() async {
      await CloudApi.deleteSync();
      await TokenManager.setLastSyncAt(DateTime.now());
    }, '云端备份已删除');
  }

  Future<void> _logout() async {
    final ok = await _confirm(
      '退出登录',
      '退出后本机数据不变，云端备份保留。继续？',
    );
    if (!ok) return;
    await _run(() => CloudApi.logout(), '已退出登录');
  }

  String get _syncText {
    final t = _lastSync;
    if (t == null) return '从未同步';
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云端同步')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            children: [
              _loggedIn ? _buildSyncPanel() : _buildAuthPanel(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 登录 / 注册 ----------------

  Widget _buildAuthPanel() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.cloud_outlined,
              size: 40, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text('友爱账号（Uniai）· 一次注册，多端登录',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('登录')),
              ButtonSegment(value: false, label: Text('注册')),
            ],
            selected: {_isLogin},
            onSelectionChanged: (s) => setState(() => _isLogin = s.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            maxLength: 11,
            decoration: const InputDecoration(
              labelText: '手机号',
              prefixIcon: Icon(Icons.phone_android_outlined),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwdCtrl,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: '密码（8-64 位）',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_isLogin ? '登录' : '注册并登录'),
          ),
          const SizedBox(height: 12),
          Text(
            '友爱账号密码经服务器加密保存；WiFi 档案上传前由服务器按账号独立加密存储，'
            '仅你本人登录后可读取。可随时在同步页删除云端备份。',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(height: 1.6),
          ),
        ],
      ),
    );
  }

  // ---------------- 已登录 ----------------

  Widget _buildSyncPanel() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: ListTile(
            leading: Icon(Icons.account_circle_outlined,
                color: scheme.primary, size: 34),
            title: Text(_phone, style: theme.textTheme.titleMedium),
            subtitle: Text(
              _cloudEmpty ? '云端暂无备份' : '上次同步：$_syncText',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _upload,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: const Text('备份到云端（覆盖）'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _download,
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('从云端恢复到本机'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text('删除云端备份',
                    style: TextStyle(color: scheme.error)),
                onTap: _busy ? null : _deleteCloud,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('退出登录'),
                onTap: _busy ? null : _logout,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '云端仅保存最近一次整体备份（WiFi 档案含密码，服务端加密存储）；'
          '备份为整体覆盖，不做多版本保留。',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall,
        ),
      ],
    );
  }
}
