import '../models/synced_lyrics.dart';

/// Servicio para ajustar timestamps de lyrics cuando hay desincronización
class LyricsAdjuster {
  /// Ajusta los lyrics basándose en la duración esperada vs real
  static SyncedLyrics adjustLyrics({
    required SyncedLyrics lyrics,
    required Duration expectedDuration,
    required Duration actualDuration,
  }) {
    // Si no hay lyrics sincronizados, retornar sin cambios
    if (lyrics.lines.isEmpty) {
      return lyrics;
    }

    // Calcular diferencia en segundos
    final difference = (actualDuration.inSeconds - expectedDuration.inSeconds)
        .abs();

    // Si la diferencia es muy pequeña (<1 segundo), no ajustar
    if (difference < 1) {
      return lyrics;
    }

    // Calcular ratio de ajuste
    final ratio =
        actualDuration.inMilliseconds / expectedDuration.inMilliseconds;

    // Ajustar cada línea
    final adjustedLines = lyrics.lines.map((line) {
      final adjustedMillis = (line.timestamp.inMilliseconds * ratio).round();

      return LyricLine(
        timestamp: Duration(milliseconds: adjustedMillis),
        text: line.text,
      );
    }).toList();

    return SyncedLyrics(
      songTitle: lyrics.songTitle,
      artist: lyrics.artist,
      lines: adjustedLines,
    );
  }

  /// Detecta si hay una intro extra comparando el timestamp de la primera línea
  static Duration _detectIntro(List<LyricLine> syncedLyrics) {
    if (syncedLyrics.isEmpty) return Duration.zero;

    // Si la primera línea está después de 5 segundos, probablemente hay intro
    final firstLineTime = syncedLyrics.first.timestamp;

    // Buscar la primera línea con texto real (no vacía)
    final firstRealLine = syncedLyrics.firstWhere(
      (line) => line.text.trim().isNotEmpty,
      orElse: () => syncedLyrics.first,
    );

    // Si la primera línea real está después de 5 segundos, hay intro
    if (firstRealLine.timestamp.inSeconds > 5) {
      return Duration(seconds: firstRealLine.timestamp.inSeconds - 2);
    }

    return Duration.zero;
  }

  /// Ajusta un timestamp individual (útil para ajustes manuales)
  static Duration adjustTimestamp({
    required Duration originalTimestamp,
    required Duration expectedDuration,
    required Duration actualDuration,
    Duration introOffset = Duration.zero,
  }) {
    if (expectedDuration.inMilliseconds == 0) return originalTimestamp;

    final ratio =
        actualDuration.inMilliseconds / expectedDuration.inMilliseconds;
    final adjustedMillis =
        ((originalTimestamp.inMilliseconds + introOffset.inMilliseconds) *
                ratio)
            .round();

    return Duration(milliseconds: adjustedMillis);
  }
}
