import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

enum PlaybackStartResult { ready, failed, timedOut, cancelled }

Duration playbackStartTimeout({required bool remote}) =>
    Duration(seconds: remote ? 45 : 15);

bool hasLoadedMedia(PlayerState state) =>
    state.duration > Duration.zero ||
    ((state.videoParams.w ?? 0) > 0 && (state.videoParams.h ?? 0) > 0) ||
    state.position > Duration.zero;

/// Attach before open() so an early native error cannot be lost. Readiness is
/// armed after open() resets the previous media's state.
class PlaybackStartWaiter {
  final Player player;
  final ValueListenable<int> generation;
  final int expectedGeneration;
  final _result = Completer<PlaybackStartResult>();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _timer;
  bool _armed = false;
  bool _failed = false;

  PlaybackStartWaiter(this.player, this.generation, this.expectedGeneration) {
    _subscriptions.addAll([
      player.stream.duration.listen((_) => _check()),
      player.stream.videoParams.listen((_) => _check()),
      player.stream.position.listen((_) => _check()),
      player.stream.playing.listen((_) => _check()),
      player.stream.buffering.listen((_) => _check()),
      player.stream.error.listen((_) {
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
        }
      }
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    generation.removeListener(_check);
    _complete(PlaybackStartResult.cancelled);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}
