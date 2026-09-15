import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'innertube_service.dart' show InnertubeTrack, InnertubeTrackJson;

/// Entrada genérica del caché: payload + timestamp para el TTL.
class _CacheEntry {
  final Map<String, dynamic> data;
  final DateTime at;

  const _CacheEntry(this.data, this.at);

  Map<String, dynamic> toJson() => {
        'at': at.millisecondsSinceEpoch,
        'data': data,
      };

  static _CacheEntry? fromJson(Map<String, dynamic> json) {
    final atMs = json['at'];
    final raw = json['data'];
    if (atMs is! int || raw is! Map<String, dynamic>) return null;
    return _CacheEntry(
      raw,
      DateTime.fromMillisecondsSinceEpoch(atMs),
    );
  }
}

/// Caché PERSISTENTE de búsquedas (memoria + disco), compartida por los
/// buscadores de música (Innertube) y video (yt-dlp -j):
///
/// - La primera vez que el app hace una búsqueda paga el coste completo de
///   red/proceso. Las siguientes sesiones la sirven de disco en <5ms mientras
///   no expire el TTL (2 días).
/// - LRU simple por orden de inserción, con tope de entradas y limpieza de
///   vencidas en cada carga/guardado.
/// - Un solo archivo JSON ("searches.json") guarda todas las entradas; el
///   guardado es diferido 2s para agrupar ráfagas.
///
/// `version` invalida TODO el caché cuando cambia el formato serializado.
class SearchCacheStore {
  SearchCacheStore._internal();
  static final SearchCacheStore _instance = SearchCacheStore._internal();
  factory SearchCacheStore() => _instance;

  static const int version = 1;

  /// TTL de las entradas (el usuario pidió 2 días).
  static const Duration ttl = Duration(days: 2);

  static const int maxEntries = 100;

  /// Nombres de fuente para separar dominios en el mismo archivo:
  ///  - 'music'  : búsquedas de pistas (InnertubeService.searchTracks)
  ///  - 'video'  : metadatos de video (yt-dlp -j, clave = url)
  static const String sourceMusic = 'music';
  static const String sourceVideo = 'video';

  final Map<String, _CacheEntry> _mem = {};
  Directory? _dir;
  Timer? _saveTimer;
  bool _dirty = false;
  bool _diskLoaded = false;

  String _key(String source, String query, int limit) =>
      '$source|$query|$limit';

  Future<Directory> _cacheDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'search_cache'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  File _file(Directory dir) => File(p.join(dir.path, 'searches.json'));

  File _versionFile(Directory dir) => File(p.join(dir.path, 'version.json'));

  /// Resultados cacheados y vigentes, o null.
  Future<Map<String, dynamic>?> get(
    String source,
    String query,
    int limit,
  ) async {
    final key = _key(source, query.trim().toLowerCase(), limit);
    final hit = _mem[key];
    if (hit != null) {
      if (DateTime.now().difference(hit.at) < ttl) return hit.data;
      _mem.remove(key);
      return null;
    }
    // Cache-miss en memoria: intenta cargar de disco UNA vez.
    await _loadFromDisk();
    final diskHit = _mem[key];
    if (diskHit == null) return null;
    if (DateTime.now().difference(diskHit.at) < ttl) return diskHit.data;
    _mem.remove(key);
    return null;
  }

  /// Atajo tipado para búsquedas de música.
  Future<List<InnertubeTrack>?> getMusic(String query, int limit) async {
    final raw = await get(sourceMusic, query, limit);
    if (raw == null) return null;
    final list = raw['tracks'];
    if (list is! List) return null;
    try {
      return [
        for (final e in list)
          if (e is Map<String, dynamic>) InnertubeTrackJson.fromJson(e),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Guarda resultados (memoria + persistencia diferida).
  Future<void> put(
    String source,
    String query,
    int limit,
    Map<String, dynamic> data,
  ) async {
    final key = _key(source, query.trim().toLowerCase(), limit);
    // Reinserta al final = LRU por orden.
    _mem.remove(key);
    while (_mem.length >= maxEntries) {
      _mem.remove(_mem.keys.first);
    }
    _mem[key] = _CacheEntry(data, DateTime.now());
    _dirty = true;
    // Persistencia diferida 2s: agrupa ráfagas.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_flush());
    });
  }

  /// Atajo tipado para búsquedas de música.
  Future<void> putMusic(
    String query,
    int limit,
    List<InnertubeTrack> tracks,
  ) async {
    if (tracks.isEmpty) return; // fallos no se cachean
    await put(sourceMusic, query, limit, {
      'tracks': [for (final t in tracks) InnertubeTrackJson.toJson(t)],
    });
  }

  Future<void> _loadFromDisk() async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final dir = await _cacheDir();
      // Versión del formato: si difiere, borra el archivo y empieza de cero.
      final vf = _versionFile(dir);
      var stale = true;
      if (await vf.exists()) {
        try {
          final v = jsonDecode(await vf.readAsString());
          if (v is Map && v['format'] == version) stale = false;
        } catch (_) {}
      }
      final f = _file(dir);
      if (stale) {
        _dirty = false;
        try {
          if (await f.exists()) await f.delete();
          if (await vf.exists()) await vf.delete();
        } catch (_) {}
        unawaited(
          vf.writeAsString(jsonEncode({'format': version}), flush: true),
        );
        return;
      }
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return;
      final now = DateTime.now();
      for (final entry in data.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        final parsed = _CacheEntry.fromJson(entry.value);
        if (parsed == null) continue;
        if (now.difference(parsed.at) >= ttl) continue; // vencida: descarta
        _mem[entry.key] = parsed;
      }
      _mem.removeWhere((_, v) => now.difference(v.at) >= ttl);
    } catch (_) {
      // Caché corrupta o ilegible: se regenera sola.
      if (kDebugMode) {
        debugPrint('[SearchCacheStore] load error (regenerating)');
      }
    }
  }

  Future<void> _flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final dir = await _cacheDir();
      final now = DateTime.now();
      _mem.removeWhere((_, v) => now.difference(v.at) >= ttl);
      final data = {for (final e in _mem.entries) e.key: e.value.toJson()};
      await _file(dir).writeAsString(jsonEncode(data), flush: true);
      // Marca el formato actual para que la próxima sesión no lo invalide.
      final vf = _versionFile(dir);
      if (!await vf.exists()) {
        unawaited(
          vf.writeAsString(jsonEncode({'format': version}), flush: true),
        );
      }
    } catch (_) {}
  }

  /// Elimina UNA entrada para forzar su re-lectura la próxima vez.
  Future<void> remove(String source, String query, int limit) async {
    final key = _key(source, query.trim().toLowerCase(), limit);
    _mem.remove(key);
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_flush());
    });
  }

  /// Vacía el caché (p. ej. acción de "limpiar caché" en ajustes).
  Future<void> clear() async {
    _mem.clear();
    _dirty = false;
    _saveTimer?.cancel();
    try {
      final dir = await _cacheDir();
      final f = _file(dir);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
