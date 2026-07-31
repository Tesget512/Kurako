<p align="center">
  <img src="assets/images/kurako_icon.png" width="128" alt="Kurako 图标">
</p>

<h1 align="center">Kurako</h1>

<p align="center">使用 Flutter 与 Rust 构建的跨平台本地番剧库与视频播放器。</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0--only-blue">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.44.8-02569B?logo=flutter">
  <img alt="Platforms" src="https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows-555">
</p>

> Kurako 1.0.0 正在准备首次公开发布。当前软件、安装包和数据格式仍可能调整。

## 功能

- 扫描本地文件夹、SMB 共享与 WebDAV 服务器，并按文件夹优先级整理番剧库。
- 通过 Bangumi 匹配番剧资料、评分、标签和收藏状态。
- 基于 media_kit 与 mpv 播放视频，支持外挂字幕、常见字幕编码和语言选择。
- 提供触屏与键鼠播放器控制、播放进度记忆、自动续播、连播和 Android 系统媒体控制。
- 支持将网络视频与外挂字幕下载到本机，并在下载管理中播放或清理。
- 提供可选 Anime4K 实时超分辨率，使用时会增加 GPU、发热与耗电负载。
- 使用 Flutter 编写界面与应用层，Rust 提供数据库、媒体扫描、SMB、WebDAV 和 Bangumi 等跨平台核心能力。

## 平台

| 平台 | 最低版本 | 分发形式 |
| --- | --- | --- |
| Android | Android 7.0 / API 24 | `armeabi-v7a`、`arm64-v8a`、`x86_64` 单架构 APK |
| iOS / iPadOS | iOS 13 | 完全未签名 IPA，由使用者自行签名和侧载 |
| macOS | macOS 12 | `arm64 + x86_64` 通用 App 压缩包 |
| Windows | 64 位 Windows 10 / 11 | Inno Setup 安装包与便携压缩包 |

正式安装包将在 [GitHub Releases](https://github.com/Tesget512/Kurako/releases) 提供，并附带 SHA-256 校验文件。

## 从源码构建

### 基础工具链

- Flutter `3.44.8` stable
- Rust stable 与 rustup
- Android Studio / Android SDK 36 / NDK `28.2.13676358`（Android）
- Xcode 26 与 CocoaPods（iOS、iPadOS、macOS）
- Visual Studio 2022、Desktop development with C++ 与 Inno Setup 6（Windows）

Bangumi OAuth 凭证不会进入仓库。首次构建前复制公开模板并填写自己的 Bangumi 开发者应用：

```bash
cp rust/src/secrets.rs.example rust/src/secrets.rs
flutter pub get
flutter run
```

Android 签名见 [docs/ANDROID_SIGNING.md](docs/ANDROID_SIGNING.md)，Apple 平台构建与签名见 [docs/APPLE_PLATFORM.md](docs/APPLE_PLATFORM.md)。
维护者发布新版本时还应遵循 [docs/RELEASE.md](docs/RELEASE.md) 的跨平台检查清单。

## 数据与隐私

Kurako 不提供中心服务器，也不包含遥测或广告 SDK。应用只会根据用户操作访问本地文件、用户配置的 SMB/WebDAV 服务器，以及 Bangumi 和封面图片服务。账号、网络凭证与媒体库数据库保存在当前设备；配置导出文件可包含敏感凭证，应妥善保存。

详细说明见 [PRIVACY.md](PRIVACY.md)。

## 参与开发

问题反馈与代码贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。版本变化记录在 [CHANGELOG.md](CHANGELOG.md)。

## 开源许可

Kurako 原创代码以 [GNU General Public License v3.0 only](LICENSE)（`GPL-3.0-only`）发布。

项目使用的第三方组件继续适用各自的许可证，主要组件、字体与来源见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。分发二进制时应同时提供对应版本的完整源代码和许可证文本。

Copyright (C) 2026 Tesget512 and Kurako contributors.

## 致谢与开发方式

Kurako 由 [Tesget512](https://github.com/Tesget512) 发起、设计、测试与维护，并在 Claude 与 OpenAI Codex 等 AI 编程智能体协助下开发。相关提交保留实际参与智能体的 `Co-authored-by` 记录。

感谢 Flutter、Rust、flutter_rust_bridge、media_kit、mpv、Anime4K、Bangumi、bangumi-proxy、Kazumi、霞鹜文楷及所有上游项目的维护者与贡献者。
