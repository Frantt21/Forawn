import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:forawn/services/global_music_player.dart';
import 'package:forawn/services/local_music_database.dart';
import 'package:forawn/services/metadata_service.dart';
import 'package:path/path.dart' as p;

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
    if (_initialized) return;
    if (!Platform.isWindows) return;

    try {
      debugPrint('[WindowMediaService] Initializing SMTCWindows...');
      await SMTCWindows.initialize();

      final title = _player.currentTitle.value;
      final artist = _player.currentArtist.value;
      final duration = _player.duration.value;

      // Prepare initial thumbnail if available
      String? initialThumbnail;
      final currentPath = _player.currentFilePath.value;
      if (currentPath.isNotEmpty) {
        final cachedPath = await LocalMusicDatabase().getCachedArtworkPath(
          currentPath,
        );
        if (cachedPath != null) {
          initialThumbnail = Uri.file(cachedPath).toString();
        }
      }

      debugPrint(
        '[WindowMediaService] Creating instance with initial metadata',
      );
      _smtc = SMTCWindows(
        config: const SMTCConfig(
          fastForwardEnabled: true,
          nextEnabled: true,
          pauseEnabled: true,
          playEnabled: true,
          prevEnabled: true,
          rewindEnabled: true,
          stopEnabled: true,
        ),
        metadata: MusicMetadata(
          title: title.isNotEmpty ? title : 'Forawn',
          artist: artist.isNotEmpty ? artist : 'Forawn Music',
          album: 'Forawn Music',
          albumArtist: artist,
          thumbnail: initialThumbnail,
        ),
        timeline: PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: duration.inMilliseconds,
          positionMs: 0,
        ),
      );

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

    _smtc!.buttonPressStream.listen((event) {
      switch (event) {
        case PressedButton.play:
          _player.player.resume();
          _smtc?.setPlaybackStatus(PlaybackStatus.playing);
          break;
        case PressedButton.pause:
          _player.player.pause();
          _smtc?.setPlaybackStatus(PlaybackStatus.paused);
          break;
        case PressedButton.stop:
          _player.player.stop();
          _smtc?.setPlaybackStatus(PlaybackStatus.stopped);
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

    // Initial update verified in constructor, but update status again
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

    String? finalThumbnailUri;

    // Use cached/temp artwork logic, but ensure it ends up as URI
    if (currentFilePath.isNotEmpty) {
      final thumbnailPath = await LocalMusicDatabase().getCachedArtworkPath(
        currentFilePath,
      );
      if (thumbnailPath != null) {
        try {
          // Use temp copy logic
          final fileName = p.basename(thumbnailPath);
          final tempDir = Directory.systemTemp;
          final tempFile = File(p.join(tempDir.path, 'forawn_smtc_$fileName'));

          if (!await tempFile.exists()) {
            await File(thumbnailPath).copy(tempFile.path);
            debugPrint(
              '[WindowMediaService] Copied art to temp: ${tempFile.path}',
            );
          }
          // Convert to URI
          finalThumbnailUri = Uri.file(tempFile.path).toString();
        } catch (e) {
          debugPrint('[WindowMediaService] Art copy error: $e');
          // Fallback to original path as URI
          finalThumbnailUri = Uri.file(thumbnailPath).toString();
        }
      }
    }

    // Try to fetch online artwork (Discord style)
    try {
      final metadata = await MetadataService().searchMetadata(title, artist);
      if (metadata?.albumArtUrl != null && metadata!.albumArtUrl!.isNotEmpty) {
        finalThumbnailUri = metadata.albumArtUrl;
      }
    } catch (e) {
      debugPrint('[WindowMediaService] Error fetching online artwork: $e');
    }

    debugPrint(
      '[WindowMediaService] Updating Metadata: $title, Art: $finalThumbnailUri',
    );

    _smtc!.updateMetadata(
      MusicMetadata(
        title: title,
        artist: artist,
        album: album,
        albumArtist: artist,
        thumbnail: finalThumbnailUri,
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
