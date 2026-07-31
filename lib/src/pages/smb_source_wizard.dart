import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/network_discovery.dart';
import '../services/remote_path_selection.dart';
import '../state/providers.dart';
import '../widgets/remote_folder_selection_header.dart';

/// Remove nested selections when an ancestor folder is already selected. This
/// prevents scanning the same tree twice while retaining independent siblings.
Set<String> compactSelectedSmbPaths(Iterable<String> paths) {
  return compactSelectedRemotePaths(paths);
}

class SmbSourceWizardPage extends ConsumerStatefulWidget {
  const SmbSourceWizardPage({super.key});

  @override
  ConsumerState<SmbSourceWizardPage> createState() =>
      _SmbSourceWizardPageState();
}

class _SmbSourceWizardPageState extends ConsumerState<SmbSourceWizardPage> {
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _manualShare = TextEditingController();

  int _step = 0;
  bool _busy = false;
  bool _discovering = false;
  bool _committed = false;
  String? _error;
  String? _selectedShare;
  String? _setupToken;
  String _currentPath = '';
  List<SmbServerCandidate> _servers = const [];
  List<SmbCredentials> _history = const [];
  List<SmbShareInfo> _shares = const [];
  List<RemoteDirectory> _directories = const [];
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    unawaited(_restoreAndDiscover());
  }

  Future<void> _restoreAndDiscover() async {
    final credentials = await SmbCredentials.load();
    final history = await SmbCredentials.loadHistory();
    if (!mounted) return;
    _host.text = credentials.host;
    _user.text = credentials.user;
    _password.text = credentials.password;
    _manualShare.text = credentials.share;
    setState(() {
      _history = [
        if (credentials.isConfigured &&
            !history.any(
              (entry) =>
                  entry.host == credentials.host &&
                  entry.share == credentials.share &&
                  entry.user == credentials.user,
            ))
          credentials,
        ...history,
      ];
    });
    await _discover();
  }

  @override
  void dispose() {
    final token = _setupToken;
    if (!_committed && token != null) {
      unawaited(rust.smbSetupCancel(token: token));
    }
    _host.dispose();
    _user.dispose();
    _password.dispose();
    _manualShare.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    if (_discovering) return;
    if (mounted) setState(() => _discovering = true);
    try {
      final servers = await discoverSmbServers();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        if (_step == 0) {
          _error = servers.isEmpty ? '未发现局域网中的 SMB 服务，仍可手动填写主机' : null;
        }
      });
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _loadShares() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '请填写或选择 SMB 主机');
      return;
    }
    _setBusy(true);
    try {
      try {
        final result = await rust.smbListShares(
          host: host,
          user: _user.text,
          password: _password.text,
        );
        if (!mounted) return;
        setState(() {
          _shares = result.shares;
          _selectedShare = result.shares.length == 1
              ? result.shares.single.name
              : null;
          _step = 2;
          _error = result.warning != null
              ? '${result.warning}\n可以继续手动填写共享名。'
              : result.shares.isEmpty
              ? '账号验证成功，但没有发现可枚举的磁盘共享，可以手动填写共享名。'
              : null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _shares = const [];
          _selectedShare = null;
          _error = '无法登录或连接 SMB 服务器：$e';
        });
      }
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _openShare() async {
    final share = (_selectedShare ?? _manualShare.text).trim();
    if (share.isEmpty) {
      setState(() => _error = '请选择或填写共享名');
      return;
    }
    _setBusy(true);
    try {
      final previous = _setupToken;
      if (previous != null) await rust.smbSetupCancel(token: previous);
      final token = await rust.smbSetupBegin(
        host: _host.text.trim(),
        share: share,
        user: _user.text,
        password: _password.text,
      );
      final directories = await rust.smbSetupListDirectories(
        token: token,
        subdir: '',
      );
      if (!mounted) {
        await rust.smbSetupCancel(token: token);
        return;
      }
      setState(() {
        _manualShare.text = share;
        _selectedShare = share;
        _setupToken = token;
        _directories = directories;
        _currentPath = '';
        _selectedPaths.clear();
        _step = 3;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '无法打开共享：$e');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _browse(String path) async {
    final token = _setupToken;
    if (token == null) return;
    _setBusy(true);
    try {
      final directories = await rust.smbSetupListDirectories(
        token: token,
        subdir: path,
      );
      if (!mounted) return;
      setState(() {
        _currentPath = path;
        _directories = directories;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '无法读取文件夹：$e');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _finish() async {
    final token = _setupToken;
    final share = _selectedShare;
    final paths = compactSelectedSmbPaths(_selectedPaths);
    if (token == null || share == null || paths.isEmpty) {
      setState(() => _error = '请至少勾选一个需要扫描的文件夹（可选择共享根目录）');
      return;
    }

    _setBusy(true);
    try {
      final folders = await rust.listLibraryFolders();
      final expectedRoot =
          '${_host.text.trim().toLowerCase()}/${share.toLowerCase()}';
      final incompatible = folders.where((folder) {
        if (folder.sourceType != 'smb') return false;
        final rest = folder.path.replaceFirst(RegExp(r'^smb://'), '');
        final parts = rest.split('/');
        if (parts.length < 2) return true;
        return '${parts[0].toLowerCase()}/${parts[1].toLowerCase()}' !=
            expectedRoot;
      }).toList();
      if (incompatible.isNotEmpty) {
        throw StateError('当前版本的一组 SMB 凭证只能对应同一主机与共享；请先删除旧 SMB 文件夹后再切换');
      }

      await rust.smbSetupCommit(token: token);
      final credentials = SmbCredentials(
        host: _host.text.trim(),
        share: share,
        user: _user.text,
        password: _password.text,
      );
      await credentials.save();
      for (final path in paths) {
        final suffix = path.isEmpty ? '' : '/$path';
        await rust.addLibraryFolder(
          path: 'smb://${credentials.host}/${credentials.share}$suffix',
          sourceType: 'smb',
        );
      }
      _committed = true;
      _setupToken = null;
      ref.invalidate(foldersProvider);
      ref.invalidate(smbConfiguredProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '添加 SMB 文件夹失败：$e');
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    if (mounted) setState(() => _busy = value);
  }

  Future<bool> _goBack() async {
    if (_busy) return false;
    if (_step == 0) return true;
    if (_step == 3) {
      final token = _setupToken;
      _setupToken = null;
      if (token != null) await rust.smbSetupCancel(token: token);
    }
    setState(() {
      _step--;
      _error = null;
    });
    return false;
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    canPop: _step == 0 && !_busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_goBack());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(['选择 SMB 服务器', '登录 SMB', '选择共享', '选择文件夹'][_step]),
        leading: IconButton(
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back),
          onPressed: _busy
              ? null
              : () async {
                  if (await _goBack() && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
        ),
      ),
      body: Column(
        children: [
          if (_busy || (_step == 0 && _discovering))
            const LinearProgressIndicator(),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _step == 3
                    ? _directoryStep()
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (_error != null) _errorBanner(context, _error!),
                          if (_step == 0) _serverStep(),
                          if (_step == 1) _credentialsStep(),
                          if (_step == 2) _shareStep(),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _serverStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_history.isNotEmpty) ...[
        DropdownButtonFormField<int>(
          key: ValueKey('smb-history-${_history.length}'),
          initialValue: null,
          decoration: const InputDecoration(
            labelText: '已连接过的 SMB',
            prefixIcon: Icon(Icons.history),
          ),
          hint: const Text('选择地址并回填凭证'),
          isExpanded: true,
          items: [
            for (var i = 0; i < _history.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                  _history[i].historyLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _busy
              ? null
              : (index) {
                  if (index == null) return;
                  final credentials = _history[index];
                  setState(() {
                    _host.text = credentials.host;
                    _user.text = credentials.user;
                    _password.text = credentials.password;
                    _manualShare.text = credentials.share;
                    _selectedShare = null;
                    _error = null;
                  });
                },
        ),
        const SizedBox(height: 12),
      ],
      TextField(
        controller: _host,
        onChanged: (_) => setState(() => _error = null),
        decoration: const InputDecoration(
          labelText: '服务器地址',
          hintText: '192.168.1.100 或 server.local',
          prefixIcon: Icon(Icons.dns_outlined),
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Text('局域网中的服务器', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(
            tooltip: '重新扫描',
            onPressed: _discovering ? null : _discover,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      RadioGroup<String>(
        groupValue: _host.text.trim(),
        onChanged: (value) => setState(() {
          _host.text = value ?? '';
          _error = null;
        }),
        child: Column(
          children: [
            for (final server in _servers)
              RadioListTile<String>(
                value: server.address,
                title: Text(server.name),
                subtitle: Text('${server.address} · ${server.source}'),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _busy
            ? null
            : () => setState(() {
                if (_host.text.trim().isEmpty) {
                  _error = '请填写或选择 SMB 主机';
                } else {
                  _step = 1;
                  _error = null;
                }
              }),
        icon: const Icon(Icons.arrow_forward),
        label: const Text('下一步'),
      ),
    ],
  );

  Widget _credentialsStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.dns_outlined),
        title: Text(_host.text.trim()),
        subtitle: const Text('凭证只保存在当前设备的 Kurako 配置中'),
      ),
      TextField(
        controller: _user,
        decoration: const InputDecoration(
          labelText: '用户名',
          prefixIcon: Icon(Icons.person_outline),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: '密码',
          prefixIcon: Icon(Icons.password_outlined),
        ),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _busy ? null : _loadShares,
        icon: const Icon(Icons.login),
        label: const Text('登录并读取共享'),
      ),
    ],
  );

  Widget _shareStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_shares.isNotEmpty) ...[
        Text('服务器共享', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: _selectedShare,
          onChanged: (value) => setState(() {
            _selectedShare = value;
            _manualShare.text = value ?? '';
          }),
          child: Column(
            children: [
              for (final share in _shares)
                RadioListTile<String>(
                  value: share.name,
                  title: Text(share.name),
                  subtitle: share.comment.isEmpty ? null : Text(share.comment),
                ),
            ],
          ),
        ),
        const Divider(height: 32),
      ],
      TextField(
        controller: _manualShare,
        onChanged: (_) => setState(() => _selectedShare = null),
        decoration: const InputDecoration(
          labelText: '手动填写共享名',
          hintText: 'Anime',
          prefixIcon: Icon(Icons.folder_shared_outlined),
        ),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _busy ? null : _openShare,
        icon: const Icon(Icons.folder_open),
        label: const Text('打开共享'),
      ),
    ],
  );

  Widget _directoryStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: _errorBanner(context, _error!),
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: RemoteFolderSelectionHeader(
          breadcrumbs: _breadcrumbs(),
          selectedCount: compactSelectedSmbPaths(_selectedPaths).length,
          onConfirm: _busy || _selectedPaths.isEmpty ? null : _finish,
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _selectedPaths.contains(_currentPath),
              title: Text(_currentPath.isEmpty ? '选择整个共享' : '选择当前文件夹'),
              subtitle: Text(
                _currentPath.isEmpty
                    ? '/${_selectedShare ?? ''}'
                    : _currentPath,
              ),
              onChanged: (selected) => setState(() {
                selected == true
                    ? _selectedPaths.add(_currentPath)
                    : _selectedPaths.remove(_currentPath);
              }),
            ),
            const Divider(),
            if (_directories.isEmpty)
              const ListTile(
                leading: Icon(Icons.folder_off_outlined),
                title: Text('当前目录没有子文件夹'),
              ),
            for (final directory in _directories)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Checkbox(
                  value: _selectedPaths.contains(directory.path),
                  onChanged: (selected) => setState(() {
                    selected == true
                        ? _selectedPaths.add(directory.path)
                        : _selectedPaths.remove(directory.path);
                  }),
                ),
                title: Text(directory.name),
                subtitle: Text(directory.path),
                trailing: IconButton(
                  tooltip: '进入文件夹',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _busy ? null : () => _browse(directory.path),
                ),
                onTap: _busy ? null : () => _browse(directory.path),
              ),
          ],
        ),
      ),
    ],
  );

  List<Widget> _breadcrumbs() {
    final widgets = <Widget>[
      ActionChip(
        avatar: const Icon(Icons.folder_shared_outlined, size: 16),
        label: Text(_selectedShare ?? '共享'),
        onPressed: _busy ? null : () => _browse(''),
      ),
    ];
    final segments = _currentPath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    for (var i = 0; i < segments.length; i++) {
      final path = segments.take(i + 1).join('/');
      widgets.add(
        ActionChip(
          label: Text(segments[i]),
          onPressed: _busy ? null : () => _browse(path),
        ),
      );
    }
    return widgets;
  }

  Widget _errorBanner(BuildContext context, String message) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}
