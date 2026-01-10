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
import '../services/metadata_service.dart';
import '../services/global_theme_service.dart';

import '../services/music_metadata_cache.dart';
import 'playlist_detail_screen.dart';
import '../services/playlist_service.dart';
import '../models/playlist_model.dart';
import '../models/song_model.dart';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:palette_generator/palette_generator.dart';
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
          GlobalThemeService().updateDominantColor(cachedColor);
        }
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
      await _loadMetadata(filePath);
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
      setState(() {
        _currentTitle = _musicPlayer.currentTitle.value;
        _currentArtist = _musicPlayer.currentArtist.value;
        _currentArt = _musicPlayer.currentArt.value;
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

  /// Normaliza caracteres especiales mal codificados
  String _normalizeText(String text) {
    // Mapa de caracteres mal codificados comunes a sus equivalentes correctos
    final replacements = {
      'Ã­': 'í', // í
      'Ã¡': 'á', // á
      'Ã©': 'é', // é
      'Ã³': 'ó', // ó
      'Ãº': 'ú', // ú
      'Ã±': 'ñ', // ñ
      'Ã': 'Í', // Í
      'Ã': 'Á', // Á
      'Ã': 'É', // É
      'Ã': 'Ó', // Ó
      'Ã': 'Ú', // Ú
      'Ã': 'Ñ', // Ñ
    };

    String normalized = text;
    replacements.forEach((bad, good) {
      normalized = normalized.replaceAll(bad, good);
    });

    return normalized;
  }

  /// Parsea metadatos de YouTube para extraer artista y título
  Map<String, String> _parseMetadata(String rawTitle, String rawArtist) {
    // Normalizar caracteres primero
    String title = _normalizeText(rawTitle);
    String artist = _normalizeText(rawArtist);

    // Remover patrones comunes de YouTube del título
    final patterns = [
      r'\(Official Video\)',
      r'\(Official Audio\)',
      r'\(Official Music Video\)',
      r'\(Visualizer\)',
      r'\(Lyric Video\)',
      r'\(Lyrics\)',
      r'\(Audio\)',
      r'\(Video\)',
      r'\[Official Video\]',
      r'\[Official Audio\]',
      r'\[Visualizer\]',
      r'\[Lyric Video\]',
      r'\[Lyrics\]',
      r'- Topic\$',
      r'\| Topic\$',
    ];

    for (final pattern in patterns) {
      title = title.replaceAll(RegExp(pattern, caseSensitive: false), '');
    }

    // Si hay un pipe (|), la parte antes es el artista y después el título
    // Ejemplo: "kLOuFRENS (Visualizer) | DeBÍ TiRAR MáS FOTos"
    if (title.contains('|')) {
      final parts = title.split('|');
      if (parts.length > 1) {
        // Si no hay artista o es "Unknown Artist", usar la parte antes del pipe
        if (artist.isEmpty || artist == 'Unknown Artist') {
          artist = parts[0].trim();
        }
        title = parts.last.trim();
      }
    }
    // Si hay un guion " - " y no tenemos artista, intentar separar
    // Ejemplo: "Bad Bunny - KLOuFRENS"
    else if (title.contains(' - ') &&
        (artist.isEmpty || artist == 'Unknown Artist')) {
      final parts = title.split(' - ');
      if (parts.length == 2) {
        artist = parts[0].trim();
        title = parts[1].trim();
      }
    }

    // Limpiar espacios extras
    title = title.trim();
    artist = artist.trim();

    return {
      'title': title.isNotEmpty ? title : rawTitle,
      'artist': artist.isNotEmpty ? artist : rawArtist,
    };
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
      final parsed = _parseMetadata(title, artist);
      _musicPlayer.currentTitle.value = parsed['title']!;
      _musicPlayer.currentArtist.value = parsed['artist']!;
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
    try {
      final result = await FilePicker.platform.getDirectoryPath();

      if (result == null) return;

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
                        return Text(
                          'Procesando metadatos ($processed/$total)...',
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

      totalFiles.value = files.length;

      for (int i = 0; i < files.length && !cancelled; i++) {
        await Song.fromFile(files[i]);
        processedFiles.value = i + 1;
        await Future.delayed(const Duration(milliseconds: 10));
      }

      if (!cancelled) {
        await _musicPlayer.loadLibraryFromFolder(folderPath);
        _files = List<FileSystemEntity>.from(_musicPlayer.filesList.value);
        _filteredFiles = _files;

        if (mounted) {
          setState(() {});
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

  Future<void> _loadMetadata(String filePath) async {
    try {
      final file = File(filePath);

      // Intentar obtener del caché primero
      SongMetadata? cachedMetadata = _libraryMetadataCache[filePath];
      cachedMetadata ??= await MusicMetadataCache.get(filePath);

      String title = p.basename(filePath);
      String artist = widget.getText(
        'unknown_artist',
        fallback: 'Unknown Artist',
      );
      Uint8List? artwork;

      // Si tenemos caché, usarlo
      if (cachedMetadata != null) {
        title = cachedMetadata.title;
        artist = cachedMetadata.artist;
        artwork = cachedMetadata.artwork;
        debugPrint('[MusicPlayer] Using cached metadata for: $title');
      } else {
        // Solo si no hay caché, leer del archivo
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

        // Guardar en caché para uso futuro
        await MusicMetadataCache.saveFromMetadata(
          key: filePath,
          title: metadata.title,
          artist: metadata.artist,
          album: metadata.album,
          durationMs: metadata.duration?.inMilliseconds,
          artworkData: artwork,
        );

        _libraryMetadataCache[filePath] = SongMetadata(
          title: title,
          artist: artist,
          album: metadata.album,
          durationMs: metadata.duration?.inMilliseconds,
          artwork: artwork,
        );
      }

      // Parsear metadatos para limpiar títulos de YouTube
      final originalTitle = title; // Guardar título original
      final parsed = _parseMetadata(title, artist);
      title = parsed['title']!;
      artist = parsed['artist']!;

      // Detectar si probablemente viene de YouTube:
      // 1. Artista desconocido
      // 2. Título original tenía caracteres de YouTube
      // 3. No hay artwork (YouTube no embebe portadas correctamente)
      // 4. Título tiene caracteres mal codificados
      final likelyFromYouTube =
          artist == 'Unknown Artist' ||
          originalTitle.contains('|') ||
          originalTitle.contains('(') ||
          originalTitle.contains('Visualizer') ||
          originalTitle.contains('Official') ||
          artwork == null ||
          title.contains('�'); // Caracteres mal codificados

      // Intentar enriquecer con metadatos de Spotify
      if (likelyFromYouTube) {
        try {
          debugPrint(
            '[MusicPlayer] Attempting to enrich metadata from Spotify for: $title - $artist',
          );
          final spotifyMetadata = await MetadataService().searchMetadata(
            title,
            artist != 'Unknown Artist' ? artist : null,
          );

          if (spotifyMetadata != null) {
            debugPrint(
              '[MusicPlayer] Enriched: ${spotifyMetadata.title} by ${spotifyMetadata.artist}',
            );
            title = spotifyMetadata.title;
            artist = spotifyMetadata.artist;

            // Descargar portada de Spotify si no hay artwork local
            if (artwork == null && spotifyMetadata.albumArtUrl != null) {
              final spotifyArtwork = await MetadataService().downloadAlbumArt(
                spotifyMetadata.albumArtUrl,
              );
              if (spotifyArtwork != null) {
                artwork = spotifyArtwork;
                debugPrint('[MusicPlayer] Using Spotify album art');
              }
            }
          }
        } catch (e) {
          debugPrint('[MusicPlayer] Error enriching metadata: $e');
        }
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
          // GlobalThemeService().updateDominantColor(dominantColor); // DISABLED to stop AppBar color change
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
          GlobalThemeService().updateDominantColor(null);
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

  /// Ajustar el color dominante para los controles
  /// Si el color es claro, lo oscurece mezclándolo con negro
  /// Si el color es oscuro, lo aclara mezclándolo con blanco
  Color _adjustColorForControls(Color? baseColor) {
    if (baseColor == null) return Colors.purpleAccent;

    // Calcular luminancia para determinar si es claro u oscuro
    final luminance = baseColor.computeLuminance();

    // Si es muy claro (luminancia > 0.5), oscurecer mezclando con negro
    if (luminance > 0.5) {
      return Color.lerp(baseColor, Colors.black, 0.3) ?? baseColor;
    }
    // Si es oscuro, aclarar mezclando con blanco
    else {
      return Color.lerp(baseColor, Colors.white, 0.3) ?? baseColor;
    }
  }

  /// Mostrar menú de opciones de caché de colores
  /// Mostrar menú de opciones de caché de colores

  /// Mostrar menú de opciones de caché de colores

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
    final historyPaths = MusicHistory().getHistory().take(6).toList();
    final playlists = PlaylistService().playlists.take(6).toList();

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
              height: 200,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: historyPaths.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  return _buildHistoryCard(historyPaths[index]);
                },
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
              height: 180,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: playlists.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  return _buildPlaylistCard(playlists[index]);
                },
              ),
            ),

          const SizedBox(height: 100), // Bottom padding
        ],
      ),
    );
  }

  Future<SongMetadata?> _cacheAwareReadMetadata(File file) async {
    final key = file.path;

    // 1. Verificar caché en memoria primero (más rápido)
    if (_libraryMetadataCache.containsKey(key)) {
      return _libraryMetadataCache[key];
    }

    // 2. Verificar caché persistente
    final cached = await MusicMetadataCache.get(key);
    if (cached != null) {
      _libraryMetadataCache[key] = cached;
      return cached;
    }

    // 3. Leer del archivo (solo etiquetas, sin cargar imagen completa aún)
    try {
      final meta = await Future(() => readMetadata(file, getImage: true));
      final artwork = meta.pictures.firstOrNull?.bytes;

      final metadata = SongMetadata(
        title: meta.title ?? p.basename(file.path),
        artist: meta.artist ?? "Unknown Artist",
        album: meta.album,
        durationMs: meta.duration?.inMilliseconds,
        artwork: artwork,
      );

      // Guardar en ambos cachés
      await MusicMetadataCache.saveFromMetadata(
        key: key,
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        durationMs: meta.duration?.inMilliseconds,
        artworkData: artwork,
      );

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
          ).then((_) {
            if (mounted) setState(() {});
          });
        }
      },
      child: Container(
        width: 140,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: FutureBuilder<SongMetadata?>(
          future: _cacheAwareReadMetadata(file),
          builder: (context, snapshot) {
            final data = snapshot.data;
            final art = data?.artwork;
            final title = data?.title ?? fileName;
            final artist = data?.artist ?? "Unknown Artist";

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(12),
                      ),
                      color: Colors.grey[900],
                      image: art != null
                          ? DecorationImage(
                              image: MemoryImage(art),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: art == null
                        ? const Center(
                            child: Icon(
                              Icons.music_note,
                              size: 50,
                              color: Colors.grey,
                            ),
                          )
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: Column(
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
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
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
  }

  Widget _buildPlaylistCard(Playlist playlist) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PlaylistDetailScreen(playlist: playlist),
          ),
        ).then((_) => setState(() {}));
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
        width: 140,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                  color: Colors.grey[800],
                  image: playlist.imagePath != null
                      ? DecorationImage(
                          image: FileImage(File(playlist.imagePath!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: playlist.imagePath == null
                    ? const Center(
                        child: Icon(
                          Icons.queue_music,
                          size: 40,
                          color: Colors.white54,
                        ),
                      )
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
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
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "${playlist.songs.length} songs",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
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
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.grey[900],
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
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _dominantColor != null
              ? _dominantColor!.withOpacity(0.15)
              : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: (_dominantColor ?? Colors.black).withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            // Artwork with fade transition
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              transitionBuilder: (child, animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: Container(
                key: ValueKey(_currentTitle),
                width: 42,
                height: 42,
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
            const SizedBox(width: 12),
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
                    ),
                  ),
                  Text(
                    _currentArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              onPressed: _togglePlayPause,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: _playNext,
            ),
          ],
        ),
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
