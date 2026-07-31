# Kurako 发布检查清单

本文用于维护者准备 GitHub Release。普通源码构建请先阅读根目录 README 以及对应平台文档。

## 版本与源码

1. 确认 `pubspec.yaml`、变更记录和 Git 标签使用相同版本。
2. 所有平台使用相同的 Flutter stable patch 版本和同一个 `KURAKO_BUILD_TIME`。
3. 使用项目要求的依赖源运行 `flutter pub get`，不得提交构建机产生的 `pubspec.lock` 漂移。
4. 发布提交应通过 Flutter 静态分析、完整 Flutter 测试和完整 Rust 测试。
5. 从准备发布的精确 Git 标签构建全部产物；GitHub 上的同一标签源码即为 GPL-3.0-only 二进制对应源码。

## 分发产物

| 平台 | 必需产物 | 签名要求 |
| --- | --- | --- |
| Android | `armeabi-v7a`、`arm64-v8a`、`x86_64` 三个单架构 Release APK | 使用 Kurako 正式 Android 私钥签名 |
| iOS / iPadOS | `Kurako-iOS-unsigned-release.ipa` | 完全未签名，由使用者自行签名 |
| macOS | 包含 `arm64` 与 `x86_64` 的通用 App 压缩包 | 必须签名，并在发布说明中写明实际签名类型和是否公证 |
| Windows | x64 便携压缩包与 Inno Setup 安装包 | 当前不签名 |

Android 不发布 universal APK。缺少正式私钥时只能生成使用 `.dev` 包名的开发包，不能作为正式 Release。

## Apple 平台核验

- iOS IPA 内的 Runner、Framework 和扩展不得包含 `_CodeSignature`、`embedded.mobileprovision` 或其他签名材料。
- macOS 使用 `lipo -archs` 确认主程序包含 `x86_64` 与 `arm64`。
- macOS 使用 `codesign --verify --deep --strict --verbose=2` 验证 App；ad-hoc、Apple Development 与 Developer ID 必须准确区分。
- 签名不代表已经公证，发布说明必须分别记录。

## 归档与校验

1. 将最终 Release 产物整理到 `dist/out/`，不得直接上传临时 `build/` 目录内容。
2. 解压或列出每个压缩包，确认文件完整且不包含调试符号、私钥、OAuth 凭证或本机路径。
3. 记录每个产物的文件大小和 SHA-256，并随 GitHub Release 提供校验文件。
4. 在至少一个对应平台验证安装与启动；若某平台没有完成真机验证，应在发布说明中明确标注。
5. 将 `CHANGELOG.md` 中对应版本的 `Unreleased` 替换为实际发布日期后再创建标签。
