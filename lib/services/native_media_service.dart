import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:forawn/services/global_music_player.dart';

// Late initialization via initNativeMediaService
late AudioHandler nativeAudioHandler;

Future<void> initNativeMediaService() async {
  nativeAudioHandler = await AudioService.init(
    builder: () => NativeMediaService(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.forawn.app.audio',
      androidNotificationChannelName: 'Forawn Music',
      androidNotificationOngoing: true,
      // Windows configuration relies on metadata updates
    ),
  );
}

class NativeMediaService extends BaseAudioHandler {
  final GlobalMusicPlayer _player = GlobalMusicPlayer();

  NativeMediaService() {
    _initListeners();
  }

  void _initListeners() {
    // Listen to player state changes
    _player.isPlaying.addListener(_broadcastPlaybackState);
    _player.position.addListener(_broadcastPlaybackState);

    // Listen to metadata changes
    _player.currentTitle.addListener(_broadcastMediaItem);
    _player.currentArtist.addListener(_broadcastMediaItem);
    _player.currentArt.addListener(_broadcastMediaItem);
    _player.duration.addListener(_broadcastMediaItem);

    // Initial broadcast
    _broadcastMediaItem();
    _broadcastPlaybackState();
  }

  void _broadcastMediaItem() {
    final title = _player.currentTitle.value;
    final artist = _player.currentArtist.value;
    final duration = _player.duration.value;

    if (title.isEmpty) return;

    // Convert artBytes to Uri if possible, or just ignore for now if platform doesn't support bytes directly
    // AudioService supports content:// or file:// but raw bytes need a custom content provider or just omitted.
    // However, on Windows, SMTC might pick up ArtUri if it's a file path.
    // GlobalMusicPlayer has currentFilePath.
    final path = _player.currentFilePath.value;

    // Attempt to use local file URI for artwork if we don't have bytes-to-uri mapping handy
    // But typically SMTC on Windows prefers explicit connection.
    // Newer audio_service windows implementation might handle things differently.
    // For now we set basic text metadata.

    final item = MediaItem(
      id: path,
      album: 'Forawn Music',
      title: title,
      artist: artist,
      duration: duration,
      artUri: Uri.file(path),
    );

    mediaItem.add(item);
  }

  void _broadcastPlaybackState() {
    final playing = _player.isPlaying.value;
    final position = _player.position.value;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.stop,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: position,
        bufferedPosition: position,
        speed: 1.0,
        queueIndex: _player.currentIndex.value,
      ),
    );
  }

  @override
  Future<void> play() async {
    await _player.player.resume();
  }

  @override
  Future<void> pause() async {
    await _player.player.pause();
  }

  @override
  Future<void> stop() async {
    await _player.player.stop();
  }

  @override
  Future<void> skipToNext() async {
    debugPrint('[NativeMediaService] Skip to next');
    await _player.playNext();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint('[NativeMediaService] Skip to previous');
    await _player.playPrevious();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.player.seek(position);
  }
}
