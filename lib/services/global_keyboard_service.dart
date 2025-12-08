import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'global_music_player.dart';
import 'music_history.dart';
import 'dart:io';
import 'dart:math';

class GlobalKeyboardService {
  static final GlobalKeyboardService _instance = GlobalKeyboardService._internal();
  
  factory GlobalKeyboardService() {
    return _instance;
  }

  GlobalKeyboardService._internal();

  final GlobalMusicPlayer _musicPlayer = GlobalMusicPlayer();
  final MusicHistory _history = MusicHistory();
  FocusNode? _focusNode;
  List<File>? _files;
  bool _isNavigatingHistory = false;

  // Callbacks registrados desde music_player_screen
  VoidCallback? _playPreviousCallback;
  VoidCallback? _playNextCallback;
  VoidCallback? _togglePlayPauseCallback;

  /// Registrar callbacks desde music_player_screen
  void registerCallbacks({
    required VoidCallback playPrevious,
    required VoidCallback playNext,
    required VoidCallback togglePlayPause,
  }) {
    _playPreviousCallback = playPrevious;
    _playNextCallback = playNext;
    _togglePlayPauseCallback = togglePlayPause;
    print('[GlobalKeyboardService] Callbacks registered from MusicPlayerScreen');
  }

  /// Desregistrar callbacks
  void unregisterCallbacks() {
    _playPreviousCallback = null;
    _playNextCallback = null;
    _togglePlayPauseCallback = null;
    print('[GlobalKeyboardService] Callbacks unregistered');
  }

  void initialize(FocusNode focusNode, List<File>? files) {
    _focusNode = focusNode;
    _files = files;
    
    // Hacer que el focus node siempre tenga focus
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode?.requestFocus();
    });
  }

  /// Actualizar la lista de archivos disponibles
  /// Se debe llamar cada vez que cambia la lista de reproducción
  void setCurrentFiles(List<File> files) {
    _files = files;
    print('[GlobalKeyboardService] Files updated: ${files.length} files');
  }

  /// Reproduce una canción por índice
  /// Usado por toda la aplicación (botones UI, atajos de teclado)
  /// Siempre agrega al historial automáticamente
  void playFile(int index) {
    _playFile(index, skipHistory: false);
  }
  
  /// Reproduce una canción sin agregar al historial
  /// Usado al navegar hacia atrás en el historial
  void playFileSkipHistory(int index) {
    _isNavigatingHistory = true;
    _playFile(index, skipHistory: true);
    _isNavigatingHistory = false;
  }

  void _playFile(int index, {bool skipHistory = false}) {
    if (_files == null || index < 0 || index >= _files!.length) return;
    final file = _files![index];
    
    print('[GlobalKeyboardService] Playing file at index $index: ${file.path}');
    print('[GlobalKeyboardService] skipHistory=$skipHistory, _isNavigatingHistory=$_isNavigatingHistory');
    
    try {
      _musicPlayer.player.play(DeviceFileSource(file.path));
      _musicPlayer.currentIndex.value = index;
      _musicPlayer.currentFilePath.value = file.path;
      _musicPlayer.filesList.value = _files!;
      
      // NO AGREGAR AL HISTORIAL AQUÍ
      // El historial se agrega desde music_player_screen._playFile
      // que es la fuente única de verdad para el historial
      if (!skipHistory) {
        _history.addToHistory(file);
        print('[GlobalKeyboardService] Added to history');
      } else {
        print('[GlobalKeyboardService] Skipped history - navigating backward');
      }
      
      // Actualizar metadata - extraer solo el nombre del archivo, no la ruta completa
      final fileName = file.path.split('/').last.split('\\').last;
      _musicPlayer.currentTitle.value = fileName;
      _musicPlayer.currentArtist.value = 'Unknown Artist';
      print('[GlobalKeyboardService] Updated title: $fileName');
    } catch (e) {
      print('[GlobalKeyboardService] Error playing file: $e');
    }
  }

  void handleKeyboardEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    
    final logicalKey = event.logicalKey;
    
    // F9 = Anterior
    if (logicalKey == LogicalKeyboardKey.f9) {
      // Si hay callback registrado, usarlo (primeros music_player_screen)
      if (_playPreviousCallback != null) {
        _playPreviousCallback!.call();
      } else {
        // Fallback: usar lógica de GlobalKeyboardService
        _handlePreviousTrack();
      }
      return;
    }
    
    // F10 = Play/Pausa
    if (logicalKey == LogicalKeyboardKey.f10) {
      // Si hay callback registrado, usarlo
      if (_togglePlayPauseCallback != null) {
        _togglePlayPauseCallback!.call();
      } else {
        // Fallback: usar lógica de GlobalKeyboardService
        _handlePlayPause();
      }
      return;
    }
    
    // F11 = Siguiente
    if (logicalKey == LogicalKeyboardKey.f11) {
      // Si hay callback registrado, usarlo
      if (_playNextCallback != null) {
        _playNextCallback!.call();
      } else {
        // Fallback: usar lógica de GlobalKeyboardService
        _handleNextTrack();
      }
      return;
    }
  }

  void _handlePreviousTrack() {
    if (_files == null || _files!.isEmpty) return;
    
    print('[GlobalKeyboardService] Previous track pressed');
    print('[GlobalKeyboardService] Current position: ${_musicPlayer.position.value.inSeconds}s');
    
    // Si la canción lleva más de 3 segundos, reiniciarla
    if (_musicPlayer.position.value.inSeconds >= 3) {
      final currentIndex = _musicPlayer.currentIndex.value ?? 0;
      print('[GlobalKeyboardService] Position > 3s, restarting current track');
      playFileSkipHistory(currentIndex);
    } else {
      // Si es menos de 3 segundos, ir a la canción anterior en el historial
      final previousTrack = _history.getPreviousTrack();
      print('[GlobalKeyboardService] Position < 3s, trying history. Previous track: ${previousTrack?.path}');
      if (previousTrack != null) {
        final index = _files!.indexWhere((f) => f.path == previousTrack.path);
        print('[GlobalKeyboardService] Found previous track at index: $index');
        if (index >= 0) {
          playFileSkipHistory(index);
        }
      } else {
        // Si no hay historial, ir a la anterior en la playlist
        final cur = _musicPlayer.currentIndex.value ?? 0;
        final nextIndex = max(0, cur - 1);
        print('[GlobalKeyboardService] No history, going to previous in playlist: $nextIndex');
        playFileSkipHistory(nextIndex);
      }
    }
  }

  void _handlePlayPause() {
    print('[GlobalKeyboardService] Play/Pause pressed');
    if (_musicPlayer.isPlaying.value) {
      print('[GlobalKeyboardService] Pausing');
      _musicPlayer.player.pause();
      // El listener onPlayerStateChanged actualizará isPlaying.value
    } else {
      if (_musicPlayer.currentIndex.value != null) {
        print('[GlobalKeyboardService] Resuming');
        _musicPlayer.player.resume();
        // El listener onPlayerStateChanged actualizará isPlaying.value
      }
    }
  }

  void _handleNextTrack() {
    if (_files == null || _files!.isEmpty) return;
    
    print('[GlobalKeyboardService] Next track pressed');
    print('[GlobalKeyboardService] Current index from global: ${_musicPlayer.currentIndex.value}');
    
    int nextIndex;
    if (_musicPlayer.isShuffle.value) {
      nextIndex = Random().nextInt(_files!.length);
      print('[GlobalKeyboardService] Shuffle mode - random index: $nextIndex');
    } else {
      // Usar el índice actual de forma segura
      int cur = _musicPlayer.currentIndex.value ?? -1;
      
      // Si no hay índice establecido, empezar desde 0
      if (cur == -1) {
        cur = 0;
      }
      
      // Avanzar al siguiente
      nextIndex = cur + 1;
      
      // Si llegamos al final, quedarse en el último
      if (nextIndex >= _files!.length) {
        nextIndex = _files!.length - 1;
      }
      
      print('[GlobalKeyboardService] Normal mode - current: $cur, next index: $nextIndex');
    }
    playFile(nextIndex);
  }
}

