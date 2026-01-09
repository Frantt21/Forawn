import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:palette_generator/palette_generator.dart';

import '../services/global_music_player.dart';
import '../services/music_history.dart';
import '../services/album_color_cache.dart';
import '../services/global_theme_service.dart';
import '../models/synced_lyrics.dart';
import '../services/lyrics_service.dart';
import 'lyrics_display_widget.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class PlayerScreen extends StatefulWidget {
  final TextGetter getText;

  const PlayerScreen({super.key, required this.getText});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final GlobalMusicPlayer _musicPlayer = GlobalMusicPlayer();
  late AudioPlayer _player;
  late FocusNode _focusNode;

  // Local state
  bool _showPlaylist = false;
  bool _useBlurBackground = false;
  bool _toggleLocked = false;

  // UI colors/state
  Color? _dominantColor;
  Uint8List? _currentArt;
  String _currentTitle = '';
  String _currentArtist = '';

  // Playlist management
  List<FileSystemEntity> _files = [];
  List<FileSystemEntity> _filteredFiles = [];
  final TextEditingController _searchController = TextEditingController();
  final Set<int> _playedIndices = {};

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _player = _musicPlayer.player;

    // Sync initial state
    _useBlurBackground = GlobalThemeService().blurBackground.value;
    _files = List<FileSystemEntity>.from(_musicPlayer.filesList.value);
    _filteredFiles = _files;

    // Sync song info
    _currentTitle = _musicPlayer.currentTitle.value;
    _currentArtist = _musicPlayer.currentArtist.value;
    _currentArt = _musicPlayer.currentArt.value;

    // Initial color extraction
    if (_musicPlayer.currentFilePath.value.isNotEmpty) {
      final cachedColor = AlbumColorCache().getColor(
        _musicPlayer.currentFilePath.value,
      );
      if (cachedColor != null) {
        _dominantColor = cachedColor;
      } else if (_currentArt != null) {
        _extractColor(_currentArt!);
      }
    }

    // Listeners
    GlobalThemeService().blurBackground.addListener(_onBlurChanged);
    _musicPlayer.filesList.addListener(_onFilesChanged);
    _musicPlayer.currentArt.addListener(_onArtChanged);
    _musicPlayer.currentTitle.addListener(_onTitleChanged);
    _musicPlayer.currentArtist.addListener(_onArtistChanged);

    // Keyboard listeners are handled by RawKeyboardListener in build
  }

  @override
  void dispose() {
    GlobalThemeService().blurBackground.removeListener(_onBlurChanged);
    _musicPlayer.filesList.removeListener(_onFilesChanged);
    _musicPlayer.currentArt.removeListener(_onArtChanged);
    _musicPlayer.currentTitle.removeListener(_onTitleChanged);
    _musicPlayer.currentArtist.removeListener(_onArtistChanged);
    _focusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onBlurChanged() {
    if (mounted)
      setState(
        () => _useBlurBackground = GlobalThemeService().blurBackground.value,
      );
  }

  void _onFilesChanged() {
    if (mounted) {
      setState(() {
        _files = List<FileSystemEntity>.from(_musicPlayer.filesList.value);
        _filterFiles(_searchController.text);
      });
    }
  }

  void _onArtChanged() {
    final art = _musicPlayer.currentArt.value;
    if (mounted) {
      setState(() => _currentArt = art);
      if (art != null) {
        // Try get from cache first
        if (_musicPlayer.currentFilePath.value.isNotEmpty) {
          final cached = AlbumColorCache().getColor(
            _musicPlayer.currentFilePath.value,
          );
          if (cached != null) {
            setState(() => _dominantColor = cached);
            return;
          }
        }
        _extractColor(art);
      } else {
        setState(() => _dominantColor = null);
      }
    }
  }

  void _onTitleChanged() {
    if (mounted)
      setState(() => _currentTitle = _musicPlayer.currentTitle.value);
  }

  void _onArtistChanged() {
    if (mounted)
      setState(() => _currentArtist = _musicPlayer.currentArtist.value);
  }

  Future<void> _extractColor(Uint8List bytes) async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        MemoryImage(bytes),
        size: const Size(50, 50),
      );
      if (mounted) {
        setState(() {
          _dominantColor =
              palette.dominantColor?.color ?? palette.vibrantColor?.color;
        });
        // Save to cache
        if (_dominantColor != null &&
            _musicPlayer.currentFilePath.value.isNotEmpty) {
          await AlbumColorCache().setColor(
            _musicPlayer.currentFilePath.value,
            _dominantColor!,
          );
        }
      }
    } catch (_) {}
  }

  Color _adjustColorForControls(Color? color) {
    if (color == null) return Colors.white;
    // Return the color itself if possible, but ensuring it's visible on dark background
    // If background is transparent/black, we want bright colors.
    // Use HSL to guarantee brightness
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness < 0.3) {
      return hsl.withLightness(0.6).toColor();
    }
    return color;
  }

  Color _getContrastColor(Color color) {
    return color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  void _togglePlaylist() {
    if (_toggleLocked) return;
    _toggleLocked = true;
    setState(() => _showPlaylist = !_showPlaylist);
    Future.delayed(
      const Duration(milliseconds: 350),
      () => _toggleLocked = false,
    );
  }

  void _filterFiles(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredFiles = _files;
      } else {
        _filteredFiles = _files.where((file) {
          final fileName = p.basename(file.path).toLowerCase();
          return fileName.contains(query.toLowerCase());
        }).toList();
      }
    });
  }

  // --- Playback Logic (Simplified duplication of MusicPlayerScreen logic for robustness) ---

  int _getNextShuffleIndex() {
    final availableIndices = List.generate(
      _files.length,
      (i) => i,
    ).where((i) => !_playedIndices.contains(i)).toList();

    if (availableIndices.isEmpty) {
      _playedIndices.clear();
      return Random().nextInt(_files.length);
    }
    return availableIndices[Random().nextInt(availableIndices.length)];
  }

  Future<void> _playFile(int index) async {
    if (index < 0 || index >= _files.length) return;
    _playedIndices.add(index);
    final file = _files[index] as File;

    try {
      await _player.stop();
      await _player.play(DeviceFileSource(file.path));

      // 1. Basic Title fallback
      final parsedTitle = p.basename(file.path);

      String title = parsedTitle;
      String artist = 'Unknown Artist';
      Uint8List? artwork;

      // 2. Read Metadata
      try {
        final metadata = readMetadata(file, getImage: true);
        title = metadata.title?.isNotEmpty == true
            ? metadata.title!
            : parsedTitle;
        artist = metadata.artist?.isNotEmpty == true
            ? metadata.artist!
            : 'Unknown Artist';
        if (metadata.pictures.isNotEmpty) {
          artwork = metadata.pictures.first.bytes;
        }
      } catch (_) {}

      // 3. Update Global State
      // CRITICAL: Update path FIRST so listeners (like _onArtChanged) see the NEW song's path.
      _musicPlayer.currentFilePath.value = file.path;
      _musicPlayer.currentIndex.value = index;
      _musicPlayer.currentTitle.value = title;
      _musicPlayer.currentArtist.value = artist;

      // Update Art LAST so listeners read correct Path for caching
      _musicPlayer.currentArt.value = artwork;
      _musicPlayer.isPlaying.value = true;

      MusicHistory().addToHistory(file);

      // 4. Update Color (reset if null, otherwise listener handles it)
      if (artwork == null) {
        if (mounted) setState(() => _dominantColor = null);
      }

      // 5. Fetch Lyrics
      _musicPlayer.currentLyrics.value = null;
      LyricsService().fetchLyrics(title, artist).then((lyrics) {
        if (mounted) {
          _musicPlayer.currentLyrics.value = lyrics;
        }
      });
    } catch (e) {
      debugPrint("Error playing file: $e");
    }
  }

  void _playPrevious() {
    // 1. Try History logic
    final prevFile = MusicHistory().getPreviousTrack();
    if (prevFile != null) {
      final index = _files.indexWhere((f) => f.path == prevFile.path);
      if (index != -1) {
        _playFile(index);
        return;
      }
    }

    // 2. Fallback
    final currentIndex = _musicPlayer.currentIndex.value ?? 0;
    if (_files.isEmpty) return;
    int newIndex;

    // Linear back (ignoring shuffle for fallback)
    newIndex = currentIndex - 1;
    if (newIndex < 0) newIndex = _files.length - 1;

    _playFile(newIndex);
  }

  void _playNext() {
    final currentIndex = _musicPlayer.currentIndex.value ?? 0;
    if (_files.isEmpty) return;
    int newIndex;

    // Check Shuffle
    if (_musicPlayer.isShuffle.value == true) {
      newIndex = _getNextShuffleIndex();
    } else {
      newIndex = currentIndex + 1;
      if (newIndex >= _files.length) newIndex = 0;
    }
    _playFile(newIndex);
  }

  void _togglePlayPause() async {
    if (_musicPlayer.isPlaying.value) {
      await _player.pause();
    } else {
      await _player.resume();
    }
  }

  void _handleKeyboardEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.f9) _playPrevious();
    if (event.logicalKey == LogicalKeyboardKey.f10) _togglePlayPause();
    if (event.logicalKey == LogicalKeyboardKey.f11) _playNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Important: Use transparent/black scaffold to let logic draw background
      backgroundColor: Colors.black,
      body: RawKeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKey: _handleKeyboardEvent,
        child: Stack(
          children: [
            // Row Layout
            Row(
              children: [
                // Main Player Area
                Expanded(
                  flex: 3,
                  child: Stack(
                    children: [
                      // Blur Background
                      if (_useBlurBackground && _currentArt != null)
                        Positioned.fill(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 800),
                            child: ImageFiltered(
                              key: ValueKey(_currentTitle),
                              imageFilter: ImageFilter.blur(
                                sigmaX: 30,
                                sigmaY: 30,
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                  image: DecorationImage(
                                    image: MemoryImage(_currentArt!),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                child: Container(
                                  color: _dominantColor != null
                                      ? _dominantColor!.withOpacity(0.75)
                                      : Colors.black.withOpacity(0.8),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Dynamic color background if blur is off
                      if (!_useBlurBackground)
                        Container(
                          color: _dominantColor != null
                              ? _dominantColor!.withOpacity(0.1)
                              : Colors.black,
                        ),

                      // Back button overlay
                      Positioned(
                        top: 16,
                        left: 16,
                        child: IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),

                      // Content
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: _musicPlayer.showLyrics,
                              builder: (context, showLyrics, _) {
                                return Expanded(
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 500),
                                    child: showLyrics
                                        ? Row(
                                            key: const ValueKey(
                                              'lyrics_split_view',
                                            ),
                                            children: [
                                              // Artwork (Small)
                                              Expanded(
                                                flex: 1,
                                                child: LayoutBuilder(
                                                  builder: (context, constraints) {
                                                    return SingleChildScrollView(
                                                      child: ConstrainedBox(
                                                        constraints:
                                                            BoxConstraints(
                                                              minHeight:
                                                                  constraints
                                                                      .maxHeight,
                                                            ),
                                                        child: Column(
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .center,
                                                          children: [
                                                            AspectRatio(
                                                              aspectRatio: 1,
                                                              child: Container(
                                                                decoration: BoxDecoration(
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        20,
                                                                      ),
                                                                  boxShadow: [
                                                                    BoxShadow(
                                                                      color: Colors
                                                                          .black45,
                                                                      blurRadius:
                                                                          20,
                                                                    ),
                                                                  ],
                                                                  image:
                                                                      _currentArt !=
                                                                          null
                                                                      ? DecorationImage(
                                                                          image: MemoryImage(
                                                                            _currentArt!,
                                                                          ),
                                                                          fit: BoxFit
                                                                              .cover,
                                                                        )
                                                                      : null,
                                                                  color: Colors
                                                                      .white12,
                                                                ),
                                                                child:
                                                                    _currentArt ==
                                                                        null
                                                                    ? const Icon(
                                                                        Icons
                                                                            .music_note,
                                                                        size:
                                                                            80,
                                                                        color: Colors
                                                                            .white12,
                                                                      )
                                                                    : null,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 20,
                                                            ),
                                                            Text(
                                                              _currentTitle
                                                                      .isEmpty
                                                                  ? widget.getText(
                                                                      'no_song',
                                                                      fallback:
                                                                          'No Song',
                                                                    )
                                                                  : _currentTitle,
                                                              style: const TextStyle(
                                                                fontSize: 24,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                color: Colors
                                                                    .white,
                                                              ),
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                            ),
                                                            Text(
                                                              _currentArtist,
                                                              style: TextStyle(
                                                                fontSize: 16,
                                                                color: _adjustColorForControls(
                                                                  _dominantColor,
                                                                ),
                                                              ),
                                                              textAlign:
                                                                  TextAlign
                                                                      .center,
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                              const SizedBox(width: 48),
                                              // Lyrics
                                              Expanded(
                                                flex: 1,
                                                child: ValueListenableBuilder<SyncedLyrics?>(
                                                  valueListenable: _musicPlayer
                                                      .currentLyrics,
                                                  builder: (context, lyrics, _) {
                                                    if (lyrics == null ||
                                                        !lyrics.hasLyrics) {
                                                      return Center(
                                                        child: Text(
                                                          widget.getText(
                                                            'no_lyrics',
                                                            fallback:
                                                                'No Lyrics Found',
                                                          ),
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white54,
                                                                fontSize: 18,
                                                              ),
                                                        ),
                                                      );
                                                    }
                                                    return LyricsDisplay(
                                                      lyrics: lyrics,
                                                      currentIndexNotifier:
                                                          _musicPlayer
                                                              .currentLyricIndex,
                                                      getText: widget.getText,
                                                    );
                                                  },
                                                ),
                                              ),
                                            ],
                                          )
                                        : Column(
                                            key: const ValueKey('cover_art'),
                                            children: [
                                              const Spacer(),
                                              Flexible(
                                                flex: 12,
                                                child: AspectRatio(
                                                  aspectRatio: 1,
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            20,
                                                          ),
                                                      boxShadow: [
                                                        if (_dominantColor !=
                                                            null)
                                                          BoxShadow(
                                                            color:
                                                                _dominantColor!
                                                                    .withOpacity(
                                                                      0.5,
                                                                    ),
                                                            blurRadius: 40,
                                                            spreadRadius: 5,
                                                          ),
                                                        const BoxShadow(
                                                          color: Colors.black45,
                                                          blurRadius: 20,
                                                        ),
                                                      ],
                                                      image: _currentArt != null
                                                          ? DecorationImage(
                                                              image: MemoryImage(
                                                                _currentArt!,
                                                              ),
                                                              fit: BoxFit.cover,
                                                            )
                                                          : null,
                                                      color: Colors.white12,
                                                    ),
                                                    child: _currentArt == null
                                                        ? const Icon(
                                                            Icons.music_note,
                                                            size: 120,
                                                            color:
                                                                Colors.white12,
                                                          )
                                                        : null,
                                                  ),
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                _currentTitle.isEmpty
                                                    ? widget.getText(
                                                        'no_song',
                                                        fallback: 'No Song',
                                                      )
                                                    : _currentTitle,
                                                style: const TextStyle(
                                                  fontSize: 28,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white,
                                                ),
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                _currentArtist,
                                                style: TextStyle(
                                                  fontSize: 18,
                                                  color:
                                                      _adjustColorForControls(
                                                        _dominantColor,
                                                      ),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ],
                                          ),
                                  ),
                                );
                              },
                            ),

                            const SizedBox(height: 24),

                            // Controls
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.shuffle,
                                        color: _musicPlayer.isShuffle.value
                                            ? _adjustColorForControls(
                                                _dominantColor,
                                              )
                                            : Colors.white54,
                                      ),
                                      onPressed: () {
                                        _musicPlayer.isShuffle.value =
                                            !_musicPlayer.isShuffle.value;
                                        setState(() {});
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(
                                        _musicPlayer.loopMode.value ==
                                                LoopMode.one
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        color:
                                            _musicPlayer.loopMode.value !=
                                                LoopMode.off
                                            ? _adjustColorForControls(
                                                _dominantColor,
                                              )
                                            : Colors.white54,
                                      ),
                                      onPressed: () {
                                        final modes = [
                                          LoopMode.off,
                                          LoopMode.all,
                                          LoopMode.one,
                                        ];
                                        final idx = modes.indexOf(
                                          _musicPlayer.loopMode.value,
                                        );
                                        _musicPlayer.loopMode.value =
                                            modes[(idx + 1) % modes.length];
                                        setState(() {});
                                      },
                                    ),

                                    const SizedBox(width: 16),

                                    IconButton(
                                      icon: Icon(
                                        Icons.skip_previous_rounded,
                                        size: 48,
                                        color: _adjustColorForControls(
                                          _dominantColor,
                                        ),
                                      ),
                                      onPressed: _playPrevious,
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      decoration: BoxDecoration(
                                        color: _adjustColorForControls(
                                          _dominantColor,
                                        ),
                                        shape: BoxShape.circle,
                                      ),
                                      child: IconButton(
                                        icon: ValueListenableBuilder<bool>(
                                          valueListenable:
                                              _musicPlayer.isPlaying,
                                          builder: (ctx, isPlaying, _) => Icon(
                                            isPlaying
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            color: _getContrastColor(
                                              _adjustColorForControls(
                                                _dominantColor,
                                              ),
                                            ),
                                            size: 40,
                                          ),
                                        ),
                                        onPressed: _togglePlayPause,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: Icon(
                                        Icons.skip_next_rounded,
                                        size: 48,
                                        color: _adjustColorForControls(
                                          _dominantColor,
                                        ),
                                      ),
                                      onPressed: _playNext,
                                    ),

                                    const SizedBox(width: 24),

                                    // Volume
                                    Icon(
                                      Icons.volume_up,
                                      color: _adjustColorForControls(
                                        _dominantColor,
                                      ).withOpacity(0.7),
                                      size: 20,
                                    ),
                                    SizedBox(
                                      width: 120,
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 2,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                enabledThumbRadius: 5,
                                              ),
                                          activeTrackColor:
                                              _adjustColorForControls(
                                                _dominantColor,
                                              ).withOpacity(0.7),
                                          inactiveTrackColor: Colors.white10,
                                          thumbColor: _adjustColorForControls(
                                            _dominantColor,
                                          ),
                                        ),
                                        child: Slider(
                                          value: _musicPlayer.volume.value,
                                          onChanged: (v) async {
                                            _musicPlayer.volume.value = v;
                                            _musicPlayer.isMuted.value = v == 0;
                                            await _player.setVolume(v);
                                            setState(() {});
                                          },
                                        ),
                                      ),
                                    ),

                                    const SizedBox(width: 16),

                                    // Lyrics Toggle
                                    ValueListenableBuilder<bool>(
                                      valueListenable: _musicPlayer.showLyrics,
                                      builder: (context, showLyrics, _) {
                                        return IconButton(
                                          icon: Icon(
                                            showLyrics
                                                ? Icons.lyrics
                                                : Icons.lyrics_outlined,
                                            color: showLyrics
                                                ? _adjustColorForControls(
                                                    _dominantColor,
                                                  )
                                                : Colors.white54,
                                          ),
                                          onPressed: () =>
                                              _musicPlayer.showLyrics.value =
                                                  !showLyrics,
                                        );
                                      },
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 24),

                                // Progress Bar
                                StreamBuilder<Duration>(
                                  stream: _player.onPositionChanged,
                                  builder: (context, snapshot) {
                                    final position =
                                        snapshot.data ?? Duration.zero;
                                    final duration =
                                        _musicPlayer.duration.value;
                                    return Column(
                                      children: [
                                        SliderTheme(
                                          data: SliderTheme.of(context)
                                              .copyWith(
                                                trackHeight: 2,
                                                thumbShape:
                                                    const RoundSliderThumbShape(
                                                      enabledThumbRadius: 6,
                                                    ),
                                                activeTrackColor:
                                                    _adjustColorForControls(
                                                      _dominantColor,
                                                    ),
                                                inactiveTrackColor:
                                                    Colors.white10,
                                                thumbColor:
                                                    _adjustColorForControls(
                                                      _dominantColor,
                                                    ),
                                              ),
                                          child: Slider(
                                            value: position.inSeconds
                                                .toDouble()
                                                .clamp(
                                                  0.0,
                                                  duration.inSeconds.toDouble(),
                                                ),
                                            max:
                                                duration.inSeconds.toDouble() >
                                                    0
                                                ? duration.inSeconds.toDouble()
                                                : 1.0,
                                            onChanged: (v) => _player.seek(
                                              Duration(seconds: v.toInt()),
                                            ),
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 24,
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                _formatDuration(position),
                                                style: const TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              Text(
                                                _formatDuration(duration),
                                                style: const TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Playlist Sidebar
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: _showPlaylist ? 350 : 0,
                  color: Colors.black.withOpacity(0.9),
                  child: Offstage(
                    offstage: !_showPlaylist,
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: Colors.white.withOpacity(0.1),
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.queue_music,
                                color: Colors.purpleAccent,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                widget.getText(
                                  'playlist_title',
                                  fallback: 'Start List',
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: Colors.white,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  size: 20,
                                  color: Colors.white,
                                ),
                                onPressed: () =>
                                    setState(() => _showPlaylist = false),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: TextField(
                            controller: _searchController,
                            onChanged: _filterFiles,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: widget.getText(
                                'search_song',
                                fallback: 'Search in list...',
                              ),
                              hintStyle: const TextStyle(color: Colors.white54),
                              prefixIcon: const Icon(
                                Icons.search,
                                size: 20,
                                color: Colors.white54,
                              ),
                              filled: true,
                              fillColor: Colors.white10,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _filteredFiles.length,
                            itemBuilder: (context, index) {
                              final file = _filteredFiles[index] as File;
                              final name = p.basename(file.path);
                              final isPlaying =
                                  _musicPlayer.currentFilePath.value ==
                                  file.path;
                              return Material(
                                color: isPlaying
                                    ? Colors.purpleAccent.withOpacity(0.1)
                                    : Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    final realIndex = _files.indexOf(file);
                                    if (realIndex != -1) _playFile(realIndex);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        if (isPlaying)
                                          const Padding(
                                            padding: EdgeInsets.only(right: 12),
                                            child: Icon(
                                              Icons.equalizer,
                                              color: Colors.purpleAccent,
                                              size: 20,
                                            ),
                                          )
                                        else
                                          const Padding(
                                            padding: EdgeInsets.only(right: 12),
                                            child: Text(
                                              "•",
                                              style: TextStyle(
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ),
                                        Expanded(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: isPlaying
                                                  ? Colors.purpleAccent
                                                  : Colors.white,
                                              fontWeight: isPlaying
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Toggle Strip
                Container(
                  width: 40,
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          _showPlaylist
                              ? Icons.chevron_right
                              : Icons.chevron_left,
                          color: Colors.white60,
                        ),
                        onPressed: _togglePlaylist,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
