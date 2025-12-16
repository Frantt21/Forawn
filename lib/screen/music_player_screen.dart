import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/global_music_player.dart';
import '../services/music_history.dart';
import '../services/global_keyboard_service.dart';
import '../services/album_color_cache.dart';
import '../services/music_state_service.dart';
import '../services/discord_service.dart';
import '../services/thumbnail_search_service.dart';
import '../services/lyrics_service.dart';
import '../models/synced_lyrics.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:palette_generator/palette_generator.dart';
import 'lyrics_display_widget.dart';

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
  List<FileSystemEntity> _filteredFiles = []; // Lista filtrada para búsqueda

  bool _isLoading = false;
  bool _showPlaylist = false;
  bool _toggleLocked = false;
  bool _useBlurBackground = true; // Estado para fondo difuminado

  // Controlador de búsqueda
  final TextEditingController _searchController =
      TextEditingController(); // Controlador de búsqueda

  // Campos para UI local (sincronizados con global)
  String _currentTitle = '';
  String _currentArtist = '';
  Uint8List? _currentArt;
  Color? _dominantColor;
  int? _currentIndex;
  final Set<int> _playedIndices = {}; // Rastreo para shuffle inteligente

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _musicPlayer = GlobalMusicPlayer();
    _player = _musicPlayer.player;
    debugPrint('[MusicPlayer] initState - Player state: ${_player.state}');

    // Cargar caché de colores
    AlbumColorCache().loadCache();

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
        final cachedColor = AlbumColorCache().getColor(
          _musicPlayer.currentFilePath.value,
        );
        if (cachedColor != null) {
          _dominantColor = cachedColor;
        }
      }
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
      debugPrint('[MusicPlayer] Cached state - Playlist: $_showPlaylist');
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

  Future<void> _updateMetadataFromFile(int index) async {
    if (index < 0 || index >= _files.length) return;
    _playedIndices.add(
      index,
    ); // Registrar en historial para shuffle inteligente
    final file = _files[index] as File;

    try {
      // Valor por defecto
      String title = p.basename(file.path);
      String artist = 'Unknown Artist';
      Uint8List? artwork;

      // Intentar leer metadatos reales
      try {
        final metadata = readMetadata(file, getImage: true);
        if (metadata.title?.isNotEmpty == true) {
          title = metadata.title!;
        }
        if (metadata.artist?.isNotEmpty == true) {
          artist = metadata.artist!;
        }
        if (metadata.pictures.isNotEmpty) {
          artwork = metadata.pictures.first.bytes;
        }
      } catch (e) {
        debugPrint('[MusicPlayer] Error reading metadata in background: $e');
      }

      // Detener reproducción anterior
      await _musicPlayer.player.stop();

      // Reproducir archivo
      await _musicPlayer.player.play(DeviceFileSource(file.path));

      // Actualizar estado global INMEDIATAMENTE con metadatos
      _musicPlayer.currentTitle.value = title;
      _musicPlayer.currentArtist.value = artist;
      _musicPlayer.currentArt.value = artwork; // Actualizar portada!
      _musicPlayer.currentIndex.value = index;
      _musicPlayer.currentFilePath.value = file.path;
      _musicPlayer.filesList.value = _files;

      // Agregar al historial también en background
      MusicHistory().addToHistory(file);

      // Pequeño delay antes de obtener duración y colores
      Future.delayed(const Duration(milliseconds: 100), () async {
        final dur = await _musicPlayer.player.getDuration();
        _musicPlayer.duration.value = dur ?? Duration.zero;

        // Procesar color si hay arte
        if (artwork != null) {
          // Intentar obtener color del caché primero
          Color? dominantColor = AlbumColorCache().getColor(file.path);

          // Si no está en caché y hay artwork, extraer el color
          if (dominantColor == null) {
            try {
              final paletteGenerator = await PaletteGenerator.fromImageProvider(
                MemoryImage(artwork),
                size: const Size(50, 50),
              );
              dominantColor =
                  paletteGenerator.dominantColor?.color ??
                  paletteGenerator.vibrantColor?.color;

              if (dominantColor != null) {
                await AlbumColorCache().setColor(file.path, dominantColor);
              }
            } catch (e) {
              debugPrint(
                '[MusicPlayer] Error extracting color in background: $e',
              );
            }
          }
          // Aquí no actualizamos UI local de color porque asumimos background,
          // pero el componente que escuche podría querer saber el color.
          // Por ahora, el MiniPlayer no usa el color dominante global (¿o sí?),
          // pero sí usa el artwork.
        }
      });

      // Si por casualidad estamos montados (caso raro), actualizar local
      if (mounted) {
        setState(() {
          _currentTitle = title;
          _currentArtist = artist;
          _currentArt = artwork;
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

      // Cargar preferencia de fondo difuminado
      if (mounted) {
        setState(() {
          _useBlurBackground = prefs.getBool('use_blur_background') ?? false;
        });
      }
      final folder = prefs.getString('download_folder');
      if (folder != null && folder.isNotEmpty) {
        await _loadFiles(folder);

        // Verificar auto-actualización de colores
        if (await AlbumColorCache().getAutoUpdateOnStartup()) {
          // Ejecutar en segundo plano sin esperar
          _preloadAllColors();
        }
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
          _filteredFiles = allFiles; // Inicializar lista filtrada
          _playedIndices.clear(); // Reiniciar historial de shuffle
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

  /// Filtrar archivos según búsqueda
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

      if (metadata.title?.isNotEmpty == true) {
        title = metadata.title!;
      }
      if (metadata.artist?.isNotEmpty == true) {
        artist = metadata.artist!;
      }
      if (metadata.pictures.isNotEmpty) {
        artwork = metadata.pictures.first.bytes;
      }

      // Intentar obtener color del caché primero
      Color? dominantColor = AlbumColorCache().getColor(filePath);

      // Si no está en caché y hay artwork, extraer el color
      if (dominantColor == null && artwork != null) {
        try {
          final paletteGenerator = await PaletteGenerator.fromImageProvider(
            MemoryImage(artwork),
            size: const Size(50, 50), // Reducido para mejor rendimiento
          );
          dominantColor =
              paletteGenerator.dominantColor?.color ??
              paletteGenerator.vibrantColor?.color;

          // Guardar en caché para uso futuro
          if (dominantColor != null) {
            await AlbumColorCache().setColor(filePath, dominantColor);
          }
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

      // Buscar thumbnail de YouTube para Discord (en background)
      ThumbnailSearchService().searchThumbnail(title, artist).then((
        thumbnailUrl,
      ) {
        if (thumbnailUrl != null) {
          MusicStateService().updateMusicState(thumbnailUrl: thumbnailUrl);
          // Actualizar Discord con el nuevo thumbnail
          if (DiscordService().isConnected) {
            DiscordService().updateMusicPresence();
          }
        }
      });

      // Actualizar servicio de estado de música para Discord
      MusicStateService().updateMusicState(
        title: title,
        artist: artist,
        artwork: artwork,
        isPlaying: _isPlaying,
        duration: _musicPlayer.duration.value,
        position: _musicPlayer.position.value,
      );

      // Actualizar Discord Rich Presence si está conectado
      if (DiscordService().isConnected) {
        DiscordService().updateMusicPresence();
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

      // Actualizar servicio de estado de música para Discord
      MusicStateService().updateMusicState(
        title: title,
        artist: artist,
        artwork: null,
        isPlaying: _isPlaying,
        duration: _musicPlayer.duration.value,
        position: _musicPlayer.position.value,
      );

      // Actualizar Discord Rich Presence si está conectado
      if (DiscordService().isConnected) {
        DiscordService().updateMusicPresence();
      }
    }
  }

  Future<void> _playFile(int index) async {
    if (index < 0 || index >= _files.length) return;
    final file = _files[index] as File;

    try {
      if (mounted) {
        setState(() {
          _currentIndex = index;
          _playedIndices.add(index); // Marcar como reproducida
        });
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

  /// Calcular color con buen contraste basado en el color dominante
  Color _getContrastColor(Color? baseColor) {
    if (baseColor == null)
      return Colors.black; // Negro sobre blanco por defecto

    // Calcular luminancia
    final luminance = baseColor.computeLuminance();

    // Si el color es oscuro, usar blanco; si es claro, usar negro
    return luminance > 0.5 ? Colors.black : Colors.white;
  }

  /// Mostrar menú de opciones de caché de colores
  /// Mostrar menú de opciones de caché de colores
  void _showColorCacheMenu() {
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return FutureBuilder<bool>(
            future: AlbumColorCache().getAutoUpdateOnStartup(),
            builder: (context, snapshot) {
              final autoUpdate = snapshot.data ?? false;

              return AlertDialog(
                backgroundColor: const Color(0xFF1E1E1E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                title: Row(
                  children: [
                    const Icon(Icons.settings, color: Colors.purpleAccent),
                    const SizedBox(width: 8),
                    Text(
                      widget.getText(
                        'player_options',
                        fallback: 'Player Options',
                      ),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.getText('cached_colors', fallback: 'Cached colors')}: ${AlbumColorCache().getStats()['totalColors']}',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.getText(
                        'configuration',
                        fallback: 'Configuration:',
                      ),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Opción de fondo difuminado
                    Theme(
                      data: ThemeData(
                        unselectedWidgetColor: Colors.white54,
                        checkboxTheme: CheckboxThemeData(
                          fillColor: MaterialStateProperty.resolveWith(
                            (states) => states.contains(MaterialState.selected)
                                ? Colors.purpleAccent
                                : Colors.white54,
                          ),
                        ),
                      ),
                      child: CheckboxListTile(
                        title: Text(
                          widget.getText(
                            'blur_background',
                            fallback: 'Blurred album cover background',
                          ),
                          style: const TextStyle(color: Colors.white),
                        ),
                        value: _useBlurBackground,
                        onChanged: (value) async {
                          if (value != null) {
                            setState(() => _useBlurBackground = value);
                            setDialogState(() {});
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setBool('use_blur_background', value);
                          }
                        },
                        contentPadding: EdgeInsets.zero,
                        activeColor: Colors.purpleAccent,
                      ),
                    ),
                    // Opción de auto-actualización
                    Theme(
                      data: ThemeData(
                        unselectedWidgetColor: Colors.white54,
                        checkboxTheme: CheckboxThemeData(
                          fillColor: MaterialStateProperty.resolveWith(
                            (states) => states.contains(MaterialState.selected)
                                ? Colors.purpleAccent
                                : Colors.white54,
                          ),
                        ),
                      ),
                      child: CheckboxListTile(
                        title: Text(
                          widget.getText(
                            'auto_update_colors',
                            fallback: 'Update colors on startup',
                          ),
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          widget.getText(
                            'may_take_longer',
                            fallback: 'May take a bit longer to start',
                          ),
                          style: const TextStyle(color: Colors.white54),
                        ),
                        value: autoUpdate,
                        onChanged: (value) async {
                          if (value != null) {
                            await AlbumColorCache().setAutoUpdateOnStartup(
                              value,
                            );
                            setDialogState(() {});
                          }
                        },
                        contentPadding: EdgeInsets.zero,
                        activeColor: Colors.purpleAccent,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Botones de acción adicionales
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            Navigator.pop(dialogContext);
                            await _preloadAllColors();
                          },
                          icon: const Icon(
                            Icons.refresh,
                            size: 16,
                            color: Colors.purpleAccent,
                          ),
                          label: Text(
                            widget.getText(
                              'preload_colors',
                              fallback: 'Preload',
                            ),
                            style: const TextStyle(color: Colors.purpleAccent),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            Navigator.pop(dialogContext);
                            await AlbumColorCache().clearCache();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    widget.getText(
                                      'cache_cleared',
                                      fallback: 'Cache cleared',
                                    ),
                                  ),
                                  backgroundColor: const Color(0xFF2C2C2C),
                                  action: SnackBarAction(
                                    label: 'OK',
                                    onPressed: () {},
                                    textColor: Colors.purpleAccent,
                                  ),
                                ),
                              );
                            }
                          },
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: Colors.redAccent,
                          ),
                          label: Text(
                            widget.getText(
                              'clear_cache',
                              fallback: 'Clear Cache',
                            ),
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(
                      widget.getText('close', fallback: 'Close'),
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  /// Pre-cargar colores de todas las canciones
  Future<void> _preloadAllColors() async {
    if (_files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.getText('no_songs_loaded', fallback: 'No songs loaded'),
            ),
          ),
        );
      }
      return;
    }

    final processedNotifier = ValueNotifier<int>(0);
    final total = _files.length;

    // Mostrar diálogo de progreso
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<int>(
        valueListenable: processedNotifier,
        builder: (context, processed, _) {
          return AlertDialog(
            title: Text(
              widget.getText(
                'processing_colors',
                fallback: 'Processing Colors',
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: total > 0 ? processed / total : 0,
                ),
                const SizedBox(height: 16),
                Text(
                  '$processed / $total ${widget.getText('songs_count', fallback: 'songs')}',
                ),
              ],
            ),
          );
        },
      ),
    );

    // Procesar archivos en segundo plano
    try {
      for (final fileEntity in _files) {
        final file = fileEntity as File;
        final filePath = file.path;

        // Saltar si ya está en caché
        if (AlbumColorCache().getColor(filePath) != null) {
          processedNotifier.value++;
          continue;
        }

        try {
          final metadata = readMetadata(file, getImage: true);
          if (metadata?.pictures.isNotEmpty == true) {
            final artwork = metadata!.pictures.first.bytes;
            final paletteGenerator = await PaletteGenerator.fromImageProvider(
              MemoryImage(artwork),
              size: const Size(50, 50),
            );
            final color =
                paletteGenerator.dominantColor?.color ??
                paletteGenerator.vibrantColor?.color;

            if (color != null) {
              await AlbumColorCache().setColor(filePath, color);
            }
          }
        } catch (e) {
          debugPrint('[ColorCache] Error processing $filePath: $e');
        }

        processedNotifier.value++;
      }

      // Guardar caché final
      await AlbumColorCache().saveCache();
    } finally {
      // Cerrar diálogo
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${processedNotifier.value} ${widget.getText('colors_processed', fallback: 'colors processed')}',
            ),
          ),
        );
      }
      processedNotifier.dispose();
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
            child: Stack(
              children: [
                // Fondo difuminado (si está activado)
                if (_useBlurBackground && _currentArt != null)
                  Positioned.fill(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 800),
                      child: ImageFiltered(
                        key: ValueKey(_currentTitle),
                        imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                        child: Container(
                          decoration: BoxDecoration(
                            image: DecorationImage(
                              image: MemoryImage(_currentArt!),
                              fit: BoxFit.cover,
                            ),
                          ),
                          child: Container(
                            color: _dominantColor != null
                                ? _dominantColor!.withOpacity(0.3)
                                : Colors.black.withOpacity(0.5),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Panel de Lyrics Global (entre fondo y controles)
                ValueListenableBuilder<bool>(
                  valueListenable: _musicPlayer.showLyrics,
                  builder: (context, showLyrics, _) {
                    if (!showLyrics) return const SizedBox.shrink();

                    return ValueListenableBuilder<SyncedLyrics?>(
                      valueListenable: _musicPlayer.currentLyrics,
                      builder: (context, lyrics, _) {
                        if (lyrics == null || !lyrics.hasLyrics) {
                          return const SizedBox.shrink();
                        }

                        return Positioned.fill(
                          child: LyricsDisplay(
                            lyrics: lyrics,
                            currentIndexNotifier:
                                _musicPlayer.currentLyricIndex,
                            getText: widget.getText,
                          ),
                        );
                      },
                    );
                  },
                ),

                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.all(24),
                  decoration: _dominantColor != null && !_useBlurBackground
                      ? BoxDecoration(color: _dominantColor!.withOpacity(0.08))
                      : _useBlurBackground
                      ? null
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
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 500),
                            child: Container(
                              key: ValueKey(_currentTitle),
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
                                          color: _dominantColor!.withOpacity(
                                            0.5,
                                          ),
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
                      ),

                      const Spacer(flex: 1),

                      // Metadata
                      Text(
                        _currentTitle.isEmpty
                            ? widget.getText(
                                'no_song',
                                fallback: 'No Song Playing',
                              )
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
                        style: TextStyle(
                          fontSize: 16,
                          color: _dominantColor ?? Colors.purpleAccent,
                          fontWeight: FontWeight.w500,
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
                                      activeTrackColor:
                                          _dominantColor ?? Colors.purpleAccent,
                                      inactiveTrackColor: Colors.grey[800],
                                      thumbColor:
                                          _dominantColor ?? Colors.white,
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
                                color: _getContrastColor(_dominantColor),
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
                              final nextIndex =
                                  (currentIndex + 1) % modes.length;
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
                                _dominantColor?.withOpacity(0.7) ??
                                Colors.white54,
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
                            tooltip: widget.getText(
                              'show_miniplayer',
                              fallback: 'Show mini player',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),

                // Botón de lyrics flotante
                Positioned(
                  top: 16,
                  right: 64,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _musicPlayer.showLyrics,
                    builder: (context, showLyrics, child) {
                      return IconButton(
                        icon: Icon(
                          showLyrics ? Icons.lyrics : Icons.lyrics_outlined,
                          color: showLyrics
                              ? Colors.purpleAccent
                              : Colors.white70,
                        ),
                        onPressed: () {
                          _musicPlayer.showLyrics.value = !showLyrics;
                        },
                        tooltip: widget.getText(
                          showLyrics ? 'hide_lyrics' : 'show_lyrics',
                          fallback: showLyrics ? 'Hide lyrics' : 'Show lyrics',
                        ),
                      );
                    },
                  ),
                ),

                // Botón de menú flotante
                Positioned(
                  top: 16,
                  right: 16,
                  child: IconButton(
                    icon: const Icon(Icons.more_vert, color: Colors.white70),
                    onPressed: _showColorCacheMenu,
                    tooltip: widget.getText(
                      'cache_options',
                      fallback: 'Cache options',
                    ),
                  ),
                ),
              ],
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
                  // Campo de búsqueda
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: TextField(
                      controller: _searchController,
                      onChanged: _filterFiles,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: widget.getText(
                          'search_song',
                          fallback: 'Search song...',
                        ),
                        hintStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(
                          Icons.search,
                          color: Colors.white54,
                        ),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(
                                  Icons.clear,
                                  color: Colors.white54,
                                ),
                                onPressed: () {
                                  _searchController.clear();
                                  _filterFiles('');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: Colors.white10,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : _filteredFiles.isEmpty
                        ? Center(
                            child: Text(
                              _searchController.text.isNotEmpty
                                  ? widget.getText(
                                      'no_songs_found_search',
                                      fallback: 'No songs found',
                                    )
                                  : widget.getText(
                                      'no_files',
                                      fallback: 'Empty',
                                    ),
                              style: const TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _filteredFiles.length,
                            itemBuilder: (context, index) {
                              if (index >= _filteredFiles.length) {
                                return const SizedBox.shrink();
                              }
                              final file = _filteredFiles[index];
                              // Encontrar el índice real en _files para reproducir correctamente
                              final realIndex = _files.indexWhere(
                                (f) => f.path == file.path,
                              );
                              final isSelected = realIndex == _currentIndex;
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
                                      if (realIndex >= 0) {
                                        _playFile(realIndex);
                                      }
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
