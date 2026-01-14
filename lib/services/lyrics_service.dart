import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:forawn/config/api_config.dart';
import 'package:forawn/models/synced_lyrics.dart';
import 'package:forawn/models/lyrics_search_result.dart';

/// Servicio para gestionar letras sincronizadas de canciones (LRCLIB provider)
class LyricsService {
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  final _log = Logger('LyricsService');
  Database? _database;
  final _cache = <String, SyncedLyrics>{}; // Cache en memoria

  /// Busca letras manualmente devolviendo una lista de resultados
  Future<List<LyricsSearchResult>> searchLyrics(String query) async {
    try {
      final encodedQuery = Uri.encodeComponent(query);
      final uri = Uri.parse(
        '${ApiConfig.lyricsBaseUrl}/search?q=$encodedQuery',
      );

      _log.info('Manual search lyrics: $query');
      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Timeout searching lyrics'),
          );

      if (response.statusCode == 200) {
        final List results = json.decode(response.body);
        return results
            .map((e) => LyricsSearchResult.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      _log.warning('Error searching lyrics: $e');
      return [];
    }
  }

  /// Guarda unos lyrics seleccionados manualmente
  Future<void> saveManualLyrics(
    String songTitle,
    String artist,
    String lrcContent,
  ) async {
    try {
      // Guardar en DB
      await _storeLyrics(songTitle, artist, lrcContent, notFound: false);

      // Actualizar caché
      final lyrics = SyncedLyrics.fromLRC(
        songTitle: songTitle,
        artist: artist,
        lrcContent: lrcContent,
      );
      final cacheKey = '${songTitle.toLowerCase()}_${artist.toLowerCase()}';
      _cache[cacheKey] = lyrics;

      _log.info('Lyrics manually saved for: $songTitle - $artist');
    } catch (e) {
      _log.warning('Error saving manual lyrics: $e');
    }
  }

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
            try {
              await db.execute(
                'ALTER TABLE lyrics ADD COLUMN not_found INTEGER DEFAULT 0',
              );
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
      final cacheKey = '${title.toLowerCase()}_${artist.toLowerCase()}';
      if (_cache.containsKey(cacheKey)) {
        return _cache[cacheKey];
      }

      final stored = await getStoredLyrics(title, artist);
      if (stored != null) {
        _cache[cacheKey] = stored;
        return stored;
      }

      final alreadyChecked = await wasAlreadyChecked(title, artist);
      if (alreadyChecked) {
        _log.fine(
          'Ya se verificó anteriormente (no encontrado): $title - $artist',
        );
        return null; // Return null if previously not found to avoid spamming API
        // User wants manual search though? This is automatic fetch.
      }

      // Limpiar título y artista
      final cleanTrack = _cleanTitle(title);
      final cleanArtist = _cleanArtist(artist);
      final query = '$cleanTrack $cleanArtist';

      _log.info('Fetching lyrics from LRCLIB: $query');

      final encodedQuery = Uri.encodeComponent(query);
      // Usar endpoint de búsqueda para mejor matching
      final uri = Uri.parse(
        '${ApiConfig.lyricsBaseUrl}/search?q=$encodedQuery',
      );

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw Exception('Timeout al descargar lyrics'),
          );

      if (response.statusCode == 200) {
        final List results = json.decode(response.body);

        if (results.isNotEmpty) {
          // Find best match
          for (final item in results) {
            final data = item as Map<String, dynamic>;
            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final resultTrackName = (data['trackName'] as String? ?? '')
                .toLowerCase();
            final resultArtistName = (data['artistName'] as String? ?? '')
                .toLowerCase();

            // Similarity check
            final searchTrack = cleanTrack.toLowerCase();
            final searchArtist = cleanArtist.toLowerCase();

            final trackSimilarity = _calculateSimilarity(
              resultTrackName,
              searchTrack,
            );
            final artistSimilarity = _calculateSimilarity(
              resultArtistName,
              searchArtist,
            );

            final trackMatches =
                resultTrackName == searchTrack || trackSimilarity > 0.5;
            final artistMatches =
                resultArtistName == searchArtist || artistSimilarity > 0.5;

            if (!trackMatches || !artistMatches) continue;

            if (syncedLyricsRaw == null || syncedLyricsRaw.trim().isEmpty)
              continue;

            // Parse existing model
            final lyrics = SyncedLyrics.fromLRC(
              songTitle: title, // Keep original title
              artist: artist,
              lrcContent: syncedLyricsRaw,
            );

            await _storeLyrics(title, artist, syncedLyricsRaw, notFound: false);
            _cache[cacheKey] = lyrics;
            _log.info('Lyrics found and saved for: $title');
            return lyrics;
          }
        }
      }

      // Try fallback with only title if artist fails
      // ... (Simplified: just marking as not found for now to match current impl behavior)

      await _storeLyrics(title, artist, '', notFound: true);
      _log.warning('Lyrics not found for: $title');
      return null;
    } catch (e) {
      _log.warning('Error al obtener lyrics: $e');
      return null;
    }
  }

  /// Limpia el título
  String _cleanTitle(String title) {
    String clean = title;
    clean = clean.replaceAll(
      RegExp(r'\s*-\s*Remaster(ed)?\s*\d*', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\(Remaster(ed)?\s*\d*\)', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\[Remaster(ed)?\s*\d*\]', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\(.*?(?:Remix|Version|Edit|Mix).*?\)', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(r'\s*\[.*?(?:Remix|Version|Edit|Mix).*?\]', caseSensitive: false),
      '',
    );
    clean = clean.replaceAll(
      RegExp(
        r'\s+(?:ft\.?|feat\.?|featuring|con|with)\s+.*',
        caseSensitive: false,
      ),
      '',
    );
    return clean.trim();
  }

  /// Limpia el artista
  String _cleanArtist(String artist) {
    String clean = artist;
    clean = clean.replaceAll(
      RegExp(r'\s*-\s*Topic\s*$', caseSensitive: false),
      '',
    );
    final match = RegExp(r'^([^,&]+)').firstMatch(clean);
    if (match != null) {
      clean = match.group(1) ?? clean;
    }
    return clean.trim();
  }

  /// Levenshtein similarity
  double _calculateSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final len1 = s1.length;
    final len2 = s2.length;
    final maxLen = len1 > len2 ? len1 : len2;
    final matrix = List.generate(len1 + 1, (i) => List.filled(len2 + 1, 0));
    for (var i = 0; i <= len1; i++) matrix[i][0] = i;
    for (var j = 0; j <= len2; j++) matrix[0][j] = j;
    for (var i = 1; i <= len1; i++) {
      for (var j = 1; j <= len2; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return 1.0 - (matrix[len1][len2] / maxLen);
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
      return null;
    }
  }

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
      return false;
    }
  }

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

  Future<void> deleteLyrics(String title, String artist) async {
    if (_database == null) await initialize();
    try {
      await _database!.delete(
        'lyrics',
        where: 'LOWER(song_title) = ? AND LOWER(artist) = ?',
        whereArgs: [title.toLowerCase(), artist.toLowerCase()],
      );
      _cache.remove('${title.toLowerCase()}_${artist.toLowerCase()}');
    } catch (e) {
      _log.warning('Error al eliminar lyrics: $e');
    }
  }

  Future<int> clearAllLyrics() async {
    if (_database == null) await initialize();
    try {
      final count = await _database!.delete('lyrics');
      _cache.clear();
      return count;
    } catch (e) {
      _log.warning('Error al eliminar todas las lyrics: $e');
      return 0;
    }
  }
}
