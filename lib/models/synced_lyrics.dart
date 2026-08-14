/// Palabra con timestamp propio (formato karaoke <mm:ss.xx> de SyncLRC).
class KaraokeWord {
  final Duration timestamp;
  final String text;

  KaraokeWord({required this.timestamp, required this.text});
}

/// Modelo para una línea de letra sincronizada
class LyricLine {
  final Duration timestamp;
  final String text;
  final List<KaraokeWord>? words;

  LyricLine({required this.timestamp, required this.text, this.words});

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
    final fullText = match.group(4)!;

    final timestamp = Duration(
      minutes: minutes,
      seconds: seconds,
      milliseconds: centiseconds * 10,
    );

    // Palabras con timestamps propios (formato karaoke <mm:ss.xx>)
    List<KaraokeWord>? words;
    final wordRegex = RegExp(r'(?:<(\d{2}):(\d{2})\.(\d{2,3})>)?([^<]+)');
    if (fullText.contains('<')) {
      words = [];
      for (final wMatch in wordRegex.allMatches(fullText)) {
        final wText = wMatch.group(4)!.trimRight();
        if (wText.isEmpty) continue;
        words.add(
          KaraokeWord(
            timestamp: wMatch.group(1) != null
                ? Duration(
                    minutes: int.parse(wMatch.group(1)!),
                    seconds: int.parse(wMatch.group(2)!),
                    milliseconds:
                        int.parse(wMatch.group(3)!) *
                        (wMatch.group(3)!.length == 3 ? 1 : 10),
                  )
                : timestamp,
            text: wText,
          ),
        );
      }
    }

    // Limpiar las etiquetas internas <mm:ss.xx> del texto visible
    var text = fullText.replaceAll(
      RegExp(r'<\d{2}:\d{2}\.\d{2,3}>'),
      '',
    );
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return LyricLine(timestamp: timestamp, text: text, words: words);
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
