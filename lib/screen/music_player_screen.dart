import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
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
import '../services/local_music_database.dart';
import '../services/music_state_service.dart';
import '../services/discord_service.dart';
import '../services/lyrics_service.dart';
import '../services/global_theme_service.dart';
import '../services/playlist_service.dart';
import '../models/playlist_model.dart';
import '../models/song_model.dart';

import 'player_screen.dart';
import 'playlist_detail_screen.dart';
import '../widgets/mini_player.dart';

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

class _MusicPlayerScreenState extends State<MusicPlayerScreen>
    with AutomaticKeepAliveClientMixin<MusicPlayerScreen> {
  @override
  bool get wantKeepAlive => true; // Keep state alive when navigating away
  late AudioPlayer _player;
  late GlobalMusicPlayer _musicPlayer;
  late FocusNode _focusNode;

  List<FileSystemEntity> _files = [];
  List<FileSystemEntity> _filteredFiles = []; // Lista filtrada para búsqueda

  // Controlador de búsqueda

  // Campos para UI local (sincronizados con global)
  // Campos para UI local (sincronizados con global)
  // String _currentTitle = ''; // Removed
  // String _currentArtist = ''; // Removed
  // Uint8List? _currentArt; // Removed
  // Color? _dominantColor; // Removed
  int? _currentIndex;
  final Set<int> _playedIndices = {}; // Rastreo para shuffle inteligente

  // Cache de metadatos pre-cargados para evitar FutureBuilder en cada scroll
  final Map<String, SongMetadata?> _libraryMetadataCache = {};

  // Flag para evitar inicializar servicios múltiples veces
  static bool _servicesInitialized = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _musicPlayer = GlobalMusicPlayer();
    _player = _musicPlayer.player;
    debugPrint('[MusicPlayer] initState - Player state: ${_player.state}');

    // Inicializar servicio de lyrics
    LyricsService().initialize();

    // Cargar estado de la playlist y otros valores cacheados
    _loadCachedState();

    // Sincronizar la información de la canción actual desde el estado global
    if (_musicPlayer.currentIndex.value != null &&
        _musicPlayer.currentIndex.value! >= 0) {
      _currentIndex = _musicPlayer.currentIndex.value;
      _currentIndex = _musicPlayer.currentIndex.value;
      // _currentTitle, _currentArtist, _currentArt removed

      // Restaurar color dominante desde el caché
      if (_musicPlayer.currentFilePath.value.isNotEmpty) {
        LocalMusicDatabase()
            .getDominantColor(_musicPlayer.currentFilePath.value)
            .then((cachedColor) {
              if (cachedColor != null) {
                GlobalThemeService().updateDominantColor(cachedColor);
              }
            });
      }
    }

    // Listener para sincronizar cuando cambia la canción en otro lado
    _musicPlayer.currentIndex.addListener(_onCurrentIndexChanged);

    // Update local state when Global Music Player changes track details
    // This fixes the MiniPlayer sync issue
    _musicPlayer.currentTitle.addListener(_onMetadataChanged);
    _musicPlayer.currentArtist.addListener(_onMetadataChanged);
    _musicPlayer.currentArt.addListener(_onMetadataChanged);

    // Registrar callbacks con GlobalKeyboardService
    GlobalKeyboardService().registerCallbacks(
      playPrevious: _playPrevious,
      playNext: _playNext,
      togglePlayPause: _togglePlayPause,
    );

    _initPlayer();
    _init();

    // Register metadata callback for when playing from playlist
    _musicPlayer.onMetadataNeeded = (filePath) async {
      // Find index of file and update metadata
      final index = _files.indexWhere((f) => (f as File).path == filePath);
      if (index != -1) {
        await _updateMetadataFromFile(index, shouldPlay: false);
      }
    };

    // Initialize services ONCE (solo la primera vez que se carga la app)
    if (!_servicesInitialized) {
      PlaylistService().init();
      _servicesInitialized = true;
      debugPrint('[MusicPlayer] Services initialized for the first time');
    } else {
      debugPrint('[MusicPlayer] Services already initialized, skipping');
    }

    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectFolder);
    }
  }

  void _onMetadataChanged() {
    final newArt = _musicPlayer.currentArt.value;
    final path = _musicPlayer.currentFilePath.value;

    if (path.isNotEmpty) {
      _updateGlobalColor(path, newArt);
    }

    // Local state updates removed as MiniPlayer handles its own state
  }

  Future<void> _updateGlobalColor(String filePath, Uint8List? artwork) async {
    if (filePath.isEmpty) return;

    Color? color;
    try {
      // LocalMusicDatabase handles extraction automatically
      color = await LocalMusicDatabase().getDominantColor(filePath);
    } catch (e) {
      debugPrint('[MusicPlayer] Error getting dominant color: $e');
    }

    // Update Global Service (ALWAYS, even if unmounted)
    if (color != null) {
      GlobalThemeService().updateDominantColor(color);
    } else if (artwork == null) {
      // Only reset if no artwork
      GlobalThemeService().updateDominantColor(null);
    }

    // Update Local State (Only if mounted) -> Removed _dominantColor
  }

  Future<void> _loadCachedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Cargar loop mode por defecto: all (repetir todas)
      if (_musicPlayer.loopMode.value == LoopMode.off) {
        _musicPlayer.loopMode.value = LoopMode.all;
      }

      debugPrint('[MusicPlayer] Loaded cached state');
    } catch (e) {
      debugPrint('[MusicPlayer] Error loading cached state: $e');
    }
  }

  void _onCurrentIndexChanged() {
    // Use path-based lookup to sync with global player
    final path = _musicPlayer.currentFilePath.value;
    // Use case-insensitive comparison for Windows robustness
    final index = _files.indexWhere(
      (f) => f.path.toLowerCase() == path.toLowerCase(),
    );

    if (index != -1) {
      if (_currentIndex != index) {
        setState(() {
          _currentIndex = index;
        });
      }
      // Sync local UI state from global state (already set by PlayerScreen or elsewhere)
      // Only sync local variables - NO metadata fetching needed here
      // as the source that changed currentIndex is responsible for setting metadata
    } else {
      // Song not in this folder.
      // Only reset if we actually have a valid path but it's not in the list
      // (To avoid clearing state during initial load glitches)
      if (path.isNotEmpty && _currentIndex != null && _files.isNotEmpty) {
        setState(() {
          _currentIndex = null;
        });
      }
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
          // Local metadata removed
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
          nextIdx = _getNextShuffleIndex();
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
          nextIdx = _getNextShuffleIndex();
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

  Future<void> _updateMetadataFromFile(
    int index, {
    bool shouldPlay = true,
  }) async {
    if (index < 0 || index >= _files.length) return;
    _playedIndices.add(index);
    final file = _files[index] as File;

    try {
      if (shouldPlay) {
        // 1. Playback Priority: Start Audio & Update Basic State IMMEDIATELY
        final filename = p.basename(file.path);

        // Update direction
        if (_musicPlayer.currentIndex.value != null) {
          _musicPlayer.transitionDirection.value =
              index > _musicPlayer.currentIndex.value! ? 1 : -1;
        }

        // Set optimistic state
        _musicPlayer.currentFilePath.value = file.path;
        _musicPlayer.currentIndex.value = index;
        _musicPlayer.filesList.value = _files;

        // Optimistic metadata (prevents empty UI while loading)
        // Only set if we don't have cached metadata handy to avoid flicker
        _musicPlayer.currentTitle.value = filename;
        _musicPlayer.currentArtist.value = 'Unknown Artist';
        _musicPlayer.currentArt.value = null;
        _musicPlayer.isPlaying.value = true;

        // Stop & Play (handling audio)
        // We don't await stop() strictly before setting UI state to make it feel snappier
        _musicPlayer.player.stop().then((_) async {
          await _musicPlayer.player.play(DeviceFileSource(file.path));
        });

        // Add history in background
        MusicHistory().addToHistory(file);
      }

      // 2. Fetch Metadata in Background (Non-blocking)
      // We wrap in a separate async flow
      _fetchAndUpdateMetadata(file, index);
    } catch (e) {
      debugPrint('[MusicPlayer] Error in playback flow: $e');
    }
  }

  Future<void> _fetchAndUpdateMetadata(File file, int index) async {
    try {
      final metadata = await LocalMusicDatabase().getMetadata(file.path);

      // 3. Update Global State ONLY if still playing the same song
      // (User might have skipped rapidly)
      if (_musicPlayer.currentFilePath.value == file.path) {
        if (metadata != null) {
          _musicPlayer.currentTitle.value = metadata.title;
          _musicPlayer.currentArtist.value = metadata.artist;
          _musicPlayer.currentArt.value = metadata.artwork;
        } else {
          // Keep filename if no metadata found (or update if needed)
          if (_musicPlayer.currentTitle.value == p.basename(file.path)) {
            // Already set defaults
          }
        }

        // 4. Color Extraction (Low priority)
        Future.delayed(const Duration(milliseconds: 200), () async {
          if (_musicPlayer.currentFilePath.value != file.path) return;
          final dur = await _musicPlayer.player.getDuration();
          _musicPlayer.duration.value = dur ?? Duration.zero;

          if (metadata?.artwork != null) {
            final color = await LocalMusicDatabase().getDominantColor(
              file.path,
            );
            if (color != null &&
                _musicPlayer.currentFilePath.value == file.path) {
              GlobalThemeService().updateDominantColor(color);
            }
          }
        });

        if (mounted) {
          setState(() {
            // Local metadata removed
            _currentIndex = index;
          });
        }
      }
    } catch (e) {
      debugPrint('[MusicPlayer] Error fetching metadata: $e');
    }
  }

  @override
  void dispose() {
    // Desregistrar callbacks del servicio de teclado global
    GlobalKeyboardService().unregisterCallbacks();

    // Remover listeners de sincronización
    // Remover listeners de sincronización
    _musicPlayer.currentIndex.removeListener(_onCurrentIndexChanged);
    _musicPlayer.currentTitle.removeListener(_onMetadataChanged);
    _musicPlayer.currentArtist.removeListener(_onMetadataChanged);
    _musicPlayer.currentArt.removeListener(_onMetadataChanged);
    _musicPlayer.isPlaying.removeListener(_onPlayPauseChanged);

    _focusNode.dispose();

    // Los listeners globales persisten para el mini player
    // No detenemos el reproductor aquí porque queremos que continúe sonando
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Cargar preferencia de fondo difuminado
      if (mounted) {
        setState(() {
          final useBlur = prefs.getBool('use_blur_background') ?? false;
          GlobalThemeService().blurBackground.value = useBlur;
        });
      }

      // Cargar librería globalmente (solo se carga una vez)
      await _musicPlayer.loadLibraryIfNeeded();

      // Sincronizar lista local con la global
      if (_musicPlayer.filesList.value.isNotEmpty) {
        setState(() {
          _files = _musicPlayer.filesList.value;
          _filteredFiles = _files;
        });

        debugPrint(
          '[MusicPlayer] Synced with global library: ${_files.length} files',
        );
      }

      // IMPORTANTE: Cargar estado guardado del reproductor después de cargar la librería
      // Esto asegura que el mini-player muestre la última canción reproducida
      await _musicPlayer.loadPlayerState();
    } catch (e) {
      debugPrint('[MusicPlayer] Error in _init: $e');
    }
  }

  Future<void> _selectFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();

      if (result == null) return;

      // Limpiar base de datos anterior al cambiar de carpeta
      debugPrint('[MusicPlayer] Clearing database for new folder');
      await LocalMusicDatabase().clearDatabase();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('download_folder', result);

      if (!mounted) return;
      await _showLoadingDialog(result);
    } catch (e) {
      debugPrint('[MusicPlayer] Error selecting folder: $e');
    }
  }

  Future<void> _showLoadingDialog(String folderPath) async {
    final ValueNotifier<int> processedFiles = ValueNotifier(0);
    final ValueNotifier<int> totalFiles = ValueNotifier(0);
    bool cancelled = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false,
        child: Dialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Cargando librería',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 32),
                ValueListenableBuilder<int>(
                  valueListenable: processedFiles,
                  builder: (context, processed, _) {
                    return ValueListenableBuilder<int>(
                      valueListenable: totalFiles,
                      builder: (context, total, _) {
                        final progress = total > 0 ? processed / total : 0.0;
                        final percentage = (progress * 100).toInt();

                        return SizedBox(
                          width: 120,
                          height: 120,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 120,
                                height: 120,
                                child: CircularProgressIndicator(
                                  value: progress,
                                  strokeWidth: 8,
                                  backgroundColor: Colors.white10,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                        Color(0xFFBB86FC),
                                      ),
                                ),
                              ),
                              Text(
                                '$percentage%',
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 24),
                ValueListenableBuilder<int>(
                  valueListenable: processedFiles,
                  builder: (context, processed, _) {
                    return ValueListenableBuilder<int>(
                      valueListenable: totalFiles,
                      builder: (context, total, _) {
                        final isColors = processed > (total / 2);
                        return Text(
                          isColors
                              ? 'Extrayendo colores ($processed/$total)...'
                              : 'Procesando metadatos ($processed/$total)...',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    Navigator.of(context).pop();
                  },
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Color(0xFFBB86FC)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final dir = Directory(folderPath);
      final files = dir.listSync(recursive: true).whereType<File>().where((f) {
        final ext = p.extension(f.path).toLowerCase();
        return ext == '.mp3' || ext == '.m4a' || ext == '.flac';
      }).toList();

      totalFiles.value = files.length * 2;

      // Fase 1: Metadatos
      for (int i = 0; i < files.length && !cancelled; i++) {
        await LocalMusicDatabase().getMetadata(files[i].path);
        processedFiles.value = i + 1;
        await Future.delayed(const Duration(milliseconds: 1));
      }

      // Fase 2: Colores
      for (int i = 0; i < files.length && !cancelled; i++) {
        await LocalMusicDatabase().getDominantColor(files[i].path);
        processedFiles.value = files.length + i + 1;
        await Future.delayed(const Duration(milliseconds: 1));
      }

      if (!cancelled) {
        // Reload library from GlobalMusicPlayer
        await _musicPlayer.loadLibraryFromFolder(folderPath);

        // Sync local state with global
        if (mounted) {
          setState(() {
            _files = List<FileSystemEntity>.from(_musicPlayer.filesList.value);
            _filteredFiles = _files;
          });

          debugPrint('[MusicPlayer] Library reloaded: ${_files.length} files');
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      debugPrint('[MusicPlayer] Error loading library: $e');
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _loadFiles(String folderPath) async {
    if (!mounted) return;

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
          _filteredFiles = allFiles; // Inicializar lista filtrada
          _playedIndices.clear(); // Reiniciar historial de shuffle
        });

        // Actualizar lista de archivos en el servicio global de teclado
        GlobalKeyboardService().setCurrentFiles(List<File>.from(allFiles));

        if (_files.isEmpty) {
          try {
            await _player.stop();
          } catch (_) {}
          // Local metadata reset removed
          _musicPlayer.position.value = Duration.zero;
          _musicPlayer.duration.value = Duration.zero;
        }
      }
    } catch (e) {
      debugPrint("Error loading files: $e");
    }
  }

  Future<void> _playFile(int index) async {
    // Simplified to route through unified logic
    if (index >= 0 && index < _files.length) {
      debugPrint('[MusicPlayer] _playFile requested for index $index');
      await _updateMetadataFromFile(index);
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

  /// Obtener índice para shuffle inteligente
  int _getNextShuffleIndex() {
    if (_files.isEmpty) return 0;

    // Si hemos reproducido casi todas, reiniciar ciclo (salvo la actual)
    if (_playedIndices.length >= _files.length - 1) {
      _playedIndices.clear();
      if (_currentIndex != null) _playedIndices.add(_currentIndex!);
    }

    final currentIdx = _currentIndex ?? -1;
    final candidates = <int>[];

    for (int i = 0; i < _files.length; i++) {
      // Excluir las ya reproducidas y la actual
      if (!_playedIndices.contains(i) && i != currentIdx) {
        candidates.add(i);
      }
    }

    if (candidates.isEmpty) {
      if (_files.length > 1) {
        // Fallback: cualquiera menos la actual
        int r;
        do {
          r = Random().nextInt(_files.length);
        } while (r == currentIdx);
        return r;
      }
      return 0;
    }

    return candidates[Random().nextInt(candidates.length)];
  }

  /// Función unificada para siguiente
  /// Usada tanto por botones como por teclas globales
  void _playNext() {
    if (_files.isEmpty) return;

    int nextIndex;
    if (_musicPlayer.isShuffle.value) {
      nextIndex = _getNextShuffleIndex();
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
      // Remove manual update to let listener handle it and trigger save
      // _musicPlayer.isPlaying.value = false;

      // Actualizar estado de reproducción para Discord
      MusicStateService().updateMusicState(isPlaying: false);

      // Actualizar Discord para mostrar "En pausa"
      if (DiscordService().isConnected) {
        DiscordService().updateMusicPresence();
      }

      if (mounted) {
        setState(() {
          debugPrint('[MusicPlayer] UI updated to paused');
        });
      }
    } else {
      // Reanudar o reproducir
      if (_currentIndex == null && _files.isNotEmpty) {
        // Intentar recuperar el índice si hay un path guardado
        final currentPath = _musicPlayer.currentFilePath.value;
        if (currentPath.isNotEmpty) {
          final recoveredIndex = _files.indexWhere(
            (f) => f.path.toLowerCase() == currentPath.toLowerCase(),
          );
          if (recoveredIndex != -1) {
            debugPrint(
              '[MusicPlayer] Recovered index for resume: $recoveredIndex',
            );
            _playFile(recoveredIndex);
            return;
          }
        }

        // Si no hay canción seleccionada, reproducir la primera
        debugPrint('[MusicPlayer] No song selected, playing first file');
        _playFile(0);
      } else {
        // Si hay canción en pausa, reanudar
        debugPrint('[MusicPlayer] Resuming...');
        _player.resume();
        // Remove manual update to let listener handle it
        // _musicPlayer.isPlaying.value = true;

        // Actualizar estado de reproducción para Discord
        MusicStateService().updateMusicState(isPlaying: true);

        // Actualizar Discord para mostrar "Reproduciendo"
        if (DiscordService().isConnected) {
          DiscordService().updateMusicPresence();
        }

        if (mounted) {
          setState(() {
            debugPrint('[MusicPlayer] UI updated to playing');
          });
        }
      }
    }
  }

  /// Recargar solo los colores faltantes
  Future<void> _reloadMissingColors() async {
    if (_files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.getText(
                'no_songs_loaded',
                fallback: 'No hay canciones cargadas',
              ),
            ),
          ),
        );
      }
      return;
    }

    // Contar cuántos colores faltan
    int missingCount = 0;
    final List<File> filesToProcess = [];

    for (final fileEntity in _files) {
      final file = fileEntity as File;
      if (await LocalMusicDatabase().getDominantColor(file.path) == null) {
        missingCount++;
        filesToProcess.add(file);
      }
    }

    if (missingCount == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.getText(
                'all_colors_cached',
                fallback: 'Todos los colores ya están en caché',
              ),
            ),
          ),
        );
      }
      return;
    }

    final processedNotifier = ValueNotifier<int>(0);

    // Mostrar diálogo de progreso
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<int>(
        valueListenable: processedNotifier,
        builder: (context, processed, _) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            title: Text(
              widget.getText(
                'reloading_missing_colors',
                fallback: 'Recargando Colores Faltantes',
              ),
              style: const TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: missingCount > 0 ? processed / missingCount : 0,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFFBB86FC),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '$processed / $missingCount ${widget.getText('colors', fallback: 'colores')}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          );
        },
      ),
    );

    // Procesar solo archivos sin color
    try {
      for (final file in filesToProcess) {
        try {
          // LocalMusicDatabase handles extraction automatically
          await LocalMusicDatabase().getDominantColor(file.path);
        } catch (e) {
          debugPrint('[ColorCache] Error processing ${file.path}: $e');
        }

        processedNotifier.value++;
      }

      // Guardar caché final
      // Cache saved automatically by LocalMusicDatabase
    } finally {
      // Cerrar diálogo
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${processedNotifier.value} ${widget.getText('colors_processed', fallback: 'colores procesados')}',
            ),
          ),
        );
      }
      processedNotifier.dispose();
    }
  }

  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return _buildLibraryView();
  }

  Widget _buildLibraryView() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Column(
            children: [
              // Custom Tab Bar
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                height: 40,
                child: Row(
                  children: [
                    Expanded(
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          _buildTabButton(
                            widget.getText('home', fallback: 'Home'),
                            0,
                          ),
                          const SizedBox(width: 8),
                          _buildTabButton(
                            widget.getText('library', fallback: 'Library'),
                            1,
                          ),
                          const SizedBox(width: 8),
                          _buildTabButton(
                            widget.getText('playlists', fallback: 'Playlists'),
                            2,
                          ),
                        ],
                      ),
                    ),
                    // Menu button
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, color: Colors.white70),
                      color: const Color(0xFF1C1C1E),
                      onSelected: (value) {
                        if (value == 'reload_colors') {
                          _reloadMissingColors();
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'reload_colors',
                          child: Row(
                            children: [
                              const Icon(
                                Icons.palette,
                                color: Colors.amberAccent,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                widget.getText(
                                  'reload_missing_colors',
                                  fallback: 'Reload Missing Colors',
                                ),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),

              // Content
              Expanded(
                child: IndexedStack(
                  index: _tabIndex,
                  children: [
                    _buildHomeTab(),
                    _buildLibraryTab(),
                    _buildPlaylistsTab(),
                  ],
                ),
              ),
              // Spacing for MiniPlayer removed to allow content to scroll behind
            ],
          ),

          // Mini Player at the bottom
          Positioned(
            left: 32,
            right: 32,
            bottom: 32,
            child: MiniPlayer(getText: widget.getText),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(String label, int index) {
    bool isSelected = _tabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withOpacity(0.2) // Active
              : Colors.white.withOpacity(0.05), // Inactive
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            height: 1.0,
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    final historyPaths = MusicHistory().getHistory().take(10).toList();
    final playlists = PlaylistService().playlists.take(10).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          Text(
            widget.getText('recently_played', fallback: 'Recently Played'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (historyPaths.isEmpty)
            const Text(
              "No recently played songs.",
              style: TextStyle(color: Colors.grey),
            )
          else
            SizedBox(
              height: 160,
              child: ScrollConfiguration(
                behavior: const ScrollBehavior().copyWith(
                  scrollbars: false,
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse, // Enable mouse drag
                  },
                ),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics:
                      const AlwaysScrollableScrollPhysics(), // Ensure scrolling always works
                  itemCount: historyPaths.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    return _buildHistoryCard(historyPaths[index]);
                  },
                ),
              ),
            ),

          const SizedBox(height: 24),
          Text(
            widget.getText('recent_playlists', fallback: 'Recent Playlists'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (playlists.isEmpty)
            Container(
              height: 150,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text(
                  "No playlists yet",
                  style: TextStyle(color: Colors.white.withOpacity(0.3)),
                ),
              ),
            )
          else
            SizedBox(
              height: 160,
              child: ScrollConfiguration(
                behavior: const ScrollBehavior().copyWith(
                  scrollbars: false,
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse, // Enable mouse drag
                  },
                ),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: playlists.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    return _buildPlaylistCard(playlists[index]);
                  },
                ),
              ),
            ),

          const SizedBox(height: 24),
          Text(
            widget.getText('recent_favorites', fallback: 'Recent Favorites'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _buildRecentFavorites(),

          const SizedBox(
            height: 140,
          ), // Bottom padding increased to avoid overlap
        ],
      ),
    );
  }

  Widget _buildRecentFavorites() {
    final likedIds = PlaylistService().likedSongIds;
    if (likedIds.isEmpty) {
      return Container(
        height: 150,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            widget.getText('no_favorites_yet', fallback: 'No favorites yet'),
            style: TextStyle(color: Colors.white.withOpacity(0.3)),
          ),
        ),
      );
    }

    // Filtrar archivos que están en favoritos y tomar los últimos 10
    final favoritePaths = _files
        .where((file) => likedIds.contains(file.path.hashCode.toString()))
        .map((file) => file.path)
        .toList()
        .reversed // De la más reciente a la más antigua
        .take(10)
        .toList()
        .reversed // Invertir para mostrar de la más antigua a la más reciente
        .toList();

    if (favoritePaths.isEmpty) {
      return Container(
        height: 150,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            widget.getText(
              'no_favorites_in_library',
              fallback: 'No favorites in current library',
            ),
            style: TextStyle(color: Colors.white.withOpacity(0.3)),
          ),
        ),
      );
    }

    return SizedBox(
      height: 160,
      child: ScrollConfiguration(
        behavior: const ScrollBehavior().copyWith(
          scrollbars: false,
          dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse},
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: favoritePaths.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            return _buildFavoriteCard(favoritePaths[index]);
          },
        ),
      ),
    );
  }

  Widget _buildFavoriteCard(String filePath) {
    final file = File(filePath);
    final fileName = p.basename(filePath);

    return GestureDetector(
      onTap: () {
        final index = _files.indexWhere((f) => f.path == filePath);
        if (index != -1) {
          _playFile(index);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlayerScreen(getText: widget.getText),
            ),
          ).then((_) async {
            if (mounted) {
              final song = GlobalMusicPlayer().songsList.value.firstWhere(
                (s) => s.filePath == filePath,
                orElse: () => Song(id: '', title: '', artist: '', filePath: ''),
              );
              if (song.filePath.isNotEmpty) {
                final color = await LocalMusicDatabase().getDominantColor(
                  song.filePath,
                );
                GlobalThemeService().updateDominantColor(color);
              }
              if (mounted) setState(() {});
            }
          });
        }
      },
      child: Container(
        width: 160,
        height: 160,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: FutureBuilder<SongMetadata?>(
            future: _cacheAwareReadMetadata(file),
            builder: (context, snapshot) {
              final data = snapshot.data;
              final art = data?.artwork;
              final title = data?.title ?? fileName;
              final artist = data?.artist ?? "Unknown Artist";

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Background Image or Placeholder
                  art != null
                      ? Image.memory(art, fit: BoxFit.cover)
                      : Container(
                          color: Colors.grey[900],
                          child: const Icon(
                            Icons.music_note,
                            size: 50,
                            color: Colors.grey,
                          ),
                        ),

                  // Gradient Overlay
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.8),
                        ],
                        stops: const [0.5, 1.0],
                      ),
                    ),
                  ),

                  // Text Content
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.white,
                            shadows: [
                              Shadow(blurRadius: 2, color: Colors.black),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            shadows: [
                              Shadow(blurRadius: 2, color: Colors.black),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<SongMetadata?> _cacheAwareReadMetadata(File file) async {
    final key = file.path;

    // 1. Verificar caché en memoria
    if (_libraryMetadataCache.containsKey(key)) {
      return _libraryMetadataCache[key];
    }

    // 2. Usar LocalMusicDatabase (maneja caché automáticamente)
    try {
      final metadata = await LocalMusicDatabase().getMetadata(key);
      _libraryMetadataCache[key] = metadata;
      return metadata;
    } catch (e) {
      _libraryMetadataCache[key] = null;
      return null;
    }
  }

  Widget _buildHistoryCard(String filePath) {
    final file = File(filePath);
    final fileName = p.basename(filePath);

    return GestureDetector(
      onTap: () {
        final index = _files.indexWhere((f) => f.path == filePath);
        if (index != -1) {
          _playFile(index);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlayerScreen(getText: widget.getText),
            ),
          ).then((_) async {
            if (mounted) {
              // Refresh metadata and color from global state
              // Trigger global color update from current song
              final song = GlobalMusicPlayer().songsList.value.firstWhere(
                (s) => s.filePath == filePath,
                orElse: () => Song(id: '', title: '', artist: '', filePath: ''),
              );
              if (song.filePath.isNotEmpty) {
                // Fix: Get color from cache instead of passing raw bytes
                final color = await LocalMusicDatabase().getDominantColor(
                  song.filePath,
                );
                GlobalThemeService().updateDominantColor(color);
              }
              if (mounted) setState(() {});
            }
          });
        }
      },
      child: FutureBuilder<Color?>(
        future: LocalMusicDatabase().getDominantColor(filePath),
        builder: (context, colorSnapshot) {
          final dominantColor = colorSnapshot.data;
          final currentFilePath = GlobalMusicPlayer().currentFilePath.value;
          final isCurrentSong = currentFilePath == filePath;
          final isPlaying =
              GlobalMusicPlayer().isPlaying.value && isCurrentSong;

          return Container(
            width: 160,
            height: 160,
            margin: const EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(12),
              border: isCurrentSong && dominantColor != null
                  ? Border.all(color: dominantColor, width: 3)
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: FutureBuilder<SongMetadata?>(
                future: _cacheAwareReadMetadata(file),
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  final art = data?.artwork;
                  final title = data?.title ?? fileName;
                  final artist = data?.artist ?? "Unknown Artist";

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // Background Image or Placeholder
                      art != null
                          ? Image.memory(art, fit: BoxFit.cover)
                          : Container(
                              color: Colors.grey[900],
                              child: const Icon(
                                Icons.music_note,
                                size: 50,
                                color: Colors.grey,
                              ),
                            ),

                      // Gradient Overlay
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withOpacity(0.8),
                            ],
                            stops: const [0.5, 1.0],
                          ),
                        ),
                      ),

                      // Audio bars indicator - persistent for current song
                      if (isCurrentSong)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: _AnimatedAudioBars(
                            size: 16,
                            playing: GlobalMusicPlayer().isPlaying.value,
                          ),
                        ),

                      // Text Content
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.white,
                                shadows: [
                                  Shadow(blurRadius: 2, color: Colors.black),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                shadows: [
                                  Shadow(blurRadius: 2, color: Colors.black),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaylistCard(
    Playlist playlist, {
    bool isFavorite = false,
    double? width = 160,
    double? height = 160,
  }) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PlaylistDetailScreen(
              playlist: playlist,
              getText: widget.getText,
              isReadOnly: isFavorite,
            ),
          ),
        ).then((_) => setState(() {}));
      },
      onLongPress: isFavorite
          ? null
          : () {
              showModalBottomSheet(
                context: context,
                backgroundColor: const Color(0xFF1C1C1E),
                builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.delete, color: Colors.red),
                      title: Text(
                        widget.getText('delete', fallback: "Delete"),
                        style: const TextStyle(color: Colors.red),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        PlaylistService().deletePlaylist(playlist.id);
                        setState(() {});
                      },
                    ),
                  ],
                ),
              );
            },
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
          boxShadow: isFavorite
              ? [
                  BoxShadow(
                    color: Colors.purpleAccent.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background (Special for Favorites)
              if (isFavorite)
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.purpleAccent.withOpacity(0.6),
                        Colors.deepPurple.withOpacity(0.8),
                      ],
                    ),
                  ),
                  child: const Center(
                    child: Icon(Icons.favorite, size: 40, color: Colors.white),
                  ),
                )
              // Standard Playlist Image
              else if (playlist.imagePath != null)
                Image.file(File(playlist.imagePath!), fit: BoxFit.cover)
              else
                Container(
                  color: Colors.grey[800],
                  child: const Icon(
                    Icons.queue_music,
                    size: 40,
                    color: Colors.white54,
                  ),
                ),

              // Gradient Overlay (Only for non-favorites or image ones)
              if (!isFavorite || playlist.imagePath != null)
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.8),
                      ],
                      stops: const [0.5, 1.0],
                    ),
                  ),
                ),

              // Text Content
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 2, color: Colors.black)],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${playlist.songs.length} songs",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        shadows: [Shadow(blurRadius: 2, color: Colors.black)],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Construct virtual Favorites playlist

  Widget _buildLibraryTab() {
    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              widget.getText('no_songs_loaded', fallback: "No songs loaded"),
            ),
            TextButton(
              onPressed: _selectFolder,
              child: Text(
                widget.getText('select_folder', fallback: "Select Folder"),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: _filteredFiles.length,
      addRepaintBoundaries: true,
      cacheExtent: 500, // Increased cache
      addAutomaticKeepAlives: true, // Keep items alive
      itemBuilder: (context, index) {
        final file = _filteredFiles[index] as File;
        final name = p.basename(file.path);
        // Basic list tile
        final isPlaying =
            _currentIndex != null && _files.indexOf(file) == _currentIndex;

        return FutureBuilder<SongMetadata?>(
          future: _cacheAwareReadMetadata(file),
          builder: (context, snapshot) {
            final data = snapshot.data;
            final art = data?.artwork; // This will prompt library to load art
            final title = data?.title ?? name;
            final artist = data?.artist ?? "Unknown Artist";

            return ListTile(
              key: ValueKey(file.path), // Prevent rebuilds on scroll
              leading: Container(
                width: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  image: art != null
                      ? DecorationImage(
                          image: MemoryImage(art),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: art == null
                    ? const Icon(Icons.music_note, color: Colors.grey)
                    : null,
              ),
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isPlaying ? Colors.purpleAccent : Colors.white,
                  fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              subtitle: Text(
                artist,
                style: const TextStyle(color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                color: const Color(0xFF1C1C1E),
                onSelected: (value) async {
                  if (value == 'add_to_playlist') {
                    await _showAddToPlaylistDialog(file);
                  } else if (value == 'toggle_favorite') {
                    final song = await Song.fromFile(file);
                    if (song != null) {
                      PlaylistService().toggleLike(song.id);
                      if (mounted) setState(() {}); // Actualizar UI
                    }
                  } else if (value == 'delete') {
                    // Confirm delete logic could go here
                  }
                },
                itemBuilder: (BuildContext context) {
                  // Usar el mismo sistema de ID que Song.fromFile
                  final songId = file.path.hashCode.toString();
                  final isLiked = PlaylistService().isLiked(songId);
                  return [
                    PopupMenuItem(
                      value: 'add_to_playlist',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.playlist_add,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            widget.getText(
                              'add_to_playlist',
                              fallback: "Add to Playlist",
                            ),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'toggle_favorite',
                      child: Row(
                        children: [
                          Icon(
                            isLiked ? Icons.favorite : Icons.favorite_border,
                            color: isLiked ? Colors.purpleAccent : Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.getText(
                              isLiked ? 'remove_favorites' : 'add_favorites',
                              fallback: isLiked
                                  ? "Remove from Favorites"
                                  : "Add to Favorites",
                            ),
                            style: TextStyle(
                              color: isLiked
                                  ? Colors.purpleAccent
                                  : Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            widget.getText('delete', fallback: "Delete"),
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ),
                    ),
                  ];
                },
              ),
              onTap: () {
                final actualIndex = _files.indexOf(file);
                // When playing from library, update metadata immediately for UI feedback
                if (mounted) {
                  setState(() {
                    _currentIndex = actualIndex;
                    // Local metadata updates removed
                  });
                }
                _playFile(actualIndex);
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showAddToPlaylistDialog(File file) async {
    final playlists = PlaylistService().playlists;
    // We need Song ID check
    final song = await Song.fromFile(file);
    if (song == null) return;

    await showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 350,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                widget.getText('add_playlist', fallback: "Add to Playlist"),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),

              // New Playlist Button
              Material(
                color: Colors.purpleAccent.withOpacity(0.1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: Colors.purpleAccent.withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    Navigator.pop(context);
                    _showCreatePlaylistDialog();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.purpleAccent.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.add,
                            color: Colors.purpleAccent,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          widget.getText(
                            'new_playlist',
                            fallback: "New Playlist",
                          ),
                          style: const TextStyle(
                            color: Colors.purpleAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Playlist List
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    final alreadyIn = playlist.songs.any(
                      (s) => s.filePath == file.path,
                    );

                    return Material(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: alreadyIn
                            ? null
                            : () {
                                PlaylistService().addSongToPlaylist(
                                  playlist.id,
                                  song,
                                );
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text("Added to ${playlist.name}"),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    backgroundColor: Colors.grey[900],
                                  ),
                                );
                              },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              // Playlist Image
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: Colors.grey[850],
                                  borderRadius: BorderRadius.circular(8),
                                  image: playlist.imagePath != null
                                      ? DecorationImage(
                                          image: FileImage(
                                            File(playlist.imagePath!),
                                          ),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: playlist.imagePath == null
                                    ? const Icon(
                                        Icons.queue_music,
                                        color: Colors.white54,
                                        size: 24,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 16),
                              // Info
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      playlist.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w500,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${playlist.songs.length} ${widget.getText('songs', fallback: 'songs')}',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.5),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Status Badge
                              if (alreadyIn)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF1E3A25,
                                    ), // Dark green bg
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.check_circle,
                                        color: Color(
                                          0xFF4CAF50,
                                        ), // Bright green
                                        size: 14,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        widget.getText(
                                          'added',
                                          fallback: "Added",
                                        ),
                                        style: const TextStyle(
                                          color: Color(0xFF4CAF50),
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
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

              // Cancel Button
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      widget.getText('cancel', fallback: "Cancel"),
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    String? selectedImagePath;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(
              widget.getText('new_playlist', fallback: "New Playlist"),
              style: const TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () async {
                    FilePickerResult? result = await FilePicker.platform
                        .pickFiles(type: FileType.image);
                    if (result != null) {
                      setDialogState(() {
                        selectedImagePath = result.files.single.path;
                      });
                    }
                  },
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(12),
                      image: selectedImagePath != null
                          ? DecorationImage(
                              image: FileImage(File(selectedImagePath!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: selectedImagePath == null
                        ? const Icon(
                            Icons.add_photo_alternate,
                            color: Colors.white54,
                            size: 40,
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  cursorColor: Colors.purpleAccent,
                  decoration: InputDecoration(
                    labelText: widget.getText('name', fallback: "Name"),
                    labelStyle: const TextStyle(color: Colors.grey),
                    enabledBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey),
                    ),
                    focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.purpleAccent),
                    ),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
                TextField(
                  controller: descController,
                  cursorColor: Colors.purpleAccent,
                  decoration: InputDecoration(
                    labelText: widget.getText(
                      'description',
                      fallback: "Description",
                    ),
                    labelStyle: const TextStyle(color: Colors.grey),
                    enabledBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.grey),
                    ),
                    focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.purpleAccent),
                    ),
                  ),
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  widget.getText('cancel', fallback: "Cancel"),
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () {
                  if (nameController.text.isNotEmpty) {
                    PlaylistService().createPlaylist(
                      nameController.text,
                      description: descController.text,
                      imagePath: selectedImagePath,
                    );
                    Navigator.pop(context);
                    setState(() {});
                  }
                },
                child: Text(
                  widget.getText('create', fallback: "Create"),
                  style: const TextStyle(color: Colors.purpleAccent),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // Keyboard handling disabled locally as it's handled globally
  // void _handleKeyboardEvent(RawKeyEvent event) { ... }

  Widget _buildPlaylistsTab() {
    final playlists = PlaylistService().playlists;
    // Ensure favorites playlist is built correctly or use placeholder
    final favoritesPlaylist = _buildFavoritesPlaylist();
    // 1 for Favorites + N playlists + 1 for Create Button
    final itemCount = playlists.length + 2;

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200, // Reduced from 1:1 fixed crossAxisCount: 2
        childAspectRatio: 1.0,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        // 1. Favorites (First)
        if (index == 0) {
          return _buildPlaylistCard(
            favoritesPlaylist,
            isFavorite: true,
            width: null, // Flexible width for Grid
            height: null,
          );
        }

        // 3. Create Playlist (Last)
        if (index == itemCount - 1) {
          return _buildCreatePlaylistCard();
        }

        // 2. Existing Playlists
        // Index 0 is Favorites, so playlist index starts at 0 when index is 1
        return _buildPlaylistCard(
          playlists[index - 1],
          width: null, // Flexible width for Grid
          height: null,
        );
      },
    );
  }

  Playlist _buildFavoritesPlaylist() {
    final likedIds = PlaylistService().likedSongIds;
    final favoriteSongs = <Song>[];

    if (_files.isNotEmpty) {
      for (var entity in _files) {
        if (entity is File) {
          // Usar el mismo sistema de ID que Song.fromFile
          final songId = entity.path.hashCode.toString();
          if (likedIds.contains(songId)) {
            favoriteSongs.add(
              Song(
                id: songId,
                title: p.basename(entity.path),
                artist: 'Unknown',
                filePath: entity.path,
              ),
            );
          }
        }
      }
    }

    return Playlist(
      id: 'favorites',
      name: widget.getText('favorites', fallback: 'Favorites'),
      songs: favoriteSongs,
      isPinned: true,
      createdAt: DateTime.now(),
      lastOpened: DateTime.now(),
    );
  }

  Widget _buildCreatePlaylistCard() {
    return GestureDetector(
      onTap: () => _showCreatePlaylistDialog(),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withOpacity(0.3),
            width: 1,
            style: BorderStyle.solid,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.purpleAccent.withOpacity(0.2),
              ),
              child: const Icon(
                Icons.add,
                size: 32,
                color: Colors.purpleAccent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.getText('create_playlist', fallback: 'Create Playlist'),
              style: const TextStyle(
                color: Colors.purpleAccent,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// Animated audio bars widget for playing indicator
class _AnimatedAudioBars extends StatefulWidget {
  final double size;
  final bool playing;

  const _AnimatedAudioBars({required this.size, required this.playing});

  @override
  State<_AnimatedAudioBars> createState() => _AnimatedAudioBarsState();
}

class _AnimatedAudioBarsState extends State<_AnimatedAudioBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    if (widget.playing) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_AnimatedAudioBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing) {
      if (widget.playing) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildBar(0.3 + (_controller.value * 0.7)),
              _buildBar(0.5 + (_controller.value * 0.5)),
              _buildBar(0.4 + (_controller.value * 0.6)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBar(double heightFactor) {
    return Container(
      width: widget.size / 5,
      height: widget.size * heightFactor,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(widget.size / 10),
      ),
    );
  }
}
