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
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE lyrics (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              song_title TEXT NOT NULL,
              artist TEXT NOT NULL,
              lrc_content TEXT,
              not_found INTEGER DEFAULT 0,
              created_at INTEGER NOT NULL,
              UNIQUE(song_title, artist)
            )
          ''');

          // Índice para búsquedas rápidas
          await db.execute('''
            CREATE INDEX idx_song_artist ON lyrics(song_title, artist)
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            // Agregar columna not_found a bases de datos existentes
            try {
              await db.execute(
                'ALTER TABLE lyrics ADD COLUMN not_found INTEGER DEFAULT 0',
              );
              _log.info('Base de datos actualizada a versión 2');
            } catch (e) {
              _log.warning('Error al actualizar base de datos: $e');
            }
          }
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

      // Verificar base de datos (incluyendo si ya se intentó y no se encontró)
      final stored = await getStoredLyrics(title, artist);
      if (stored != null) {
        _cache[cacheKey] = stored;
        return stored;
      }

      // Verificar si ya se intentó descargar antes y no se encontró
      final alreadyChecked = await wasAlreadyChecked(title, artist);
      if (alreadyChecked) {
        _log.fine(
          'Ya se verificó anteriormente (no encontrado): $title - $artist',
        );
        return null;
      }

      // Descargar de la API
      final query = '$title $artist'.trim();
      final encodedQuery = Uri.encodeComponent(query);
      final url = '${ApiConfig.lyricsApiUrl}?query=$encodedQuery';

      _log.info('Descargando lyrics: $query');

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
        // La API puede devolver directamente 'results' o tener un 'status'
        final results = (data['results'] ?? data) as dynamic;

        if (results is List && results.isNotEmpty) {
          // Iterar sobre los resultados hasta encontrar uno con syncedLyrics
          for (final result in results) {
            // Intentar obtener syncedLyrics directamente o desde details
            String? lrcContent;

            // Primero intentar desde details.syncedLyrics
            if (result['details'] != null &&
                result['details']['syncedLyrics'] != null) {
              lrcContent = result['details']['syncedLyrics'] as String?;
            }
            // Si no está en details, intentar directamente en result
            else if (result['syncedLyrics'] != null) {
              lrcContent = result['syncedLyrics'] as String?;
            }

            // Verificar que no esté vacío
            if (lrcContent == null || lrcContent.trim().isEmpty) continue;

            // Crear objeto SyncedLyrics
            final lyrics = SyncedLyrics.fromLRC(
              songTitle: title,
              artist: artist,
              lrcContent: lrcContent,
            );

            // Guardar en base de datos
            await _storeLyrics(title, artist, lrcContent, notFound: false);

            // Guardar en cache
            _cache[cacheKey] = lyrics;

            _log.info(
              'Lyrics descargados y guardados: $title - $artist (${lyrics.lineCount} líneas)',
            );
            return lyrics;
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

      // Marcar como no encontrado para no volver a intentar
      await _storeLyrics(title, artist, '', notFound: true);
      _log.warning(
        'No se encontraron lyrics para: $title - $artist (marcado como no encontrado)',
      );
      return null;
    } catch (e) {
      _log.warning('Error al obtener lyrics: $e');
      return null;
    }
  }

  /// Obtiene lyrics almacenados localmente
  Future<SyncedLyrics?> getStoredLyrics(String title, String artist) async {
    if (_database == null) await initialize();

    try {
      final results = await _database!.query(
        'lyrics',
        where: 'LOWER(song_title) = ? AND LOWER(artist) = ? AND not_found = 0',
        whereArgs: [title.toLowerCase(), artist.toLowerCase()],
        limit: 1,
      );

      if (results.isNotEmpty) {
        final row = results.first;
        final lrcContent = row['lrc_content'] as String?;
        if (lrcContent != null && lrcContent.isNotEmpty) {
          return SyncedLyrics.fromLRC(
            songTitle: row['song_title'] as String,
            artist: row['artist'] as String,
            lrcContent: lrcContent,
          );
        }
      }

      return null;
    } catch (e) {
      _log.warning('Error al leer lyrics almacenados: $e');
      return null;
    }
  }

  /// Verifica si ya se intentó descargar lyrics para esta canción
  Future<bool> wasAlreadyChecked(String title, String artist) async {
    if (_database == null) await initialize();

    try {
      final results = await _database!.query(
        'lyrics',
        where: 'LOWER(song_title) = ? AND LOWER(artist) = ?',
        whereArgs: [title.toLowerCase(), artist.toLowerCase()],
        limit: 1,
      );

      return results.isNotEmpty;
    } catch (e) {
      _log.warning('Error al verificar si ya se revisó: $e');
      return false;
    }
  }

  /// Almacena lyrics en la base de datos
  Future<void> _storeLyrics(
    String title,
    String artist,
    String lrcContent, {
    required bool notFound,
  }) async {
    if (_database == null) await initialize();

    try {
      await _database!.insert('lyrics', {
        'song_title': title,
        'artist': artist,
        'lrc_content': lrcContent,
        'not_found': notFound ? 1 : 0,
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

  /// Limpia las entradas marcadas como "no encontrado" para permitir reintentar
  Future<void> clearNotFoundEntries() async {
    if (_database == null) await initialize();

    try {
      final count = await _database!.delete('lyrics', where: 'not_found = 1');
      _log.info('Eliminadas $count entradas marcadas como no encontradas');
    } catch (e) {
      _log.warning('Error al limpiar entradas no encontradas: $e');
    }
  }

  /// Obtiene estadísticas
  Future<Map<String, int>> getStats() async {
    if (_database == null) await initialize();

    try {
      final successResult = await _database!.rawQuery(
        'SELECT COUNT(*) as count FROM lyrics WHERE not_found = 0',
      );
      final successCount = Sqflite.firstIntValue(successResult) ?? 0;

      final failedResult = await _database!.rawQuery(
        'SELECT COUNT(*) as count FROM lyrics WHERE not_found = 1',
      );
      final failedCount = Sqflite.firstIntValue(failedResult) ?? 0;

      return {
        'totalLyrics': successCount,
        'notFound': failedCount,
        'cacheSize': _cache.length,
      };
    } catch (e) {
      return {'totalLyrics': 0, 'notFound': 0, 'cacheSize': _cache.length};
    }
  }

  /// Cierra la base de datos
  Future<void> dispose() async {
    await _database?.close();
    _database = null;
    _cache.clear();
  }
}
