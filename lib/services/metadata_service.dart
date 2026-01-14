import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
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

  /// Actualiza los metadatos del archivo usando FFmpeg
  Future<bool> updateFileMetadata(
    String filePath,
    TrackMetadata metadata,
  ) async {
    File? tempCoverFile;
    try {
      debugPrint('[MetadataService] Updating metadata for: $filePath');

      // 1. Descargar cover si existe
      String? coverPath;
      if (metadata.albumArtUrl != null && metadata.albumArtUrl!.isNotEmpty) {
        final coverBytes = await downloadAlbumArt(metadata.albumArtUrl);
        if (coverBytes != null) {
          final tempDir = Directory.systemTemp;
          tempCoverFile = File(
            '${tempDir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          await tempCoverFile.writeAsBytes(coverBytes);
          coverPath = tempCoverFile.path;
        }
      }

      // 2. Preparar archivo de salida temporal
      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('[MetadataService] File does not exist: $filePath');
        return false;
      }

      final extension = filePath.split('.').last;
      final tempOutputPath = '${filePath}.temp.$extension';

      // 3. Construir argumentos FFmpeg
      List<String> args = ['-i', filePath];

      if (coverPath != null) {
        args.addAll(['-i', coverPath]);
        args.addAll(['-map', '0:a', '-map', '1:0']);
        args.addAll(['-c', 'copy']);
        args.addAll(['-id3v2_version', '3']);
        args.addAll([
          '-metadata:s:v',
          'title="Album cover"',
          '-metadata:s:v',
          'comment="Cover (front)"',
        ]);
      } else {
        args.addAll(['-c', 'copy']);
      }

      // Añadir metadatos de texto
      if (metadata.title.isNotEmpty)
        args.addAll(['-metadata', 'title=${metadata.title}']);
      if (metadata.artist.isNotEmpty)
        args.addAll(['-metadata', 'artist=${metadata.artist}']);
      if (metadata.album.isNotEmpty)
        args.addAll(['-metadata', 'album=${metadata.album}']);
      if (metadata.year != null)
        args.addAll(['-metadata', 'date=${metadata.year}']);
      if (metadata.trackNumber != null)
        args.addAll(['-metadata', 'track=${metadata.trackNumber}']);

      // Sobrescribir salida
      args.addAll(['-y', tempOutputPath]);

      debugPrint('[MetadataService] Running FFmpeg command logic');

      // Localizar ffmpeg
      final toolsDir = _findToolsDir();
      debugPrint('[MetadataService] Tools dir found: "$toolsDir"');

      var ffmpegExe = 'ffmpeg'; // Default global

      if (toolsDir.isNotEmpty) {
        var localFfmpeg = p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe');
        if (!File(localFfmpeg).existsSync()) {
          localFfmpeg = p.join(toolsDir, 'ffmpeg.exe');
        }

        debugPrint(
          '[MetadataService] Checking local ffmpeg at: "$localFfmpeg"',
        );
        if (File(localFfmpeg).existsSync()) {
          ffmpegExe = localFfmpeg;
          debugPrint('[MetadataService] Found local ffmpeg: $ffmpegExe');
        } else {
          debugPrint(
            '[MetadataService] Local ffmpeg NOT found at expected path.',
          );
        }
      } else {
        debugPrint('[MetadataService] Tools directory not found.');
      }

      debugPrint('[MetadataService] Executing: $ffmpegExe ...');

      final result = await Process.run(ffmpegExe, args);

      if (result.exitCode != 0) {
        debugPrint('[MetadataService] FFmpeg error: ${result.stderr}');
        // Si falla con map 0:a intentamos sin map específico (a veces 0:0 es audio)
        if (coverPath != null) {
          debugPrint('[MetadataService] Retrying without specific map...');
          // Reintentar lógica simplificada si falla mapeo complejo
          // ... Pendiente de implementación robusta, por ahora retornamos false
        }
        return false;
      }

      // 4. Reemplazar archivo original
      final tempFile = File(tempOutputPath);
      if (await tempFile.exists()) {
        // Pequeña espera para liberar handles si es necesario
        await Future.delayed(const Duration(milliseconds: 200));
        try {
          await file.delete();
          await tempFile.rename(filePath);
          debugPrint('[MetadataService] Metadata updated successfully');
          return true;
        } catch (e) {
          debugPrint('[MetadataService] Error replacing file: $e');
          // Intentar restaurar si es posible
          return false;
        }
      } else {
        debugPrint('[MetadataService] Temp file created by ffmpeg not found');
        return false;
      }
    } catch (e) {
      debugPrint('[MetadataService] Error updating metadata: $e');
      return false;
    } finally {
      if (tempCoverFile != null && await tempCoverFile.exists()) {
        try {
          await tempCoverFile.delete();
        } catch (_) {}
      }
    }
  }

  // --- Process runner / tools helpers ---
  String _findBaseDir() {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      if (Directory(p.join(exeDir, 'tools')).existsSync()) return exeDir;
    } catch (_) {}
    final currentDir = Directory.current.path;
    if (Directory(p.join(currentDir, 'tools')).existsSync()) return currentDir;

    final candidates = <String>[
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Debug'),
      p.join(currentDir, 'build', 'windows', 'runner', 'Debug'),
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Release'),
      p.join(currentDir, 'build', 'windows', 'runner', 'Release'),
      p.normalize(p.current),
    ];
    for (final base in candidates) {
      if (Directory(p.join(base, 'tools')).existsSync()) return base;
    }
    return '';
  }

  String _findToolsDir() =>
      _findBaseDir().isEmpty ? '' : p.join(_findBaseDir(), 'tools');
}
