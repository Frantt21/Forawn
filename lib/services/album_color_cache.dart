import 'dart:ui';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Servicio para cachear colores dominantes de portadas de álbum
class AlbumColorCache {
  static final AlbumColorCache _instance = AlbumColorCache._internal();
  factory AlbumColorCache() => _instance;
  AlbumColorCache._internal();

  final Map<String, Color> _colorCache = {};
  bool _isLoaded = false;

  /// Cargar caché desde SharedPreferences
  Future<void> loadCache() async {
    if (_isLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString('album_color_cache');

      if (cacheJson != null) {
        final Map<String, dynamic> decoded = json.decode(cacheJson);
        _colorCache.clear();

        decoded.forEach((key, value) {
          if (value is int) {
            _colorCache[key] = Color(value);
          }
        });

        print('[ColorCache] Loaded ${_colorCache.length} colors from cache');
      }

      _isLoaded = true;
    } catch (e) {
      print('[ColorCache] Error loading cache: $e');
      _isLoaded = true;
    }
  }

  /// Guardar caché en SharedPreferences
  Future<void> saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, int> toSave = {};

      _colorCache.forEach((key, color) {
        toSave[key] = color.value;
      });

      await prefs.setString('album_color_cache', json.encode(toSave));
      print('[ColorCache] Saved ${_colorCache.length} colors to cache');
    } catch (e) {
      print('[ColorCache] Error saving cache: $e');
    }
  }

  /// Obtener color del caché
  Color? getColor(String filePath) {
    return _colorCache[filePath];
  }

  /// Guardar color en el caché
  Future<void> setColor(String filePath, Color color) async {
    _colorCache[filePath] = color;
    // Guardar cada 10 colores nuevos para no saturar el disco
    if (_colorCache.length % 10 == 0) {
      await saveCache();
    }
  }

  /// Limpiar caché
  Future<void> clearCache() async {
    _colorCache.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('album_color_cache');
    print('[ColorCache] Cache cleared');
  }

  /// Obtener estadísticas del caché
  Map<String, dynamic> getStats() {
    return {'totalColors': _colorCache.length, 'isLoaded': _isLoaded};
  }
}
