import 'dart:io';
import 'local_music_database.dart';

class MusicHistory {
  static final MusicHistory _instance = MusicHistory._internal();

  factory MusicHistory() {
    return _instance;
  }

  MusicHistory._internal() {
    _loadHistory();
  }

  // Mantenemos una copia en memoria para acceso síncrono rápido (ej. botón 'atrás')
  final List<String> _history = [];
  static const int maxHistorySize = 50; // Aumentado ya que SQL aguanta más

  /// Cargar historial desde Base de Datos Local (SQLite)
  Future<void> _loadHistory() async {
    try {
      final dbHistory = await LocalMusicDatabase().getHistory(
        limit: maxHistorySize,
      );
      _history.clear();
      _history.addAll(dbHistory);
      print('[MusicHistory] Loaded history from DB: ${_history.length} songs');
    } catch (e) {
      print('[MusicHistory] Error loading history: $e');
    }
  }

  /// Agregar una canción al historial
  /// Se llama cuando se EMPIEZA a reproducir (desde _playFile)
  void addToHistory(File file) {
    final path = file.path;

    // Si la canción ya está al principio, no hacer nada (evita duplicados consecutivos)
    if (_history.isNotEmpty && _history.first == path) {
      return;
    }

    // En memoria: Remover si ya existe para moverlo al principio
    _history.removeWhere((p) => p == path);
    _history.insert(0, path);

    // Mantener límite en memoria
    if (_history.length > maxHistorySize) {
      _history.removeLast();
    }

    // Persistencia: Guardar en SQLite (Fire & Forget)
    LocalMusicDatabase().addToHistory(path);
  }

  /// Obtener la canción anterior en el historial y eliminarla
  /// Cuando retrocedes, eliminas la canción actual del historial
  File? getPreviousTrack() {
    if (_history.length < 2) {
      print('[MusicHistory] Not enough history to go back');
      return null;
    }

    // 1. La "actual" es la primera (índice 0). La eliminamos del historial
    // porque estamos yendo "hacia atrás", es decir, deshaciendo la navegación.
    final currentPath = _history[0];
    _history.removeAt(0);

    // Eliminar de DB también
    LocalMusicDatabase().removeFromHistory(currentPath);

    // 2. La "anterior" es ahora la nueva primera (índice 0)
    if (_history.isNotEmpty) {
      final previousPath = _history.first;
      print('[MusicHistory] Going back to: $previousPath');
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
    await LocalMusicDatabase().clearHistoryOnly();
    print('[MusicHistory] History cleared');
  }

  /// Obtener tamaño actual del historial
  int getHistorySize() {
    return _history.length;
  }
}
