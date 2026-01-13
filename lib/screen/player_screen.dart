import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;

import '../services/global_music_player.dart';
import '../services/music_history.dart';

import '../services/global_theme_service.dart';
import '../models/synced_lyrics.dart';

import 'lyrics_display_widget.dart';
import 'package:window_manager/window_manager.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class PlayerScreen extends StatefulWidget {
  final TextGetter getText;

  const PlayerScreen({super.key, required this.getText});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WindowListener {
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

  Future<void> _minimize() async => await windowManager.minimize();
  Future<void> _maximizeRestore() async {
    final isMax = await windowManager.isMaximized();
    if (isMax) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  void onWindowMaximize() {
    setState(() {});
  }

  @override
  void onWindowUnmaximize() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _focusNode = FocusNode();
    _player = _musicPlayer.player;

    // Sync initial state
    _useBlurBackground = GlobalThemeService().blurBackground.value;
    _dominantColor =
        GlobalThemeService().dominantColor.value; // Use global color directly
    _files = List<FileSystemEntity>.from(_musicPlayer.filesList.value);
    _filteredFiles = _files;

    // Sync song info
    _currentTitle = _musicPlayer.currentTitle.value;
    _currentArtist = _musicPlayer.currentArtist.value;
    _currentArt = _musicPlayer.currentArt.value;

    // Listeners
    GlobalThemeService().blurBackground.addListener(_onBlurChanged);
    GlobalThemeService().dominantColor.addListener(
      _onColorChanged,
    ); // Listen to global color
    _musicPlayer.filesList.addListener(_onFilesChanged);
    _musicPlayer.currentArt.addListener(_onArtChanged);
    _musicPlayer.currentTitle.addListener(_onTitleChanged);
    _musicPlayer.currentArtist.addListener(_onArtistChanged);

    // Keyboard listeners are handled by RawKeyboardListener in build
  }

  @override
  void dispose() {
    GlobalThemeService().blurBackground.removeListener(_onBlurChanged);
    GlobalThemeService().dominantColor.removeListener(_onColorChanged);
    _musicPlayer.filesList.removeListener(_onFilesChanged);
    _musicPlayer.currentArt.removeListener(_onArtChanged);
    _musicPlayer.currentTitle.removeListener(_onTitleChanged);
    _musicPlayer.currentArtist.removeListener(_onArtistChanged);
    _focusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onColorChanged() {
    if (mounted) {
      setState(() => _dominantColor = GlobalThemeService().dominantColor.value);
    }
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

  Future<void> _onArtChanged() async {
    final art = _musicPlayer.currentArt.value;
    if (mounted) {
      setState(() => _currentArt = art);
      // Color is handled by _onColorChanged via GlobalThemeService
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

  void _playFile(int index, {int? transitionDirection}) {
    if (index < 0 || index >= _files.length) return;
    _playedIndices.add(index);
    final file = _files[index] as File;

    debugPrint('[PlayerScreen] _playFile: index=$index, path=${file.path}');

    // 1. Set explicit direction if provided, otherwise infer or default to 1 (next)
    if (transitionDirection != null) {
      _musicPlayer.transitionDirection.value = transitionDirection;
    } else {
      final previousIdx = _musicPlayer.currentIndex.value;
      if (previousIdx != null) {
        // Fallback: simple comparison, though less reliable with shuffle
        _musicPlayer.transitionDirection.value = index > previousIdx ? 1 : -1;
      }
    }

    // 2. Update global state IMMEDIATELY (synchronous, no await)
    _musicPlayer.currentFilePath.value = file.path;
    _musicPlayer.currentIndex.value = index;
    _musicPlayer.isPlaying.value = true;

    // 3. Try to get metadata from pre-loaded songsList (instant, no I/O)
    final songs = _musicPlayer.songsList.value;
    final matchingSong = songs
        .where((s) => s.filePath == file.path)
        .firstOrNull;
    if (matchingSong != null) {
      _musicPlayer.currentTitle.value = matchingSong.title;
      _musicPlayer.currentArtist.value = matchingSong.artist;
      _musicPlayer.currentArt.value = matchingSong.artworkData;
      // Update theme color from pre-cached dominantColor (instant, no I/O)
      if (matchingSong.dominantColor != null) {
        GlobalThemeService().updateDominantColor(
          Color(matchingSong.dominantColor!),
        );
      }
    } else {
      // Fallback to filename if song not in preloaded list
      _musicPlayer.currentTitle.value = p.basenameWithoutExtension(file.path);
      _musicPlayer.currentArtist.value = 'Unknown Artist';
    }

    // 4. Audio operations - fire and forget (non-blocking)
    _player.stop().then((_) {
      _player.play(DeviceFileSource(file.path)).catchError((e) {
        debugPrint("Error playing file: $e");
      });
    });

    // 5. Background tasks (non-blocking)
    MusicHistory().addToHistory(file);
    // savePlayerState se llama automáticamente en el listener de pausa

    debugPrint('[PlayerScreen] _playFile: completed with metadata');
  }

  void _playPrevious() {
    // 1. Try History logic
    final prevFile = MusicHistory().getPreviousTrack();
    if (prevFile != null) {
      final index = _files.indexWhere((f) => f.path == prevFile.path);
      if (index != -1) {
        _playFile(index, transitionDirection: -1);
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

    _playFile(newIndex, transitionDirection: -1);
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
    _playFile(newIndex, transitionDirection: 1);
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
            // GLOBAL BACKGROUND
            if (_useBlurBackground && _currentArt != null)
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 800),
                  child: ImageFiltered(
                    key: ValueKey(_currentTitle),
                    imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
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

            if (!_useBlurBackground)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeInOut,
                  color: _dominantColor != null
                      ? _dominantColor!.withOpacity(0.1)
                      : Colors.black,
                ),
              ),

            // Row Layout
            Row(
              children: [
                // Main Player Area
                Expanded(
                  flex: 3,
                  child: Stack(
                    children: [
                      // Content (Background moved to root)

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
                                  child: IndexedStack(
                                    index: showLyrics ? 0 : 1,
                                    sizing: StackFit.expand,
                                    children: [
                                      // Lyrics View
                                      IgnorePointer(
                                        ignoring: !showLyrics,
                                        child: AnimatedOpacity(
                                          opacity: showLyrics ? 1.0 : 0.0,
                                          duration: const Duration(
                                            milliseconds: 0,
                                          ),
                                          child: SizedBox.expand(
                                            child: Column(
                                              key: const ValueKey(
                                                'lyrics_column_view',
                                              ),
                                              children: [
                                                // HEADER ROW: Artwork + Info + Controls
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 0,
                                                        right: 0,
                                                        top: 40,
                                                        bottom: 10,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      // Artwork (Small)
                                                      Container(
                                                        width: 80,
                                                        height: 80,
                                                        decoration: BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                8,
                                                              ),
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
                                                          color: Colors.white12,
                                                        ),
                                                        child:
                                                            _currentArt == null
                                                            ? const Icon(
                                                                Icons
                                                                    .music_note,
                                                                color: Colors
                                                                    .white54,
                                                              )
                                                            : null,
                                                      ),
                                                      const SizedBox(width: 16),

                                                      // Info: Title + Artist
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
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
                                                                fontSize: 20,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                color: Colors
                                                                    .white,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                            const SizedBox(
                                                              height: 4,
                                                            ),
                                                            Text(
                                                              _currentArtist,
                                                              style: TextStyle(
                                                                fontSize: 16,
                                                                color: _adjustColorForControls(
                                                                  _dominantColor,
                                                                ),
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                          ],
                                                        ),
                                                      ),

                                                      const SizedBox(width: 16),

                                                      // Mini Controls
                                                      Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          IconButton(
                                                            icon: Icon(
                                                              Icons
                                                                  .skip_previous_rounded,
                                                              color: _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                            ),
                                                            onPressed:
                                                                _playPrevious,
                                                          ),
                                                          Container(
                                                            decoration: BoxDecoration(
                                                              color: _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                              shape: BoxShape
                                                                  .circle,
                                                            ),
                                                            child: IconButton(
                                                              icon: ValueListenableBuilder<bool>(
                                                                valueListenable:
                                                                    _musicPlayer
                                                                        .isPlaying,
                                                                builder: (ctx, isPlaying, _) => Icon(
                                                                  isPlaying
                                                                      ? Icons
                                                                            .pause_rounded
                                                                      : Icons
                                                                            .play_arrow_rounded,
                                                                  color: _getContrastColor(
                                                                    _adjustColorForControls(
                                                                      _dominantColor,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                              onPressed:
                                                                  _togglePlayPause,
                                                            ),
                                                          ),
                                                          IconButton(
                                                            icon: Icon(
                                                              Icons
                                                                  .skip_next_rounded,
                                                              color: _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                            ),
                                                            onPressed:
                                                                _playNext,
                                                          ),
                                                          // Lyrics Toggle (to exit view)
                                                          IconButton(
                                                            icon: const Icon(
                                                              Icons.lyrics,
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                            onPressed: () =>
                                                                _musicPlayer
                                                                        .showLyrics
                                                                        .value =
                                                                    false,
                                                            tooltip: widget.getText(
                                                              'hide_lyrics',
                                                              fallback:
                                                                  'Hide Lyrics',
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),

                                                const Divider(
                                                  color: Colors.white12,
                                                  height: 30,
                                                ),

                                                // LYRICS AREA
                                                Expanded(
                                                  child: ValueListenableBuilder<SyncedLyrics?>(
                                                    valueListenable:
                                                        _musicPlayer
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
                                                        key: ValueKey(
                                                          _musicPlayer
                                                              .currentFilePath
                                                              .value,
                                                        ),
                                                        lyrics: lyrics,
                                                        currentIndexNotifier:
                                                            _musicPlayer
                                                                .currentLyricIndex,
                                                        positionNotifier:
                                                            _musicPlayer
                                                                .position,
                                                        getText: widget.getText,
                                                        textAlign:
                                                            TextAlign.start,
                                                        onTap: (timestamp) {
                                                          _player.seek(
                                                            timestamp,
                                                          );
                                                        },
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),

                                      // Cover Art View
                                      IgnorePointer(
                                        ignoring: showLyrics,
                                        child: AnimatedOpacity(
                                          opacity: showLyrics ? 0.0 : 1.0,
                                          duration: const Duration(
                                            milliseconds: 0,
                                          ),
                                          child: Column(
                                            key: const ValueKey('cover_art'),
                                            children: [
                                              const Spacer(),
                                              Flexible(
                                                flex: 12,
                                                child: AspectRatio(
                                                  aspectRatio: 1,
                                                  child: ValueListenableBuilder<bool>(
                                                    valueListenable: ValueNotifier(
                                                      true,
                                                    ), // Dummy wrapper to minimize changes if needed or just remove it.
                                                    builder: (context, _, __) {
                                                      return Container(
                                                        decoration: BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                20,
                                                              ),
                                                          boxShadow: [
                                                            if (_dominantColor !=
                                                                null)
                                                              BoxShadow(
                                                                color: _dominantColor!
                                                                    .withOpacity(
                                                                      0.5,
                                                                    ),
                                                                blurRadius: 40,
                                                                spreadRadius: 5,
                                                              ),
                                                            const BoxShadow(
                                                              color: Colors
                                                                  .black45,
                                                              blurRadius: 20,
                                                            ),
                                                          ],
                                                          color: Colors.white12,
                                                        ),
                                                        child: ClipRRect(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                20,
                                                              ),
                                                          child: AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      350,
                                                                ),
                                                            switchInCurve: Curves
                                                                .easeOutQuad,
                                                            switchOutCurve:
                                                                Curves
                                                                    .easeInQuad,
                                                            transitionBuilder: (child, animation) {
                                                              // Determine direction from GlobalMusicPlayer
                                                              // 1 = Next (Enter from Right), -1 = Prev (Enter from Left)
                                                              final direction =
                                                                  _musicPlayer
                                                                      .transitionDirection
                                                                      .value;

                                                              // Calculate offsets based on direction
                                                              final inBegin =
                                                                  Offset(
                                                                    direction
                                                                        .toDouble(),
                                                                    0.0,
                                                                  );
                                                              final outEnd = Offset(
                                                                -direction
                                                                    .toDouble(),
                                                                0.0,
                                                              );

                                                              final inAnimation =
                                                                  Tween<Offset>(
                                                                    begin:
                                                                        inBegin,
                                                                    end: Offset
                                                                        .zero,
                                                                  ).animate(
                                                                    CurvedAnimation(
                                                                      parent:
                                                                          animation,
                                                                      curve: Curves
                                                                          .easeOutQuad,
                                                                    ),
                                                                  );

                                                              final outAnimation =
                                                                  Tween<Offset>(
                                                                    begin:
                                                                        outEnd, // Start at -1 if dir=1 (Wait, no. Start at 0, end at -1)
                                                                    // BUT for exit, we map t=1->0 to Position.
                                                                    // We want child to move FROM 0 TO -1.
                                                                    // At t=1 (start), pos should be 0.
                                                                    // At t=0 (end), pos should be -1.
                                                                    // So Tween(begin: -1, end: 0) works because lerp(-1,0,1)=0, lerp(-1,0,0)=-1.
                                                                    // IF direction=1 (Next), we want exit to Left (-1). So Tween(-1, 0).
                                                                    // IF direction=-1 (Prev), we want exit to Right (1). So Tween(1, 0).
                                                                    end: Offset
                                                                        .zero,
                                                                  ).animate(
                                                                    CurvedAnimation(
                                                                      parent:
                                                                          animation,
                                                                      curve: Curves
                                                                          .easeInQuad,
                                                                    ),
                                                                  );

                                                              if (child.key ==
                                                                  ValueKey(
                                                                    _currentTitle,
                                                                  )) {
                                                                return SlideTransition(
                                                                  position:
                                                                      inAnimation,
                                                                  child: child,
                                                                );
                                                              } else {
                                                                return SlideTransition(
                                                                  position:
                                                                      outAnimation,
                                                                  child: child,
                                                                );
                                                              }
                                                            },
                                                            child: Container(
                                                              key: ValueKey(
                                                                _currentTitle,
                                                              ),
                                                              width: double
                                                                  .infinity,
                                                              height: double
                                                                  .infinity,
                                                              decoration:
                                                                  _currentArt !=
                                                                      null
                                                                  ? BoxDecoration(
                                                                      image: DecorationImage(
                                                                        image: MemoryImage(
                                                                          _currentArt!,
                                                                        ),
                                                                        fit: BoxFit
                                                                            .cover,
                                                                      ),
                                                                    )
                                                                  : null,
                                                              child:
                                                                  _currentArt ==
                                                                      null
                                                                  ? const Icon(
                                                                      Icons
                                                                          .music_note,
                                                                      size: 120,
                                                                      color: Colors
                                                                          .white12,
                                                                    )
                                                                  : null,
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    },
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
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),

                            ValueListenableBuilder<bool>(
                              valueListenable: _musicPlayer.showLyrics,
                              builder: (context, showLyrics, _) {
                                return AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 0),
                                  child: showLyrics
                                      ? const SizedBox.shrink()
                                      : Column(
                                          key: const ValueKey(
                                            'player_controls',
                                          ),
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const SizedBox(height: 24),
                                            // Controls
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    IconButton(
                                                      icon: Icon(
                                                        Icons.shuffle,
                                                        color:
                                                            _musicPlayer
                                                                .isShuffle
                                                                .value
                                                            ? _adjustColorForControls(
                                                                _dominantColor,
                                                              )
                                                            : Colors.white54,
                                                      ),
                                                      onPressed: () {
                                                        _musicPlayer
                                                                .isShuffle
                                                                .value =
                                                            !_musicPlayer
                                                                .isShuffle
                                                                .value;
                                                        setState(() {});
                                                      },
                                                    ),
                                                    const SizedBox(width: 8),
                                                    IconButton(
                                                      icon: Icon(
                                                        _musicPlayer
                                                                    .loopMode
                                                                    .value ==
                                                                LoopMode.one
                                                            ? Icons
                                                                  .repeat_one_rounded
                                                            : Icons
                                                                  .repeat_rounded,
                                                        color:
                                                            _musicPlayer
                                                                    .loopMode
                                                                    .value !=
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
                                                        final idx = modes
                                                            .indexOf(
                                                              _musicPlayer
                                                                  .loopMode
                                                                  .value,
                                                            );
                                                        _musicPlayer
                                                                .loopMode
                                                                .value =
                                                            modes[(idx + 1) %
                                                                modes.length];
                                                        setState(() {});
                                                      },
                                                    ),

                                                    const SizedBox(width: 16),

                                                    IconButton(
                                                      icon: Icon(
                                                        Icons
                                                            .skip_previous_rounded,
                                                        size: 48,
                                                        color:
                                                            _adjustColorForControls(
                                                              _dominantColor,
                                                            ),
                                                      ),
                                                      onPressed: _playPrevious,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      decoration: BoxDecoration(
                                                        color:
                                                            _adjustColorForControls(
                                                              _dominantColor,
                                                            ),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: IconButton(
                                                        icon: ValueListenableBuilder<bool>(
                                                          valueListenable:
                                                              _musicPlayer
                                                                  .isPlaying,
                                                          builder: (ctx, isPlaying, _) => Icon(
                                                            isPlaying
                                                                ? Icons
                                                                      .pause_rounded
                                                                : Icons
                                                                      .play_arrow_rounded,
                                                            color: _getContrastColor(
                                                              _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                            ),
                                                            size: 40,
                                                          ),
                                                        ),
                                                        onPressed:
                                                            _togglePlayPause,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    IconButton(
                                                      icon: Icon(
                                                        Icons.skip_next_rounded,
                                                        size: 48,
                                                        color:
                                                            _adjustColorForControls(
                                                              _dominantColor,
                                                            ),
                                                      ),
                                                      onPressed: _playNext,
                                                    ),

                                                    const SizedBox(width: 24),

                                                    // Volume
                                                    Icon(
                                                      Icons.volume_up,
                                                      color:
                                                          _adjustColorForControls(
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
                                                                enabledThumbRadius:
                                                                    5,
                                                              ),
                                                          activeTrackColor:
                                                              _adjustColorForControls(
                                                                _dominantColor,
                                                              ).withOpacity(
                                                                0.7,
                                                              ),
                                                          inactiveTrackColor:
                                                              Colors.white10,
                                                          thumbColor:
                                                              _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                        ),
                                                        child: Slider(
                                                          value: _musicPlayer
                                                              .volume
                                                              .value,
                                                          onChanged: (v) async {
                                                            _musicPlayer
                                                                    .volume
                                                                    .value =
                                                                v;
                                                            _musicPlayer
                                                                    .isMuted
                                                                    .value =
                                                                v == 0;
                                                            await _player
                                                                .setVolume(v);
                                                            setState(() {});
                                                          },
                                                        ),
                                                      ),
                                                    ),

                                                    const SizedBox(width: 16),

                                                    // Lyrics Toggle
                                                    ValueListenableBuilder<
                                                      bool
                                                    >(
                                                      valueListenable:
                                                          _musicPlayer
                                                              .showLyrics,
                                                      builder: (context, showLyrics, _) {
                                                        return IconButton(
                                                          icon: Icon(
                                                            showLyrics
                                                                ? Icons.lyrics
                                                                : Icons
                                                                      .lyrics_outlined,
                                                            color: showLyrics
                                                                ? _adjustColorForControls(
                                                                    _dominantColor,
                                                                  )
                                                                : Colors
                                                                      .white54,
                                                          ),
                                                          onPressed: () =>
                                                              _musicPlayer
                                                                      .showLyrics
                                                                      .value =
                                                                  !showLyrics,
                                                        );
                                                      },
                                                    ),
                                                  ],
                                                ),

                                                const SizedBox(height: 8),

                                                // Progress Bar
                                                ValueListenableBuilder<
                                                  Duration
                                                >(
                                                  valueListenable:
                                                      _musicPlayer.position,
                                                  builder: (context, position, _) {
                                                    final duration =
                                                        _musicPlayer
                                                            .duration
                                                            .value;
                                                    return Column(
                                                      children: [
                                                        SliderTheme(
                                                          data: SliderTheme.of(context).copyWith(
                                                            trackHeight: 2,
                                                            thumbShape:
                                                                const RoundSliderThumbShape(
                                                                  enabledThumbRadius:
                                                                      6,
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
                                                            value: position
                                                                .inSeconds
                                                                .toDouble()
                                                                .clamp(
                                                                  0.0,
                                                                  duration
                                                                      .inSeconds
                                                                      .toDouble(),
                                                                ),
                                                            max:
                                                                duration.inSeconds
                                                                        .toDouble() >
                                                                    0
                                                                ? duration
                                                                      .inSeconds
                                                                      .toDouble()
                                                                : 1.0,
                                                            onChanged: (v) =>
                                                                _player.seek(
                                                                  Duration(
                                                                    seconds: v
                                                                        .toInt(),
                                                                  ),
                                                                ),
                                                          ),
                                                        ),
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 24,
                                                              ),
                                                          child: Row(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment
                                                                    .spaceBetween,
                                                            children: [
                                                              Text(
                                                                _formatDuration(
                                                                  position,
                                                                ),
                                                                style: const TextStyle(
                                                                  color: Colors
                                                                      .white54,
                                                                  fontSize: 12,
                                                                ),
                                                              ),
                                                              Text(
                                                                _formatDuration(
                                                                  duration,
                                                                ),
                                                                style: const TextStyle(
                                                                  color: Colors
                                                                      .white54,
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
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Playlist Sidebar (Flat Design)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: _showPlaylist ? 350 : 0,
                  color: Colors
                      .transparent, // Transparent to show global background
                  child: Offstage(
                    offstage: !_showPlaylist,
                    child: Column(
                      children: [
                        // Simple Header
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: Colors.white12,
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.queue_music,
                                color: Colors.white,
                                size: 24,
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
                                  color: Colors.white70,
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
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
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
                                    ? Colors.white.withOpacity(0.1)
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
                                              color: Colors.white,
                                              size: 16,
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
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontWeight: isPlaying
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                              fontSize: 14,
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

            // Custom AppBar (Matching Settings Style)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => windowManager.startDragging(),
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  color: Colors.transparent,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            color: Colors.black26,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.music_note,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.getText(
                            'music_player_title',
                            fallback: 'Music Player',
                          ),
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                        ),
                      ),
                      IconButton(
                        tooltip: widget.getText(
                          'minimize',
                          fallback: 'Minimize',
                        ),
                        icon: const Icon(
                          Icons.remove,
                          size: 18,
                          color: Colors.white,
                        ),
                        onPressed: _minimize,
                      ),
                      IconButton(
                        tooltip: widget.getText(
                          'maximize',
                          fallback: 'Maximize',
                        ),
                        icon: const Icon(
                          Icons.crop_square,
                          size: 18,
                          color: Colors.white,
                        ),
                        onPressed: _maximizeRestore,
                      ),
                      IconButton(
                        tooltip: widget.getText('back', fallback: 'Back'),
                        icon: const Icon(
                          Icons.arrow_back,
                          size: 18,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
