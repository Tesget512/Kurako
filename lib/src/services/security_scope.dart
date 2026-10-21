import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// macOS App Sandbox: access granted by the folder picker lasts for that
/// launch only. Security-scoped bookmark data retains the grant across
/// launches; without it mpv's open() fails with "Operation not permitted"
/// even though the scan could still list directory metadata.
///
/// Only macOS has the native bridge; every other platform is a no-op so the
/// call sites stay platform-independent.
const MethodChannel _scopeChannel = MethodChannel(
  'com.tesget.kurako/security_scope',
);

class SecurityScopeException implements Exception {
  final String message;
  const SecurityScopeException(this.message);
  @override
  String toString() => message;
}

/// Result of starting security-scoped access.
///
/// Bookmarks are stored per FOLDER, so starting access resolves to the folder
/// URL. [path] re-applies the caller's original file path under that live
/// folder (the mount point may have moved); [scopePath] is the folder the
/// native side actually started and therefore the one [SecurityScope.release]
/// must receive.
class ScopedPath {
  final String path;
  final String scopePath;
  const ScopedPath(this.path, this.scopePath);
}

class SecurityScope {
  const SecurityScope._();

  static bool get _supported => Platform.isMacOS;

  static String _key(String path) =>
      'scope_bookmark_v1_${sha256.convert(utf8.encode(path))}';

  /// Bookmarks are retained per FOLDER (what the user picks), but callers
  /// hand us paths underneath it. Return the bookmark plus the folder path it
  /// was stored for — the ancestor is what a resolved bookmark points at.
  static Future<({String bookmark, String root})?> _bookmarkWithRoot(
    String path,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final direct = prefs.getString(_key(path));
    if (direct != null) return (bookmark: direct, root: path);
    String? bestPath;
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('scope_bookmark_v1_') || key.endsWith('.path')) {
        continue;
      }
      final storedPath = prefs.getString('$key.path');
      if (storedPath == null) continue;
      if (!path.startsWith('$storedPath/') && path != storedPath) continue;
      if (bestPath == null || storedPath.length > bestPath.length) {
        bestPath = storedPath;
      }
    }
    if (bestPath == null) return null;
    final bookmark = prefs.getString(_key(bestPath));
    if (bookmark == null) return null;
    return (bookmark: bookmark, root: bestPath);
  }

  /// Re-apply [path] under [newRoot] when the bookmark resolved elsewhere.
  static String _reRoot(String path, String oldRoot, String newRoot) {
    if (oldRoot == newRoot) return path;
    if (path == oldRoot) return newRoot;
    if (path.startsWith('$oldRoot/')) {
      return '$newRoot${path.substring(oldRoot.length)}';
    }
    return path;
  }

  /// Persist a bookmark for [path]. Call right after the user picks the
  /// folder — the grant is alive in this launch, which is what bookmark
  /// creation requires.
  static Future<void> retain(String path, {String? base64Bookmark}) async {
    if (!_supported) return;
    try {
      final value =
          base64Bookmark ??
          await _scopeChannel.invokeMethod<String>('createBookmark', path);
      if (value == null || value.isEmpty) {
        throw const SecurityScopeException('无法创建访问书签');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(path), value);
      // Human-readable path record so file-path lookups can find this folder
      // (keys are hashes; the path itself is not secret but is not the key).
      await prefs.setString('${_key(path)}.path', path);
    } on SecurityScopeException {
      rethrow;
    } on PlatformException catch (error) {
      throw SecurityScopeException('无法创建访问书签：${error.code}');
    } on MissingPluginException {
      // Debug runner without the native bridge (e.g. iOS): keep working.
    }
  }

  /// Pick a folder AND retain its bookmark in one native step on macOS.
  ///
  /// The bookmark must be created from the NSOpenPanel URL itself: the blob
  /// encodes the powerbox grant, and a bookmark recreated from the bare path
  /// string is accepted by startAccessing yet silently refused by the kernel
  /// when mpv opens a file (observed: file-issue-extension deny). Returns the
  /// picked path, or null when cancelled. Other platforms return null —
  /// callers fall back to their normal folder picker and plain [retain].
  static Future<String?> pickAndRetainFolder() async {
    if (!_supported) return null;
    try {
      final picked = await _scopeChannel.invokeMethod<Map<Object?, Object?>>(
        'pickFolder',
      );
      final path = picked?['path'] as String?;
      final bookmark = picked?['bookmark'] as String?;
      if (path == null || bookmark == null) return null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(path), bookmark);
      await prefs.setString('${_key(path)}.path', path);
      return path;
    } on PlatformException catch (error) {
      if (error.code == 'NO_WINDOW') {
        throw const SecurityScopeException('无法打开文件夹选择窗口，请重试');
      }
      throw SecurityScopeException('选择文件夹失败：${error.code}');
    }
  }

  /// Resolve the stored bookmark without starting access. Returns the live
  /// path (the mount point may have changed since the folder was picked), or
  /// null when the bookmark is missing/cannot be resolved (volume unmounted).
  static Future<String?> resolve(String path) async {
    if (!_supported) return path;
    final found = await _bookmarkWithRoot(path);
    if (found == null) return null;
    try {
      final resolved = await _scopeChannel.invokeMethod<String>(
        'resolveBookmark',
        found.bookmark,
      );
      if (resolved == null) return null;
      return _reRoot(path, found.root, resolved);
    } on PlatformException {
      return null;
    }
  }

  /// Start security-scoped access for [path]; throws when the retained
  /// bookmark no longer resolves (volume absent or bookmark deleted).
  ///
  /// The returned [ScopedPath.path] is the caller's own path re-rooted under
  /// the live mount, so a file path stays a file path. [ScopedPath.scopePath]
  /// is the folder the native side started — pass THAT to [release], or the
  /// native guard refuses to stop the extension.
  static Future<ScopedPath> access(String path) async {
    if (!_supported) return ScopedPath(path, path);
    final found = await _bookmarkWithRoot(path);
    if (found == null) {
      throw const SecurityScopeException('该文件夹缺少沙盒访问书签，请在设置中重新选择一次');
    }
    try {
      final resolved = await _scopeChannel.invokeMethod<String>(
        'startAccess',
        found.bookmark,
      );
      assert(() {
        debugPrint(
          'kurako/scope access -> ${resolved == null ? 'DENIED' : 'granted'}',
        );
        return true;
      }());
      if (resolved == null) {
        throw const SecurityScopeException('无法访问该文件夹（可能未挂载），请重新在设置中选择');
      }
      return ScopedPath(_reRoot(path, found.root, resolved), resolved);
    } on PlatformException catch (error) {
      throw SecurityScopeException('无法启动文件夹访问：${error.code}');
    }
  }

  /// Pair with a successful [access]. Never throws: a missed stop only keeps
  /// the extension open until process exit.
  static Future<void> release(String path) async {
    if (!_supported) return;
    try {
      await _scopeChannel.invokeMethod<void>('stopAccess', path);
    } on PlatformException {
      // Best-effort.
    }
  }
}
