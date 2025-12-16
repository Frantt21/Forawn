/// Modelo para una línea de letra sincronizada
class LyricLine {
  final Duration timestamp;
  final String text;

  LyricLine({required this.timestamp, required this.text});

  /// Crea una LyricLine desde formato LRC: [mm:ss.xx] texto
  factory LyricLine.fromLRC(String line) {
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2})\]\s*(.*)');
    final match = regex.firstMatch(line);

    if (match == null) {
      throw FormatException('Formato LRC inválido: $line');
    }

    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    final centiseconds = int.parse(match.group(3)!);
    final text = match.group(4)!.trim();

    final timestamp = Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: centiseconds * 10,
    );

    return LyricLine(timestamp: timestamp, text: text);
  }

  /// Convierte a formato LRC
  String toLRC() {
    final minutes = timestamp.inMinutes.toString().padLeft(2, '0');
    final seconds = (timestamp.inSeconds % 60).toString().padLeft(2, '0');
    final centiseconds = ((timestamp.inMilliseconds % 1000) ~/ 10)
        .toString()
        .padLeft(2, '0');
    return '[$minutes:$seconds.$centiseconds] $text';
  }

  @override
  String toString() => toLRC();
}

/// Modelo completo de letras sincronizadas
class SyncedLyrics {
  final String songTitle;
  final String artist;
  final List<LyricLine> lines;

  SyncedLyrics({
    required this.songTitle,
    required this.artist,
    required this.lines,
  });

  /// Crea SyncedLyrics desde el formato LRC completo
  factory SyncedLyrics.fromLRC({
    required String songTitle,
    required String artist,
    required String lrcContent,
  }) {
    final lines = <LyricLine>[];

    for (final line in lrcContent.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      try {
        lines.add(LyricLine.fromLRC(trimmed));
      } catch (e) {
        // Ignorar líneas con formato inválido
        continue;
      }
    }

    // Ordenar por timestamp
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return SyncedLyrics(songTitle: songTitle, artist: artist, lines: lines);
  }

  /// Obtiene la línea actual basada en la posición de reproducción
  LyricLine? getCurrentLine(Duration position) {
    if (lines.isEmpty) return null;

    LyricLine? current;
    for (final line in lines) {
      if (line.timestamp <= position) {
        current = line;
      } else {
        break;
      }
    }
    return current;
  }

  /// Obtiene el índice de la línea actual
  /// Adelanta 500ms para mejor sincronización
  int? getCurrentLineIndex(Duration position) {
    if (lines.isEmpty) return null;

    // Adelantar 500ms para mejor sincronización visual
    final adjustedPosition = position + const Duration(milliseconds: 500);

    for (int i = lines.length - 1; i >= 0; i--) {
      if (lines[i].timestamp <= adjustedPosition) {
        return i;
      }
    }
    return null;
  }

  /// Convierte a formato LRC completo
  String toLRC() {
    return lines.map((line) => line.toLRC()).join('\n');
  }

  /// Verifica si tiene letras
  bool get hasLyrics => lines.isNotEmpty;

  /// Obtiene el número de líneas
  int get lineCount => lines.length;
}
