# 变更记录

本项目遵循语义化版本。首次公开发布前的内部提交统一整理到 1.0.1。

## [1.0.2] - 2026-08-04

### 新增

- 新增实验性 Linux 桌面版本，当前仅提供在 Linux Mint 22.3 / Ubuntu 24.04 同代环境构建验证的 x86_64 Debian `.deb` 测试包。
- Linux Runner 支持单实例、`kurako://` URI 回调、桌面菜单入口与 AppStream 元数据。
- Linux 端支持读取环境变量和 GNOME 系统代理，用于 Bangumi 等网络请求。

### 修复

- 修复 Windows、macOS 与 Linux 详情页标题栏拖动区域失效及标题意外居中的问题。
- 修复 Linux 播放 HEVC Main10 等片源时，libmpv 软件像素输出的 alpha 填充导致蓝屏或透明画面的问题。
- Linux 播放器改为将硬件解码与 Flutter 纹理输出解耦，在多显卡环境中保留 `auto-copy` 解码选择并使用稳定像素输出。
- 修复 Linux OAuth 冷启动 URI 丢失、重复窗口及错误链信息不完整的问题。
- 修复 Linux Debian 包中插件 ELF 可能保留构建机绝对 RUNPATH 的问题。

### 发布说明

- Linux 仍为实验性支持，不提供 AppImage、Arch 或 arm64 Linux 包，不保证覆盖所有桌面环境、显卡、驱动和发行版组合。
- Android、iOS/iPadOS、macOS 与 Windows 延续现有分发和签名策略。

## [1.0.1] - 2026-08-01

### 新增

- Windows、Android、iOS、iPadOS 与 macOS 跨平台支持。
- 新增实验性 Linux 桌面支持，当前仅提供 x86_64 Debian `.deb` 测试包；AppImage、Arch 和 Linux arm64 暂不提供。
- 本地文件夹、SMB 与 WebDAV 媒体源及目录选择。
- Bangumi 匹配、评分、标签与收藏状态。
- 基于 media_kit/mpv 的内置播放器、外挂字幕和 Anime4K 超分辨率。
- 下载管理、配置导入导出、播放历史和系统媒体控制。

### 发布说明

- 项目采用 GPL-3.0-only。
- 正式包标识为 `com.tesget.kurako`。
- Android 分架构发布；iOS/iPadOS 提供不含开发者身份的 `no_sign` IPA；macOS 提供内含 ad-hoc 签名通用 App 的 DMG；Windows 提供安装包和便携包。
