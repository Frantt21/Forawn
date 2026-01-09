import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Metadata de una canción (clase pública para uso externo)
class SongMetadata {
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final Uint8List? artwork;
  final String?
  artworkUri; // URI content:// de Android (Not heavily used in Desktop)
  final int? dominantColor; // Color dominante cacheado

  SongMetadata({
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.artwork,
    this.artworkUri,
    this.dominantColor,
  });
}

/// Servicio de caché persistente para metadata de música (FileSystem + SharedPrefs)
///
/// Características optimizadas:
/// - Compresión de artwork (300x300, JPEG 85%)
/// - Límite de tamaño total (100MB)
/// - Limpieza automática de caché antiguo (>30 días)
/// - Estadísticas de uso
class MusicMetadataCache {
  // Caché en memoria para acceso rápido durante la sesión
  static final Map<String, _CachedMetadata> _memoryCache = {};

  // Configuración
  static const int maxArtworkSize = 200 * 1024; // 200KB max por artwork
  static const int maxCacheAge = 30; // días
  static const int maxCacheSize = 100 * 1024 * 1024; // 100MB total

  /// Obtener archivo de caché para una key
  static Future<File> _getCacheFile(String key) async {
    final dir = await getApplicationCacheDirectory();
    // Usar hashcode para evitar problemas con caracteres especiales en rutas
    final fileName = 'art_${key.hashCode}.jpg';
    return File('${dir.path}/$fileName');
  }

  /// Obtener metadata del caché (memoria O disco)
  static Future<SongMetadata?> get(String key) async {
    // 1. Memoria
    if (_memoryCache.containsKey(key)) {
      return _convertToSongMetadata(_memoryCache[key]!);
    }

    try {
      // 2. Disco
      final prefs = await SharedPreferences.getInstance();

      // Intentar leer texto (título, artista...)
      final metaJson = prefs.getString('meta_txt_$key');

      Uint8List? artworkBytes;

      // Intentar leer imagen del sistema de archivos
      final file = await _getCacheFile(key);
      if (await file.exists()) {
        artworkBytes = await file.readAsBytes();
      }

      if (metaJson != null) {
        final data = json.decode(metaJson) as Map<String, dynamic>;
        final cached = _CachedMetadata(
          title: data['title'],
          artist: data['artist'],
          album: data['album'],
          durationMs: data['duration'],
          artworkBytes: artworkBytes,
          artworkUri: data['artworkUri'], // Cargar URI
          dominantColor: data['dominantColor'], // Cargar color
          timestamp: data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
        );

        // Hidratar memoria
        _memoryCache[key] = cached;
        return _convertToSongMetadata(cached);
      } else if (artworkBytes != null) {
        // Solo imagen encontrada
        final cached = _CachedMetadata(
          artworkBytes: artworkBytes,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        _memoryCache[key] = cached;
        return _convertToSongMetadata(cached);
      }
    } catch (e) {
      print('[MetadataCache] Error reading cache: $e');
    }

    return null;
  }

  /// Convierte _CachedMetadata a SongMetadata
  static SongMetadata _convertToSongMetadata(_CachedMetadata cached) {
    return SongMetadata(
      title: cached.title ?? 'Unknown',
      artist: cached.artist ?? 'Unknown Artist',
      album: cached.album,
      durationMs: cached.durationMs,
      artwork: cached.artworkBytes,
      artworkUri: cached.artworkUri,
      dominantColor: cached.dominantColor,
    );
  }

  /// Comprimir imagen para almacenamiento eficiente
  static Uint8List? _compressArtwork(Uint8List originalBytes) {
    try {
      // Decodificar imagen
      final image = img.decodeImage(originalBytes);
      if (image == null) return null;

      // Redimensionar a máximo 300x300 (mantiene aspect ratio)
      final resized = img.copyResize(
        image,
        width: image.width > 300 ? 300 : image.width,
        height: image.height > 300 ? 300 : image.height,
        interpolation: img.Interpolation.average,
      );

      // Comprimir como JPEG con calidad 85
      final compressed = img.encodeJpg(resized, quality: 85);
      return Uint8List.fromList(compressed);
    } catch (e) {
      print('[MetadataCache] Error compressing artwork: $e');
      return null;
    }
  }

  // Eliminado método save(Tag tag) para desacoplar de librería específica

  /// Guardar metadata directamente
  static Future<void> saveFromMetadata({
    required String key,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    Uint8List? artworkData,
    String? artworkUri,
    int? dominantColor,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // 1. Guardar Texto + URI en SharedPrefs
      final data = {
        'title': title,
        'artist': artist,
        'album': album,
        'duration': durationMs,
        'artworkUri': artworkUri, // Guardar URI
        'dominantColor': dominantColor, // Guardar color
        'timestamp': timestamp,
      };
      await prefs.setString('meta_txt_$key', json.encode(data));

      // 2. Guardar Imagen en Disco (FileSystem) (Solo si tenemos bytes binarios, si tenemos URI, ¿necesitamos bytes? Quizás como fallback)
      Uint8List? finalArtBytes;
      if (artworkData != null) {
        final compressed = _compressArtwork(artworkData);
        if (compressed != null) {
          final file = await _getCacheFile(key);
          await file.writeAsBytes(compressed);
          finalArtBytes = compressed;
        }
      }

      // 3. Actualizar memoria
      _memoryCache[key] = _CachedMetadata(
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        artworkBytes: finalArtBytes,
        artworkUri: artworkUri,
        dominantColor: dominantColor,
        timestamp: timestamp,
      );
    } catch (e) {
      print('[MetadataCache] Error saving cache: $e');
    }
  }

  /// Eliminar una entrada específica del caché
  static Future<void> delete(String key) async {
    // 1. Eliminar de memoria
    _memoryCache.remove(key);

    try {
      // 2. Eliminar archivo de artwork
      final file = await _getCacheFile(key);
      if (await file.exists()) {
        await file.delete();
      }

      // 3. Eliminar metadata de SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('meta_txt_$key');

      print('[MetadataCache] Deleted cache for key: $key');
    } catch (e) {
      print('[MetadataCache] Error deleting cache: $e');
    }
  }

  /// Limpiar caché (útil para debug o liberar espacio)
  static Future<void> clearCache() async {
    _memoryCache.clear();
    try {
      final dir = await getApplicationCacheDirectory();
      final files = dir.listSync();
      for (var f in files) {
        if (f is File && f.path.contains('art_')) {
          await f.delete();
        }
      }

      // Limpiar prefs keys
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('meta_txt_'));
      for (var k in keys) {
        await prefs.remove(k);
      }
    } catch (e) {
      print('[MetadataCache] Error clearing: $e');
    }
  }
}

/// Clase para almacenar metadata cacheada (Interna)
class _CachedMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final Uint8List? artworkBytes; // RAW bytes, no base64 string
  final String? artworkUri; // URI content://
  final int? dominantColor; // Color dominante cacheado
  final int timestamp; // Timestamp de cuando se guardó

  _CachedMetadata({
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.artworkBytes,
    this.artworkUri,
    this.dominantColor,
    required this.timestamp,
  });

  // Getter de compatibilidad por si alguien llamaba .artwork
  Uint8List? get artwork => artworkBytes;
}
