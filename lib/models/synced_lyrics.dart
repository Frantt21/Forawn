/// Línea activa 500ms antes de su timestamp (anticipación del highlight).
const Duration kCurrentLineAdvance = Duration(milliseconds: 500);

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

  /// Evidencia de convención de sílabas detectada al parsear (Scrup).
  final bool conventionEvidence;

  LyricLine({
    required this.timestamp,
    required this.text,
    this.words,
    this.conventionEvidence = false,
  });

  bool get hasWords => words != null && words!.isNotEmpty;

  /// Crea una LyricLine desde formato LRC: [mm:ss.xx] texto, opcionalmente
  /// con tokens de sílaba <mm:ss.xx>. Limpieza de timestamps de Scrup:
  /// detecta si los tokens son sílabas (convención) o palabras y une los
  /// fragmentos en consecuencia.
  factory LyricLine.fromLRC(String line, {bool forceWordGlue = false}) {
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

    // Tokens de sílaba con timestamps propios (formato karaoke <mm:ss.xx>).
    List<KaraokeWord>? words;
    var evidence = false;
    final wordRegex = RegExp(r'(?:<(\d{2}):(\d{2})\.(\d{2,3})>)?([^<]+)');
    if (fullText.contains('<')) {
      // 1) Tokenizar conservando el separador que sigue a cada token.
      final tokens = <({Duration ts, String text, int sepAfter})>[];
      for (final wMatch in wordRegex.allMatches(fullText)) {
        final raw = wMatch.group(4)!;
        final text = raw.trimRight();
        final sepAfter = raw.length - text.length;
        final ts = wMatch.group(1) != null
            ? Duration(
                minutes: int.parse(wMatch.group(1)!),
                seconds: int.parse(wMatch.group(2)!),
                milliseconds:
                    int.parse(wMatch.group(3)!) *
                    (wMatch.group(3)!.length == 3 ? 1 : 10),
              )
            : timestamp;

        if (text.isEmpty) {
          // Token vacío: conservar su separador en el token anterior.
          if (tokens.isNotEmpty) {
            final p = tokens.removeLast();
            tokens.add((
              ts: p.ts,
              text: p.text,
              sepAfter: p.sepAfter + sepAfter,
            ));
          }
          continue;
        }
        tokens.add((ts: ts, text: text, sepAfter: sepAfter));
      }

      // 2) Evidencia de convención de sílabas: algún token NO final
      // termina en frontera de palabra (0 = pegado, >=2 = espacio nuevo).
      evidence =
          tokens.length >= 2 &&
          tokens
              .take(tokens.length - 1)
              .any((t) => t.sepAfter >= 2 || t.sepAfter == 0);
      final conventional = evidence || forceWordGlue;

      // 3) Unir sílabas en palabras cuando la convención lo indica.
      final merged = <KaraokeWord>[];
      for (var i = 0; i < tokens.length; i++) {
        final t = tokens[i];
        if (conventional && i > 0 && tokens[i - 1].sepAfter <= 1) {
          final p = merged.removeLast();
          merged.add(
            KaraokeWord(timestamp: p.timestamp, text: p.text + t.text),
          );
        } else {
          merged.add(KaraokeWord(timestamp: t.ts, text: t.text));
        }
      }
      words = merged;
    }

    // Limpiar las etiquetas internas <mm:ss.xx> del texto visible.
    String text;
    if (words != null && words.isNotEmpty && (evidence || forceWordGlue)) {
      text = words.map((w) => w.text).join(' ');
    } else {
      text = fullText.replaceAll(
        RegExp(r'<\d{2}:\d{2}\.\d{2,3}>'),
        '',
      );
      text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    return LyricLine(
      timestamp: timestamp,
      text: text,
      words: words,
      conventionEvidence: evidence,
    );
  }

  /// Convierte a formato LRC, opcionalmente preservando los timestamps
  /// por palabra.
  String toLRC({bool includeWordTags = false}) {
    final minutes = timestamp.inMinutes.toString().padLeft(2, '0');
    final seconds = (timestamp.inSeconds % 60).toString().padLeft(2, '0');
    final centiseconds = ((timestamp.inMilliseconds % 1000) ~/ 10)
        .toString()
        .padLeft(2, '0');
    final prefix = '[$minutes:$seconds.$centiseconds]';
    if (includeWordTags && hasWords) {
      final parts = <String>[];
      for (final w in words!) {
        final wmins = w.timestamp.inMinutes.toString().padLeft(2, '0');
        final wsecs = (w.timestamp.inSeconds % 60).toString().padLeft(2, '0');
        final wcs = ((w.timestamp.inMilliseconds % 1000) ~/ 10)
            .toString()
            .padLeft(2, '0');
        parts.add('<$wmins:$wsecs.$wcs>${w.text}');
      }
      return '$prefix ${parts.join(' ')}';
    }
    return '$prefix $text';
  }

  @override
  String toString() => toLRC();
}

/// Modelo completo de letras sincronizadas
class SyncedLyrics {
  final String songTitle;
  final String artist;
  final List<LyricLine> lines;

  /// Proveedor de las letras ('KPoe', 'LRCLIB' o null si se desconoce).
  final String? source;

  SyncedLyrics({
    required this.songTitle,
    required this.artist,
    required this.lines,
    this.source,
  });

  /// Crea SyncedLyrics desde el formato LRC completo. Re-parsea con
  /// [forceWordGlue] si se detecta la convención de sílabas en algunas
  /// líneas pero no en otras (Scrup).
  factory SyncedLyrics.fromLRC({
    required String songTitle,
    required String artist,
    required String lrcContent,
    String? source,
  }) {
    final lines = _parseLrc(lrcContent);

    if (lines.any((l) => l.conventionEvidence) &&
        lines.any((l) => !l.conventionEvidence && l.hasWords)) {
      final glued = _parseLrc(lrcContent, forceWordGlue: true);
      return SyncedLyrics(
        songTitle: songTitle,
        artist: artist,
        lines: glued,
        source: source,
      );
    }

    return SyncedLyrics(
      songTitle: songTitle,
      artist: artist,
      lines: lines,
      source: source,
    );
  }

  static List<LyricLine> _parseLrc(
    String lrcContent, {
    bool forceWordGlue = false,
  }) {
    final lines = <LyricLine>[];

    for (final line in lrcContent.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      try {
        lines.add(LyricLine.fromLRC(trimmed, forceWordGlue: forceWordGlue));
      } catch (e) {
        // Ignorar líneas con formato inválido
        continue;
      }
    }

    // Ordenar por timestamp
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
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

  /// Obtiene el índice de la línea actual. Las líneas karaoke usan
  /// matching exacto (sin adelanto) para no cortar la última palabra;
  /// las líneas normales se adelantan 500ms (Scrup).
  int? getCurrentLineIndex(Duration position) {
    if (lines.isEmpty) return null;

    var exact = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].timestamp <= position) {
        exact = i;
      } else {
        break;
      }
    }
    if (exact >= 0 && lines[exact].hasWords) return exact;

    final adjustedPosition = position + kCurrentLineAdvance;
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

  /// LRC con los timestamps por palabra preservados.
  String toKaraokeLrc() {
    return lines.map((line) => line.toLRC(includeWordTags: true)).join('\n');
  }

  /// Verifica si tiene letras
  bool get hasLyrics => lines.isNotEmpty;

  /// Obtiene el número de líneas
  int get lineCount => lines.length;
}
