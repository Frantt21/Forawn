import 'dart:async';
import 'package:discord_rich_presence/discord_rich_presence.dart';
import 'package:logging/logging.dart';
import 'package:forawn/config/api_config.dart';
import 'package:forawn/services/music_state_service.dart';
import 'package:forawn/services/metadata_service.dart';

/// Servicio para gestionar la integración con Discord Rich Presence
class DiscordService {
  static final DiscordService _instance = DiscordService._internal();
  factory DiscordService() => _instance;
  DiscordService._internal();

  final _log = Logger('DiscordService');
  Client? _client;
  bool _isInitialized = false;
  bool _isConnected = false;
  DateTime _startTime = DateTime.now();

  /// Verifica si el servicio está conectado
  bool get isConnected => _isConnected;

  /// Verifica si el servicio está inicializado
  bool get isInitialized => _isInitialized;

  /// Sanitiza un string para Discord (elimina caracteres problemáticos y limita longitud)
  String _sanitizeString(String? input, {int maxLength = 128}) {
    if (input == null || input.isEmpty) return '';

    // Normalizar caracteres Unicode a ASCII (Discord tiene problemas con UTF-8)
    String sanitized = input
        // Vocales con tilde
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('Á', 'A')
        .replaceAll('É', 'E')
        .replaceAll('Í', 'I')
        .replaceAll('Ó', 'O')
        .replaceAll('Ú', 'U')
        // Vocales con diéresis
        .replaceAll('ü', 'u')
        .replaceAll('Ü', 'U')
        // Eñe
        .replaceAll('ñ', 'n')
        .replaceAll('Ñ', 'N')
        // Otros caracteres comunes
        .replaceAll('¿', '')
        .replaceAll('¡', '')
        // Eliminar caracteres de control
        .replaceAll(RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F]'), '')
        .trim();

    // Limitar longitud (Discord tiene límites estrictos)
    if (sanitized.length > maxLength) {
      sanitized = '${sanitized.substring(0, maxLength - 3)}...';
    }

    return sanitized.isEmpty ? 'N/A' : sanitized;
  }

  /// Inicializa la conexión con Discord
  Future<bool> initialize() async {
    if (_isInitialized) return _isConnected;

    try {
      _client = Client(clientId: ApiConfig.discordApplicationId);

      // Intentar conectar con timeout para evitar bloqueos
      await _client!.connect().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Discord connection timeout');
        },
      );

      _isInitialized = true;
      _isConnected = true;
      _log.info('Discord RPC inicializado correctamente');

      // Actualizar presencia inicial
      await updatePresence(screen: 'Inicio');
      return true;
    } on TimeoutException catch (e) {
      _log.warning('Timeout al conectar con Discord: $e');
      _isInitialized = false;
      _isConnected = false;
      _client = null;
      return false;
    } catch (e) {
      // Manejar cualquier error (incluyendo PathNotFoundException)
      _log.warning('Discord no está disponible o no se pudo conectar: $e');
      _isInitialized = false;
      _isConnected = false;
      _client = null;
      return false;
    }
  }

  /// Actualiza la presencia en Discord
  Future<void> updatePresence({
    required String screen,
    String? details,
    String? state,
    bool forceMusicUpdate = false,
  }) async {
    if (!_isConnected || _client == null) {
      _log.fine('No se puede actualizar presencia: no conectado');
      return;
    }

    try {
      final musicState = MusicStateService();

      // Determinar si debemos mostrar información de música
      final showMusicInfo =
          forceMusicUpdate ||
          (screen == 'Reproductor' && musicState.hasActiveSong);

      String activityName;
      String activityDetails;
      String? activityState;
      String largeImage;
      String largeText;
      String? smallImage;
      String? smallText;
      ActivityType activityType;
      ActivityTimestamps timestamps;

      if (showMusicInfo && musicState.hasActiveSong) {
        // Modo música: Mostrar información de la canción
        // Nombre de actividad fijo (Discord agrega "Escuchando" automáticamente)
        // activityName = 'en Forawn';
        activityName = _sanitizeString(musicState.currentTitle, maxLength: 128);
        if (activityName.isEmpty) activityName = 'Música';

        // Details: Artista (Negrita)
        activityDetails = _sanitizeString(
          musicState.currentTitle,
          maxLength: 128,
        );
        if (activityDetails.isEmpty) activityDetails = 'Canción desconocida';

        // State: Nombre de la canción (Texto normal debajo)
        activityState = _sanitizeString(
          musicState.currentArtist,
          maxLength: 128,
        );
        if (activityState.isEmpty) activityState = 'Artista desconocido';

        // Usar tipo "Escuchando"
        activityType = ActivityType.listening;

        // Imagen grande: thumbnail de YouTube si está disponible, sino player_icon
        if (musicState.thumbnailUrl != null &&
            musicState.thumbnailUrl!.isNotEmpty) {
          largeImage = musicState.thumbnailUrl!;
          _log.fine('Usando thumbnail de YouTube: ${musicState.thumbnailUrl}');
        } else {
          largeImage = 'player_icon';
        }

        // Texto de la imagen grande (tooltip)
        largeText = 'Forawn Music Player';

        // Imagen pequeña: logo de Forawn
        smallImage = _getMainLogo();
        smallText = 'Forawn';

        // Timestamps: mostrar progreso de la canción
        if (musicState.duration != null &&
            musicState.position != null &&
            musicState.duration!.inSeconds > 0) {
          try {
            final now = DateTime.now();
            final elapsed = musicState.position!;
            final total = musicState.duration!;

            // Validar que los valores sean razonables
            if (elapsed.inSeconds >= 0 && elapsed <= total) {
              if (musicState.isPlaying) {
                // Si está reproduciendo, mostrar progreso en tiempo real
                final songStart = now.subtract(elapsed);
                final songEnd = songStart.add(total);
                timestamps = ActivityTimestamps(start: songStart, end: songEnd);
              } else {
                // Si está pausado, solo mostrar tiempo transcurrido (sin end)
                // Esto evita que Discord muestre progreso
                final songStart = now.subtract(elapsed);
                timestamps = ActivityTimestamps(
                  start: songStart,
                  // NO enviar 'end' cuando está pausado
                );
              }
            } else {
              // Si los valores no son válidos, usar tiempo de sesión
              _log.warning(
                'Duración o posición de música inválida. Usando tiempo de sesión.',
              );
              timestamps = ActivityTimestamps(start: _startTime);
            }
          } catch (e) {
            _log.warning('Error calculando timestamps de música: $e');
            timestamps = ActivityTimestamps(start: _startTime);
          }
        } else {
          // Si no hay duración, solo mostrar tiempo desde que empezó la sesión
          timestamps = ActivityTimestamps(start: _startTime);
        }
      } else {
        // Modo normal: Mostrar información de la pantalla
        activityName = 'Forawn';
        activityDetails = _sanitizeString(
          details ?? 'Navegando en $screen',
          maxLength: 128,
        );
        activityState = _sanitizeString(
          state ?? 'Usando Forawn',
          maxLength: 128,
        );
        activityType = ActivityType.playing;

        largeImage = _getMainLogo();
        largeText = 'Forawn App';
        smallImage = _getScreenIcon(screen);
        smallText = screen;

        timestamps = ActivityTimestamps(start: _startTime);
      }

      // Validar que los strings no estén vacíos (segunda capa de validación)
      if (activityName.isEmpty) activityName = 'Forawn';
      if (activityDetails.isEmpty) activityDetails = 'Usando la aplicación';

      final activity = Activity(
        name: activityName,
        details: activityDetails,
        state: activityState,
        type: activityType,
        timestamps: timestamps,
        assets: ActivityAssets(
          largeImage: largeImage,
          // largeText: largeText,
          smallImage: smallImage,
          smallText: smallText,
        ),
      );

      await _client!.setActivity(activity);
      _log.fine(
        'Presencia actualizada: $screen${showMusicInfo ? " (música)" : ""}',
      );
    } catch (e, stackTrace) {
      _log.severe('Error al actualizar presencia de Discord: $e');
      _log.fine('Stack trace: $stackTrace');

      // Marcar como desconectado para evitar más intentos fallidos
      _isConnected = false;

      // No intentar cerrar aquí, puede causar más errores
      // El usuario puede reconectar manualmente desde ajustes
    }
  }

  /// Obtiene el logo principal de la aplicación
  ///
  /// OPCIÓN 1 (Actual): Usar nombre de Discord Developer Portal
  /// - Sube tu logo a https://discord.com/developers/applications
  /// - En Rich Presence → Art Assets, súbelo con el nombre 'forawn_logo'
  ///
  /// OPCIÓN 2 (Alternativa): Usar URL externa
  /// - Sube tu logo a Imgur, GitHub, etc.
  /// - Reemplaza el return con la URL completa
  String _getMainLogo() {
    // OPCIÓN 1: Nombre en Discord Developer Portal (Recomendado)
    return 'forawn_logo';

    // OPCIÓN 2: URL externa (Descomenta para usar)
    // return 'https://i.imgur.com/tu-logo-principal.png';
  }

  /// Obtiene el icono correspondiente a cada pantalla
  ///
  /// OPCIÓN 1 (Actual): Usar nombres de Discord Developer Portal
  /// - Sube cada icono a https://discord.com/developers/applications
  /// - En Rich Presence → Art Assets con los nombres exactos de abajo
  ///
  /// OPCIÓN 2 (Alternativa): Usar URLs externas
  /// - Descomenta el segundo bloque de 'icons'
  /// - Reemplaza las URLs con tus imágenes hosteadas
  String _getScreenIcon(String screen) {
    // OPCIÓN 1: Nombres de Discord Developer Portal (Actual)
    final icons = {
      'Inicio': 'home_icon',
      'ImagesIA': 'image_icon',
      'Música': 'music_icon',
      'Reproductor': 'player_icon',
      'Video': 'video_icon',
      'Notas': 'notes_icon',
      'Traductor': 'translate_icon',
      'Generador QR': 'qr_icon',
    };

    // OPCIÓN 2: URLs externas (Descomenta para usar)
    /*
    final icons = {
      'Inicio': 'https://i.imgur.com/home.png',
      'ForaAI': 'https://i.imgur.com/ai.png',
      'ImagesIA': 'https://i.imgur.com/image.png',
      'Música': 'https://i.imgur.com/music.png',
      'Reproductor': 'https://i.imgur.com/player.png',
      'Video': 'https://i.imgur.com/video.png',
      'Notas': 'https://i.imgur.com/notes.png',
      'Traductor': 'https://i.imgur.com/translate.png',
      'Generador QR': 'https://i.imgur.com/qr.png',
    };
    */

    return icons[screen] ?? 'home_icon';
  }

  /// Actualiza la presencia de Discord con información de la música actual
  /// Llama a este método cuando cambie la canción en el reproductor
  Future<void> updateMusicPresence() async {
    if (!_isConnected) return;

    final musicState = MusicStateService();

    // Si no tenemos URL de thumbnail o es local, intentamos buscarla
    if (musicState.hasActiveSong &&
        (musicState.thumbnailUrl == null ||
            !musicState.thumbnailUrl!.startsWith('http'))) {
      try {
        // Usar MetadataService para buscar metadatos que incluyan cover URL
        // Limitamos la búsqueda a título + artista para mayor precisión
        if (musicState.currentTitle != null) {
          final metadata = await MetadataService().searchMetadata(
            musicState.currentTitle!,
            musicState.currentArtist,
          );

          if (metadata?.albumArtUrl != null &&
              metadata!.albumArtUrl!.isNotEmpty) {
            // Actualizamos el estado musical con la nueva URL encontrada
            // Esto es temporal en memoria para que Discord lo pueda usar
            musicState.updateMusicState(thumbnailUrl: metadata.albumArtUrl);
            _log.fine(
              'Thumbnail encontrado para Discord: ${metadata.albumArtUrl}',
            );
          }
        }
      } catch (e) {
        _log.warning('Error buscando thumbnail para Discord: $e');
      }
    }

    await updatePresence(screen: 'Reproductor', forceMusicUpdate: true);
  }

  /// Limpia la presencia de Discord
  Future<void> clearPresence() async {
    if (!_isConnected || _client == null) return;

    try {
      // El paquete no tiene clearActivity, así que desconectamos
      await _client!.disconnect();
      _isConnected = false;
      _log.fine('Presencia limpiada');
    } catch (e) {
      _log.warning('Error al limpiar presencia: $e');
      // Marcar como desconectado de todos modos
      _isConnected = false;
    }
  }

  /// Cierra la conexión con Discord
  Future<void> dispose() async {
    if (_client == null) return;

    try {
      // Intentar desconectar solo si parece que todavía está conectado
      if (_isConnected || _isInitialized) {
        await _client!.disconnect();
      }
    } catch (e) {
      _log.warning('Error al cerrar Discord RPC: $e');
      // Ignorar errores al cerrar, ya que puede estar desconectado
    } finally {
      // Siempre limpiar el estado
      _isConnected = false;
      _isInitialized = false;
      _client = null;
      _log.info('Discord RPC cerrado');
    }
  }

  /// Reconecta al servicio de Discord
  Future<bool> reconnect() async {
    _log.info('Intentando reconectar a Discord...');

    // Limpiar estado anterior
    if (_client != null) {
      try {
        await _client!.disconnect();
      } catch (e) {
        _log.warning('Error al desconectar antes de reconectar: $e');
      }
    }

    _isInitialized = false;
    _isConnected = false;
    _client = null;

    // Reiniciar tiempo de inicio
    _startTime = DateTime.now();

    // Intentar inicializar nuevamente
    return await initialize();
  }

  /// Actualiza la presencia cuando el usuario está en una pantalla específica
  Future<void> updateScreenPresence(String screenId) async {
    final screenNames = {
      'home': 'Inicio',
      'images': 'ImagesIA',
      'music': 'Música',
      'player': 'Reproductor',
      'video': 'Video',
      'notes': 'Notas',
      'translate': 'Traductor',
      'qr': 'Generador QR',
    };

    final screenName = screenNames[screenId] ?? screenId;

    String details = 'Navegando en $screenName';
    String? state;

    // Personaliza el mensaje según la pantalla
    switch (screenId) {
      case 'images':
        details = 'Generando imagenes';
        state = 'ImagesIA';
        break;
      case 'music':
        details = 'Descargando musica';
        state = 'Spotify Downloader';
        break;
      case 'player':
        details = 'Escuchando musica';
        state = 'Reproductor de musica';
        break;
      case 'video':
        details = 'Descargando videos';
        state = 'Video Downloader';
        break;
      case 'notes':
        details = 'Tomando notas';
        break;
      case 'translate':
        details = 'Traduciendo texto';
        state = 'Traductor';
        break;
      case 'qr':
        details = 'Generando codigos QR';
        state = 'Generador QR';
        break;
    }

    await updatePresence(screen: screenName, details: details, state: state);
  }
}
