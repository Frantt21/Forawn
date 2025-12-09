import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/global_music_player.dart';
import '../services/music_history.dart';
import '../services/global_keyboard_service.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:palette_generator/palette_generator.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({
    super.key,
    required this.getText,
    this.onRegisterFolderAction,
  });

  final TextGetter getText;
  final Function(VoidCallback)? onRegisterFolderAction;

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  late AudioPlayer _player;
  late GlobalMusicPlayer _musicPlayer;
  late FocusNode _focusNode;

  List<FileSystemEntity> _files = [];
  bool _isLoading = false;
  bool _showPlaylist = false;
  bool _toggleLocked = false;

  // Campos para UI local (sincronizados con global)
  String _currentTitle = '';
  String _currentArtist = '';
  Uint8List? _currentArt;
  Color? _dominantColor;
  int? _currentIndex;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _musicPlayer = GlobalMusicPlayer();
    _player = _musicPlayer.player;
    debugPrint('[MusicPlayer] initState - Player state: ${_player.state}');

    // Cargar estado de la playlist y otros valores cacheados
    _loadCachedState();

    // Sincronizar la información de la canción actual desde el estado global
    if (_musicPlayer.currentIndex.value != null &&
        _musicPlayer.currentIndex.value! >= 0) {
      _currentIndex = _musicPlayer.currentIndex.value;
      _currentTitle = _musicPlayer.currentTitle.value;
      _currentArtist = _musicPlayer.currentArtist.value;
    }

    // Listener para sincronizar cuando cambia la canción en otro lado
    _musicPlayer.currentIndex.addListener(_onCurrentIndexChanged);

    // Registrar callbacks con GlobalKeyboardService
    // Las teclas globales usarán estas funciones
    GlobalKeyboardService().registerCallbacks(
      playPrevious: _playPrevious,
      playNext: _playNext,
      togglePlayPause: _togglePlayPause,
    );

    _initPlayer();
    _init();
    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectFolder);
    }
  }

  Future<void> _loadCachedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Cargar estado de playlist (default: true - abierta)
      _showPlaylist = prefs.getBool('playlistVisible') ?? true;

      // Cargar loop mode por defecto: all (repetir todas)
      if (_musicPlayer.loopMode.value == LoopMode.off) {
        _musicPlayer.loopMode.value = LoopMode.all;
      }

      debugPrint('[MusicPlayer] Playlist visible: $_showPlaylist');
    } catch (e) {
      debugPrint('[MusicPlayer] Error loading cached state: $e');
    }
  }

  Future<void> _saveCachedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('playlistVisible', _showPlaylist);
      debugPrint('[MusicPlayer] Cached playlist state: $_showPlaylist');
    } catch (e) {
      debugPrint('[MusicPlayer] Error saving cached state: $e');
    }
  }

  void _onCurrentIndexChanged() {
    if (mounted) {
      setState(() {
        _currentIndex = _musicPlayer.currentIndex.value;
      });
    }
  }

  void _initPlayer() {
    _player.setReleaseMode(ReleaseMode.stop);

    // Listener para sincronizar play/pausa desde el estado global
    _musicPlayer.isPlaying.addListener(_onPlayPauseChanged);

    // Registrar el callback global para auto-advance
    // Esto funciona incluso cuando no estamos en el screen del player
    _musicPlayer.onSongComplete = (currentIndex, loopMode, isShuffle) {
      _handleSongComplete(currentIndex);
      // Actualizar UI local si estamos montados
      if (mounted) {
        setState(() {
          _currentTitle = _musicPlayer.currentTitle.value;
          _currentArtist = _musicPlayer.currentArtist.value;
        });
      }
    };
  }

  void _onPlayPauseChanged() {
    debugPrint(
      '[MusicPlayer] Play pause changed: ${_musicPlayer.isPlaying.value}',
    );
    if (mounted) {
      setState(() {
        // Forzar rebuild para actualizar el botón play/pausa
        debugPrint(
          '[MusicPlayer] Updating UI - isPlaying: ${_musicPlayer.isPlaying.value}',
        );
      });
    }
  }

  void _handleSongComplete([int? overrideIndex]) {
    final currentIndex = overrideIndex ?? _musicPlayer.currentIndex.value;

    // Si estamos montados, usar _playFile que actualiza todo correctamente
    if (mounted) {
      if (_musicPlayer.loopMode.value == LoopMode.one && currentIndex != null) {
        _playFile(currentIndex);
      } else if (_musicPlayer.loopMode.value != LoopMode.off &&
          _files.isNotEmpty) {
        int nextIdx;
        if (_musicPlayer.isShuffle.value) {
          nextIdx = Random().nextInt(_files.length);
        } else {
          nextIdx = (currentIndex ?? -1) + 1;
        }
        if (nextIdx < _files.length) {
          _playFile(nextIdx);
        } else if (_musicPlayer.loopMode.value == LoopMode.all) {
          _playFile(0);
        }
      }
    } else {
      // Si NO estamos montados, actualizar solo el estado global
      if (_musicPlayer.loopMode.value == LoopMode.one && currentIndex != null) {
        _updateMetadataFromFile(currentIndex);
      } else if (_musicPlayer.loopMode.value != LoopMode.off &&
          _files.isNotEmpty) {
        int nextIdx;
        if (_musicPlayer.isShuffle.value) {
          nextIdx = Random().nextInt(_files.length);
        } else {
          nextIdx = (currentIndex ?? -1) + 1;
        }
        if (nextIdx < _files.length) {
          _updateMetadataFromFile(nextIdx);
        } else if (_musicPlayer.loopMode.value == LoopMode.all) {
          _updateMetadataFromFile(0);
        }
      }
    }
  }

  void _updateMetadataFromFile(int index) {
    if (index < 0 || index >= _files.length) return;
    final file = _files[index] as File;

    try {
      final title = p.basename(file.path);
      final artist = 'Unknown Artist';

      // Detener reproducción anterior
      _musicPlayer.player.stop();

      // Reproducir archivo
      _musicPlayer.player.play(DeviceFileSource(file.path));

      // Pequeño delay antes de obtener duración
      Future.delayed(const Duration(milliseconds: 100), () {
        _musicPlayer.player.getDuration().then((dur) {
          _musicPlayer.duration.value = dur ?? Duration.zero;
        });
      });

      // Actualizar estado global
      _musicPlayer.currentTitle.value = title;
      _musicPlayer.currentArtist.value = artist;
      _musicPlayer.currentIndex.value = index;
      _musicPlayer.currentFilePath.value = file.path;
      _musicPlayer.filesList.value = _files;

      // Si estamos montados, también actualizar el estado local
      if (mounted) {
        setState(() {
          _currentTitle = title;
          _currentArtist = artist;
          _currentIndex = index;
        });
      }
    } catch (e) {
      debugPrint('[MusicPlayer] Error updating metadata: $e');
    }
  }

  @override
  void dispose() {
    // Desregistrar callbacks del servicio de teclado global
    GlobalKeyboardService().unregisterCallbacks();

    // Remover listeners de sincronización
    _musicPlayer.currentIndex.removeListener(_onCurrentIndexChanged);
    _musicPlayer.isPlaying.removeListener(_onPlayPauseChanged);
    _focusNode.dispose();

    // Los listeners globales persisten para el mini player
    // No detenemos el reproductor aquí porque queremos que continúe sonando
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final folder = prefs.getString('download_folder');
      if (folder != null && folder.isNotEmpty) {
        await _loadFiles(folder);
      }
    } catch (e) {
      debugPrint('[MusicPlayer] Error in _init: $e');
    }
  }

  Future<void> _selectFolder() async {
    final folder = await FilePicker.platform.getDirectoryPath();
    if (folder != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('download_folder', folder);
      await _loadFiles(folder);
    }
  }

  void _togglePlaylist() {
    if (_toggleLocked) return;
    _toggleLocked = true;
    setState(() => _showPlaylist = !_showPlaylist);
    _saveCachedState(); // Guardar el nuevo estado
    Future.delayed(const Duration(milliseconds: 350), () {
      _toggleLocked = false;
    });
  }

  Future<void> _loadFiles(String folderPath) async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) throw Exception("Directory not found");

      final List<FileSystemEntity> allFiles = [];
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (['.mp3', '.m4a', '.wav', '.flac', '.ogg', '.aac'].contains(ext)) {
            allFiles.add(entity);
          }
        }
      }

      allFiles.sort(
        (a, b) => p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase()),
      );

      if (mounted) {
        setState(() {
          _files = allFiles;
          _isLoading = false;
        });

        // Actualizar lista de archivos en el servicio global de teclado
        GlobalKeyboardService().setCurrentFiles(List<File>.from(allFiles));

        if (_files.isEmpty) {
          try {
            await _player.stop();
          } catch (_) {}
          _currentTitle = '';
          _currentArtist = '';
          _currentArt = null;
          _musicPlayer.position.value = Duration.zero;
          _musicPlayer.duration.value = Duration.zero;
        }
      }
    } catch (e) {
      debugPrint("Error loading files: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMetadata(String filePath) async {
    try {
      final file = File(filePath);
      final metadata = readMetadata(file, getImage: true);

      String title = p.basename(filePath);
      String artist = widget.getText(
        'unknown_artist',
        fallback: 'Unknown Artist',
      );
      Uint8List? artwork;

      if (metadata != null) {
        if (metadata.title != null && metadata.title!.isNotEmpty) {
          title = metadata.title!;
        }
        if (metadata.artist != null && metadata.artist!.isNotEmpty) {
          artist = metadata.artist!;
        }
        if (metadata.pictures.isNotEmpty) {
          artwork = metadata.pictures.first.bytes;
        }
      }

      Color? dominantColor;
      if (artwork != null) {
        try {
          final paletteGenerator = await PaletteGenerator.fromImageProvider(
            MemoryImage(artwork),
            size: const Size(100, 100),
          );
          dominantColor =
              paletteGenerator.dominantColor?.color ??
              paletteGenerator.vibrantColor?.color;
        } catch (e) {
          debugPrint('[MusicPlayer] Error extracting color: $e');
        }
      }

      if (mounted) {
        setState(() {
          _currentTitle = title;
          _currentArtist = artist;
          _currentArt = artwork;
          _dominantColor = dominantColor;
        });
      }

      _musicPlayer.currentTitle.value = title;
      _musicPlayer.currentArtist.value = artist;
      if (artwork != null) {
        _musicPlayer.currentArt.value = artwork;
      }

      debugPrint(
        '[MusicPlayer] Loaded metadata: $title by $artist (color: ${dominantColor != null})',
      );
    } catch (e) {
      debugPrint('[MusicPlayer] Error loading metadata: $e');

      final title = p.basename(filePath);
      final artist = widget.getText(
        'unknown_artist',
        fallback: 'Unknown Artist',
      );

      if (mounted) {
        setState(() {
          _currentTitle = title;
          _currentArtist = artist;
          _currentArt = null;
          _dominantColor = null;
        });
      }

      _musicPlayer.currentTitle.value = title;
      _musicPlayer.currentArtist.value = artist;
      _musicPlayer.currentArt.value = null;
    }
  }

  Future<void> _playFile(int index) async {
    if (index < 0 || index >= _files.length) return;
    final file = _files[index] as File;

    try {
      if (mounted) {
        setState(() => _currentIndex = index);
      }

      debugPrint('[MusicPlayer] Playing file: ${file.path}');

      // Detener reproducción anterior
      try {
        await _player.stop();
      } catch (e) {
        debugPrint("[MusicPlayer] Error stopping player: $e");
      }

      // Reproducir archivo
      try {
        await _player.play(DeviceFileSource(file.path));
        debugPrint('[MusicPlayer] Play started successfully');
      } catch (e) {
        debugPrint("[MusicPlayer] Error playing file: $e");
        if (mounted) {
          setState(() => _currentIndex = null);
        }
        return;
      }

      // Pequeño delay antes de obtener duración
      await Future.delayed(const Duration(milliseconds: 100));

      // Obtener duración
      try {
        final dur = await _player.getDuration() ?? Duration.zero;
        debugPrint('[MusicPlayer] Duration: ${dur.inSeconds}s');
        _musicPlayer.duration.value = dur;
      } catch (e) {
        debugPrint("[MusicPlayer] Error getting duration: $e");
        _musicPlayer.duration.value = Duration.zero;
      }

      // IMPORTANTE: Cargar metadata ANTES de actualizar índice
      // Esto asegura que los títulos se actualicen inmediatamente
      await _loadMetadata(file.path);

      // Actualizar índice y datos globales
      _musicPlayer.currentIndex.value = index;
      _musicPlayer.currentFilePath.value = file.path;
      _musicPlayer.filesList.value = _files;

      // Agregar al historial cuando se empieza a reproducir
      MusicHistory().addToHistory(file);

      // El mini reproductor ya no se muestra automáticamente
      // El usuario debe presionar el botón de "mostrar mini reproductor"
    } catch (e) {
      debugPrint("[MusicPlayer] Unexpected error in _playFile: $e");
      if (mounted) {
        setState(() => _currentIndex = null);
      }
    }
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return "--:--";
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  bool get _isPlaying => _musicPlayer.isPlaying.value;

  /// Función unificada para retroceso
  /// Usada tanto por botones como por teclas globales
  void _playPrevious() {
    if (_files.isEmpty) return;

    // Si la canción lleva más de 3 segundos, reiniciarla
    if (_musicPlayer.position.value.inSeconds >= 3) {
      _playFile(_currentIndex ?? 0);
    } else {
      // Si es menos de 3 segundos, ir a la canción anterior en el historial
      final previousTrack = MusicHistory().getPreviousTrack();
      if (previousTrack != null) {
        final index = _files.indexWhere(
          (f) => (f as File).path == previousTrack.path,
        );
        if (index >= 0) {
          _playFile(index);
        }
      } else {
        // Si no hay historial, ir a la anterior en la playlist
        final cur = _currentIndex ?? 0;
        final nextIndex = max(0, cur - 1);
        _playFile(nextIndex);
      }
    }
  }

  /// Función unificada para siguiente
  /// Usada tanto por botones como por teclas globales
  void _playNext() {
    if (_files.isEmpty) return;

    int nextIndex;
    if (_musicPlayer.isShuffle.value) {
      nextIndex = Random().nextInt(_files.length);
    } else {
      final cur = _currentIndex ?? -1;
      nextIndex = min(_files.length - 1, cur + 1);
    }
    _playFile(nextIndex);
  }

  /// Función unificada para play/pausa
  /// Usada tanto por botones como por teclas globales
  void _togglePlayPause() {
    debugPrint(
      '[MusicPlayer] Toggle play/pause pressed. Current state: ${_musicPlayer.isPlaying.value}',
    );

    if (_isPlaying) {
      // Pausar
      debugPrint('[MusicPlayer] Pausing...');
      _player.pause();
      // Actualizar estado global y local inmediatamente
      _musicPlayer.isPlaying.value = false;
      if (mounted) {
        setState(() {
          debugPrint('[MusicPlayer] UI updated to paused');
        });
      }
    } else {
      // Reanudar o reproducir
      if (_currentIndex == null && _files.isNotEmpty) {
        // Si no hay canción seleccionada, reproducir la primera
        debugPrint('[MusicPlayer] No song selected, playing first file');
        _playFile(0);
      } else {
        // Si hay canción en pausa, reanudar
        debugPrint('[MusicPlayer] Resuming...');
        _player.resume();
        // Actualizar estado global y local inmediatamente
        _musicPlayer.isPlaying.value = true;
        if (mounted) {
          setState(() {
            debugPrint('[MusicPlayer] UI updated to playing');
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKey: (event) {
        _handleKeyboardEvent(event);
      },
      child: Row(
        children: [
          // Main Player Area
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: _dominantColor != null
                  ? BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 1.5,
                        colors: [
                          _dominantColor!.withOpacity(0.3),
                          _dominantColor!.withOpacity(0.15),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    )
                  : null,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(flex: 1),

                  // Album Art (más centrada)
                  Flexible(
                    flex: 5,
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        constraints: const BoxConstraints(
                          maxWidth: 400,
                          maxHeight: 400,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: Colors.black26,
                          boxShadow: _dominantColor != null
                              ? [
                                  BoxShadow(
                                    color: _dominantColor!.withOpacity(0.5),
                                    blurRadius: 40,
                                    spreadRadius: 5,
                                    offset: const Offset(0, 10),
                                  ),
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 20,
                                    offset: const Offset(0, 10),
                                  ),
                                ]
                              : [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 20,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                          image: _currentArt != null
                              ? DecorationImage(
                                  image: MemoryImage(_currentArt!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: _currentArt == null
                            ? const Icon(
                                Icons.music_note,
                                size: 120,
                                color: Colors.white12,
                              )
                            : null,
                      ),
                    ),
                  ),

                  const Spacer(flex: 1),

                  // Metadata
                  Text(
                    _currentTitle.isEmpty
                        ? widget.getText('no_song', fallback: 'No Song Playing')
                        : _currentTitle,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _currentArtist,
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.purpleAccent,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 24),

                  // Progress
                  ValueListenableBuilder<Duration>(
                    valueListenable: _musicPlayer.position,
                    builder: (context, position, _) {
                      return ValueListenableBuilder<Duration>(
                        valueListenable: _musicPlayer.duration,
                        builder: (context, duration, _) {
                          return Column(
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 4,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  activeTrackColor: Colors.purpleAccent,
                                  inactiveTrackColor: Colors.grey[800],
                                  thumbColor: Colors.white,
                                ),
                                child: Slider(
                                  value: min(
                                    position.inMilliseconds.toDouble(),
                                    duration.inMilliseconds.toDouble(),
                                  ),
                                  max: max(
                                    duration.inMilliseconds.toDouble(),
                                    1.0,
                                  ),
                                  onChanged: (value) async {
                                    final pos = Duration(
                                      milliseconds: value.toInt(),
                                    );
                                    await _player.seek(pos);
                                    if (!_isPlaying) await _player.resume();
                                  },
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _formatDuration(position),
                                      style: const TextStyle(
                                        color: Colors.white54,
                                      ),
                                    ),
                                    Text(
                                      _formatDuration(duration),
                                      style: const TextStyle(
                                        color: Colors.white54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),

                  const Spacer(flex: 1),

                  // Controls con colores dinámicos
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          color: _musicPlayer.isShuffle.value
                              ? (_dominantColor ?? Colors.purpleAccent)
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
                          Icons.skip_previous_rounded,
                          size: 48,
                          color: _dominantColor ?? Colors.white,
                        ),
                        onPressed: _playPrevious,
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: _dominantColor ?? Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: Icon(
                            _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.black,
                            size: 40,
                          ),
                          onPressed: _togglePlayPause,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          Icons.skip_next_rounded,
                          size: 48,
                          color: _dominantColor ?? Colors.white,
                        ),
                        onPressed: _playNext,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          _musicPlayer.loopMode.value == LoopMode.one
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          color: _musicPlayer.loopMode.value != LoopMode.off
                              ? (_dominantColor ?? Colors.purpleAccent)
                              : Colors.white54,
                        ),
                        onPressed: () {
                          final modes = [
                            LoopMode.off,
                            LoopMode.all,
                            LoopMode.one,
                          ];
                          final currentIndex = modes.indexOf(
                            _musicPlayer.loopMode.value,
                          );
                          final nextIndex = (currentIndex + 1) % modes.length;
                          _musicPlayer.loopMode.value = modes[nextIndex];
                          setState(() {});
                        },
                      ),
                      const SizedBox(width: 16),

                      // Volume inline
                      Icon(
                        _musicPlayer.isMuted.value
                            ? Icons.volume_off
                            : Icons.volume_up,
                        color:
                            _dominantColor?.withOpacity(0.7) ?? Colors.white54,
                        size: 20,
                      ),
                      SizedBox(
                        width: 120,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5,
                            ),
                            activeTrackColor:
                                _dominantColor?.withOpacity(0.7) ??
                                Colors.white54,
                            inactiveTrackColor: Colors.white10,
                            thumbColor: _dominantColor ?? Colors.white,
                          ),
                          child: Slider(
                            value: _musicPlayer.volume.value,
                            onChanged: (value) async {
                              _musicPlayer.volume.value = value;
                              _musicPlayer.isMuted.value = value == 0;
                              await _player.setVolume(value);
                              setState(() {});
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Show Mini Player Button
                      IconButton(
                        icon: Icon(
                          Icons.picture_in_picture,
                          size: 24,
                          color: _dominantColor ?? Colors.purpleAccent,
                        ),
                        onPressed: () {
                          _musicPlayer.showMiniPlayer.value = true;
                        },
                        tooltip: 'Mostrar mini reproductor',
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // Playlist Sidebar (Offstage + AnimatedContainer + ListTile protegido)
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: _showPlaylist ? 300 : 0,
            decoration: const BoxDecoration(
              color: Colors.black26,
              border: Border(left: BorderSide(color: Colors.white10)),
            ),
            child: Offstage(
              offstage: !_showPlaylist,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.queue_music, color: Colors.purpleAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.getText(
                              'playlist_title',
                              fallback: 'Playlist',
                            ),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : _files.isEmpty
                        ? Center(
                            child: Text(
                              widget.getText('no_files', fallback: 'Empty'),
                              style: const TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _files.length,
                            itemBuilder: (context, index) {
                              if (index >= _files.length)
                                return const SizedBox.shrink();
                              final file = _files[index];
                              final isSelected = index == _currentIndex;
                              final title = p.basename(file.path);

                              return LayoutBuilder(
                                builder: (context, constraints) {
                                  if (constraints.maxWidth < 80) {
                                    return const SizedBox(height: 56);
                                  }

                                  return ListTile(
                                    selected: isSelected,
                                    selectedTileColor: Colors.white10,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    minLeadingWidth: 56,
                                    leading: isSelected
                                        ? const Icon(
                                            Icons.graphic_eq,
                                            color: Colors.purpleAccent,
                                            size: 20,
                                          )
                                        : const Icon(
                                            Icons.music_note,
                                            size: 20,
                                            color: Colors.white54,
                                          ),
                                    title: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isSelected
                                            ? Colors.purpleAccent
                                            : Colors.white70,
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                    onTap: () {
                                      if (index < _files.length)
                                        _playFile(index);
                                    },
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

          // Toggle strip
          Container(
            width: 40,
            color: Colors.transparent,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(
                    _showPlaylist ? Icons.chevron_right : Icons.chevron_left,
                  ),
                  onPressed: _togglePlaylist,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleKeyboardEvent(RawKeyEvent event) {
    // Solo procesar eventos de tecla presionada
    if (event is! RawKeyDownEvent) return;

    final logicalKey = event.logicalKey;

    // Detectar F9 para anterior - usa la misma función que el botón
    if (logicalKey == LogicalKeyboardKey.f9) {
      _playPrevious();
      return;
    }

    // Detectar F10 para play/pausa - usa la misma función que el botón
    if (logicalKey == LogicalKeyboardKey.f10) {
      _togglePlayPause();
      return;
    }

    // Detectar F11 para siguiente - usa la misma función que el botón
    if (logicalKey == LogicalKeyboardKey.f11) {
      _playNext();
      return;
    }
  }
}
