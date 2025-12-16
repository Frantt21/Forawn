import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import '../services/lyrics_service.dart';
import '../models/synced_lyrics.dart';

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

  void _initGlobalListeners() {
    // Estos listeners NUNCA se cancelan - son globales y persisten
    player.onPositionChanged.listen((pos) {
      position.value = pos;
    });

    player.onDurationChanged.listen((dur) {
      duration.value = dur;
    });

    player.onPlayerStateChanged.listen((state) {
      isPlaying.value = state == PlayerState.playing;
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
