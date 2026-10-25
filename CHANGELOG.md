# 变更记录

本项目遵循语义化版本。首次公开发布前的内部提交统一整理到 1.0.1。

## [1.1.1] - 2026-10-25

### 新增

- 新增 Bangumi 个人访问令牌登录：在官网生成令牌后粘贴即可登录，令牌保存于各平台安全存储（macOS 为应用沙盒内文件，其余平台为系统密钥串/Keystore/DPAPI/libsecret），绝不进入配置备份与日志。
- 新增反向代理 OAuth 登录（实验性）：官方站点无法直接访问时，可启用 bangumi.lat 反向代理完成授权与令牌交换。实现为 Rust 内置 Anubis 工作量证明客户端，无 WebView、无平台分支，Cookie 仅存内存；开关关闭时一切走官方链路。移动端、Linux 与桌面端行为统一。
- Bangumi API/封面镜像支持 lain.bangumi.lat；登录与收藏读写为两个独立开关，默认关闭。
- 更新检查：启动静默检查 GitHub 最新 Release，库页顶部横幅提示；GitHub API 限流时自动回退网页解析链路。
- 扫描进度改为库页内联展示，支持取消与详情，切换页面不中断；增量扫描只识别变化文件。
- 播放器控件重做为 Material Design 3。
- 桌面端窗口体验：启动不再闪现黑窗；新增"记住窗口大小"开关（默认开）；标题栏与播放器顶栏整行可拖动/双击最大化；全屏时最大化按钮等价于退出全屏且按钮状态保持同步。

### 修复

- 修复 OAuth 令牌交换的安全问题：响应体不再写入错误信息，服务端错误码走白名单映射，交换回传 state 并调用 token_status 校验。
- 修复 macOS 授权回调未注册 `kurako://` scheme 导致授权完成后重定向被静默丢弃的问题。
- 修复镜像收藏请求不带 Bearer 身份的问题。
- 新增 iOS/iPadOS 系统代理支持，修正挂代理时仍直连 API 的问题；macOS 读取 CFNetwork 系统代理，回环地址全局绕过代理。
- 修复 macOS 沙盒下载目录书签解析错误导致播放实际打开目录的问题；本地文件改走回环 HTTP Range 代理。
- 修复 Windows 播放画面撕裂。
- 播放器亮度/音量手势改为"起点固定 + 累计位移"，修复拖动抖动与 iOS 亮度调节延迟。
- 损坏/无法读取的视频文件现在给出分类原因提示并附重试按钮；提示不再残留到播放器退出之后。
- 修复"未开始下载却提示已完成"：SMB/WebDAV 下载失败不再被静默吞掉。
- 修复详情页窄布局信息溢出、macOS PAT 登录时的钥匙串授权弹窗、PAT 登录态下显示无关续期文案等问题。
- Android 下载与 SMB 扫描多项修复。

### 发布说明

- 版本 `1.1.1+5`；正式包标识为 `com.tesget.kurako`。
- Android 分架构发布；iOS/iPadOS 提供不含开发者身份的 `no_sign` IPA；macOS 提供内含 ad-hoc 签名通用 App 的 DMG（未公证）；Windows 提供安装包和便携包（未签名）；Linux 提供 x86_64 Debian `.deb` 实验包，仅保证 Ubuntu 24.04 同代环境。
- 反向代理与镜像功能默认关闭，仅建议官方站点无法直接访问的用户启用。
- Linux 登录授权回跳依赖浏览器的自定义协议处理，snap 沙盒版 Firefox 可能静默失败，建议使用发行版原生 Firefox/Chromium。

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
