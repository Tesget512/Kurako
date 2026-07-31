import 'package:flutter/material.dart';

import '../build_info.dart';
import '../widgets/window_caption.dart';

/// Product and attribution information kept out of the operational settings
/// page. The project-home row is deliberately a visible placeholder until the
/// public GitHub repository URL is finalized.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

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
          subtitle: Text('版本 1.0.0\n编译时间：$kBuildTime'),
        ),
        const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.code_outlined),
          title: const Text('GitHub 项目主页'),
          subtitle: const Text('项目公开后将在此处提供跳转链接'),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('GitHub 项目主页尚未配置'))),
        ),
        const Divider(height: 32),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.balance_outlined),
          title: Text('开源许可'),
          subtitle: Text(
            'GNU General Public License v3.0 only（GPL-3.0-only）\n'
            'Kurako 原创代码允许在该许可证约束下使用、研究、修改与再分发。',
          ),
        ),
        const Divider(height: 32),
        const _Acknowledgements(),
      ],
    ),
  );
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
        entries: ['media_kit / mpv — 跨平台视频播放', 'Anime4K（bloc97）— 超分辨率着色器'],
      ),
      _AcknowledgementGroup(
        title: '数据与网络服务',
        entries: [
          'Bangumi 番组计划 — 番剧元数据与评分',
          'bangumi-proxy（Yuri-NagaSaki）— 大陆可达镜像',
        ],
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
