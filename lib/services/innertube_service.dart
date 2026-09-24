import 'dart:convert';
import 'dart:async';
import 'dart:io' show HttpException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'search_cache_store.dart';

/// (De)serialización mínima de InnertubeTrack para el caché de búsquedas
/// en disco (SearchCacheStore).
class InnertubeTrackJson {
  static Map<String, dynamic> toJson(InnertubeTrack t) => {
        'vid': t.videoId,
        'raw': t.rawTitle,
        'chan': t.channel,
        'album': t.album,
        'thumb': t.thumbnailUrl,
        'dur': t.durationMs,
        'clean': t.cleanMetadata,
      };

  static InnertubeTrack fromJson(Map<String, dynamic> j) {
    final vid = j['vid'];
    final raw = j['raw'];
    final chan = j['chan'];
    if (vid is! String || vid.isEmpty) {
      throw const FormatException('InnertubeTrack sin videoId');
    }
    final thumb = j['thumb'];
    final album = j['album'];
    final durMs = j['dur'];
    return InnertubeTrack(
      videoId: vid,
      watchUrl: 'https://www.youtube.com/watch?v=$vid',
      rawTitle: raw is String ? raw : '',
      channel: chan is String ? chan : '',
      album: album is String ? album : '',
      thumbnailUrl: thumb is String ? thumb : '',
      durationMs: durMs is int && durMs > 0 ? durMs : 0,
      cleanMetadata: j['clean'] == true,
    );
  }
}

/// Resultado de pista resuelto desde Innertube.
class InnertubeTrack {
  final String videoId;
  final String watchUrl;
  final String rawTitle;

  /// Artista ya limpio (canal de YT Music o columna de artista).
  final String channel;

  /// Álbum cuando la fila lo trae (YT Music).
  final String album;

  /// Artwork cuadrado en la mejor resolución disponible.
  final String thumbnailUrl;
  final int durationMs;

  /// URL de watch de la pista. Las pistas de YT Music (`cleanMetadata: true`
  /// o provenientes del browse de música) usan el dominio
  /// `music.youtube.com` — es el mismo videoId, pero mantiene la coherencia
  /// con la fuente del resultado; las del fallback WEB usan
  /// `www.youtube.com`.
  String get watchUrlForDownload => cleanMetadata
      ? 'https://music.youtube.com/watch?v=$videoId'
      : 'https://www.youtube.com/watch?v=$videoId';

  /// true si los metadatos vienen ya limpios de YT Music (no requieren la
  /// limpieza de ruido "(Official Video)", etc.).
  final bool cleanMetadata;

  const InnertubeTrack({
    required this.videoId,
    required this.watchUrl,
    required this.rawTitle,
    required this.channel,
    this.album = '',
    this.thumbnailUrl = '',
    this.durationMs = 0,
    this.cleanMetadata = false,
  });
}

/// Pista de una playlist de Spotify (pre-resolución a YouTube).
class SpotifyPlaylistTrack {
  final String id;
  final String title;

  /// Artistas separados por coma (campo `subtitle` del embed).
  final String artists;
  final int durationMs;

  const SpotifyPlaylistTrack({
    required this.id,
    required this.title,
    required this.artists,
    this.durationMs = 0,
  });
}

/// Playlist cargada (de YouTube/YT Music o resuelta de Spotify).
class InnertubePlaylist {
  final String id;
  final String name;

  /// Pistas de YouTube/YT Music (para playlists de YouTube).
  final List<InnertubeTrack> tracks;

  /// Pistas de Spotify aún sin resolver a YouTube.
  final List<SpotifyPlaylistTrack> spotifyTracks;

  const InnertubePlaylist({
    required this.id,
    required this.name,
    this.tracks = const [],
    this.spotifyTracks = const [],
  });
}

/// Origen de una URL de playlist introducida por el usuario.
enum PlaylistKind { none, youtube, spotify }

/// Cliente ligero de la InnerTube API de YouTube / YT Music.
///
/// Estrategia (basada en el proyecto Scrup):
///  1. Principal: búsqueda en YT Music (`music.youtube.com`, cliente
///     WEB_REMIX + filtro de canciones). Devuelve filas
///     `musicResponsiveListItemRenderer` con título limpio, artista real,
///     álbum, duración y artwork CUADRADO de álbum (como Deezer).
///  2. Fallback: búsqueda WEB estándar (`videoRenderer`) con limpieza de
///     título/canal propia, por si YT Music falla o cambia.
///
/// En ambos casos la URL de descarga es el `watch?v=VIDEOID` exacto del
/// resultado, para que yt-dlp descargue la pista mostrada en la lista.
class InnertubeService {
  static final InnertubeService _instance = InnertubeService._internal();
  factory InnertubeService() => _instance;
  InnertubeService._internal();

  static const String _webEndpoint =
      'https://www.youtube.com/youtubei/v1/search?prettyPrint=false';
  static const String _musicEndpoint =
      'https://music.youtube.com/youtubei/v1/search?prettyPrint=false';

  // Cliente YT Music (mismos valores que usa Scrup).
  static const String _musicClientName = 'WEB_REMIX';
  static const String _musicClientVersion = '1.20240403.01.00';

  /// Filtro "Songs" de YT Music (copiado de Scrup).
  static const String _songsFilterParam = 'EgWKAQIIAWoKEAkQBRAKEAMQBA==';

  static final RegExp _clockRe = RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$');
  static final RegExp _ytListParamRe = RegExp(r'[?&]list=([A-Za-z0-9_-]+)');
  static final RegExp _ytBarePlaylistRe = RegExp(
    r'^(?:PL|UU|OL|FL|RD|LL|UL)[A-Za-z0-9_-]{10,}$',
  );
  static final RegExp _spotifyUrlRe = RegExp(
    r'open\.spotify\.com/(?:intl-[a-z-]+/)?(playlist|track)/([A-Za-z0-9]+)',
  );
  static final RegExp _spotifyUriRe = RegExp(
    r'^spotify:(playlist|track):([A-Za-z0-9]+)',
  );

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    'Accept-Language': 'en-US,en;q=0.9',
  };

  static const Map<String, String> _musicHeaders = {
    'Content-Type': 'application/json',
    'User-Agent': 'Mozilla/5.0',
    'X-YouTube-Client-Name': '67',
    'X-YouTube-Client-Version': _musicClientVersion,
  };

  final Map<String, List<InnertubeTrack>> _searchCache = {};

  /// Busca pistas: primero en YT Music (artwork cuadrado, metadatos limpios);
  /// si no hay resultados o falla, en YouTube WEB con limpieza local.
  ///
  /// El resultado se cachea en memoria (por sesión) y en disco
  /// (SearchCacheStore, TTL 2 días) para que reabrir el app o repetir la
  /// búsqueda no vuelva a pagar el coste de red.
  Future<List<InnertubeTrack>> searchTracks(
    String query, {
    int limit = 40,
  }) async {
    final key = '${query.trim().toLowerCase()}|$limit';
    final cached = _searchCache[key];
    if (cached != null) return cached;

    // 0) Caché persistente (TTL 2 días)
    try {
      final persisted = await SearchCacheStore().getMusic(query, limit);
      if (persisted != null && persisted.isNotEmpty) {
        _searchCache[key] = persisted;
        debugPrint(
          '[InnertubeService] "$query" served from disk cache '
          '(${persisted.length} tracks)',
        );
        return persisted;
      }
    } catch (_) {
      // Caché ilegible: seguir con la búsqueda normal.
    }

    // 1) YT Music (fuente preferida: artwork de álbum + metadatos limpios)
    final musicTracks = await _searchYtMusic(query, limit);
    if (musicTracks.isNotEmpty) {
      debugPrint(
        '[InnertubeService] YTMusic search "$query" -> ${musicTracks.length} tracks',
      );
      _searchCache[key] = musicTracks;
      unawaited(
        SearchCacheStore().putMusic(query, limit, musicTracks).catchError((_) {}),
      );
      return musicTracks;
    }

    // 2) Fallback: YouTube WEB
    final webTracks = await _searchWeb(query, limit);
    debugPrint(
      '[InnertubeService] WEB search "$query" -> ${webTracks.length} tracks (fallback)',
    );
    _searchCache[key] = webTracks;
    unawaited(
      SearchCacheStore().putMusic(query, limit, webTracks).catchError((_) {}),
    );
    return webTracks;
  }

  Future<List<InnertubeTrack>> _searchYtMusic(
    String query,
    int limit,
  ) async {
    try {
      final body = jsonEncode({
        'context': {
          'client': {
            'clientName': _musicClientName,
            'clientVersion': _musicClientVersion,
            'hl': 'en',
            'gl': 'US',
          },
        },
        'query': query,
        'params': _songsFilterParam,
      });

      final response = await http
          .post(Uri.parse(_musicEndpoint), headers: _musicHeaders, body: body)
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        debugPrint(
          '[InnertubeService] YTMusic search failed: HTTP ${response.statusCode}',
        );
        return const [];
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) return const [];
      return _extractMusicListItems(data, limit);
    } on TimeoutException catch (e) {
      debugPrint('[InnertubeService] YTMusic timeout: $e');
      return const [];
    } on http.ClientException catch (e) {
      debugPrint('[InnertubeService] YTMusic network error: $e');
      return const [];
    } on FormatException catch (e) {
      debugPrint('[InnertubeService] YTMusic JSON parse error: $e');
      return const [];
    } catch (e) {
      debugPrint('[InnertubeService] YTMusic unexpected error: $e');
      return const [];
    }
  }

  Future<List<InnertubeTrack>> _searchWeb(String query, int limit) async {
    try {
      final body = jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': '2.20240304.00.00',
            'hl': 'en',
            'gl': 'US',
          },
        },
        'query': query,
      });

      final response = await http
          .post(Uri.parse(_webEndpoint), headers: _headers, body: body)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint(
          '[InnertubeService] WEB search failed: HTTP ${response.statusCode}',
        );
        return const [];
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _extractVideoRenderers(data, limit);
    } on TimeoutException catch (e) {
      debugPrint('[InnertubeService] WEB timeout: $e');
      return const [];
    } on http.ClientException catch (e) {
      debugPrint('[InnertubeService] WEB network error: $e');
      return const [];
    } on FormatException catch (e) {
      debugPrint('[InnertubeService] WEB JSON parse error: $e');
      return const [];
    } catch (e) {
      debugPrint('[InnertubeService] WEB unexpected error: $e');
      return const [];
    }
  }

  /// Resuelve la pista más relevante para una consulta y devuelve su URL
  /// exacta (`watch?v=VIDEOID`) para pasarla a yt-dlp.
  Future<String?> resolveTrackUrl(String query) async {
    final tracks = await searchTracks(query, limit: 5);
    if (tracks.isEmpty) return null;
    return tracks.first.watchUrlForDownload;
  }

  // ---------------------------------------------------------------------------
  // Playlists
  // ---------------------------------------------------------------------------

  /// Detecta el tipo de playlist contenida en `input` (URL o ID suelto).
  static PlaylistKind playlistKind(String input) {
    final t = input.trim();
    if (t.isEmpty) return PlaylistKind.none;
    if (t.contains('open.spotify.com') || t.startsWith('spotify:')) {
      final isSp = t.contains('/playlist/') ||
          t.contains('/track/') ||
          t.startsWith('spotify:playlist:') ||
          t.startsWith('spotify:track:');
      return isSp ? PlaylistKind.spotify : PlaylistKind.none;
    }
    return extractYoutubePlaylistId(t) != null
        ? PlaylistKind.youtube
        : PlaylistKind.none;
  }

  /// Extrae el ID de playlist de una URL de YouTube/YT Music o un ID suelto.
  static String? extractYoutubePlaylistId(String urlOrId) {
    final t = urlOrId.trim();
    final m = _ytListParamRe.firstMatch(t);
    if (m != null && m.group(1)!.isNotEmpty) return m.group(1);
    if (_ytBarePlaylistRe.hasMatch(t)) return t;
    return null;
  }

  /// Devuelve (`kind`, `id`) de una URL/URI/ID de Spotify.
  static (String, String)? extractSpotifyTarget(String urlOrId) {
    final t = urlOrId.trim();
    final m = _spotifyUrlRe.firstMatch(t) ?? _spotifyUriRe.firstMatch(t);
    if (m != null) return (m.group(1)!, m.group(2)!);
    if (RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(t)) return ('playlist', t);
    return null;
  }

  /// Carga una playlist pública de YouTube / YT Music vía InnerTube browse
  /// (mismo enfoque que `fetchPlaylist` de Scrup): pagina con tokens de
  /// continuación y deduplica por videoId.
  Future<InnertubePlaylist> fetchPlaylist(
    String urlOrId, {
    int maxTracks = 2000,
  }) async {
    final id = extractYoutubePlaylistId(urlOrId);
    if (id == null) {
      throw const FormatException('No es una playlist de YouTube válida');
    }

    final tracks = <InnertubeTrack>[];
    final seen = <String>{};
    String? continuation;
    var name = '';

    for (var page = 0; page < 50 && tracks.length < maxTracks; page++) {
      final body = jsonEncode({
        'context': {
          'client': {
            'clientName': _musicClientName,
            'clientVersion': _musicClientVersion,
            'hl': 'en',
            'gl': 'US',
          },
        },
        if (continuation == null) 'browseId': 'VL$id' else 'continuation': continuation,
      });

      final response = await http
          .post(
            Uri.parse(
              'https://music.youtube.com/youtubei/v1/browse?prettyPrint=false',
            ),
            headers: _musicHeaders,
            body: body,
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        if (page == 0) break; // YT Music falló; probar fallback WEB.
        throw HttpException('browse HTTP ${response.statusCode}');
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final parsed = _parseMusicBrowsePage(data);
      name = name.isEmpty ? parsed.$3 : name;
      var added = 0;
      for (final t in parsed.$1) {
        if (seen.add(t.videoId)) {
          tracks.add(t);
          added++;
        }
      }
      if (parsed.$2 == null || added == 0) break;
      continuation = parsed.$2;
    }

    // Fallback: browse WEB (playlistVideoRenderer) cuando YT Music no devuelve
    // nada (playlists que no son de YT Music o cambio de formato).
    if (tracks.isEmpty) {
      final web = await _fetchWebPlaylist(id, maxTracks);
      if (web.tracks.isEmpty) {
        throw HttpException('Playlist vacía o no encontrada');
      }
      return web;
    }

    return InnertubePlaylist(id: id, name: name, tracks: tracks);
  }

  /// Carga una playlist o pista de Spotify vía su página embed pública
  /// (JSON `__NEXT_DATA__` con `entity.trackList`).
  Future<InnertubePlaylist> fetchSpotifyPlaylist(String urlOrId) async {
    final target = extractSpotifyTarget(urlOrId);
    if (target == null) {
      throw const FormatException('No es una URL de Spotify válida');
    }
    final (kind, id) = target;

    final uri = Uri.parse('https://open.spotify.com/embed/$kind/$id');
    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException('Spotify embed HTTP ${response.statusCode}');
    }

    final body = utf8.decode(response.bodyBytes);
    const marker = '__NEXT_DATA__" type="application/json">';
    final start = body.indexOf(marker);
    if (start < 0) {
      throw const FormatException('Embed de Spotify sin __NEXT_DATA__');
    }
    final from = start + marker.length;
    final end = body.indexOf('</script>', from);
    if (end < 0) throw const FormatException('Embed de Spotify truncado');

    final data = jsonDecode(body.substring(from, end));
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Embed de Spotify inesperado');
    }

    // Localiza el entity que contiene `trackList` y el nombre de la playlist.
    Map<String, dynamic>? entity;
    String name = '';
    void walk(Object? node) {
      if (entity != null) return;
      if (node is Map<String, dynamic>) {
        if (node['trackList'] is List) {
          entity = node;
          final n = node['name'];
          if (n is String && n.trim().isNotEmpty) name = n.trim();
          return;
        }
        for (final v in node.values) {
          walk(v);
          if (entity != null) return;
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
          if (entity != null) return;
        }
      }
    }

    walk(data);
    final list = entity?['trackList'];
    if (list is! List || list.isEmpty) {
      throw const FormatException('Playlist de Spotify vacía o privada');
    }

    final tracks = <SpotifyPlaylistTrack>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final uri = item['uri']?.toString() ?? '';
      final tid = uri.split(':').length > 2 ? uri.split(':').last : '';
      final title = item['title']?.toString() ?? '';
      if (tid.isEmpty || title.isEmpty) continue;
      tracks.add(
        SpotifyPlaylistTrack(
          id: tid,
          title: title,
          artists: item['subtitle']?.toString() ?? '',
          durationMs: (item['duration'] is num)
              ? (item['duration'] as num).toInt()
              : 0,
        ),
      );
    }
    if (tracks.isEmpty) {
      throw const FormatException('Playlist de Spotify sin pistas utilizables');
    }

    return InnertubePlaylist(
      id: id,
      name: name,
      spotifyTracks: tracks,
    );
  }

  /// Página de browse de YT Music: (pistas, token de continuación, título).
  static (List<InnertubeTrack>, String?, String) _parseMusicBrowsePage(
    Object? node,
  ) {
    final items = <InnertubeTrack>[];
    final seen = <String>{};
    String? continuation;
    var name = '';

    void walk(Object? n) {
      if (n is Map<String, dynamic>) {
        final renderer = n['musicResponsiveListItemRenderer'];
        if (renderer is Map<String, dynamic>) {
          final t = _trackFromMusicListItem(renderer);
          if (t != null && seen.add(t.videoId)) items.add(t);
        }
        if (continuation == null) {
          final cont = (n['continuationItemRenderer']
              as Map<String, dynamic>?)?['continuationEndpoint']
          as Map<String, dynamic>?;
          final token = (cont?['continuationCommand']
              as Map<String, dynamic>?)?['token'] as String?;
          if (token != null && token.isNotEmpty) continuation = token;
        }
        for (final headerKey in const [
          'musicResponsiveHeaderRenderer',
          'playlistHeaderRenderer',
        ]) {
          if (name.isEmpty && n[headerKey] is Map<String, dynamic>) {
            final header = n[headerKey] as Map<String, dynamic>;
            final title = header['title'];
            if (title is Map<String, dynamic>) {
              final simple = title['simpleText'];
              if (simple is String && simple.trim().isNotEmpty) {
                name = simple.trim();
              } else if (title['runs'] is List) {
                final runs = (title['runs'] as List)
                    .whereType<Map<String, dynamic>>()
                    .toList();
                if (runs.isNotEmpty) {
                  final text = runs.first['text']?.toString() ?? '';
                  if (text.trim().isNotEmpty) name = text.trim();
                }
              }
            }
          }
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return (items, continuation, name);
  }

  /// Fallback: playlist vía browse WEB (playlistVideoRenderer).
  Future<InnertubePlaylist> _fetchWebPlaylist(
    String id,
    int maxTracks,
  ) async {
    final tracks = <InnertubeTrack>[];
    final seen = <String>{};
    String? continuation;
    var name = '';

    for (var page = 0; page < 30 && tracks.length < maxTracks; page++) {
      final body = jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': '2.20240304.00.00',
            'hl': 'en',
            'gl': 'US',
          },
        },
        if (continuation == null) 'browseId': 'VL$id' else 'continuation': continuation,
      });

      final response = await http
          .post(
            Uri.parse(
              'https://www.youtube.com/youtubei/v1/browse?prettyPrint=false',
            ),
            headers: _headers,
            body: body,
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) break;

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final parsed = _parseWebBrowsePage(data);
      name = name.isEmpty ? parsed.$3 : name;
      var added = 0;
      for (final t in parsed.$1) {
        if (seen.add(t.videoId)) {
          tracks.add(t);
          added++;
        }
      }
      if (parsed.$2 == null || added == 0) break;
      continuation = parsed.$2;
    }

    return InnertubePlaylist(id: id, name: name, tracks: tracks);
  }

  /// Página de browse WEB: (pistas, token de continuación, título).
  static (List<InnertubeTrack>, String?, String) _parseWebBrowsePage(
    Object? node,
  ) {
    final items = <InnertubeTrack>[];
    final seen = <String>{};
    String? continuation;
    var name = '';

    void walk(Object? n) {
      if (n is Map<String, dynamic>) {
        final vr = n['playlistVideoRenderer'];
        if (vr is Map<String, dynamic>) {
          final videoId = vr['videoId']?.toString() ?? '';
          final rawTitle = _titleFromRenderer(vr);
          if (videoId.isNotEmpty && rawTitle.isNotEmpty) {
            final t = InnertubeTrack(
              videoId: videoId,
              watchUrl: 'https://www.youtube.com/watch?v=$videoId',
              rawTitle: rawTitle,
              channel: _channelFromRenderer(vr),
              thumbnailUrl: _hiRes(_bestThumb(_videoThumbs(vr))),
              durationMs: _durationFromRenderer(vr),
            );
            if (seen.add(videoId)) items.add(t);
          }
        }
        if (name.isEmpty && n['playlistHeaderRenderer'] is Map<String, dynamic>) {
          final header =
              n['playlistHeaderRenderer'] as Map<String, dynamic>;
          final title = header['title'];
          if (title is Map<String, dynamic>) {
            name = title['simpleText']?.toString() ?? '';
          }
        }
        if (continuation == null) {
          final cont = (n['continuationItemRenderer']
              as Map<String, dynamic>?)?['continuationEndpoint']
          as Map<String, dynamic>?;
          final token = (cont?['continuationCommand']
              as Map<String, dynamic>?)?['token'] as String?;
          if (token != null && token.isNotEmpty) continuation = token;
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return (items, continuation, name);
  }

  // ---------------------------------------------------------------------------
  // Parseo YT Music: musicResponsiveListItemRenderer (estilo Scrup)
  // ---------------------------------------------------------------------------

  List<InnertubeTrack> _extractMusicListItems(
    Map<String, dynamic> data,
    int limit,
  ) {
    final tracks = <InnertubeTrack>[];

    void walk(Object? node) {
      if (tracks.length >= limit) return;
      if (node is Map<String, dynamic>) {
        final item = node['musicResponsiveListItemRenderer'];
        if (item is Map<String, dynamic>) {
          final track = _trackFromMusicListItem(item);
          if (track != null) tracks.add(track);
          return;
        }
        node.forEach((_, value) => walk(value));
      } else if (node is List) {
        for (final n in node) {
          walk(n);
          if (tracks.length >= limit) return;
        }
      }
    }

    walk(data);
    return tracks;
  }

  static InnertubeTrack? _trackFromMusicListItem(Map<String, dynamic> item) {
    final videoId =
        (item['playlistItemData'] as Map<String, dynamic>?)?['videoId']
            ?.toString() ??
        ((item['navigationEndpoint'] as Map<String, dynamic>?)?['watchEndpoint']
                as Map<String, dynamic>?)?['videoId']
            ?.toString();
    if (videoId == null || videoId.isEmpty) return null;

    final columns =
        (item['flexColumns'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
            const [];

    String? title;
    String artist = '';
    String album = '';
    int durationMs = 0;

    for (var i = 0; i < columns.length; i++) {
      final runs = _musicRunsOf(columns[i]);
      if (runs.isEmpty) continue;
      final texts = [
        for (final r in runs)
          if (r['text'] is String) r['text'] as String,
      ];
      if (i == 0) {
        title = texts.isNotEmpty ? texts.first.trim() : null;
        continue;
      }
      for (final t in texts) {
        final trimmed = t.trim();
        if (trimmed.isEmpty) continue;
        if (_clockRe.hasMatch(trimmed)) {
          if (durationMs == 0) durationMs = _parseClockToMs(trimmed);
        } else if (artist.isEmpty) {
          artist = trimmed.replaceAll(RegExp(r'\s*[•|]\s*$'), '').trim();
        } else if (album.isEmpty) {
          album = trimmed.replaceAll(RegExp(r'\s*[•|]\s*$'), '').trim();
        }
      }
    }

    // Duración también puede venir en fixedColumns.
    if (durationMs == 0) {
      final fixed =
          (item['fixedColumns'] as List?)?.whereType<Map<String, dynamic>>();
      for (final col in fixed ?? const <Map<String, dynamic>>[]) {
        final runs = ((col['musicResponsiveListItemFixedColumnRenderer']
        as Map<String, dynamic>?)?['text'] as Map<String, dynamic>?)?['runs']
        as List?;
        if (runs == null) continue;
        for (final r in runs) {
          if (r is! Map<String, dynamic>) continue;
          final t = (r['text'] as String?)?.trim() ?? '';
          if (_clockRe.hasMatch(t)) {
            durationMs = _parseClockToMs(t);
            break;
          }
        }
        if (durationMs > 0) break;
      }
    }

    if (title == null || title.isEmpty) return null;

    return InnertubeTrack(
      videoId: videoId,
      watchUrl: 'https://www.youtube.com/watch?v=$videoId',
      rawTitle: title,
      channel: artist,
      album: album,
      thumbnailUrl: _hiRes(_bestThumb(_musicThumbs(item))),
      durationMs: durationMs,
      cleanMetadata: true,
    );
  }

  static List<Map<String, dynamic>> _musicRunsOf(Map<String, dynamic> column) {
    final runs = ((column['musicResponsiveListItemFlexColumnRenderer']
    as Map<String, dynamic>?)?['text'] as Map<String, dynamic>?)?['runs']
    as List?;
    if (runs is! List) return const [];
    return runs.whereType<Map<String, dynamic>>().toList();
  }

  /// Thumbnails de una fila YT Music:
  /// `item.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails`
  static List? _musicThumbs(Map<String, dynamic> item) {
    final holder = item['thumbnail'] as Map<String, dynamic>?;
    final renderer = holder?['musicThumbnailRenderer'] as Map<String, dynamic>?;
    final thumb = renderer?['thumbnail'] as Map<String, dynamic>?;
    final thumbs = thumb?['thumbnails'];
    return thumbs is List ? thumbs : null;
  }

  // ---------------------------------------------------------------------------
  // Parseo WEB: videoRenderer (fallback)
  // ---------------------------------------------------------------------------

  List<InnertubeTrack> _extractVideoRenderers(
    Map<String, dynamic> data,
    int limit,
  ) {
    final tracks = <InnertubeTrack>[];

    void walk(Object? node) {
      if (tracks.length >= limit) return;
      if (node is Map<String, dynamic>) {
        final vr = node['videoRenderer'];
        if (vr is Map<String, dynamic>) {
          final videoId = vr['videoId']?.toString() ?? '';
          final rawTitle = _titleFromRenderer(vr);
          final channel = _channelFromRenderer(vr);
          if (videoId.isNotEmpty && rawTitle.isNotEmpty) {
            tracks.add(
              InnertubeTrack(
                videoId: videoId,
                watchUrl: 'https://www.youtube.com/watch?v=$videoId',
                rawTitle: rawTitle,
                channel: channel,
                thumbnailUrl: _hiRes(_bestThumb(_videoThumbs(vr))),
                durationMs: _durationFromRenderer(vr),
              ),
            );
          }
          return;
        }
        node.forEach((_, value) => walk(value));
      } else if (node is List) {
        for (final item in node) {
          walk(item);
          if (tracks.length >= limit) return;
        }
      }
    }

    walk(data);
    return tracks;
  }

  static List? _videoThumbs(Map<String, dynamic> vr) {
    final thumbs =
        (vr['thumbnail'] as Map<String, dynamic>?)?['thumbnails'] as List?;
    return thumbs;
  }

  static int _durationFromRenderer(Map<String, dynamic> vr) {
    final lengthText = vr['lengthText'];
    if (lengthText is Map<String, dynamic>) {
      final simple = lengthText['simpleText']?.toString() ?? '';
      return _parseClockToMs(simple);
    }
    return 0;
  }

  static String _titleFromRenderer(Map<String, dynamic> vr) {
    final title = vr['title'];
    if (title is Map<String, dynamic>) {
      final runs = title['runs'];
      if (runs is List && runs.isNotEmpty) {
        final first = runs.first;
        if (first is Map<String, dynamic>) {
          return first['text']?.toString() ?? '';
        }
      }
      final simple = title['simpleText'];
      if (simple is String) return simple;
    }
    return '';
  }

  static String _channelFromRenderer(Map<String, dynamic> vr) {
    for (final key in const ['ownerText', 'longBylineText', 'shortBylineText']) {
      final byline = vr[key];
      if (byline is Map<String, dynamic>) {
        final runs = byline['runs'];
        if (runs is List && runs.isNotEmpty) {
          final first = runs.first;
          if (first is Map<String, dynamic>) {
            return first['text']?.toString() ?? '';
          }
        }
      }
    }
    return '';
  }

  // ---------------------------------------------------------------------------
  // Helpers de thumbnail (estilo Scrup)
  // ---------------------------------------------------------------------------

  /// Miniatura de mayor resolución de una lista de thumbnails.
  static String _bestThumb(List? thumbs) {
    if (thumbs == null || thumbs.isEmpty) return '';
    Map best = thumbs.first;
    var bestW = (best['width'] as num?) ?? 0;
    for (final t in thumbs) {
      if (t is! Map) continue;
      if (((t['width'] as num?) ?? 0) > bestW) {
        best = t;
        bestW = (t['width'] as num?) ?? 0;
      }
    }
    final url = best['url'];
    return url is String ? url : '';
  }

  /// Upgrade a alta resolución (equivalente a Track.hiResThumbnail de Scrup):
  ///  - ytimg: usa maxresdefault.jpg
  ///  - googleusercontent (YT Music): pide cuadrado w1200-h1200
  static String _hiRes(String url) {
    if (url.isEmpty) return url;
    final m = RegExp(r'i\.ytimg\.com/vi/([\w-]+)').firstMatch(url);
    if (m != null) {
      return 'https://i.ytimg.com/vi/${m.group(1)!}/maxresdefault.jpg';
    }
    if (url.contains('googleusercontent.com')) {
      return url.replaceFirst(RegExp(r'=(w|s)\d+.*$'), '=w1200-h1200');
    }
    return url;
  }

  static int _parseClockToMs(String clock) {
    final parts = clock.split(':');
    if (parts.isEmpty) return 0;
    final seconds = int.tryParse(parts.last) ?? 0;
    final minutes =
        parts.length > 1 ? int.tryParse(parts[parts.length - 2]) ?? 0 : 0;
    final hours =
        parts.length > 2 ? int.tryParse(parts[parts.length - 3]) ?? 0 : 0;
    return ((hours * 60 + minutes) * 60 + seconds) * 1000;
  }

  // ---------------------------------------------------------------------------
  // Limpieza compartida (fallback WEB) — debe permanecer en sincronía con la
  // cadena --parse-metadata/--replace-in-metadata de yt-dlp en
  // download_manager.dart para que lista y archivo coincidan.
  // ---------------------------------------------------------------------------

  /// Limpia sufijos de canales de música automáticos ("- Topic", "VEVO", etc.).
  static String cleanChannel(String channel) {
    return channel
        .replaceFirst(RegExp(r'\s*[-–—]?\s*(Topic|VEVO|Official)\s*$'), '')
        .trim();
  }

  /// Limpia el título crudo de Innertube quitando el ruido típico de YouTube.
  static String cleanTitle(String rawTitle) {
    var t = rawTitle;
    final sep = RegExp(r'^(?<artist>[^|]+?)\s+[-–—|]\s+(?<title>.+)$');
    final m = sep.firstMatch(t);
    if (m != null) {
      final maybeArtist = m.namedGroup('artist')?.trim() ?? '';
      final rest = m.namedGroup('title')?.trim() ?? '';
      if (maybeArtist.isNotEmpty && rest.isNotEmpty) t = rest;
    }
    t = t.replaceAll(
      RegExp(
        r'\s*[([][^)\]]*('
        '[Oo]fficial|[Ll]yric|[Aa]udio [Vv]ersion|[Aa]udio|[Vv]ideo|'
        '[Hh][Dd]|4K|[Rr]emaster|[Ee]xplicit|[Vv]isualizer|MV|M/V'
        r')[^)\]]*[)\]]\s*',
      ),
      ' ',
    );
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t;
  }

  /// Extrae el artista del título crudo ("Artista - Canción") si el canal no
  /// sirve como artista; si no, usa el canal limpio.
  static String artistFor(String channel, String rawTitle) {
    final m = RegExp(r'^(?<artist>[^|]+?)\s+[-–—|]\s+.+$').firstMatch(rawTitle);
    if (m != null) {
      final fromTitle = m.namedGroup('artist')?.trim() ?? '';
      if (fromTitle.isNotEmpty) return fromTitle;
    }
    final cleaned = cleanChannel(channel);
    return cleaned.isNotEmpty ? cleaned : channel;
  }

  void clearCache() => _searchCache.clear();
}
