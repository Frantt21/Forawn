import 'dart:typed_data';
import 'dart:convert';

/// Servicio singleton para compartir el estado actual de reproducción de música
/// entre el reproductor y Discord Rich Presence
class MusicStateService {
  static final MusicStateService _instance = MusicStateService._internal();
  factory MusicStateService() => _instance;
  MusicStateService._internal();

  // Estado actual de la música
  String? _currentTitle;
  String? _currentArtist;
  Uint8List? _currentArtwork;
  String? _thumbnailUrl; // URL del thumbnail de YouTube
  bool _isPlaying = false;
  Duration? _duration;
  Duration? _position;

  // Getters
  String? get currentTitle => _currentTitle;
  String? get currentArtist => _currentArtist;
  Uint8List? get currentArtwork => _currentArtwork;
  String? get thumbnailUrl => _thumbnailUrl;
  bool get isPlaying => _isPlaying;
  Duration? get duration => _duration;
  Duration? get position => _position;

  /// Verifica si hay una canción actualmente reproduciéndose
  bool get hasActiveSong => _currentTitle != null && _currentTitle!.isNotEmpty;

  /// Obtiene la URL de la portada en formato base64 para Discord
  /// Discord acepta URLs de imágenes, así que convertimos a data URL
  String? get artworkDataUrl {
    if (_currentArtwork == null) return null;
    try {
      final base64 = base64Encode(_currentArtwork!);
      return 'data:image/jpeg;base64,$base64';
    } catch (e) {
      return null;
    }
  }

  /// Actualiza el estado de la música actual
  void updateMusicState({
    String? title,
    String? artist,
    Uint8List? artwork,
    String? thumbnailUrl,
    bool? isPlaying,
    Duration? duration,
    Duration? position,
  }) {
    if (title != null) _currentTitle = title;
    if (artist != null) _currentArtist = artist;
    if (artwork != null) _currentArtwork = artwork;
    if (thumbnailUrl != null) _thumbnailUrl = thumbnailUrl;
    if (isPlaying != null) _isPlaying = isPlaying;
    if (duration != null) _duration = duration;
    if (position != null) _position = position;
  }

  /// Limpia el estado cuando no hay música reproduciéndose
  void clearMusicState() {
    _currentTitle = null;
    _currentArtist = null;
    _currentArtwork = null;
    _thumbnailUrl = null;
    _isPlaying = false;
    _duration = null;
    _position = null;
  }

  /// Reinicia solo la URL del thumbnail (útil al cambiar de canción)
  void resetThumbnailUrl() {
    _thumbnailUrl = null;
  }

  /// Obtiene un texto formateado para mostrar en Discord
  String getFormattedSongInfo() {
    if (!hasActiveSong) return 'Sin reproducción';

    final parts = <String>[];
    if (_currentTitle != null && _currentTitle!.isNotEmpty) {
      parts.add(_currentTitle!);
    }
    if (_currentArtist != null && _currentArtist!.isNotEmpty) {
      parts.add(_currentArtist!);
    }

    return parts.isEmpty ? 'Reproduciendo música' : parts.join(' - ');
  }
}
