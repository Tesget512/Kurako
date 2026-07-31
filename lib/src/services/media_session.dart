import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';

import '../rust/models.dart';

KurakoMediaSessionHandler? kurakoMediaSession;

Future<void> initializeKurakoMediaSession() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  kurakoMediaSession = await AudioService.init<KurakoMediaSessionHandler>(
    builder: KurakoMediaSessionHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.tesget.kurako.playback',
      androidNotificationChannelName: 'Kurako 播放控制',
      androidNotificationChannelDescription: '显示当前视频的播放状态与控制按钮',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidStopForegroundOnPause: false,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
    ),
  );
}

class KurakoMediaSessionHandler extends BaseAudioHandler with SeekHandler {
  Player? _player;
  List<Episode> _episodes = const [];
  int _episodeIndex = 0;
  String _animeTitle = 'Kurako';
  Uri? _artUri;
  int _gestureSeekSeconds = 10;
  Future<void> Function()? _onPrevious;
  Future<void> Function()? _onNext;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  int _bindingGeneration = 0;
  DateTime _lastPositionPublish = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> bind({
    required Player player,
    required List<Episode> episodes,
    required int episodeIndex,
    required String animeTitle,
    required String? coverUrl,
    required int gestureSeekSeconds,
    required Future<void> Function() onPrevious,
    required Future<void> Function() onNext,
  }) async {
    final generation = ++_bindingGeneration;
    await _cancelPlayerSubscriptions();
    if (generation != _bindingGeneration) return;

    _player = player;
    _episodes = episodes;
    _episodeIndex = episodeIndex;
    _animeTitle = animeTitle.trim().isEmpty ? 'Kurako' : animeTitle.trim();
    _artUri = _safeNetworkUri(coverUrl);
    _gestureSeekSeconds = gestureSeekSeconds.clamp(5, 90);
    _onPrevious = onPrevious;
    _onNext = onNext;

    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration.music());
    if (generation != _bindingGeneration || !identical(_player, player)) return;
    _interruptionSubscription ??= session.interruptionEventStream.listen((
      event,
    ) {
      if (event.begin &&
          event.type != AudioInterruptionType.duck &&
          _player?.state.playing == true) {
        unawaited(_player?.pause());
      }
    });
    _becomingNoisySubscription ??= session.becomingNoisyEventStream.listen((_) {
      if (_player?.state.playing == true) unawaited(_player?.pause());
    });

    _subscriptions
      ..add(player.stream.playing.listen((_) => _publishState()))
      ..add(player.stream.duration.listen((_) => _publishMetadataAndState()))
      ..add(player.stream.buffer.listen((_) => _publishState()))
      ..add(player.stream.buffering.listen((_) => _publishState()))
      ..add(player.stream.completed.listen((_) => _publishState()))
      ..add(player.stream.rate.listen((_) => _publishState()))
      ..add(
        player.stream.position.listen((_) {
          final now = DateTime.now();
          if (now.difference(_lastPositionPublish) >=
              const Duration(seconds: 1)) {
            _lastPositionPublish = now;
            _publishState();
          }
        }),
      );

    _publishQueue();
    _publishMetadataAndState();
  }

  void updateEpisode(int index, {int? gestureSeekSeconds}) {
    if (_player == null || index < 0 || index >= _episodes.length) return;
    _episodeIndex = index;
    if (gestureSeekSeconds != null) {
      _gestureSeekSeconds = gestureSeekSeconds.clamp(5, 90);
    }
    _publishMetadataAndState();
  }

  Future<void> unbind(Player player) async {
    if (!identical(_player, player)) return;
    ++_bindingGeneration;
    _player = null;
    _episodes = const [];
    _episodeIndex = 0;
    _onPrevious = null;
    _onNext = null;
    await _cancelPlayerSubscriptions();
    queue.add(const []);
    mediaItem.add(null);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  Future<void> _cancelPlayerSubscriptions() async {
    final current = List<StreamSubscription<Object?>>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in current) {
      await subscription.cancel();
    }
  }

  Episode? get _episode =>
      _episodeIndex >= 0 && _episodeIndex < _episodes.length
      ? _episodes[_episodeIndex]
      : null;

  bool get _hasPrevious => _episodeIndex > 0;
  bool get _hasNext => _episodeIndex < _episodes.length - 1;

  void _publishQueue() {
    queue.add([for (final episode in _episodes) _mediaItemFor(episode)]);
  }

  void _publishMetadataAndState() {
    final episode = _episode;
    if (episode == null) return;
    mediaItem.add(_mediaItemFor(episode, duration: _player?.state.duration));
    _publishState();
  }

  MediaItem _mediaItemFor(Episode episode, {Duration? duration}) {
    final number = episode.episodeNo?.toInt();
    final title = episode.title?.trim();
    return MediaItem(
      id: 'kurako:episode:${episode.id}',
      album: _animeTitle,
      title: title != null && title.isNotEmpty
          ? title
          : number == null
          ? episode.fileName
          : '第 $number 集',
      displayTitle: title != null && title.isNotEmpty
          ? title
          : episode.fileName,
      displaySubtitle: number == null
          ? _animeTitle
          : '$_animeTitle · 第 $number 集',
      duration: duration != null && duration > Duration.zero
          ? duration
          : episode.durationMs.toInt() > 0
          ? Duration(milliseconds: episode.durationMs.toInt())
          : null,
      artUri: _artUri,
    );
  }

  void _publishState() {
    final player = _player;
    if (player == null) return;
    final state = player.state;
    final processingState = state.completed
        ? AudioProcessingState.completed
        : state.buffering
        ? AudioProcessingState.buffering
        : state.duration <= Duration.zero
        ? AudioProcessingState.loading
        : AudioProcessingState.ready;
    final controls = <MediaControl>[
      if (_hasPrevious) MediaControl.skipToPrevious,
      state.playing ? MediaControl.pause : MediaControl.play,
      if (_hasNext) MediaControl.skipToNext,
    ];
    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekBackward,
          MediaAction.seekForward,
        },
        androidCompactActionIndices: [
          for (var i = 0; i < controls.length; i++) i,
        ],
        processingState: processingState,
        playing: state.playing,
        updatePosition: state.position,
        bufferedPosition: state.buffer,
        speed: state.rate,
        queueIndex: _episodeIndex,
      ),
    );
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> setSpeed(double speed) async => _player?.setRate(speed);

  @override
  Future<void> skipToPrevious() async {
    if (_hasPrevious) await _onPrevious?.call();
  }

  @override
  Future<void> skipToNext() async {
    if (_hasNext) await _onNext?.call();
  }

  @override
  Future<void> rewind() async {
    final player = _player;
    if (player == null) return;
    final target =
        player.state.position - Duration(seconds: _gestureSeekSeconds);
    await player.seek(target < Duration.zero ? Duration.zero : target);
  }

  @override
  Future<void> fastForward() async {
    final player = _player;
    if (player == null) return;
    final target =
        player.state.position + Duration(seconds: _gestureSeekSeconds);
    final duration = player.state.duration;
    await player.seek(
      duration > Duration.zero && target > duration ? duration : target,
    );
  }
}

Uri? _safeNetworkUri(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri;
}
