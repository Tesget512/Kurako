# 参与 Kurako 开发

感谢你关注 Kurako。提交代码前请先通过 Issue 说明问题或目标，避免在平台行为、数据格式或大型依赖上重复实现。

## 环境

- Flutter 3.44.8 stable
- Rust stable
- 对应平台的 Android、Xcode 或 Visual Studio 工具链

复制 Bangumi OAuth 模板后再进行本地构建：

```bash
cp rust/src/secrets.rs.example rust/src/secrets.rs
flutter pub get
```

不要提交真实 OAuth 凭证、Android keystore、`key.properties`、证书、配置导出文件或本机路径。

## 实现原则

- 通用界面和应用逻辑优先使用 Dart，跨平台核心能力优先使用 Rust。
- Kotlin、Swift/Objective-C 与 C++ 只用于系统无法替代的桥接。
- 修改共享行为时同时考虑 Windows、Android、iOS、iPadOS 与 macOS。
- 保持改动聚焦，说明平台差异、数据兼容和验证范围。

## 提交前检查

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml
```

只修改 Dart 且不影响 Rust/FRB 契约时，可以在说明中明确 Rust 未受影响；修改 Rust 或 Dart/Rust 数据契约时必须运行完整 Rust 测试。

提交贡献即表示你同意按项目的 [GPL-3.0-only](LICENSE) 许可发布该贡献。使用 AI 辅助时，贡献者仍需审查、测试并对提交内容负责；可在提交说明中透明标注所用工具。
