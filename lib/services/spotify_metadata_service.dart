import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class SpotifyMetadata {
  final String title;
  final String artist;
  final String album;
  final String? year;
  final int? trackNumber;
  final String? albumArtUrl;
  final String? isrc;
  final String? spotifyUrl;
  final int? duration;
  final bool hasAlbumArt;

  SpotifyMetadata({
    required this.title,
    required this.artist,
    required this.album,
    this.year,
    this.trackNumber,
    this.albumArtUrl,
    this.isrc,
    this.spotifyUrl,
    this.duration,
    this.hasAlbumArt = false,
  });

  factory SpotifyMetadata.fromJson(Map<String, dynamic> json) {
    return SpotifyMetadata(
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
      album: json['album'] ?? '',
      year: json['year']?.toString(),
      trackNumber: json['trackNumber'],
      albumArtUrl: json['albumArtUrl'],
      isrc: json['isrc'],
      spotifyUrl: json['spotifyUrl'],
      duration: json['duration'],
      hasAlbumArt: json['hasAlbumArt'] ?? false,
    );
  }
}

class SpotifyMetadataService {
  static final SpotifyMetadataService _instance =
      SpotifyMetadataService._internal();
  factory SpotifyMetadataService() => _instance;
  SpotifyMetadataService._internal();

  // URL del backend
  static const String _baseUrl = 'http://api.foranly.space:24725';

  // Cache en memoria
  final Map<String, SpotifyMetadata> _cache = {};

  /// Busca metadatos en Spotify
  Future<SpotifyMetadata?> searchMetadata(
    String title, [
    String? artist,
  ]) async {
    try {
      final cacheKey = '${title.toLowerCase()}_${artist?.toLowerCase() ?? ''}';

      // Verificar caché local
      if (_cache.containsKey(cacheKey)) {
        debugPrint('[SpotifyMetadata] Using local cache for: $title');
        return _cache[cacheKey];
      }

      // Construir URL
      final uri = Uri.parse('$_baseUrl/metadata').replace(
        queryParameters: {
          'title': title,
          if (artist != null && artist.isNotEmpty) 'artist': artist,
        },
      );

      debugPrint('[SpotifyMetadata] Fetching metadata for: $title - $artist');

      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Timeout fetching metadata');
            },
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final metadata = SpotifyMetadata.fromJson(data);

        // Guardar en caché
        _cache[cacheKey] = metadata;

        debugPrint(
          '[SpotifyMetadata] Found: ${metadata.title} by ${metadata.artist}',
        );
        return metadata;
      } else if (response.statusCode == 404) {
        debugPrint('[SpotifyMetadata] No metadata found for: $title');
        return null;
      } else {
        debugPrint('[SpotifyMetadata] Error: ${response.statusCode}');
        return null;
      }
    } on SocketException catch (e) {
      debugPrint('[SpotifyMetadata] Network error (SocketException): $e');
      return null;
    } on TimeoutException catch (e) {
      debugPrint('[SpotifyMetadata] Timeout error: $e');
      return null;
    } on http.ClientException catch (e) {
      debugPrint('[SpotifyMetadata] HTTP client error: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('[SpotifyMetadata] JSON parse error: $e');
      return null;
    } catch (e, stackTrace) {
      debugPrint('[SpotifyMetadata] Unexpected error: $e');
      debugPrint('[SpotifyMetadata] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Descarga la portada del álbum
  Future<Uint8List?> downloadAlbumArt(String? albumArtUrl) async {
    if (albumArtUrl == null || albumArtUrl.isEmpty) {
      return null;
    }

    try {
      debugPrint('[SpotifyMetadata] Downloading album art from: $albumArtUrl');

      final response = await http
          .get(Uri.parse(albumArtUrl))
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Timeout downloading album art');
            },
          );

      if (response.statusCode == 200) {
        debugPrint(
          '[SpotifyMetadata] Album art downloaded: ${response.bodyBytes.length} bytes',
        );
        return response.bodyBytes;
      } else {
        debugPrint(
          '[SpotifyMetadata] Failed to download album art: ${response.statusCode}',
        );
        return null;
      }
    } catch (e) {
      debugPrint('[SpotifyMetadata] Error downloading album art: $e');
      return null;
    }
  }

  /// Limpia el caché local
  void clearCache() {
    _cache.clear();
    debugPrint('[SpotifyMetadata] Local cache cleared');
  }

  /// Limpia el caché del servidor
  Future<void> clearServerCache() async {
    try {
      final response = await http
          .post(Uri.parse('$_baseUrl/clear-cache'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint(
          '[SpotifyMetadata] Server cache cleared: ${data['cleared']} entries',
        );
      }
    } catch (e) {
      debugPrint('[SpotifyMetadata] Error clearing server cache: $e');
    }
  }
}
