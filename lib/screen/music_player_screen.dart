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
  String _currentTitle = '';
  String _currentArtist = '';
  Uint8List? _currentArt;
  Color? _dominantColor;
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
      _currentTitle = _musicPlayer.currentTitle.value;
      _currentArtist = _musicPlayer.currentArtist.value;
      _currentArt = _musicPlayer.currentArt.value;

      // Restaurar color dominante desde el caché
      if (_musicPlayer.currentFilePath.value.isNotEmpty) {
        LocalMusicDatabase()
            .getDominantColor(_musicPlayer.currentFilePath.value)
            .then((cachedColor) {
              if (cachedColor != null && mounted) {
                setState(() => _dominantColor = cachedColor);
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
    if (mounted) {
      final newArt = _musicPlayer.currentArt.value;
      // If the art changed, we might need to update the color
      if (newArt != _currentArt) {
        final path = _musicPlayer.currentFilePath.value;
        if (path.isNotEmpty) {
          _updateGlobalColor(path, newArt);
        }
      }

      setState(() {
        _currentTitle = _musicPlayer.currentTitle.value;
        _currentArtist = _musicPlayer.currentArtist.value;
        _currentArt = newArt;
      });
    }
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

    // Update Local State (Only if mounted)
    if (mounted && color != null) {
      setState(() {
        _dominantColor = color;
      });
    }
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
    final index = _files.indexWhere((f) => f.path == path);

    if (index != -1) {
      if (_currentIndex != index) {
        setState(() {
          _currentIndex = index;
        });
      }
      // Sync local UI state from global state (already set by PlayerScreen or elsewhere)
      // Only sync local variables - NO metadata fetching needed here
      // as the source that changed currentIndex is responsible for setting metadata
      if (mounted) {
        setState(() {
          _currentTitle = _musicPlayer.currentTitle.value;
          _currentArtist = _musicPlayer.currentArtist.value;
          _currentArt = _musicPlayer.currentArt.value;
        });
      }
    } else {
      // Song not in this folder.
      if (_currentIndex != null) {
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
            _currentTitle = _musicPlayer.currentTitle.value;
            _currentArtist = _musicPlayer.currentArtist.value;
            _currentArt = _musicPlayer.currentArt.value;
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
          _currentTitle = '';
          _currentArtist = '';
          _currentArt = null;
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
      // Actualizar estado global y local inmediatamente
      _musicPlayer.isPlaying.value = false;

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
        // Si no hay canción seleccionada, reproducir la primera
        debugPrint('[MusicPlayer] No song selected, playing first file');
        _playFile(0);
      } else {
        // Si hay canción en pausa, reanudar
        debugPrint('[MusicPlayer] Resuming...');
        _player.resume();
        // Actualizar estado global y local inmediatamente
        _musicPlayer.isPlaying.value = true;

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

              // Spacing for MiniPlayer
              const SizedBox(height: 80),
            ],
          ),

          // Mini Player at the bottom
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _buildMiniPlayer(),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(String label, int index) {
    bool isSelected = _tabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withOpacity(0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.transparent : Colors.transparent,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey,
            fontWeight: FontWeight.bold,
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

          const SizedBox(height: 100), // Bottom padding
        ],
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
      child: Container(
        width: 160,
        height: 160,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
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

  Widget _buildPlaylistCard(Playlist playlist) {
    return GestureDetector(
      onTap: () {
        // TODO: Restore PlaylistDetailScreen
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Playlist detail screen temporarily unavailable'),
          ),
        );
        // Navigator.push(
        //   context,
        //   MaterialPageRoute(
        //     builder: (context) => PlaylistDetailScreen(playlist: playlist),
        //   ),
        // ).then((_) => setState(() {}));
      },
      onLongPress: () {
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
        width: 160,
        height: 160,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background Image
              playlist.imagePath != null
                  ? Image.file(File(playlist.imagePath!), fit: BoxFit.cover)
                  : Container(
                      color: Colors.grey[800],
                      child: const Icon(
                        Icons.queue_music,
                        size: 40,
                        color: Colors.white54,
                      ),
                    ),

              // Gradient Overlay
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
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
                  // Ensure explicit transparency here
                  color: Colors.transparent,
                  // Remove any shadow or border that might imply a container
                  borderRadius: BorderRadius.circular(12),
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
                    }
                  } else if (value == 'delete') {
                    // Confirm delete logic could go here
                  }
                },
                itemBuilder: (BuildContext context) {
                  return [
                    PopupMenuItem(
                      value: 'add_to_playlist',
                      child: Text(
                        widget.getText(
                          'add_to_playlist',
                          fallback: "Add to Playlist",
                        ),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'toggle_favorite',
                      child: Text(
                        widget.getText('favorite', fallback: "Favorite"),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        widget.getText('delete', fallback: "Delete"),
                        style: const TextStyle(color: Colors.red),
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
                    _currentTitle = title;
                    _currentArtist = artist;
                    _currentArt = art;
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
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: Text(
          widget.getText('add_to_playlist', fallback: "Add to Playlist"),
          style: const TextStyle(color: Colors.white),
        ),
        content: SizedBox(
          width: 300,
          height: 300,
          child: ListView.builder(
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              final alreadyIn = playlist.songs.any(
                (s) => s.filePath == file.path,
              );

              return ListTile(
                title: Text(
                  playlist.name,
                  style: TextStyle(
                    color: alreadyIn ? Colors.grey : Colors.white,
                  ),
                ),
                trailing: alreadyIn
                    ? const Icon(Icons.check, color: Colors.purpleAccent)
                    : null,
                onTap: alreadyIn
                    ? null
                    : () {
                        PlaylistService().addSongToPlaylist(playlist.id, song);
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("Added to ${playlist.name}")),
                        );
                      },
              );
            },
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

  Widget _buildPlaylistsTab() {
    final playlists = PlaylistService().playlists;

    return GridView.builder(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 100),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.8,
      ),
      itemCount: playlists.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return GestureDetector(
            onTap: _showCreatePlaylistDialog,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.purpleAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.purpleAccent.withOpacity(0.3),
                  width: 1,
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
                    widget.getText(
                      'create_playlist',
                      fallback: "Create Playlist",
                    ),
                    style: const TextStyle(
                      color: Colors.purpleAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return _buildPlaylistCard(playlists[index - 1]);
      },
    );
  }

  Widget _buildMiniPlayer() {
    // Hide if no song is loaded
    if (_currentTitle.isEmpty && _currentArt == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PlayerScreen(getText: widget.getText),
          ),
        ).then((_) {
          if (mounted) setState(() {});
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
        height: 80, // Slightly taller for floating effect
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        margin: const EdgeInsets.only(
          bottom: 16,
          left: 16,
          right: 16,
        ), // Floating margin
        decoration: BoxDecoration(
          color: Colors.transparent, // Explicit transparency for glass effect
          borderRadius: BorderRadius.circular(16),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: (_dominantColor ?? const Color(0xFF1C1C1E)).withOpacity(
                  0.60,
                ),
                borderRadius: BorderRadius.circular(16),
                // No shadow for glass feel
              ),
              child: Row(
                children: [
                  // Artwork
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: Container(
                      key: ValueKey(_currentTitle),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey[800],
                        image: _currentArt != null
                            ? DecorationImage(
                                image: MemoryImage(_currentArt!),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: _currentArt == null
                          ? const Icon(Icons.music_note, color: Colors.white54)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Title & Artist
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _currentTitle.isEmpty ? "No song" : _currentTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          _currentArtist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Controls
                  ValueListenableBuilder<bool>(
                    valueListenable: _musicPlayer.isPlaying,
                    builder: (context, isPlaying, _) {
                      return IconButton(
                        iconSize: 32,
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                        // Remove debug prints or keep them minimal
                        onPressed: _togglePlayPause,
                      );
                    },
                  ),
                  IconButton(
                    iconSize: 32,
                    icon: const Icon(
                      Icons.skip_next_rounded,
                      color: Colors.white,
                    ),
                    onPressed: _playNext,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Keyboard handling disabled locally as it's handled globally
  // void _handleKeyboardEvent(RawKeyEvent event) { ... }
}
