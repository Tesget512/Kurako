# Kurako

Kurako 是一款使用 Flutter 与 Rust 构建的跨平台本地番剧库和视频播放器，支持本地文件夹、SMB 与 WebDAV 媒体源，并可通过 Bangumi 获取番剧资料。

项目目前处于开发阶段，目标平台包括 Android、iOS、iPadOS、macOS 与 Windows。

## 开源许可

Kurako 原创代码以 [GNU General Public License v3.0 only](LICENSE)（`GPL-3.0-only`）发布。

Copyright (C) 2026 Tesget512 and Kurako contributors.

项目使用的第三方组件仍适用各自的许可证，主要组件与来源见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。

## 构建说明

- Android 正式签名配置见 [docs/ANDROID_SIGNING.md](docs/ANDROID_SIGNING.md)。
- Apple 平台说明见 [docs/APPLE_PLATFORM.md](docs/APPLE_PLATFORM.md)。
- Windows Release 可通过 `script/Build-KurakoWindowsRelease.ps1` 构建。
