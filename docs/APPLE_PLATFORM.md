# Apple 平台构建与分发

Kurako 的 iOS、iPadOS 与 macOS 界面使用 Flutter，跨平台核心由 Rust 和 flutter_rust_bridge 提供。系统桥接只用于权限、文件、认证会话、截图保存和窗口等 Apple 平台能力。

## 支持版本

- iOS / iPadOS：13.0 及以上。
- macOS：12.0 及以上。
- iOS、iPadOS 与 macOS 的 Bundle ID 均使用 `com.tesget.kurako`。

## 环境

1. 安装 Xcode、CocoaPods、Flutter 3.44.8 stable 和 Rust stable。
2. 确保 `cargo` 与 `rustc` 位于 `~/.cargo/bin`、Homebrew rustup 目录，或通过 `RUSTUP_BIN` 指定目录。
3. 使用项目要求的依赖镜像：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get
cd ios && pod install && cd ..
```

## iOS / iPadOS

GitHub Release 提供 `no_sign` IPA。构建时不得选择 Team 或 Development/Distribution 签名：

```bash
KURAKO_BUILD_TIME="YYYY-MM-DD HH:MM:SS +0800" \
  ./script/Build-KurakoIOSRelease.sh
```

使用 `script/Build-KurakoIOSRelease.sh` 生成的 `no_sign` IPA 不含开发者身份，可以保留无开发者身份的 ad-hoc 内层签名，不包含 `embedded.mobileprovision`；接收者仍需使用自己的 Apple ID/证书签名和侧载。

Xcode 真机 Debug 可以在本地选择个人 Team 并使用 Apple Development 签名，但该签名只用于调试，不得混入公开 IPA。

## macOS

macOS Release 必须包含 `arm64` 与 `x86_64`：

```bash
flutter build macos --release \
  --dart-define="KURAKO_BUILD_TIME=YYYY-MM-DD HH:MM:SS +0800"
lipo -archs build/macos/Build/Products/Release/kurako.app/Contents/MacOS/kurako
```

分发前必须对 App 及内嵌 Framework 签名，并用以下命令验证：

```bash
codesign --force --deep --sign - --options runtime \
  --entitlements macos/Runner/Release.entitlements \
  path/to/kurako.app
codesign --verify --deep --strict --verbose=2 path/to/kurako.app
```

当前 GitHub 分发不使用付费 Apple Developer Program，默认对 App 采用 ad-hoc 签名，再使用系统 `hdiutil` 封装为 DMG：

```bash
stage_dir="$(mktemp -d)"
ditto path/to/kurako.app "$stage_dir/Kurako.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create \
  -volname Kurako \
  -srcfolder "$stage_dir" \
  -ov -format UDZO \
  dist/out/Kurako-macOS-universal-adhoc-release.dmg
hdiutil verify dist/out/Kurako-macOS-universal-adhoc-release.dmg
```

ad-hoc 签名不包含开发者身份，也不能进行 Apple 公证；它与 Apple Development、Developer ID 签名均不同。交付记录必须准确写明 `ad-hoc、未公证`。

## Apple 平台行为

- iOS/iPadOS 默认下载目录为 Files 可见的 App Documents `Kurako Downloads`。
- SMB 外部播放先下载到本地，再交给系统分享面板或外部播放器。
- iOS/iPadOS 使用系统认证会话；macOS 使用系统默认浏览器。两者统一通过
  `kurako://oauth/callback` 返回应用。
- iPad 展示分享等 popover 控制器时必须设置锚点。
- Flutter 在 Apple 平台依赖 Metal 渲染；不保证在没有可用 Metal 的 macOS 主机上正常显示界面。
