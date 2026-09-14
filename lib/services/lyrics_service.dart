import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:forawn/models/synced_lyrics.dart';
import 'package:forawn/models/lyrics_search_result.dart';

/// Servicio de letras con EXACTAMENTE DOS fuentes, en este orden (igual que
/// Scrup):
///   1) KPoe / LyricsPlus (palabra a palabra / karaoke, espejos en paralelo)
///   2) LRCLIB (línea a línea), solo si KPoe no encontró nada.
///
/// Las letras word-by-word se persisten como JSON (`format: karaoke`) para
/// preservar los timestamps por palabra; el LRC plano se guarda tal cual.
class LyricsService {
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  final _log = Logger('LyricsService');
  Database? _database;
  final _cache = <String, SyncedLyrics>{}; // Cache en memoria
  final _notFound = <String>{}; // Keys buscadas sin resultado
  final _notFoundLoaded = <String>{};

  // Espejos KPoe (LyricsPlus). Todos se lanzan EN PARALELO: gana el primero
  // (en orden) que responda con letras; nunca se esperan en serie.
  // binimum.org es el espejo estable actualmente (verificado 2026-09);
  // prjktla.my.id y workers.dev siguen como respaldo por si se recuperan.
  static const List<String> _kpoeServers = [
    'https://lyricsplus.binimum.org',
    'https://lyricsplus.atomix.one',
    'https://lyricsplus.prjktla.workers.dev',
    'https://lyricsplus.prjktla.my.id',
  ];

  // ------------------------------------------------------------------
  // Búsqueda manual
  // ------------------------------------------------------------------

  /// Busca letras manualmente devolviendo una lista de resultados.
  /// KPoe primero (word-by-word, espejos en paralelo) y LRCLIB después.
  /// [titleHint]/[artistHint] (metadatos de la canción actual) generan el
  /// candidato exacto para KPoe aunque el usuario busque "Título Artista"
  /// con un espacio simple (igual que Scrup).
  Future<List<LyricsSearchResult>> searchLyrics(
    String query, {
    String? titleHint,
    String? artistHint,
  }) async {
    final results = <LyricsSearchResult>[];

    // 1) KPoe (word-by-word): candidatos normalizados + espejos paralelos.
    final candidates = _searchCandidates(query, titleHint, artistHint);
    outerKpoe:
    for (final cand in candidates) {
      final attempts = <Future<LyricsSearchResult?>>[
        for (final server in _kpoeServers)
          _kpoeSearchOne(server, cand.$1, cand.$2),
      ];
      for (final res in await Future.wait(attempts)) {
        if (res != null) {
          results.add(res);
          break outerKpoe;
        }
      }
    }

    // 2) LRCLIB (line-by-line), respaldo de KPoe.
    try {
      final encodedQuery = Uri.encodeComponent(query);
      final uri = Uri.parse(
        'https://lrclib.net/api/search?q=$encodedQuery',
      );

      _log.info('Manual search lyrics (LRCLIB): $query');
      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw Exception('Timeout searching lyrics'),
          );

      if (response.statusCode == 200) {
        final List lrclibResults = json.decode(response.body);
        for (final e in lrclibResults) {
          final map = e as Map<String, dynamic>;
          // Etiquetar la fuente (LRCLIB no incluye este campo en su JSON).
          map['source'] = 'LRCLIB';
          results.add(LyricsSearchResult.fromJson(map));
        }
      }
    } catch (e) {
      _log.warning('Error searching lyrics: $e');
    }

    return results;
  }

  /// Consulta un espejo de KPoe para la búsqueda manual; null si no responde
  /// o no trae letras. Reconstruye LRC con tags <mm:ss.xx> por sílaba para
  /// preservar el modo word-by-word al aplicar/guardar el resultado manual.
  Future<LyricsSearchResult?> _kpoeSearchOne(
    String server,
    String title,
    String artist,
  ) async {
    try {
      final uri = Uri.parse(
        '$server/v2/lyrics/get',
      ).replace(queryParameters: {'title': title, 'artist': artist});
      // 10s: los espejos pueden tardar ~8s en pistas no cacheadas.
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final lyricsList = data['lyrics'] as List?;
      if (lyricsList == null || lyricsList.isEmpty) return null;
      final metaTitle = (data['metadata']?['title'] as String?) ?? '';
      final metaArtist = (data['metadata']?['artist'] as String?) ?? '';

      final lrcLines = <String>[];
      final plainLines = <String>[];
      for (final item in lyricsList) {
        final ld = item as Map<String, dynamic>;
        final t = (ld['time'] as num?)?.toInt() ?? 0;
        final text = ((ld['text'] as String?) ?? '').trim();
        final syllabus = ld['syllabus'] as List?;
        var line = '[${_lrcTs(t)}]';
        var hasWords = false;
        if (syllabus != null && syllabus.isNotEmpty) {
          final words = <String>[];
          for (final syl in syllabus) {
            final sd = syl as Map<String, dynamic>;
            final st = (sd['time'] as num?)?.toInt() ?? 0;
            final stext = (sd['text'] as String?) ?? '';
            if (stext.isEmpty) continue;
            words.add('<${_lrcTs(st)}>$stext');
          }
          if (words.isNotEmpty) {
            line += ' ${words.join(' ')}';
            hasWords = true;
          }
        }
        if (!hasWords) line += ' $text';
        lrcLines.add(line);
        plainLines.add(text);
      }
      return LyricsSearchResult(
        id: 0,
        trackName: metaTitle.isNotEmpty ? metaTitle : title,
        artistName: metaArtist.isNotEmpty ? metaArtist : artist,
        albumName: '',
        duration: 0.0,
        synced: true,
        syncedLyrics: lrcLines.join('\n'),
        plainLyrics: plainLines.join('\n'),
        source: 'KPoe',
      );
    } catch (_) {
      return null;
    }
  }

  /// Guarda unos lyrics seleccionados manualmente, preservando
  /// word-by-word si están presentes.
  Future<void> saveManualLyrics(
    String songTitle,
    String artist,
    String lrcContent, {
    String? source,
  }) async {
    try {
      // Detectar si el LRC trae tags de karaoke <mm:ss.xx> para guardar
      // el JSON que los preserva.
      final hasWords = RegExp(r'<\d{2}:\d{2}\.\d{2,3}>').hasMatch(lrcContent);
      if (hasWords) {
        final lyrics = SyncedLyrics.fromLRC(
          songTitle: songTitle,
          artist: artist,
          lrcContent: lrcContent,
          source: source,
        );
        await _storeLyrics(
          songTitle,
          artist,
          _syncedLyricsToJson(lyrics),
          notFound: false,
        );
        _cache[_key(songTitle, artist)] = lyrics;
      } else {
        final lyrics = SyncedLyrics.fromLRC(
          songTitle: songTitle,
          artist: artist,
          lrcContent: lrcContent,
          source: source,
        );
        await _storeLyrics(songTitle, artist, lrcContent, notFound: false);
        _cache[_key(songTitle, artist)] = lyrics;
      }
      _log.info('Lyrics manually saved for: $songTitle - $artist');
    } catch (e) {
      _log.warning('Error saving manual lyrics: $e');
    }
  }

  // ------------------------------------------------------------------
  // Base de datos
  // ------------------------------------------------------------------

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

  /// Busca y descarga letras de una canción (KPoe → LRCLIB, con caché).
  /// Single-flight: las N vistas de lyrics abiertas comparten UNA petición
  /// en vuelo por canción.
  final Map<String, Future<SyncedLyrics?>> _inFlight = {};

  Future<SyncedLyrics?> fetchLyrics(String title, String artist) {
    final cacheKey = _key(title, artist);
    if (_cache.containsKey(cacheKey)) return Future.value(_cache[cacheKey]);
    if (_notFound.contains(cacheKey)) return Future.value(null);
    return _inFlight.putIfAbsent(
      cacheKey,
      // OJO: el closure debe devolver void. Si devuelve el future almacenado
      // por putIfAbsent, whenComplete se esperaría a sí mismo y NUNCA
      // completaría (lecciones de Scrup).
      () => _fetchUncached(title, artist, cacheKey).whenComplete(() {
        _inFlight.remove(cacheKey);
      }),
    );
  }

  Future<SyncedLyrics?> _fetchUncached(
    String title,
    String artist,
    String cacheKey,
  ) async {
    try {
      final stored = await getStoredLyrics(title, artist);
      if (stored != null) {
        _cache[cacheKey] = stored;
        return stored;
      }

      if (!_notFoundLoaded.contains(cacheKey)) {
        final alreadyChecked = await wasAlreadyChecked(title, artist);
        _notFoundLoaded.add(cacheKey);
        if (alreadyChecked) {
          _notFound.add(cacheKey);
          return null;
        }
      }

      final cleanTrack = _cleanTitle(title);
      final cleanArtist = _cleanArtist(artist);

      // 1) KPoe (palabra a palabra) — espejos en paralelo.
      final kpoeResult = await _fetchKpoe(
        cleanTrack,
        cleanArtist,
        title,
        artist,
      );
      if (kpoeResult != null) {
        // Guarda como JSON para preservar los timestamps palabra a palabra.
        final karaokeJson = _syncedLyricsToJson(kpoeResult);
        await _storeLyrics(title, artist, karaokeJson, notFound: false);
        _cache[cacheKey] = kpoeResult;
        _log.info('Lyrics (KPoe, word-by-word) found for: $title');
        return kpoeResult;
      }

      // 2) LRCLIB (line by line) only if KPoe found nothing.
      final lrclibResult = await _fetchLrclib(
        cleanTrack,
        cleanArtist,
        title,
        artist,
      );
      if (lrclibResult != null) {
        _cache[cacheKey] = lrclibResult;
        return lrclibResult;
      }

      _notFound.add(cacheKey);
      await _storeLyrics(title, artist, '', notFound: true);
      _log.warning('Lyrics not found for: $title');
      return null;
    } catch (e) {
      _log.warning('Error al obtener lyrics: $e');
      return null;
    }
  }

  // ── KPoe ─────────────────────────────────────────────────────────────

  Future<SyncedLyrics?> _fetchKpoe(
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
  ) async {
    // Espejos EN PARALELO: el primero (en orden de _kpoeServers) que
    // responda con letras gana.
    final attempts = <Future<SyncedLyrics?>>[
      for (final server in _kpoeServers)
        _tryKpoeServer(
          server,
          cleanTrack,
          cleanArtist,
          originalTitle,
          originalArtist,
        ),
    ];
    for (final result in await Future.wait(attempts)) {
      if (result != null) return result;
    }
    return null;
  }

  Future<SyncedLyrics?> _tryKpoeServer(
    String server,
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
  ) async {
    try {
      final params = {'title': cleanTrack, 'artist': cleanArtist};
      final queryStr = params.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final uri = Uri.parse('$server/v2/lyrics/get?$queryStr');
      // 10s: los espejos pueden tardar ~8s en pistas no cacheadas.
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final lyrics = data['lyrics'] as List?;
      if (lyrics == null || lyrics.isEmpty) return null;
      final result = _parseKpoeResponse(data, originalTitle, originalArtist);
      if (result != null && result.lines.isNotEmpty) {
        return result;
      }
    } catch (_) {
      return null; // Try next server
    }
    return null;
  }

  SyncedLyrics? _parseKpoeResponse(
    Map<String, dynamic> data,
    String title,
    String artist,
  ) {
    try {
      final lyricsList = data['lyrics'] as List;
      final lines = <LyricLine>[];

      for (final item in lyricsList) {
        final lineData = item as Map<String, dynamic>;
        final lineTimeMs = (lineData['time'] as num?)?.toInt() ?? 0;
        final lineText = (lineData['text'] as String?) ?? '';
        final syllabus = lineData['syllabus'] as List?;

        List<KaraokeWord>? words;
        if (syllabus != null && syllabus.isNotEmpty) {
          words = [];
          for (final syl in syllabus) {
            final sylData = syl as Map<String, dynamic>;
            final sylText = ((sylData['text'] as String?) ?? '').trim();
            final sylTimeMs = (sylData['time'] as num?)?.toInt() ?? 0;
            if (sylText.isNotEmpty) {
              words.add(
                KaraokeWord(
                  timestamp: Duration(milliseconds: sylTimeMs),
                  text: sylText,
                ),
              );
            }
          }
        }

        if (lineText.trim().isNotEmpty) {
          lines.add(
            LyricLine(
              timestamp: Duration(milliseconds: lineTimeMs),
              text: lineText.trim(),
              words: (words != null && words.isNotEmpty) ? words : null,
            ),
          );
        }
      }

      lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return SyncedLyrics(
        songTitle: title,
        artist: artist,
        lines: lines,
        source: 'KPoe',
      );
    } catch (_) {
      return null;
    }
  }

  // ── LRCLIB ──────────────────────────────────────────────────────────

  Future<SyncedLyrics?> _fetchLrclib(
    String cleanTrack,
    String cleanArtist,
    String originalTitle,
    String originalArtist,
  ) async {
    try {
      final query = '$cleanTrack $cleanArtist';
      final encodedQuery = Uri.encodeComponent(query);
      final uri = Uri.parse('https://lrclib.net/api/search?q=$encodedQuery');

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw Exception('Timeout al descargar lyrics'),
          );

      if (response.statusCode == 200) {
        final List results = json.decode(response.body);

        if (results.isNotEmpty) {
          for (final item in results) {
            final data = item as Map<String, dynamic>;
            final syncedLyricsRaw = data['syncedLyrics'] as String?;
            final resultTrackName = (data['trackName'] as String? ?? '')
                .toLowerCase();
            final resultArtistName = (data['artistName'] as String? ?? '')
                .toLowerCase();

            final searchTrack = cleanTrack.toLowerCase();
            final searchArtist = cleanArtist.toLowerCase();

            final trackMatches =
                resultTrackName == searchTrack ||
                _calculateSimilarity(resultTrackName, searchTrack) > 0.5;
            final artistMatches =
                resultArtistName == searchArtist ||
                _calculateSimilarity(resultArtistName, searchArtist) > 0.5;

            if (!trackMatches || !artistMatches) continue;
            if (syncedLyricsRaw == null || syncedLyricsRaw.trim().isEmpty) {
              continue;
            }

            final lyrics = SyncedLyrics.fromLRC(
              songTitle: originalTitle,
              artist: originalArtist,
              lrcContent: syncedLyricsRaw,
              source: 'LRCLIB',
            );

            await _storeLyrics(
              originalTitle,
              originalArtist,
              syncedLyricsRaw,
              notFound: false,
            );
            return lyrics;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------------
  // Limpieza de metadatos (igual que Scrup)
  // ------------------------------------------------------------------

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

  /// Genera candidatos (título, artista) para proveedores con campos
  /// separados. Dedupe case-insensitive y normaliza formatos comunes
  /// (guión, "by").
  static List<(String, String)> _searchCandidates(
    String query,
    String? titleHint,
    String? artistHint,
  ) {
    final candidates = <(String, String)>[];
    void add(String t, String a) {
      t = t.trim();
      a = a.trim();
      if (t.isEmpty || a.isEmpty) return;
      final pair = (t.toLowerCase(), a.toLowerCase());
      for (final c in candidates) {
        if (c.$1.toLowerCase() == pair.$1 && c.$2.toLowerCase() == pair.$2) {
          return;
        }
      }
      candidates.add((t, a));
    }

    if (titleHint != null && titleHint.trim().isNotEmpty) {
      add(titleHint, artistHint ?? '');
    }
    final q = query.trim();
    // "Artist - Title" / "Title - Artist"
    final dashParts = q.split(RegExp(r'\s+[-–—]\s+'));
    if (dashParts.length == 2) {
      add(dashParts[0], dashParts[1]);
      add(dashParts[1], dashParts[0]);
    }
    // "Título by Artista"
    final byMatch = RegExp(
      r'^(.*?)\s+by\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(q);
    if (byMatch != null) {
      add(byMatch.group(1)!, byMatch.group(2)!);
    }
    return candidates;
  }

  static String _lrcTs(int ms) {
    final mins = ms ~/ 60000;
    final secs = (ms % 60000) ~/ 1000;
    final cs = (ms % 1000) ~/ 10;
    return '${mins.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }

  double _calculateSimilarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    final len1 = s1.length;
    final len2 = s2.length;
    final maxLen = len1 > len2 ? len1 : len2;
    final matrix = List.generate(len1 + 1, (i) => List.filled(len2 + 1, 0));
    for (var i = 0; i <= len1; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j <= len2; j++) {
      matrix[0][j] = j;
    }
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

  // ── Serialización JSON word-by-word (igual que Scrup) ───────────────

  String _syncedLyricsToJson(SyncedLyrics lyrics) {
    final linesJson = lyrics.lines.map((line) {
      final lineMap = <String, dynamic>{
        'time': line.timestamp.inMilliseconds,
        'text': line.text,
      };
      if (line.words != null && line.words!.isNotEmpty) {
        lineMap['words'] = line.words!
            .map((w) => {'time': w.timestamp.inMilliseconds, 'text': w.text})
            .toList();
      }
      return lineMap;
    }).toList();
    return json.encode({
      'format': 'karaoke',
      if (lyrics.source != null) 'source': lyrics.source,
      'lines': linesJson,
    });
  }

  /// Parsea letras almacenadas: JSON (word-by-word) o LRC plano.
  SyncedLyrics? _parseStoredLyrics(String stored, String title, String artist) {
    if (stored.startsWith('{')) {
      try {
        final data = json.decode(stored) as Map<String, dynamic>;
        if (data['format'] == 'karaoke' && data['lines'] != null) {
          final linesList = data['lines'] as List;
          final lines = linesList.map((l) {
            final lineData = l as Map<String, dynamic>;
            final timeMs = (lineData['time'] as num?)?.toInt() ?? 0;
            final text = (lineData['text'] as String?) ?? '';
            final wordsData = lineData['words'] as List?;
            List<KaraokeWord>? words;
            if (wordsData != null && wordsData.isNotEmpty) {
              words = wordsData.map((w) {
                final wd = w as Map<String, dynamic>;
                return KaraokeWord(
                  timestamp: Duration(
                    milliseconds: (wd['time'] as num?)?.toInt() ?? 0,
                  ),
                  text: (wd['text'] as String?) ?? '',
                );
              }).toList();
            }
            return LyricLine(
              timestamp: Duration(milliseconds: timeMs),
              text: text,
              words: words,
            );
          }).toList();
          lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          return SyncedLyrics(
            songTitle: title,
            artist: artist,
            lines: lines,
            source: data['source'] as String?,
          );
        }
      } catch (_) {}
    }
    if (stored.isNotEmpty) {
      return SyncedLyrics.fromLRC(
        songTitle: title,
        artist: artist,
        lrcContent: stored,
      );
    }
    return null;
  }

  // ------------------------------------------------------------------
  // Almacenamiento
  // ------------------------------------------------------------------

  /// Obtiene lyrics almacenados localmente (JSON karaoke o LRC plano).
  /// El cache previo a la limpieza de timestamps (sin campo 'source') se
  /// ignora para forzar un re-fetch con la lógica actual.
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
        final content = row['lrc_content'] as String?;
        if (content != null && content.isNotEmpty) {
          final parsed = _parseStoredLyrics(
            content,
            row['song_title'] as String,
            row['artist'] as String,
          );
          if (parsed != null) {
            if (parsed.source == null || parsed.source!.trim().isEmpty) {
              // Entrada vieja (sin fuente): ignorar y re-fetch.
              return null;
            }
            return parsed;
          }
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
      final key = _key(title, artist);
      _cache.remove(key);
      _notFound.remove(key);
    } catch (e) {
      _log.warning('Error al eliminar lyrics: $e');
    }
  }

  Future<int> clearAllLyrics() async {
    if (_database == null) await initialize();
    try {
      final count = await _database!.delete('lyrics');
      _cache.clear();
      _notFound.clear();
      return count;
    } catch (e) {
      _log.warning('Error al eliminar todas las lyrics: $e');
      return 0;
    }
  }

  String _key(String title, String artist) =>
      '${title.toLowerCase().trim()}_${artist.toLowerCase().trim()}';
}
