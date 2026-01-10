import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:path/path.dart' as p;
import '../services/lyrics_service.dart';
import '../models/synced_lyrics.dart';
import '../models/song_model.dart';
import '../services/music_metadata_cache.dart';

enum LoopMode { off, all, one }

class GlobalMusicPlayer {
  static final GlobalMusicPlayer _instance = GlobalMusicPlayer._internal();

  factory GlobalMusicPlayer() {
    return _instance;
  }

  GlobalMusicPlayer._internal() {
    _initPersistentNotifiers();
    _initGlobalListeners();
    _initLyricsLogic(); // Inicializar lógica de lyrics
    _loadPreferences();
  }

  final AudioPlayer player = AudioPlayer();

  // Callback para cuando termina una canción
  Function(int? currentIndex, LoopMode loopMode, bool isShuffle)?
  onSongComplete;

  // Callback para cargar metadatos cuando se reproduce desde playlist
  Function(String filePath)? onMetadataNeeded;

  // Para throttling del guardado de posición
  DateTime? _lastSaveTime;

  void _initGlobalListeners() {
    // Estos listeners NUNCA se cancelan - son globales y persisten
    player.onPositionChanged.listen((pos) {
      position.value = pos;

      // Guardar estado cada segundo durante reproducción (throttled)
      if (isPlaying.value && currentFilePath.value.isNotEmpty) {
        final now = DateTime.now();
        if (_lastSaveTime == null ||
            now.difference(_lastSaveTime!).inSeconds >= 1) {
          _lastSaveTime = now;
          savePlayerState();
        }
      }
    });

    player.onDurationChanged.listen((dur) {
      duration.value = dur;
    });

    player.onPlayerStateChanged.listen((state) {
      final wasPlaying = isPlaying.value;
      isPlaying.value = state == PlayerState.playing;

      // Guardar estado cuando se pausa o detiene
      if (wasPlaying && !isPlaying.value && currentFilePath.value.isNotEmpty) {
        savePlayerState();
        debugPrint('[GlobalMusicPlayer] State saved on pause/stop');
      }

      // Cuando la canción termina, llamar al callback
      if (state == PlayerState.completed) {
        onSongComplete?.call(
          currentIndex.value,
          loopMode.value,
          isShuffle.value,
        );
      }
    });
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedLoopMode = prefs.getString('loopMode') ?? 'off';
      final savedShuffle = prefs.getBool('isShuffle') ?? false;
      final savedVolume = prefs.getDouble('volume') ?? 1.0;
      final savedLyricsVisible = prefs.getBool('lyricsVisible') ?? false;

      loopMode.value = LoopMode.values.firstWhere(
        (e) => e.toString().split('.').last == savedLoopMode,
        orElse: () => LoopMode.off,
      );
      isShuffle.value = savedShuffle;
      volume.value = savedVolume;
      showLyrics.value = savedLyricsVisible;

      await player.setVolume(savedVolume);
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error loading preferences: $e');
    }
  }

  Future<void> saveLoopMode(LoopMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('loopMode', mode.toString().split('.').last);
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error saving loopMode: $e');
    }
  }

  Future<void> saveShuffle(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isShuffle', value);
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error saving shuffle: $e');
    }
  }

  Future<void> saveVolume(double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('volume', value);
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error saving volume: $e');
    }
  }

  // Estado de reproducción
  final ValueNotifier<bool> isPlaying = ValueNotifier(false);
  final ValueNotifier<bool> showMiniPlayer = ValueNotifier(
    false,
  ); // Desactivado por defecto

  // Información de la canción actual
  final ValueNotifier<String> currentTitle = ValueNotifier('');
  final ValueNotifier<String> currentArtist = ValueNotifier('');
  final ValueNotifier<String> currentFilePath = ValueNotifier('');
  final ValueNotifier<Uint8List?> currentArt = ValueNotifier(null);

  // Posición y duración
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  // Volumen y controles - con persistencia
  late final ValueNotifier<double> volume;
  final ValueNotifier<bool> isMuted = ValueNotifier(false);
  late final ValueNotifier<LoopMode> loopMode;
  late final ValueNotifier<bool> isShuffle;

  // Índice de la canción actual en la lista
  final ValueNotifier<int?> currentIndex = ValueNotifier(null);

  // Lista de archivos
  final ValueNotifier<List<FileSystemEntity>> filesList = ValueNotifier([]);

  // Lista de Song objects con metadatos
  final ValueNotifier<List<Song>> songsList = ValueNotifier([]);

  // Flag para saber si la librería ya fue cargada
  bool _libraryLoaded = false;

  /// Cargar librería de música desde carpeta guardada
  Future<void> loadLibraryIfNeeded() async {
    if (_libraryLoaded && filesList.value.isNotEmpty) {
      debugPrint(
        '[GlobalMusicPlayer] Library already loaded (${filesList.value.length} files)',
      );
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final folder = prefs.getString('download_folder');

      if (folder == null || folder.isEmpty) {
        debugPrint('[GlobalMusicPlayer] No folder configured');
        return;
      }

      await loadLibraryFromFolder(folder);
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error loading library: $e');
    }
  }

  /// Cargar librería desde una carpeta específica
  Future<void> loadLibraryFromFolder(String folderPath) async {
    debugPrint('[GlobalMusicPlayer] Loading library from: $folderPath');

    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) {
        debugPrint('[GlobalMusicPlayer] Folder does not exist');
        return;
      }

      // Obtener todos los archivos MP3
      final allFiles = await dir.list(recursive: true).toList();
      final musicFiles = allFiles
          .where(
            (entity) =>
                entity is File &&
                (p.extension(entity.path).toLowerCase() == '.mp3' ||
                    p.extension(entity.path).toLowerCase() == '.m4a' ||
                    p.extension(entity.path).toLowerCase() == '.flac'),
          )
          .toList();

      debugPrint('[GlobalMusicPlayer] Found ${musicFiles.length} music files');

      // Actualizar lista de archivos
      filesList.value = musicFiles;

      // Convertir a Song objects (sin cargar metadatos pesados aún)
      final List<Song> songs = [];
      for (final file in musicFiles) {
        final song = await Song.fromFile(file as File);
        if (song != null) {
          songs.add(song);
        }
      }

      songsList.value = songs;
      _libraryLoaded = true;

      debugPrint('[GlobalMusicPlayer] Library loaded: ${songs.length} songs');
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error loading from folder: $e');
    }
  }

  /// Refrescar librería (forzar recarga)
  Future<void> refreshLibrary() async {
    _libraryLoaded = false;
    await loadLibraryIfNeeded();
  }

  /// Guardar estado actual del reproductor
  Future<void> savePlayerState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Obtener posición actual directamente del reproductor
      final currentPosition = position.value;

      await prefs.setInt('player_current_index', currentIndex.value ?? -1);
      await prefs.setString('player_current_path', currentFilePath.value);
      await prefs.setString('player_current_title', currentTitle.value);
      await prefs.setString('player_current_artist', currentArtist.value);
      await prefs.setInt('player_position_seconds', currentPosition.inSeconds);
      await prefs.setInt('player_duration_seconds', duration.value.inSeconds);

      debugPrint(
        '[GlobalMusicPlayer] Player state saved (position: ${currentPosition.inSeconds}s)',
      );
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error saving player state: $e');
    }
  }

  /// Cargar estado guardado del reproductor
  Future<void> loadPlayerState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final savedIndex = prefs.getInt('player_current_index') ?? -1;
      final savedPath = prefs.getString('player_current_path') ?? '';
      final savedTitle = prefs.getString('player_current_title') ?? '';
      final savedArtist = prefs.getString('player_current_artist') ?? '';
      final savedPosition = prefs.getInt('player_position_seconds') ?? 0;
      final savedDuration = prefs.getInt('player_duration_seconds') ?? 0;

      if (savedIndex >= 0 && savedPath.isNotEmpty) {
        debugPrint('[GlobalMusicPlayer] Restoring player state: $savedTitle');

        // Verificar que el archivo existe
        final file = File(savedPath);
        if (!await file.exists()) {
          debugPrint('[GlobalMusicPlayer] Saved file no longer exists');
          return;
        }

        // Restaurar estado sin auto-reproducir
        currentIndex.value = savedIndex;
        currentFilePath.value = savedPath;
        currentTitle.value = savedTitle;
        currentArtist.value = savedArtist;
        position.value = Duration(seconds: savedPosition);
        duration.value = Duration(seconds: savedDuration);
        isPlaying.value = false; // Siempre pausado al restaurar

        // Cargar el archivo en el reproductor (pausado)
        try {
          await player.setSource(DeviceFileSource(savedPath));
          await player.pause(); // Asegurar que está pausado

          // Buscar a la posición guardada
          if (savedPosition > 0) {
            await player.seek(Duration(seconds: savedPosition));
            debugPrint(
              '[GlobalMusicPlayer] Seeked to position: ${Duration(seconds: savedPosition)}',
            );
          }
        } catch (e) {
          debugPrint('[GlobalMusicPlayer] Error loading audio source: $e');
        }

        // Intentar cargar artwork desde caché
        final cached = await MusicMetadataCache.get(savedPath);
        if (cached != null && cached.artwork != null) {
          currentArt.value = cached.artwork;
          debugPrint('[GlobalMusicPlayer] Artwork restored from cache');
        }

        debugPrint('[GlobalMusicPlayer] Player state restored successfully');
      } else {
        debugPrint('[GlobalMusicPlayer] No saved player state found');
      }
    } catch (e) {
      debugPrint('[GlobalMusicPlayer] Error loading player state: $e');
    }
  }

  // Play a playlist
  Future<void> playPlaylist(List<File> files, int initialIndex) async {
    // Stop current playback
    await player.stop();

    // Update global list
    filesList.value = files;

    // Play selected song
    if (initialIndex >= 0 && initialIndex < files.length) {
      await _playFileAtIndex(initialIndex);
    }
  }

  Future<void> _playFileAtIndex(int index) async {
    final file = filesList.value[index] as File;
    currentIndex.value = index;
    currentFilePath.value = file.path;

    // Trigger metadata loading callback if registered
    if (onMetadataNeeded != null) {
      onMetadataNeeded!(file.path);
    } else {
      // Fallback: set basic filename as title
      currentTitle.value = file.uri.pathSegments.last;
    }

    await player.play(DeviceFileSource(file.path));
    isPlaying.value = true;
    showMiniPlayer.value = true;
  }

  // --- Lyrics Globales ---
  final ValueNotifier<SyncedLyrics?> currentLyrics = ValueNotifier(null);
  final ValueNotifier<int?> currentLyricIndex = ValueNotifier(null);
  late final ValueNotifier<bool> showLyrics; // Persistente
  final Map<String, SyncedLyrics> _lyricsCache = {};
  Timer? _lyricsTimer;

  void _initLyricsLogic() {
    showLyrics = ValueNotifier(false); // Default off

    // Guardar preferencia de showLyrics
    showLyrics.addListener(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('lyricsVisible', showLyrics.value);
      } catch (e) {
        debugPrint('[GlobalMusicPlayer] Error saving lyrics visible: $e');
      }
    });

    // Escuchar cambios de canción para cargar lyrics
    currentTitle.addListener(_checkLoadLyrics);
    currentArtist.addListener(_checkLoadLyrics);

    // Timer para actualizar índice de linea (más eficiente que escuchar position stream para UI)
    _lyricsTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!isPlaying.value ||
          currentLyrics.value == null ||
          !currentLyrics.value!.hasLyrics)
        return;

      final pos = position.value;
      final newIndex = currentLyrics.value!.getCurrentLineIndex(pos);

      if (newIndex != currentLyricIndex.value) {
        currentLyricIndex.value = newIndex;
      }
    });
  }

  void _checkLoadLyrics() {
    final title = currentTitle.value;
    final artist = currentArtist.value;
    if (title.isEmpty) return;

    _loadLyrics(title, artist);
  }

  Future<void> _loadLyrics(String title, String artist) async {
    // Limpiar lyrics anteriores
    currentLyrics.value = null;
    currentLyricIndex.value = null;

    final cacheKey = '${title}_$artist';

    if (_lyricsCache.containsKey(cacheKey)) {
      debugPrint('[GlobalMusicPlayer] Lyrics from cache for $title');
      currentLyrics.value = _lyricsCache[cacheKey];
    } else {
      // Fetch en background
      try {
        debugPrint('[GlobalMusicPlayer] Fetching lyrics for $title - $artist');
        final lyrics = await LyricsService().fetchLyrics(title, artist);
        if (lyrics != null) {
          _lyricsCache[cacheKey] = lyrics;
          // Solo actualizar si sigue siendo la misma canción (por si cambió rápido)
          if (currentTitle.value == title) {
            currentLyrics.value = lyrics;
          }
        }
      } catch (e) {
        debugPrint('[GlobalMusicPlayer] Error fetching lyrics: $e');
      }
    }
  }

  void _initPersistentNotifiers() {
    volume = ValueNotifier(1.0);
    loopMode = ValueNotifier(LoopMode.off);
    isShuffle = ValueNotifier(false);

    // Guardar automáticamente cambios en volume
    volume.addListener(() {
      saveVolume(volume.value);
      player.setVolume(volume.value);
    });

    // Guardar automáticamente cambios en loopMode
    loopMode.addListener(() {
      saveLoopMode(loopMode.value);
    });

    // Guardar automáticamente cambios en shuffle
    isShuffle.addListener(() {
      saveShuffle(isShuffle.value);
    });
  }

  void dispose() {
    isPlaying.dispose();
    showMiniPlayer.dispose();
    currentTitle.dispose();
    currentArtist.dispose();
    currentFilePath.dispose();
    position.dispose();
    duration.dispose();
    volume.dispose();
    isMuted.dispose();
    loopMode.dispose();
    isShuffle.dispose();
    currentIndex.dispose();
    filesList.dispose();

    // Lyrics dispose
    currentLyrics.dispose();
    currentLyricIndex.dispose();
    showLyrics.dispose();
    _lyricsTimer?.cancel();
  }
}
