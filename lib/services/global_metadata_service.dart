import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;
import 'music_metadata_cache.dart';

/// Servicio global singleton para gestión de metadatos de música
/// Mantiene caché en memoria compartido entre todos los screens
class GlobalMetadataService {
  static final GlobalMetadataService _instance =
      GlobalMetadataService._internal();
  factory GlobalMetadataService() => _instance;
  GlobalMetadataService._internal();

  // Caché global en memoria (compartido entre todos los screens)
  final Map<String, SongMetadata?> _globalCache = {};

  /// Obtener metadatos con sistema de 3 niveles:
  /// 1. Memoria (instantáneo)
  /// 2. Disco (rápido)
  /// 3. Archivo (lento, solo primera vez)
  Future<SongMetadata?> get(String filePath) async {
    // Nivel 1: Verificar caché en memoria
    if (_globalCache.containsKey(filePath)) {
      debugPrint(
        '[GlobalMetadata] Cache hit (memory): ${p.basename(filePath)}',
      );
      return _globalCache[filePath];
    }

    // Nivel 2: Verificar caché persistente en disco
    final cached = await MusicMetadataCache.get(filePath);
    if (cached != null) {
      debugPrint('[GlobalMetadata] Cache hit (disk): ${p.basename(filePath)}');
      _globalCache[filePath] = cached;
      return cached;
    }

    // Nivel 3: Leer del archivo (solo si no hay caché)
    try {
      debugPrint('[GlobalMetadata] Loading from file: ${p.basename(filePath)}');
      final file = File(filePath);
      if (!await file.exists()) {
        _globalCache[filePath] = null;
        return null;
      }

      final meta = await Future(() => readMetadata(file, getImage: true));
      final artwork = meta.pictures.firstOrNull?.bytes;

      final metadata = SongMetadata(
        title: meta.title ?? p.basename(filePath),
        artist: meta.artist ?? 'Unknown Artist',
        album: meta.album,
        durationMs: meta.duration?.inMilliseconds,
        artwork: artwork,
      );

      // Guardar en ambos cachés
      await MusicMetadataCache.saveFromMetadata(
        key: filePath,
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        durationMs: meta.duration?.inMilliseconds,
        artworkData: artwork,
      );

      _globalCache[filePath] = metadata;
      return metadata;
    } catch (e) {
      debugPrint('[GlobalMetadata] Error loading metadata: $e');
      _globalCache[filePath] = null;
      return null;
    }
  }

  /// Precargar múltiples archivos en batch (con límite)
  Future<void> preloadBatch(List<String> filePaths, {int limit = 50}) async {
    final toLoad = filePaths.take(limit);
    debugPrint('[GlobalMetadata] Preloading ${toLoad.length} files...');

    int loaded = 0;
    for (final path in toLoad) {
      if (!_globalCache.containsKey(path)) {
        await get(path);
        loaded++;
      }
    }

    debugPrint('[GlobalMetadata] Preload complete: $loaded files loaded');
  }

  /// Limpiar caché en memoria (mantiene caché en disco)
  void clearMemoryCache() {
    debugPrint(
      '[GlobalMetadata] Clearing memory cache (${_globalCache.length} entries)',
    );
    _globalCache.clear();
  }

  /// Obtener estadísticas del caché
  Map<String, int> getCacheStats() {
    return {
      'memory_entries': _globalCache.length,
      'memory_with_data': _globalCache.values.where((v) => v != null).length,
    };
  }
}
