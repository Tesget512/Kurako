# Apple Platform Adaptation Record

This document records the Apple-platform work introduced after the Windows and
Android implementation, so that the platform-specific decisions are visible in
the repository history rather than only in build output or commit titles.

## Supported Targets

- iOS and iPadOS use the Flutter `ios/` project, CocoaPods, Cargokit, and the
  Rust static library `rust_lib_kurako`.
- macOS uses the Flutter `macos/` project and the same Rust core.
- The checked-in Xcode projects, Podfiles, Podfile locks, launch assets, and
  shared workspace files are source inputs. Derived Pods, build directories,
  archives, and exported packages remain ignored.

## Build And Signing

- iOS supports a Release Dart build exported with a Development signing
  profile, suitable for direct installation on devices that belong to the
  selected Apple Development team. The release package is emitted as
  `dist/out/KURAKO-iOS-release.ipa`.
- Rust is cross-compiled through Cargokit and embedded through the generated
  podspec. The build scripts select the toolchain explicitly so Xcode shell
  phases can find `rustc` and Cargo.
- CocoaPods build settings are aligned to iOS 13, which keeps the application
  compatible with older supported iPhone and iPad releases while satisfying
  current pod deployment requirements.
- macOS can be built from the checked-in project. On this machine's GTX 1050
  Web Driver configuration, Flutter has no usable Metal renderer; software
  rendering launches a blank Flutter surface. This is a host GPU limitation,
  not an application feature flag, and does not affect iOS/iPadOS devices.

## Playback, SMB, And Downloads

- Apple SMB media is presented to the built-in player through a loopback proxy.
  Share sessions are reused and closed deterministically after scans, subtitle
  reads, downloads, and playback cancellation to reduce pressure on the SMB
  server's connection limit.
- iOS/iPadOS external playback of SMB media deliberately requires a completed
  local download. The platform shares the downloaded local file with the chosen
  player instead of handing that player a credential-bearing SMB URL.
- The default download location is a KURAKO folder exposed through the Files
  app. Completed downloads are recorded locally so player selection can prefer
  the file over the remote share.
- The Apple player includes the brightness integration needed by touch controls.
  Double-tap seeking keeps the controls hidden, and iPad exposes an optional
  desktop-style control layout while retaining touch controls by default.

## Bangumi OAuth

- Bangumi has one fixed callback registered for this application:
  `http://localhost:6420/callback`.
- The app opens a temporary loopback HTTP listener before opening the official
  Bangumi authorization page, then exchanges the returned authorization code in
  the Rust core.
- iOS and Android pass the generated authorization URL to their system browser
  without parsing and reconstructing the already-encoded `redirect_uri` query
  value. This prevents Bangumi's `invalid_uri` / missing redirect URI error.

## Verification

- Rust unit tests cover media matching and the exact OAuth authorization URL.
- Dart analysis is run against the changed application sources.
- iOS Release archives are exported with the Development export options when a
  personal Apple team is used; App Store distribution requires an appropriate
  paid distribution profile.
