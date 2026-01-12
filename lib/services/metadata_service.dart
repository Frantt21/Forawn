import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class TrackMetadata {
  final String title;
  final String artist;
  final String album;
  final String? year;
  final int? trackNumber;
  final String? albumArtUrl;
  final String? isrc;
  final String?
  spotifyUrl; // Kept for backend compatibility in model if needed, or rename
  final int? duration;
  final bool hasAlbumArt;

  TrackMetadata({
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

  factory TrackMetadata.fromJson(Map<String, dynamic> json) {
    return TrackMetadata(
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

class MetadataService {
  static final MetadataService _instance = MetadataService._internal();
  factory MetadataService() => _instance;
  MetadataService._internal();

  final Map<String, TrackMetadata> _cache = {};

  Future<TrackMetadata?> searchMetadata(String title, [String? artist]) async {
    try {
      final cacheKey = '${title.toLowerCase()}_${artist?.toLowerCase() ?? ''}';

      if (_cache.containsKey(cacheKey)) {
        debugPrint('[MetadataService] Using local cache for: $title');
        return _cache[cacheKey];
      }

      final uri = Uri.parse('${ApiConfig.foranlyBackendPrimary}/metadata')
          .replace(
            queryParameters: {
              'title': title,
              if (artist != null && artist.isNotEmpty) 'artist': artist,
            },
          );

      debugPrint('[MetadataService] Fetching metadata for: $title - $artist');

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
        final metadata = TrackMetadata.fromJson(data);

        // Guardar en caché
        _cache[cacheKey] = metadata;

        debugPrint(
          '[MetadataService] Found: ${metadata.title} by ${metadata.artist}',
        );
        return metadata;
      } else if (response.statusCode == 404) {
        debugPrint('[MetadataService] No metadata found for: $title');
        return null;
      } else {
        debugPrint('[MetadataService] Error: ${response.statusCode}');
        return null;
      }
    } on SocketException catch (e) {
      debugPrint('[MetadataService] Network error (SocketException): $e');
      return null;
    } on TimeoutException catch (e) {
      debugPrint('[MetadataService] Timeout error: $e');
      return null;
    } on http.ClientException catch (e) {
      debugPrint('[MetadataService] HTTP client error: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('[MetadataService] JSON parse error: $e');
      return null;
    } catch (e, stackTrace) {
      debugPrint('[MetadataService] Unexpected error: $e');
      debugPrint('[MetadataService] Stack trace: $stackTrace');
      return null;
    }
  }

  /// Descarga la portada del álbum
  Future<Uint8List?> downloadAlbumArt(String? albumArtUrl) async {
    if (albumArtUrl == null || albumArtUrl.isEmpty) {
      return null;
    }

    try {
      debugPrint('[MetadataService] Downloading album art from: $albumArtUrl');

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
          '[MetadataService] Album art downloaded: ${response.bodyBytes.length} bytes',
        );
        return response.bodyBytes;
      } else {
        debugPrint(
          '[MetadataService] Failed to download album art: ${response.statusCode}',
        );
        return null;
      }
    } catch (e) {
      debugPrint('[MetadataService] Error downloading album art: $e');
      return null;
    }
  }

  /// Limpia el caché local
  void clearCache() {
    _cache.clear();
    debugPrint('[MetadataService] Local cache cleared');
  }
}
