# 构建 Kurako

Kurako 使用 Flutter 构建界面和应用层，并使用 Rust 提供跨平台核心能力。开始前安装 Flutter stable、Rust stable，以及目标平台对应的 Android、Xcode、Visual Studio 或 Linux 桌面工具链。

## 准备依赖

项目锁文件使用 Flutter 中文镜像。macOS/Linux 可执行：

```sh
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get
```

Windows PowerShell：

```powershell
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
flutter pub get
```

需要使用 Bangumi 授权功能时，先将 `rust/src/secrets.rs.example` 复制为本机私有的 `rust/src/secrets.rs` 并填入自己的凭证；该文件不得提交。

## 构建命令

```sh
# Android：分别生成 armeabi-v7a、arm64-v8a、x86_64 APK
flutter build apk --release --split-per-abi

# iOS / iPadOS：生成 no_sign 分发 IPA
script/Build-KurakoIOSRelease.sh

# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux（实验性）：生成并验证 x86_64 Release bundle，再打包唯一提供的 DEB
script/Build-KurakoLinuxRelease.sh
script/Build-KurakoLinuxDeb.sh
```

Windows 的便携版与 Inno Setup 安装包可在安装了 Inno Setup 6 的环境中运行 `script/Build-Kurako.cmd` 生成。

镜像验证使用 `flutter_inappwebview`。Windows 构建机还需要在 `PATH` 中提供 NuGet CLI；插件通过 NuGet 获取 WebView2 SDK、Windows Implementation Library 与 nlohmann.json。Windows 用户使用镜像验证时需要 Microsoft Edge WebView2 Runtime；缺少该运行时应保留官方源并按应用提示安装运行时后再验证。它不改变视频播放器的渲染或安装包签名策略。Android 使用系统 WebView，iOS/iPadOS 与 macOS 使用 WKWebView，最低系统版本为 iOS/iPadOS 15.0 / macOS 12.0。

Android 平台实现固定使用本地 `third_party/flutter_inappwebview_android` 1.1.3，并通过 `dependency_overrides` 引用。该副本仅将两处默认 ProGuard 配置改为 `proguard-android-optimize.txt`，以兼容项目的 Android Gradle Plugin 9；上游许可证随副本保留。请勿改写 Pub 缓存或降级项目工具链来绕过此问题。补丁详情见 [KURAKO_PATCH.md](../third_party/flutter_inappwebview_android/KURAKO_PATCH.md)。

### Linux（实验性，仅 DEB）

Linux 版本当前处于实验阶段，发行包只提供 x86_64 Debian `.deb` 测试包；暂不提供 AppImage、Arch 包或 Linux arm64。当前构建脚本要求在 x86_64 Linux 环境中运行，虚拟机或容器也可以；仓库尚未提供从 macOS/Windows 交叉构建 Linux 包的入口。Debian/Ubuntu 的基础构建依赖包括 Flutter 官方要求的 CMake、Ninja、Clang、`pkg-config` 与 GTK3，以及 Kurako 当前 Linux 插件图所需的 libmpv、libepoxy、WebKitGTK 4.1、libsoup 3 和 ALSA 开发包。在 Linux Mint 22.3 / Ubuntu 24.04 上对应的首轮安装候选为：

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
  libmpv-dev libepoxy-dev libwebkit2gtk-4.1-dev libsoup-3.0-dev \
  libasound2-dev
```

其中 `desktop_webview_window` 优先检查 `webkit2gtk-4.1` 与 `libsoup-3.0`，本地维护的 `media_kit_video` 检查 `mpv` 与 `epoxy`，`volume_controller` 强制查找 ALSA。`media_kit_libs_linux` 首次 CMake 配置还会下载并校验 mimalloc 2.1.2，因此原生 bundle 的首次构建需要能够访问其上游源码；这也是后续离线/可复现打包需单独处理的依赖。实际包名随发行版变化，最终仍以 `flutter doctor -v`、CMake 和 `pkg-config` 的结果为准。

Linux 上的 Bangumi HTTP/OAuth 请求优先读取 `HTTPS_PROXY`、`HTTP_PROXY`、`ALL_PROXY` 环境变量；未设置时读取桌面 `org.gnome.system.proxy` 的手动 HTTP/HTTPS 代理，使系统浏览器授权与应用内 token/API 请求使用同一网络路径。应用启动后会缓存 HTTP 客户端，更改代理设置后需重启 Kurako。

`script/Build-KurakoLinuxRelease.sh` 会：

- 写入 `KURAKO_BUILD_TIME` 并构建 Release；
- 检查完整 Flutter bundle、ELF 架构和 bundle 内 ELF 的缺失共享库；
- 将已验证的核心 bundle 留在 `build/linux/x64/release/bundle/`，供 DEB 打包复用，不额外生成其他 Linux 分发包。

`script/Build-KurakoLinuxDeb.sh` 复用同架构已构建的 Release bundle，不重新编译应用。脚本将 bundle 安装到 `/opt/kurako/`，创建 `/usr/bin/kurako` 命令入口，安装 desktop、AppStream 与 hicolor 图标元数据，并对包根中的全部 ELF 使用 `dpkg-shlibdeps` 推导实际运行时依赖；存在无法解析的外部共享库时，脚本会停止打包。Flutter 插件若携带构建机绝对 RUNPATH，脚本只在包副本中修正为 `$ORIGIN`，不会污染原始 Release bundle；成包后若仍有绝对 ELF RPATH/RUNPATH，也会停止打包。输出为 `dist/out/Kurako-Linux-<version>-<arch>.deb`。在 Debian/Ubuntu 系统中可使用 `sudo apt install ./dist/out/Kurako-Linux-<version>-<arch>.deb` 安装，使 APT 同时验证并补齐依赖。

DEB 显式依赖 `desktop-file-utils`，以便安装时刷新
`x-scheme-handler/kurako` 的 MIME handler 数据库。Bangumi 登录使用系统默认
浏览器，授权完成后由 `kurako://oauth/callback` 回到应用；不会在 Linux
应用内另建 WebView 登录窗口。

DEB 的 `/usr/bin/kurako` 是薄启动包装器。默认仅在 DMI 识别为 VirtualBox 时设置 `LIBGL_ALWAYS_SOFTWARE=1`，规避无 3D 虚拟显卡缺失 OpenGL framebuffer blit 导致的 Flutter 引擎中止；实体 Linux 不受影响。可用 `KURAKO_SOFTWARE_RENDERING=1` 显式强制软件渲染，或用 `KURAKO_SOFTWARE_RENDERING=0` 禁止 VirtualBox 自动回退。Flutter 3.38+ 与旧版 `media_kit_video` Linux `FlTextureGL` 输出存在上下文兼容问题，可表现为蓝屏或 Mesa/Flutter 绘制崩溃，因此 Linux 播放器改用稳定的像素缓冲纹理输出。“自动/硬件解码”仍向 libmpv 请求 `auto-copy`，使支持的实体机可继续使用 VAAPI/VDPAU 解码后复制帧；最终是否启用硬件解码以播放器信息中的 `hwdec-current` 为准。Windows、macOS 与移动端配置不变。

Linux 初始窗口为 1440×900，最小尺寸为 960×640；GTK Runner 与 Dart `window_manager` 两层保持一致，避免插件初始化前后尺寸跳变或首次启动过小。

已构建 DEB 可复制到同架构 WSL2 Ubuntu 中执行无界面的安装兼容验证：

```bash
# 仅做包结构、MD5、desktop/AppStream、所有权、ELF 架构、RPATH 和 APT 模拟审计
script/Test-KurakoLinuxDebInWsl.sh dist/out/Kurako-Linux-<version>-<arch>.deb

# 由 root 实际安装，并额外执行 debsums、dpkg -V、全部已安装 ELF 的 ldd 和卸载模拟
KURAKO_WSL_INSTALL=1 script/Test-KurakoLinuxDebInWsl.sh \
  dist/out/Kurako-Linux-<version>-<arch>.deb

# 在已启用 WSLg 的环境额外验证窗口、PulseAudio、Linux 浏览器 handler 和 URI 单实例
KURAKO_WSL_INSTALL=1 KURAKO_WSL_GUI=1 \
  script/Test-KurakoLinuxDebInWsl.sh \
  dist/out/Kurako-Linux-<version>-<arch>.deb
```

WSLg GUI 模式要求 `/tmp/.X11-unix/X0`、`/mnt/wslg/PulseServer`、Linux 默认 HTTP/HTTPS 浏览器和 `x-scheme-handler/kurako` 均已配置。SSH 会话不一定继承 WSLg 变量，脚本会回退到 `DISPLAY=:0`、`PULSE_SERVER=unix:/mnt/wslg/PulseServer` 并以 X11 后端做可自动化的窗口检查；这只影响测试进程，不改变产品默认后端。若 WSL 宿主代理只监听 Windows 的本地端口，浏览器与 Kurako 需要改用 WSL 可访问的宿主地址；不建议通过关闭 TLS 校验或固定 Bangumi IP 绕过网络问题。

WSL2/WSLg 可以补充包结构、安装、窗口、Linux URI handler、音频桥接和较新 Ubuntu 的向前兼容验证，但不能代表实体 Linux 的 GPU、播放器硬件解码和桌面环境差异。当前实验性 x86_64 DEB 以 Mint 22.3 / Ubuntu 24.04 同代环境为构建与验证基线；这不能据此声称兼容所有 Linux 发行版、桌面环境或 GPU/驱动组合。

AppImage、Arch、Flatpak/Flathub 与 Linux arm64 当前均不在提供范围。若后续恢复这些产物，需要重新完成对应原生构建与设备矩阵验证，并在发布说明中单独标注支持范围。

## 签名与分发

- Android：正式包需要项目私有 keystore；没有它时构建会使用独立的 `.dev` 包名。详见 [Android 签名说明](ANDROID_SIGNING.md)。
- iOS / iPadOS：由 `script/Build-KurakoIOSRelease.sh` 生成 `no_sign` Release IPA，侧载前由使用者自行签名。
- macOS：发布包使用 ad-hoc 签名的通用 App，并封装为未公证 DMG。详见 [Apple 平台说明](APPLE_PLATFORM.md)。
- 发布产物、验证与版本检查详见 [发布检查清单](RELEASE.md)。
