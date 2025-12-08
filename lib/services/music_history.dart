import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class MusicHistory {
  static final MusicHistory _instance = MusicHistory._internal();

  factory MusicHistory() {
    return _instance;
  }

  MusicHistory._internal() {
    _loadHistory();
  }

  final List<String> _history = []; // Lista de rutas de archivos
  static const int maxHistorySize = 20;
  static const String _prefsKey = 'music_history';

  /// Cargar historial desde SharedPreferences
  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getString(_prefsKey);
      if (historyJson != null) {
        final decoded = jsonDecode(historyJson) as List;
        _history.clear();
        _history.addAll(decoded.cast<String>());
        print('[MusicHistory] Loaded history: ${_history.length} songs');
      }
    } catch (e) {
      print('[MusicHistory] Error loading history: $e');
    }
  }

  /// Guardar historial en SharedPreferences
  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_history);
      await prefs.setString(_prefsKey, encoded);
      print('[MusicHistory] Saved history: ${_history.length} songs');
    } catch (e) {
      print('[MusicHistory] Error saving history: $e');
    }
  }

  /// Agregar una canción al historial
  /// Se llama cuando se EMPIEZA a reproducir (desde _playFile)
  void addToHistory(File file) {
    final path = file.path;
    
    // Si la canción ya está al principio, no hacer nada
    if (_history.isNotEmpty && _history.first == path) {
      print('[MusicHistory] Song already at top of history');
      return;
    }

    // Remover duplicados del historial
    _history.removeWhere((p) => p == path);

    // Agregar al inicio (más reciente)
    _history.insert(0, path);
    
    print('[MusicHistory] Added to history: $path');
    print('[MusicHistory] History: ${_history.take(3).toList()}');

    // Mantener máximo de 20 canciones
    if (_history.length > maxHistorySize) {
      _history.removeLast();
    }
    
    // Guardar en persistencia
    _saveHistory();
  }

  /// Obtener la canción anterior en el historial y eliminarla
  /// Cuando retrocedes, eliminas la canción actual del historial
  File? getPreviousTrack() {
    if (_history.length < 2) {
      print('[MusicHistory] Not enough history to go back');
      return null;
    }

    // La canción actual es la primera, eliminarla
    _history.removeAt(0);
    print('[MusicHistory] Removed current from history');
    
    // La nueva canción actual es la que está ahora al frente
    if (_history.isNotEmpty) {
      final previousPath = _history.first;
      print('[MusicHistory] Going back to: $previousPath');
      print('[MusicHistory] History after go back: ${_history.take(3).toList()}');
      
      // Guardar cambios
      _saveHistory();
      
      return File(previousPath);
    }
    
    return null;
  }

  /// Obtener toda la lista de historial
  List<String> getHistory() {
    return List.from(_history);
  }

  /// Limpiar historial
  Future<void> clearHistory() async {
    _history.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    print('[MusicHistory] History cleared');
  }

  /// Obtener tamaño actual del historial
  int getHistorySize() {
    return _history.length;
  }
}
