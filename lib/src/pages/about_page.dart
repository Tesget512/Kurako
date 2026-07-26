import 'package:flutter/material.dart';

import '../build_info.dart';

/// Product and attribution information kept out of the operational settings
/// page. The project-home row is deliberately a visible placeholder until the
/// public GitHub repository URL is finalized.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('关于 Kurako')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.movie_outlined),
          title: Text('Kurako'),
          subtitle: Text('本地番剧库播放器 · Flutter + Rust'),
        ),
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
          leading: Icon(Icons.favorite_outline),
          title: Text('致谢'),
          subtitle: Text(
            '详情页设计参考 Kazumi（GPL-3.0）；\n'
            '元数据来自 Bangumi 番组计划；镜像由 bangumi-proxy 提供。',
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            '感谢以下开源项目与服务：\n\n'
            '• Kazumi — 详情页布局灵感\n'
            '• Bangumi 番组计划 — 番剧元数据与评分\n'
            '• bangumi-proxy (Yuri-NagaSaki) — 大陆可达镜像\n'
            '• Anime4K (bloc97) — 超分辨率着色器\n'
            '• media_kit / mpv — 视频播放\n'
            '• flutter_rust_bridge — Dart ↔ Rust 桥接',
          ),
        ),
      ],
    ),
  );
}
