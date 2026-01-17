import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:smtc_windows/src/rust/frb_generated.dart';
import 'package:forawn/services/global_music_player.dart';
import 'package:forawn/services/local_music_database.dart';

class WindowMediaService {
  static final WindowMediaService _instance = WindowMediaService._internal();

  factory WindowMediaService() {
    return _instance;
  }

  WindowMediaService._internal();

  SMTCWindows? _smtc;
  final GlobalMusicPlayer _player = GlobalMusicPlayer();
  bool _initialized = false;

  Future<void> initialize() async {
    debugPrint('[WindowMediaService] initialize() called');
    if (_initialized) {
      debugPrint('[WindowMediaService] Already initialized');
      return;
    }
    if (!Platform.isWindows) {
      debugPrint('[WindowMediaService] Not Windows');
      return;
    }

    try {
      debugPrint('[WindowMediaService] Initializing RustLib...');
      await RustLib.init();
      debugPrint('[WindowMediaService] Creating SMTCWindows instance...');
      _smtc = SMTCWindows(
        config: SMTCConfig(
          fastForwardEnabled: true,
          nextEnabled: true,
          pauseEnabled: true,
          playEnabled: true,
          prevEnabled: true,
          rewindEnabled: true,
          stopEnabled: true,
        ),
      );
      debugPrint('[WindowMediaService] SMTCWindows instance created');

      _initListeners();
      _initialized = true;
      debugPrint('[WindowMediaService] Initialized SMTC Windows');
    } catch (e, stack) {
      debugPrint('[WindowMediaService] Error initializing SMTC: $e');
      debugPrint(stack.toString());
    }
  }

  void _initListeners() {
    if (_smtc == null) return;

    // Listen to SMTC buttons
    _smtc!.buttonPressStream.listen((event) {
      switch (event) {
        case PressedButton.play:
          _player.player.resume();
          break;
        case PressedButton.pause:
          _player.player.pause();
          break;
        case PressedButton.stop:
          _player.player.stop();
          break;
        case PressedButton.next:
          _player.playNext();
          break;
        case PressedButton.previous:
          _player.playPrevious();
          break;
        case PressedButton.fastForward:
        case PressedButton.rewind:
          // Optional: handle seek or skip logic
          break;
        default:
          break;
      }
    });

    // Listen to player state to update SMTC
    _player.currentTitle.addListener(_onMetadataChanged);
    _player.currentArtist.addListener(_onMetadataChanged);
    _player.currentArt.addListener(_onMetadataChanged);
    _player.isPlaying.addListener(_updatePlaybackStatus);
    _player.position.addListener(_updateTimeline);
    _player.duration.addListener(_updateTimeline);

    // Initial update
    _onMetadataChanged();
    _updatePlaybackStatus();
  }

  // Wrapper to handle async void listener
  void _onMetadataChanged() {
    _updateMetadata();
  }

  Future<void> _updateMetadata() async {
    if (_smtc == null) return;
    final title = _player.currentTitle.value;
    final artist = _player.currentArtist.value;
    final album = 'Forawn Music';
    final currentFilePath = _player.currentFilePath.value;

    String? thumbnailPath;
    if (currentFilePath.isNotEmpty) {
      // Try to get cached jpg artwork first
      thumbnailPath = await LocalMusicDatabase().getCachedArtworkPath(
        currentFilePath,
      );

      if (thumbnailPath != null) {
        debugPrint('[WindowMediaService] Found cached artwork: $thumbnailPath');
        debugPrint(
          '[WindowMediaService] File exists: ${File(thumbnailPath).existsSync()}',
        );
      } else {
        debugPrint(
          '[WindowMediaService] No cached artwork found for: $currentFilePath',
        );
        // Fallback to file path if no cached art
        thumbnailPath = currentFilePath;
      }
    }

    // Ensure we are passing a valid absolute path or URI if required
    // For now, just logging.
    debugPrint(
      '[WindowMediaService] Updating SMTC: $title - $artist, Art: $thumbnailPath',
    );

    _smtc!.updateMetadata(
      MusicMetadata(
        title: title,
        artist: artist,
        album: album,
        thumbnail: thumbnailPath,
      ),
    );
  }

  void _updatePlaybackStatus() {
    if (_smtc == null) return;
    final isPlaying = _player.isPlaying.value;
    _smtc!.setPlaybackStatus(
      isPlaying ? PlaybackStatus.playing : PlaybackStatus.paused,
    );
  }

  void _updateTimeline() {
    if (_smtc == null) return;
    final position = _player.position.value;
    final duration = _player.duration.value;

    _smtc!.setTimeline(
      PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: duration.inMilliseconds,
        positionMs: position.inMilliseconds,
      ),
    );
  }

  void dispose() {
    if (_smtc != null) {
      _smtc!.dispose();
      _smtc = null;
    }
  }
}
