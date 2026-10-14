import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../build_info.dart';
import '../state/update_provider.dart';
import '../widgets/update_download_dialog.dart';
import '../widgets/window_caption.dart';

/// Product and attribution information kept out of the operational settings
/// page.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  static final Uri _projectUri = Uri.parse(
    'https://github.com/Tesget512/Kurako',
  );

  Future<void> _openProject(BuildContext context) async {
    final opened = await launchUrl(
      _projectUri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开 GitHub 项目主页')));
    }
  }

  Future<void> _openLicenses(BuildContext context) async {
    final packageInfo = await _packageInfo;
    if (!context.mounted) return;
    showLicensePage(
      context: context,
      applicationName: 'Kurako',
      applicationVersion: packageInfo.version,
      applicationIcon: const Image(
        image: AssetImage('assets/images/kurako_icon.png'),
        width: 64,
        height: 64,
      ),
      applicationLegalese:
          'Kurako 原创代码采用 GNU General Public License v3.0 only。',
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const SysAppBar(title: Text('关于 Kurako')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Center(
          child: Column(
            children: [
              Image(
                image: AssetImage('assets/images/kurako_icon.png'),
                width: 112,
                height: 112,
              ),
              SizedBox(height: 12),
              Text('Kurako', style: TextStyle(fontSize: 22)),
              SizedBox(height: 4),
              Text('本地番剧库播放器 · Flutter + Rust'),
              SizedBox(height: 10),
              Text('这个只是暂定的图标！\n...嗯，暂定的...', textAlign: TextAlign.center),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule_outlined),
          title: const Text('版本与编译时间'),
          subtitle: FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snapshot) {
              final version = snapshot.data?.version;
              return Text(
                '${version == null ? '版本读取中' : '版本 $version'}\n编译时间：$kBuildTime',
              );
            },
          ),
        ),
        const _UpdateCheckSection(),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.code_outlined),
          title: const Text('GitHub 项目主页'),
          subtitle: const Text('github.com/Tesget512/Kurako'),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => _openProject(context),
        ),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.balance_outlined),
          title: const Text('开源许可'),
          subtitle: const Text(
            'GNU General Public License v3.0 only（GPL-3.0-only）\n'
            '查看 Kurako、Flutter 依赖与随附资源的详细许可。',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openLicenses(context),
        ),
        const Divider(height: 32),
        const _Acknowledgements(),
      ],
    ),
  );
}

class _UpdateCheckSection extends ConsumerWidget {
  const _UpdateCheckSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateCheckProvider);
    final notifier = ref.read(updateCheckProvider.notifier);
    final statusText = switch (state.status) {
      UpdateCheckStatus.idle => '启动时静默检查 GitHub 最新稳定版本。',
      UpdateCheckStatus.checking => '正在检查 GitHub 最新稳定版本…',
      UpdateCheckStatus.noRelease => '未找到公开的稳定版本。',
      UpdateCheckStatus.upToDate =>
        '当前版本 ${state.result!.currentVersion} 已是最新。',
      UpdateCheckStatus.available =>
        '发现新版本 ${state.result!.release!.tagName}（当前 ${state.result!.currentVersion}）',
      UpdateCheckStatus.failed => state.failureMessage ?? '检查失败，请重试。',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.system_update_alt),
          title: const Text('检查更新'),
          subtitle: Text(statusText),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: state.status == UpdateCheckStatus.checking
                  ? null
                  : notifier.checkManually,
              icon: state.status == UpdateCheckStatus.checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(
                state.status == UpdateCheckStatus.checking
                    ? '正在检查'
                    : state.status == UpdateCheckStatus.failed
                    ? '重试'
                    : '检查更新',
              ),
            ),
            if (state.status == UpdateCheckStatus.available)
              FilledButton.icon(
                onPressed: () => showUpdateDownload(context, ref),
                icon: const Icon(Icons.download),
                label: const Text('下载更新'),
              ),
          ],
        ),
      ],
    );
  }
}

class _Acknowledgements extends StatelessWidget {
  const _Acknowledgements();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.favorite_outline),
        title: Text('致谢'),
        subtitle: Text('Kurako 建立在开源软件与公共服务之上。'),
      ),
      _AcknowledgementGroup(
        title: '应用与界面参考',
        entries: ['Kazumi — 详情页布局灵感（GPL-3.0）'],
      ),
      _AcknowledgementGroup(
        title: '播放与图像',
        entries: [
          'media_kit / mpv — 跨平台视频播放',
          'Anime4K（bloc97）— 超分辨率着色器',
          '霞鹜文楷 GB 屏幕阅读版 — 应用字体（OFL-1.1）',
        ],
      ),
      _AcknowledgementGroup(
        title: '数据与网络服务',
        entries: ['Bangumi 番组计划 — 番剧元数据与评分', 'Mirrox（bangumi.vip）— 可选镜像，开启需验证'],
      ),
      _AcknowledgementGroup(
        title: '跨平台基础',
        entries: ['Flutter — 应用界面', 'Rust / flutter_rust_bridge — 跨平台核心与桥接'],
      ),
    ],
  );
}

class _AcknowledgementGroup extends StatelessWidget {
  final String title;
  final List<String> entries;
  const _AcknowledgementGroup({required this.title, required this.entries});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(entry),
          ),
      ],
    ),
  );
}
