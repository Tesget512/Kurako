# Android 签名与多机构建

Kurako 的官方 Android 包由一把私有 Release keystore 签名。私钥绝不能提交到 Git，也不能放入公开 GitHub 仓库。

## 本机正式构建

本机使用被忽略的 `android/key.properties`：

```properties
storeFile=/absolute/path/to/kurako-release.jks
storePassword=...
keyPassword=...
keyAlias=kurako-release
```

四个字段齐全时，`flutter build apk --release --split-per-abi` 会生成官方包名 `com.tesget.kurako`，可覆盖其他由同一把 keystore 签名的官方 APK。

Mac 与 Windows 必须复制同一份 `.jks` 和相应的 `key.properties`。Windows 仅需将 `storeFile` 改为该机的绝对路径；不要把这两个私有文件同步进 Git。

## 他人自行编译

没有 `key.properties` 的源码检出会生成 `com.tesget.kurako.dev` / `Kurako Dev`。它可与官方版共存，但不能覆盖官方版，避免第三方签名伪装为官方更新。

## GitHub Actions 官方构建

在 GitHub 仓库 Settings → Secrets and variables → Actions 中设置：

- `ANDROID_KEYSTORE_BASE64`：`kurako-release.jks` 的 Base64 内容
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_KEY_ALIAS`：`kurako-release`
- `BANGUMI_CLIENT_ID`、`BANGUMI_CLIENT_SECRET`：官方 Bangumi OAuth 凭据

之后在 Actions → Android → Run workflow 中勾选 `official_release`。普通 push、PR 与 fork 只构建开发 APK，无法读取私钥。
开发构建会使用公开的 OAuth 占位值，因此仅适合验证编译和非 Bangumi 功能；fork 应自行创建 Bangumi 开发者应用并替换本地 `rust/src/secrets.rs`。

Base64 可在 Mac 上生成（不要把输出提交或发送到公开渠道）：

```sh
base64 -i /absolute/path/to/kurako-release.jks | tr -d '\n'
```
