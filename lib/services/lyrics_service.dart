import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:forawn/config/api_config.dart';
import 'package:forawn/models/synced_lyrics.dart';

/// Servicio para gestionar letras sincronizadas de canciones
class LyricsService {
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  final _log = Logger('LyricsService');
  Database? _database;
  final _cache = <String, SyncedLyrics>{}; // Cache en memoria

  /// Inicializa la base de datos
  Future<void> initialize() async {
    if (_database != null) return;

    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'lyrics.db');

      _database = await openDatabase(
        path,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE lyrics (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              song_title TEXT NOT NULL,
              artist TEXT NOT NULL,
              lrc_content TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              UNIQUE(song_title, artist)
            )
          ''');

          // Índice para búsquedas rápidas
          await db.execute('''
            CREATE INDEX idx_song_artist ON lyrics(song_title, artist)
          ''');
        },
      );

      _log.info('Base de datos de lyrics inicializada');
    } catch (e) {
      _log.severe('Error al inicializar base de datos de lyrics: $e');
    }
  }

  /// Busca y descarga letras de una canción
  Future<SyncedLyrics?> fetchLyrics(String title, String artist) async {
    try {
      // Verificar cache en memoria primero
      final cacheKey = '${title.toLowerCase()}_${artist.toLowerCase()}';
      if (_cache.containsKey(cacheKey)) {
        _log.fine('Lyrics encontrados en cache: $title - $artist');
        return _cache[cacheKey];
      }

      // Verificar base de datos
      final stored = await _getStoredLyrics(title, artist);
      if (stored != null) {
        _cache[cacheKey] = stored;
        return stored;
      }

      // Descargar de la API
      final query = '$title $artist'.trim();
      final encodedQuery = Uri.encodeComponent(query);
      final url = '${ApiConfig.lyricsApiUrl}?query=$encodedQuery';

      _log.fine('Descargando lyrics: $query');

      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Timeout al descargar lyrics');
            },
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // Verificar si hay resultados
        if (data['status'] == true && data['results'] != null) {
          final results = data['results'] as List;

          // Iterar sobre los resultados hasta encontrar uno con syncedLyrics
          for (final result in results) {
            final details = result['details'];
            if (details != null && details['syncedLyrics'] != null) {
              final lrcContent = details['syncedLyrics'] as String;

              // Verificar que no esté vacío
              if (lrcContent.trim().isEmpty) continue;

              // Crear objeto SyncedLyrics
              final lyrics = SyncedLyrics.fromLRC(
                songTitle: title,
                artist: artist,
                lrcContent: lrcContent,
              );

              // Guardar en base de datos
              await _storeLyrics(title, artist, lrcContent);

              // Guardar en cache
              _cache[cacheKey] = lyrics;

              _log.info(
                'Lyrics descargados y guardados: $title - $artist (${lyrics.lineCount} líneas)',
              );
              return lyrics;
            }
          }

          _log.warning(
            'No se encontraron lyrics sincronizados en ${results.length} resultados para: $title - $artist',
          );
        } else {
          _log.warning(
            'Respuesta de API sin resultados para: $title - $artist',
          );
        }
      }

      _log.warning('No se encontraron lyrics para: $title - $artist');
      return null;
    } catch (e) {
      _log.warning('Error al obtener lyrics: $e');
      return null;
    }
  }

  /// Obtiene lyrics almacenados localmente
  Future<SyncedLyrics?> _getStoredLyrics(String title, String artist) async {
    if (_database == null) await initialize();

    try {
      final results = await _database!.query(
        'lyrics',
        where: 'LOWER(song_title) = ? AND LOWER(artist) = ?',
        whereArgs: [title.toLowerCase(), artist.toLowerCase()],
        limit: 1,
      );

      if (results.isNotEmpty) {
        final row = results.first;
        return SyncedLyrics.fromLRC(
          songTitle: row['song_title'] as String,
          artist: row['artist'] as String,
          lrcContent: row['lrc_content'] as String,
        );
      }

      return null;
    } catch (e) {
      _log.warning('Error al leer lyrics almacenados: $e');
      return null;
    }
  }

  /// Almacena lyrics en la base de datos
  Future<void> _storeLyrics(
    String title,
    String artist,
    String lrcContent,
  ) async {
    if (_database == null) await initialize();

    try {
      await _database!.insert('lyrics', {
        'song_title': title,
        'artist': artist,
        'lrc_content': lrcContent,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      _log.warning('Error al guardar lyrics: $e');
    }
  }

  /// Elimina lyrics de una canción
  Future<void> deleteLyrics(String title, String artist) async {
    if (_database == null) await initialize();

    try {
      await _database!.delete(
        'lyrics',
        where: 'LOWER(song_title) = ? AND LOWER(artist) = ?',
        whereArgs: [title.toLowerCase(), artist.toLowerCase()],
      );

      // Eliminar del cache
      final cacheKey = '${title.toLowerCase()}_${artist.toLowerCase()}';
      _cache.remove(cacheKey);

      _log.info('Lyrics eliminados: $title - $artist');
    } catch (e) {
      _log.warning('Error al eliminar lyrics: $e');
    }
  }

  /// Limpia el cache en memoria
  void clearCache() {
    _cache.clear();
    _log.info('Cache de lyrics limpiado');
  }

  /// Obtiene estadísticas
  Future<Map<String, int>> getStats() async {
    if (_database == null) await initialize();

    try {
      final result = await _database!.rawQuery(
        'SELECT COUNT(*) as count FROM lyrics',
      );
      final count = Sqflite.firstIntValue(result) ?? 0;

      return {'totalLyrics': count, 'cacheSize': _cache.length};
    } catch (e) {
      return {'totalLyrics': 0, 'cacheSize': _cache.length};
    }
  }

  /// Cierra la base de datos
  Future<void> dispose() async {
    await _database?.close();
    _database = null;
    _cache.clear();
  }
}
