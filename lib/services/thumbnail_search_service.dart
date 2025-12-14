import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:forawn/config/api_config.dart';

/// Servicio para buscar thumbnails de canciones en YouTube
class ThumbnailSearchService {
  static final ThumbnailSearchService _instance =
      ThumbnailSearchService._internal();
  factory ThumbnailSearchService() => _instance;
  ThumbnailSearchService._internal();

  final _log = Logger('ThumbnailSearchService');
  final _cache = <String, String>{}; // Cache de búsquedas

  /// Busca el thumbnail de una canción en YouTube
  /// Retorna la URL del thumbnail o null si no se encuentra
  Future<String?> searchThumbnail(String title, String artist) async {
    try {
      // Crear query de búsqueda con 'audio' al final
      final searchTerms = '$title $artist'.trim();
      final query = '$searchTerms audio';
      final cacheKey = query.toLowerCase();

      // Verificar cache primero
      if (_cache.containsKey(cacheKey)) {
        _log.fine('Thumbnail encontrado en cache: $query');
        return _cache[cacheKey];
      }

      // Codificar query para URL
      final encodedQuery = Uri.encodeComponent(query);
      final url = '${ApiConfig.youtubeSearchApiUrl}?query=$encodedQuery';

      _log.fine('Buscando thumbnail: $query');

      // Hacer request con timeout
      final response = await http
          .get(Uri.parse(url))
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              throw Exception('Timeout al buscar thumbnail');
            },
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // Verificar que la respuesta sea válida
        if (data['status'] == true &&
            data['data'] != null &&
            data['data'].isNotEmpty) {
          final firstResult = data['data'][0];
          final thumbnail = firstResult['thumbnail'] as String?;

          if (thumbnail != null && thumbnail.isNotEmpty) {
            // Guardar en cache
            _cache[cacheKey] = thumbnail;
            _log.info('Thumbnail encontrado para: $query');
            return thumbnail;
          }
        }
      }

      _log.warning('No se encontró thumbnail para: $query');
      return null;
    } catch (e) {
      _log.warning('Error al buscar thumbnail: $e');
      return null;
    }
  }

  /// Limpia el cache de thumbnails
  void clearCache() {
    _cache.clear();
    _log.info('Cache de thumbnails limpiado');
  }

  /// Obtiene el tamaño del cache
  int get cacheSize => _cache.length;
}
