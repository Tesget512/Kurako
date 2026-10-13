import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api.dart' as rust;
import '../rust/models.dart';
import '../services/remote_path_selection.dart';
import '../state/providers.dart';
import '../services/scan_coordinator.dart';
import '../widgets/remote_folder_selection_header.dart';

class WebDavSourceWizardPage extends ConsumerStatefulWidget {
  const WebDavSourceWizardPage({super.key});

  @override
  ConsumerState<WebDavSourceWizardPage> createState() =>
      _WebDavSourceWizardPageState();
}

class _WebDavSourceWizardPageState
    extends ConsumerState<WebDavSourceWizardPage> {
  final _address = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  int _step = 0;
  String _authMode = 'basic';
  bool _allowInsecureTls = false;
  String _currentPath = '';
  String? _setupToken;
  bool _busy = false;
  bool _committed = false;
  String? _error;
  List<RemoteEntry> _entries = const [];
  List<WebDavCredentials> _history = const [];
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final credentials = await WebDavCredentials.load();
    final history = await WebDavCredentials.loadHistory();
    if (!mounted) return;
    _address.text = credentials.baseUrl;
    _user.text = credentials.user;
    _password.text = credentials.password;
    setState(() {
      _history = [
        if (credentials.isConfigured &&
            !history.any(
              (entry) =>
                  entry.baseUrl == credentials.baseUrl &&
                  entry.user == credentials.user &&
                  entry.authMode == credentials.authMode,
            ))
          credentials,
        ...history,
      ];
      _authMode = credentials.authMode;
      _allowInsecureTls = credentials.allowInsecureTls;
    });
  }

  @override
  void dispose() {
    final token = _setupToken;
    if (!_committed && token != null) {
      unawaited(rust.webdavSetupCancel(token: token));
    }
    _address.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final baseUrl = normalizeWebDavAddress(_address.text);
    if (baseUrl == null) {
      setState(
        () => _error = '请输入有效的 http:// 或 https:// WebDAV 地址，且不要在地址中包含账号',
      );
      return;
    }
    if (_authMode == 'basic' && baseUrl.startsWith('http://')) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('凭证将以明文传输'),
          content: const Text(
            '当前地址使用 HTTP + Basic，用户名和密码可能被同一网络中的其他设备截获。'
            '建议改用 HTTPS。确定仍要连接吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('返回修改'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('仍要连接'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }

    _setBusy(true);
    try {
      final existingFolders = (await rust.listLibraryFolders())
          .where((folder) => folder.sourceType == 'webdav')
          .toList();
      if (existingFolders.any(
        (folder) => !webDavSourceBelongsToBase(folder.path, baseUrl),
      )) {
        throw StateError('当前版本只支持一组 WebDAV 根地址；请先删除旧 WebDAV 文件夹后再切换服务器');
      }
      final previous = _setupToken;
      if (previous != null) {
        await rust.webdavSetupCancel(token: previous);
      }
      final token = await rust.webdavSetupBegin(
        baseUrl: baseUrl,
        user: _authMode == 'anonymous' ? '' : _user.text,
        password: _authMode == 'anonymous' ? '' : _password.text,
        authMode: _authMode,
        allowInsecureTls: baseUrl.startsWith('https://') && _allowInsecureTls,
      );
      final entries = await rust.webdavSetupListEntries(
        token: token,
        subdir: '',
      );
      if (!mounted) {
        await rust.webdavSetupCancel(token: token);
        return;
      }
      setState(() {
        _address.text = baseUrl;
        _setupToken = token;
        _entries = entries;
        _currentPath = '';
        _selectedPaths.clear();
        _step = 1;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'WebDAV 连接失败：$error');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _browse(String path) async {
    final token = _setupToken;
    if (token == null) return;
    _setBusy(true);
    try {
      final entries = await rust.webdavSetupListEntries(
        token: token,
        subdir: path,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _currentPath = path;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取 WebDAV 文件夹：$error');
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _finish() async {
    final token = _setupToken;
    final selected = compactSelectedRemotePaths(_selectedPaths);
    if (token == null || selected.isEmpty) {
      setState(() => _error = '请至少选择一个需要扫描的文件夹（也可选择 WebDAV 根目录）');
      return;
    }
    final mutationLock = ref.read(libraryMutationBusyProvider.notifier);
    if (ref.read(scanCoordinatorProvider).running || mutationLock.state) {
      setState(() => _error = '扫描或维护正在进行，请完成后再添加来源');
      return;
    }
    mutationLock.state = true;
    _setBusy(true);
    WebDavCredentials? oldCredentials;
    final addedFolders = <LibraryFolder>[];
    try {
      oldCredentials = await WebDavCredentials.load();
      await rust.webdavSetupCommit(token: token);
      _setupToken = null;
      final credentials = WebDavCredentials(
        baseUrl: _address.text,
        user: _authMode == 'anonymous' ? '' : _user.text,
        password: _authMode == 'anonymous' ? '' : _password.text,
        authMode: _authMode,
        allowInsecureTls:
            _address.text.startsWith('https://') && _allowInsecureTls,
      );
      await credentials.save();
      final existing = (await rust.listLibraryFolders())
          .map((folder) => '${folder.sourceType}\n${folder.path}')
          .toSet();
      for (final path in selected) {
        final uri = await rust.webdavUriForRelative(subdir: path);
        if (existing.contains('webdav\n$uri')) continue;
        final folder = await rust.addLibraryFolder(
          path: uri,
          sourceType: 'webdav',
        );
        addedFolders.add(folder);
      }
      _committed = true;
      ref.invalidate(foldersProvider);
      ref.invalidate(webDavConfiguredProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      for (final folder in addedFolders.reversed) {
        try {
          await rust.removeLibraryFolder(id: folder.id);
        } catch (_) {}
      }
      try {
        if (oldCredentials != null) {
          await oldCredentials.save(rememberInHistory: false);
          await oldCredentials.pushToRust();
        }
      } catch (_) {}
      if (mounted) setState(() => _error = '添加 WebDAV 文件夹失败：$error');
    } finally {
      mutationLock.state = false;
      _setBusy(false);
    }
  }

  Future<bool> _goBack() async {
    if (_busy) return false;
    if (_step == 0) return true;
    final token = _setupToken;
    _setupToken = null;
    if (token != null) await rust.webdavSetupCancel(token: token);
    setState(() {
      _step = 0;
      _entries = const [];
      _selectedPaths.clear();
      _error = null;
    });
    return false;
  }

  void _setBusy(bool value) {
    if (mounted) setState(() => _busy = value);
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    canPop: _step == 0 && !_busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_goBack());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_step == 0 ? '连接 WebDAV' : '选择 WebDAV 文件夹'),
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
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _step == 0
                    ? ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (_error != null) _errorBanner(_error!),
                          _credentialsStep(),
                        ],
                      )
                    : _directoryStep(),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _credentialsStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_history.isNotEmpty) ...[
        DropdownButtonFormField<int>(
          key: ValueKey('webdav-history-${_history.length}'),
          initialValue: null,
          decoration: const InputDecoration(
            labelText: '已连接过的 WebDAV',
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
                    _address.text = credentials.baseUrl;
                    _user.text = credentials.user;
                    _password.text = credentials.password;
                    _authMode = credentials.authMode;
                    _allowInsecureTls = credentials.allowInsecureTls;
                    _error = null;
                  });
                },
        ),
        const SizedBox(height: 12),
      ],
      TextField(
        controller: _address,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onChanged: (value) {
          if (!value.trim().toLowerCase().startsWith('https://') &&
              _allowInsecureTls) {
            setState(() => _allowInsecureTls = false);
          } else {
            setState(() {});
          }
        },
        decoration: const InputDecoration(
          labelText: 'WebDAV 地址',
          hintText: 'https://nas.example.com/dav/',
          prefixIcon: Icon(Icons.cloud_outlined),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _authMode,
        decoration: const InputDecoration(
          labelText: '认证方式',
          prefixIcon: Icon(Icons.security_outlined),
        ),
        items: const [
          DropdownMenuItem(value: 'basic', child: Text('Basic（推荐配合 HTTPS）')),
          DropdownMenuItem(value: 'anonymous', child: Text('匿名访问')),
        ],
        onChanged: _busy
            ? null
            : (value) => setState(() => _authMode = value ?? 'basic'),
      ),
      if (_authMode == 'basic') ...[
        const SizedBox(height: 12),
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
      ],
      if (_address.text.trim().toLowerCase().startsWith('https://')) ...[
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _allowInsecureTls,
          title: const Text('忽略 HTTPS 证书错误'),
          subtitle: Text(
            _allowInsecureTls
                ? '已降低连接安全性：会接受自签名、过期或名称不匹配的证书，仅限可信局域网。'
                : '仅在可信 NAS 使用自签名证书且严格连接失败时开启。',
          ),
          secondary: Icon(
            _allowInsecureTls
                ? Icons.warning_amber_outlined
                : Icons.verified_user_outlined,
          ),
          onChanged: _busy
              ? null
              : (value) => setState(() => _allowInsecureTls = value),
        ),
      ],
      const SizedBox(height: 12),
      Text(
        _allowInsecureTls
            ? '凭证只保存在当前设备；当前 HTTPS 连接不会校验证书。当前版本支持一组 WebDAV 根地址。'
            : '凭证只保存在当前设备；HTTPS 会严格校验证书。当前版本支持一组 WebDAV 根地址。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _busy ? null : _connect,
        icon: const Icon(Icons.login),
        label: const Text('连接并浏览'),
      ),
    ],
  );

  Widget _directoryStep() {
    final directories = _entries.where((entry) => entry.isDirectory).toList();
    final files = _entries.where((entry) => !entry.isDirectory).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _errorBanner(_error!),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: RemoteFolderSelectionHeader(
            breadcrumbs: _breadcrumbs(),
            selectedCount: compactSelectedRemotePaths(_selectedPaths).length,
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
                title: Text(
                  _currentPath.isEmpty ? '选择整个 WebDAV 根目录' : '选择当前文件夹',
                ),
                subtitle: Text(_currentPath.isEmpty ? '/' : _currentPath),
                onChanged: (selected) => setState(() {
                  selected == true
                      ? _selectedPaths.add(_currentPath)
                      : _selectedPaths.remove(_currentPath);
                }),
              ),
              const Divider(),
              if (directories.isEmpty && files.isEmpty)
                const ListTile(
                  leading: Icon(Icons.folder_off_outlined),
                  title: Text('当前目录为空'),
                ),
              for (final directory in directories)
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
              for (final file in files.take(40))
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 16),
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (files.length > 40)
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 4),
                  child: Text('另有 ${files.length - 40} 个文件未展开显示'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _breadcrumbs() {
    final result = <Widget>[
      ActionChip(
        avatar: const Icon(Icons.cloud_outlined, size: 16),
        label: const Text('WebDAV'),
        onPressed: _busy ? null : () => _browse(''),
      ),
    ];
    final segments = _currentPath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    for (var index = 0; index < segments.length; index++) {
      final path = segments.take(index + 1).join('/');
      result.add(
        ActionChip(
          label: Text(segments[index]),
          onPressed: _busy ? null : () => _browse(path),
        ),
      );
    }
    return result;
  }

  Widget _errorBanner(String message) => Container(
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

String? normalizeWebDavAddress(String input) {
  final parsed = Uri.tryParse(input.trim());
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty) {
    return null;
  }
  final segments = parsed.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    pathSegments: [...segments, ''],
  ).toString();
}

bool webDavSourceBelongsToBase(String sourceUri, String baseUrl) {
  final base = Uri.parse(baseUrl);
  final source = Uri.tryParse(sourceUri);
  if (source == null ||
      source.scheme != base.scheme ||
      source.host != base.host ||
      source.port != base.port) {
    return false;
  }
  return source.path == base.path || source.path.startsWith(base.path);
}
