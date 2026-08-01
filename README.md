<p align="center">
  <img src="assets/images/kurako_icon.png" width="128" alt="Kurako 图标">
</p>

<p align="center"><sub>这个只是暂定的图标！<br>...嗯，暂定的...</sub></p>

<h1 align="center">Kurako</h1>

<p align="center">使用 Flutter 与 Rust 构建的跨平台本地番剧库与视频播放器。</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0--only-blue">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.44.8-02569B?logo=flutter">
  <img alt="Platforms" src="https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows-555">
</p>

## 功能

- 根据文件名称自动识别番剧与集数，并按字幕组、压制组或来源自动归类。
- 整理本地文件夹、SMB 与 WebDAV 中的番剧，并按媒体目录优先级扫描和去重。
- 使用 Bangumi 匹配番剧资料、评分、标签与收藏状态。
- 播放常见视频与外挂字幕，支持字幕编码识别、语言选择和可选 Anime4K 超分辨率。
- 同时适配触屏与键鼠操作，支持进度记忆、自动续播、连播和系统媒体控制。
- 将网络视频与外挂字幕下载到本机，并通过下载管理播放或清理。

## 截图

### iOS / iPadOS

<table>
  <tr>
    <td width="33.3%"><a href="docs/images/screenshots/ios-library.png"><img src="docs/images/screenshots/ios-library.png" alt="iOS 番剧库"></a><br><sub>番剧库</sub></td>
    <td width="33.3%"><a href="docs/images/screenshots/ios-detail.png"><img src="docs/images/screenshots/ios-detail.png" alt="iOS 番剧详情"></a><br><sub>番剧详情</sub></td>
    <td width="33.3%"><a href="docs/images/screenshots/ios-settings.png"><img src="docs/images/screenshots/ios-settings.png" alt="iOS 设置"></a><br><sub>设置</sub></td>
  </tr>
  <tr>
    <td colspan="3"><a href="docs/images/screenshots/ios-player.png"><img src="docs/images/screenshots/ios-player.png" alt="iOS 播放器"></a><br><sub>播放器</sub></td>
  </tr>
</table>

### Windows

<table>
  <tr>
    <td width="50%"><a href="docs/images/screenshots/windows-library.png"><img src="docs/images/screenshots/windows-library.png" alt="Windows 番剧库"></a><br><sub>番剧库</sub></td>
    <td width="50%"><a href="docs/images/screenshots/windows-detail.png"><img src="docs/images/screenshots/windows-detail.png" alt="Windows 番剧详情"></a><br><sub>番剧详情</sub></td>
  </tr>
  <tr>
    <td width="50%"><a href="docs/images/screenshots/windows-player.png"><img src="docs/images/screenshots/windows-player.png" alt="Windows 播放器"></a><br><sub>播放器</sub></td>
    <td width="50%"><a href="docs/images/screenshots/windows-settings.png"><img src="docs/images/screenshots/windows-settings.png" alt="Windows 设置"></a><br><sub>设置</sub></td>
  </tr>
</table>

## 平台

| 平台 | 最低版本 | 分发形式 |
| --- | --- | --- |
| Android | Android 7.0 / API 24 | `armeabi-v7a`、`arm64-v8a`、`x86_64` 单架构 APK |
| iOS / iPadOS | iOS 13 | 完全未签名 IPA，由使用者自行签名和侧载 |
| macOS | macOS 12 | `arm64 + x86_64` 通用 App，使用 ad-hoc 签名封装为 DMG |
| Windows | 64 位 Windows 10 / 11 | Inno Setup 安装包与便携压缩包 |
| Linux | 在写了在写了 | `新建文件夹.jpg` |

正式安装包将在 [GitHub Releases](https://github.com/Tesget512/Kurako/releases) 提供，并附带 SHA-256 校验文件。

## 构建

环境准备、各平台构建、签名与打包方式详见 [构建说明](docs/BUILDING.md)。

## 开源许可

Kurako 原创代码以 [GNU General Public License v3.0 only](LICENSE)（`GPL-3.0-only`）发布。

项目使用的第三方组件继续适用各自的许可证，主要组件、字体与来源见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。分发二进制时应同时提供对应版本的完整源代码和许可证文本。

Copyright (C) 2026 Tesget512 and Kurako contributors.

## 致谢

Kurako 离不开以下开源项目与公共服务，感谢它们的维护者和贡献者：

- [Flutter](https://github.com/flutter/flutter) 与 [Rust](https://www.rust-lang.org/)：跨平台界面、应用层与核心能力。
- [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 与 [Cargokit](https://github.com/irondash/cargokit)：连接 Flutter 与 Rust，并完成多平台原生构建。
- [Riverpod](https://github.com/rrousselGit/riverpod)：Flutter 状态管理。
- [media_kit](https://github.com/media-kit/media-kit) 与 [mpv](https://github.com/mpv-player/mpv)：跨平台视频、音频和字幕播放。
- [Anime4K](https://github.com/bloc97/Anime4K)：实时超分辨率着色器。
- [anitomy-rs](https://github.com/Rapptz/anitomy-rs)：动画文件名解析。
- [rusqlite](https://github.com/rusqlite/rusqlite)、[smb2](https://github.com/vdavid/smb2)、[reqwest](https://github.com/seanmonstar/reqwest) 与 [reqwest_dav](https://github.com/niuhuan/reqwest_dav)：本地数据库及 SMB/WebDAV 网络访问。
- [chardetng](https://github.com/hsivonen/chardetng) 与 [encoding_rs](https://github.com/hsivonen/encoding_rs)：外挂字幕编码识别与转换。
- [Bangumi API](https://bangumi.github.io/api/) 与 [bangumi-proxy](https://github.com/Yuri-NagaSaki/bangumi-proxy)：番剧资料、评分、收藏和网络访问支持。
- [Kazumi](https://github.com/Predidit/Kazumi)：番剧详情页布局与交互参考。
- [霞鹜文楷](https://github.com/lxgw/LxgwWenKai)：应用界面与字幕字体。

同时感谢项目依赖的其他 Flutter packages、Rust crates 和各平台开源组件。完整第三方许可与来源见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。

开发过程中使用了 Claude、OpenAI Codex 等 AI 编程工具辅助实现与审查；相关提交保留实际参与工具的 `Co-authored-by` 记录。
