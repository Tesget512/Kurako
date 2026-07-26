import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Narrow bridge for iOS-only system features which Flutter's cross-platform
/// packages cannot represent faithfully: security-scoped folders and the
/// system share/open sheet.
class IosPlatform {
  static const _channel = MethodChannel('kurako/ios');

  static Future<String?> pickLibraryFolder() async {
    if (!Platform.isIOS) return null;
    return _channel.invokeMethod<String>('pickLibraryFolder');
  }

  static Future<bool> shareVideo(String path) async {
    if (!Platform.isIOS) return false;
    return await _channel.invokeMethod<bool>('shareVideo', {'path': path}) ??
        false;
  }

  /// Saves an image file into the user's system Photos library. This is kept
  /// native so iOS uses its add-only Photos permission instead of exposing a
  /// broader library-reading permission to Flutter.
  static Future<bool> saveImageToPhotos(String path) async {
    if (!Platform.isIOS) return false;
    return await _channel.invokeMethod<bool>('saveImageToPhotos', {
          'path': path,
        }) ??
        false;
  }

  /// Routes a URI to the iOS application that registered its URL scheme.
  static Future<bool> openExternalUrl(String url) async {
    if (!Platform.isIOS) return false;
    return await _channel.invokeMethod<bool>('openExternalUrl', {'url': url}) ??
        false;
  }
}
