import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:typed_data';

enum LoopMode { off, all, one }

class GlobalMusicPlayer {
  static final GlobalMusicPlayer _instance = GlobalMusicPlayer._internal();

  factory GlobalMusicPlayer() {
    return _instance;
  }

  GlobalMusicPlayer._internal() {
    _initPersistentNotifiers();
    _initGlobalListeners();
    _loadPreferences();
  }

  final AudioPlayer player = AudioPlayer();
  
  // Callback para cuando termina una canción
  Function(int? currentIndex, LoopMode loopMode, bool isShuffle)? onSongComplete;
  
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
        onSongComplete?.call(currentIndex.value, loopMode.value, isShuffle.value);
      }
    });
  }
  
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedLoopMode = prefs.getString('loopMode') ?? 'off';
      final savedShuffle = prefs.getBool('isShuffle') ?? false;
      final savedVolume = prefs.getDouble('volume') ?? 1.0;
      
      loopMode.value = LoopMode.values.firstWhere(
        (e) => e.toString().split('.').last == savedLoopMode,
        orElse: () => LoopMode.off,
      );
      isShuffle.value = savedShuffle;
      volume.value = savedVolume;
      
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
  final ValueNotifier<bool> showMiniPlayer = ValueNotifier(false); // Desactivado por defecto
  
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
  }
}
