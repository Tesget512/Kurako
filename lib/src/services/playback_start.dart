import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

enum PlaybackStartResult { ready, failed, timedOut, cancelled }

Duration playbackStartTimeout({required bool remote}) =>
    Duration(seconds: remote ? 45 : 15);

/// How long an error may stand without the media becoming loadable before the
/// wait is treated as a failure.
///
/// mpv can report a demux/decode error and then leave `buffering` true forever
/// — a damaged file on a healthy network does exactly that. Waiting for the
/// full 15/45-second deadline in that case is the "endless loading" symptom, so
/// an error alone is enough once this short grace period expires.
const playbackErrorGrace = Duration(seconds: 2);

bool hasLoadedMedia(PlayerState state) =>
    state.duration > Duration.zero ||
    ((state.videoParams.w ?? 0) > 0 && (state.videoParams.h ?? 0) > 0) ||
    state.position > Duration.zero;

/// Turn an mpv error string into a user-facing reason.
///
/// mpv's message can quote the media path or URL, so the raw text is classified
/// and never shown or logged: the user gets the cause, not their own filename.
/// [defaultReason] replaces the generic tail for callers in the load phase,
/// where "播放过程中" ("during playback") would read wrong.
String playbackErrorNotice(String raw, {String? defaultReason}) {
  final text = raw.toLowerCase();
  if (text.contains('does not exist') ||
      text.contains('no such file') ||
      text.contains('failed to open') ||
      text.contains('cannot open')) {
    return '无法读取视频文件，可能已被移动、删除或访问权限失效。';
  }
  if (text.contains('unsupported') ||
      text.contains('could not open codec') ||
      text.contains('decoder') ||
      text.contains('no video or audio streams')) {
    return '视频格式或编码不受支持，无法解码播放。';
  }
  if (text.contains('timeout') ||
      text.contains('timed out') ||
      text.contains('connection') ||
      text.contains('network') ||
      text.contains('http error') ||
      text.contains('503') ||
      text.contains('404')) {
    return '网络连接中断，视频流无法继续读取。';
  }
  if (text.contains('memory')) {
    return '内存不足，无法继续解码这段视频。';
  }
  return defaultReason ?? '播放过程中出现错误，视频可能已损坏。';
}

/// Attach before open() so an early native error cannot be lost. Readiness is
/// armed after open() resets the previous media's state.
class PlaybackStartWaiter {
  final Player player;
  final ValueListenable<int> generation;
  final int expectedGeneration;
  final _result = Completer<PlaybackStartResult>();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _timer;
  Timer? _errorGraceTimer;
  bool _armed = false;
  bool _failed = false;

  /// The most recent native error text, so a load-phase failure can be
  /// classified by [playbackErrorNotice] instead of a generic notice.
  /// Never displayed raw (it may quote the media path).
  String? error;

  PlaybackStartWaiter(this.player, this.generation, this.expectedGeneration) {
    _subscriptions.addAll([
      player.stream.duration.listen((_) => _check()),
      player.stream.videoParams.listen((_) => _check()),
      player.stream.position.listen((_) => _check()),
      player.stream.playing.listen((_) => _check()),
      player.stream.buffering.listen((_) => _check()),
      player.stream.error.listen((message) {
        error = message;
        _failed = true;
        if (_armed) _check();
      }),
    ]);
    generation.addListener(_check);
  }

  Future<PlaybackStartResult> wait(Duration timeout) {
    _armed = true;
    _timer = Timer(timeout, () => _complete(PlaybackStartResult.timedOut));
    _check();
    return _result.future;
  }

  void _complete(PlaybackStartResult value) {
    if (!_result.isCompleted) _result.complete(value);
  }

  void _check() {
    if (generation.value != expectedGeneration) {
      _complete(PlaybackStartResult.cancelled);
    } else if (_armed) {
      if (hasLoadedMedia(player.state)) {
        _complete(PlaybackStartResult.ready);
      } else if (_failed) {
        // Some codecs emit recoverable errors; the final deadline decides
        // failure unless media_kit reports an idle, non-buffering player.
        if (!player.state.buffering && !player.state.playing) {
          _complete(PlaybackStartResult.failed);
        } else {
          // Still buffering with no media after an error: give it a short
          // chance to recover, then stop pretending it will load.
          _errorGraceTimer ??= Timer(playbackErrorGrace, () {
            if (!hasLoadedMedia(player.state)) {
              _complete(PlaybackStartResult.failed);
            }
          });
        }
      }
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _errorGraceTimer?.cancel();
    generation.removeListener(_check);
    _complete(PlaybackStartResult.cancelled);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}
