import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../build_info.dart';
import '../state/update_provider.dart';
import '../ui/grouped_card.dart';
import '../ui/page_components.dart';
import '../widgets/update_download_dialog.dart';
import '../widgets/window_caption.dart';
import '../widgets/settings_scaffold.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '关于 Kurako',
    embedded: embedded,
    body: const KurakoPageList(maxWidth: 840, children: [AboutPanel()]),
  );
}

class AboutPanel extends StatefulWidget {
  const AboutPanel({super.key});
  @override
  State<AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<AboutPanel> {
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开 GitHub 项目主页')));
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const Image(
                image: AssetImage('assets/images/kurako_icon.png'),
                width: 56,
                height: 56,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Kurako',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    FutureBuilder<PackageInfo>(
                      future: _packageInfo,
                      builder: (context, snapshot) {
                        final version = snapshot.data?.version;
                        return Text(
                          '${version == null ? '版本读取中' : '版本 $version'}\n编译时间：$kBuildTime',
                          style: Theme.of(context).textTheme.bodySmall,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      const _UpdateCheckSection(),
      const SizedBox(height: 12),
      KurakoCardGrid(
        children: [
          _link(
            Icons.code_outlined,
            'GitHub 项目主页',
            () => _openProject(context),
            external: true,
          ),
          _link(Icons.balance_outlined, '开源许可', () => _openLicenses(context)),
          _link(
            Icons.favorite_outline,
            '致谢',
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AcknowledgementsPage()),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _link(
    IconData icon,
    String title,
    VoidCallback onTap, {
    bool external = false,
  }) => Card(
    margin: EdgeInsets.zero,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Icon(icon),
      title: Text(title),
      trailing: Icon(external ? Icons.open_in_new : Icons.chevron_right),
      onTap: onTap,
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
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_alt),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '软件更新',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        statusText,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  tooltip: state.status == UpdateCheckStatus.failed
                      ? '重试检查更新'
                      : '检查更新',
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
                ),
              ],
            ),
            if (state.status == UpdateCheckStatus.available)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () => showUpdateDownload(context, ref),
                    icon: const Icon(Icons.download),
                    label: const Text('下载更新'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AcknowledgementsPage extends StatelessWidget {
  const AcknowledgementsPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    appBar: SysAppBar(title: Text('致谢')),
    body: KurakoPageList(
      maxWidth: 840,
      children: [
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
          entries: [
            'Bangumi 番组计划 — 番剧元数据与评分',
            'Mirrox（bangumi.lat，作者 sakurairo）— 社区维护的反向代理',
          ],
        ),
        _AcknowledgementGroup(
          title: '跨平台基础',
          entries: ['Flutter — 应用界面', 'Rust / flutter_rust_bridge — 跨平台核心与桥接'],
        ),
      ],
    ),
  );
}

class _AcknowledgementGroup extends StatelessWidget {
  final String title;
  final List<String> entries;
  const _AcknowledgementGroup({required this.title, required this.entries});

  @override
  Widget build(BuildContext context) => SettingsGroupCard(
    title: title,
    children: [
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(entry),
        ),
    ],
  );
}
