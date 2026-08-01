# 构建 Kurako

Kurako 使用 Flutter 构建界面和应用层，并使用 Rust 提供跨平台核心能力。开始前安装 Flutter stable、Rust stable，以及目标平台对应的 Android、Xcode 或 Visual Studio 工具链。

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

# iOS / iPadOS：无签名设备包，后续由使用者自行签名
flutter build ios --release --no-codesign

# macOS
flutter build macos --release

# Windows
flutter build windows --release
```

Windows 的便携版与 Inno Setup 安装包可在安装了 Inno Setup 6 的环境中运行 `script/Build-Kurako.cmd` 生成。

## 签名与分发

- Android：正式包需要项目私有 keystore；没有它时构建会使用独立的 `.dev` 包名。详见 [Android 签名说明](ANDROID_SIGNING.md)。
- iOS / iPadOS：GitHub 分发包保持无签名，侧载前由使用者自行签名。
- macOS：发布包使用 ad-hoc 签名的通用 App，并封装为未公证 DMG。详见 [Apple 平台说明](APPLE_PLATFORM.md)。
- 发布产物、校验与版本检查详见 [发布检查清单](RELEASE.md)。
