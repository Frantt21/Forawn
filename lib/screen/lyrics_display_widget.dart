import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/synced_lyrics.dart';
import '../services/tools_service.dart';

typedef TextGetter = String Function(String key, {String? fallback});

/// Línea fantasma para gaps instrumentales (forawn_mobile).
const String kGapMarker = '•••';

class LyricsDisplay extends StatefulWidget {
  final SyncedLyrics lyrics;
  final ValueNotifier<int?> currentIndexNotifier;
  final ValueNotifier<Duration> positionNotifier;
  final TextGetter getText;
  final TextAlign textAlign;
  final Function(Duration)? onTap;

  /// Desfase de sincronización (se resta a la posición para el sweep).
  final Duration lyricsOffset;

  /// Archivo de audio para extraer la energía (waveform) con ffmpeg.
  final String? audioPath;

  /// Duración total de la canción (para mapear tiempo → muestra).
  final ValueListenable<Duration>? durationNotifier;

  const LyricsDisplay({
    super.key,
    required this.lyrics,
    required this.currentIndexNotifier,
    required this.positionNotifier,
    required this.getText,
    this.textAlign = TextAlign.center,
    this.onTap,
    this.lyricsOffset = Duration.zero,
    this.audioPath,
    this.durationNotifier,
  });

  @override
  State<LyricsDisplay> createState() => _LyricsDisplayState();
}

class _LyricsDisplayState extends State<LyricsDisplay>
    with AutomaticKeepAliveClientMixin {
  late ScrollController _controller;
  final Map<int, GlobalKey> _itemKeys = {};
  bool _showSyncButton = false;
  int _lastAutoScrolledIndex = -1;
  bool _userHasScrolled = false;

  // --- Funciones de forawn_mobile ---

  // Líneas procesadas con gaps instrumentales ('•••').
  List<LyricLine> _processedLines = [];
  SyncedLyrics? _lastLyrics;

  // Modo karaoke (sweep palabra por palabra).
  bool _isSweepEnabled = false;

  // Waveform: energía real del audio extraída con ffmpeg (equivalente al
  // audio_waveforms de forawn_mobile, que no soporta Linux/Windows).
  List<double> _waveformData = [];
  int _waveformGen = 0;

  @override
  bool get wantKeepAlive => true;

  List<LyricLine> get _lines {
    if (_lastLyrics != widget.lyrics) {
      _lastLyrics = widget.lyrics;
      _processedLines = _computeLinesWithGaps(widget.lyrics.lines);
    }
    return _processedLines;
  }

  /// Inserta líneas fantasma '•••' en los gaps instrumentales largos
  /// (misma función que forawn_mobile).
  List<LyricLine> _computeLinesWithGaps(List<LyricLine> original) {
    if (original.isEmpty) return [];

    final result = <LyricLine>[];
    // Espacio instrumental muy largo al inicio de la canción
    if (original.first.timestamp.inSeconds > 10) {
      result.add(LyricLine(timestamp: Duration.zero, text: kGapMarker));
    }

    for (var i = 0; i < original.length; i++) {
      final current = original[i];
      result.add(current);

      if (i < original.length - 1) {
        final next = original[i + 1];

        // Tiempo aproximado de canto de esta línea
        final chars = current.text.length;
        var estimatedMs = ((chars / 12.0) * 1000).toInt() + 1500;

        final durationUntilNext =
            (next.timestamp - current.timestamp).inMilliseconds;

        // Limitar la estimación a no invadir el tiempo de la próxima línea
        if (estimatedMs > durationUntilNext - 1000) {
          estimatedMs = durationUntilNext - 1000;
        }

        final currentEndApprox =
            current.timestamp + Duration(milliseconds: estimatedMs);

        // Si quedan más de 8 segundos hasta la siguiente vocal
        if (next.timestamp - currentEndApprox > const Duration(seconds: 8)) {
          result.add(LyricLine(timestamp: currentEndApprox, text: kGapMarker));
        }
      }
    }
    return result;
  }

  /// Convierte el índice de línea original (sin gaps) al índice en la
  /// lista procesada (con líneas '•••' insertadas).
  int _mapToDisplayIndex(int? originalIndex) {
    if (originalIndex == null ||
        originalIndex < 0 ||
        widget.lyrics.lines.isEmpty) {
      return -1;
    }
    final target = widget.lyrics.lines[originalIndex].timestamp;
    var shift = 0;
    for (final line in _lines) {
      if (line.text == kGapMarker && line.timestamp <= target) shift++;
    }
    return originalIndex + shift;
  }

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_checkButtonVisibility);
    widget.currentIndexNotifier.addListener(_onIndexChanged);
    _loadSweepSetting();
    _extractWaveform();

    // Crear keys para cada item (con gaps)
    for (var i = 0; i < _lines.length; i++) {
      _itemKeys[i] = GlobalKey();
    }
  }

  Future<void> _loadSweepSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('lyrics_sweep_enabled') ?? false;
      if (mounted && enabled != _isSweepEnabled) {
        setState(() => _isSweepEnabled = enabled);
      }
    } catch (_) {}
  }

  /// Extrae la energía del audio con ffmpeg (como audio_waveforms del
  /// móvil): PCM mono a 4 kHz → 1000 valores de amplitud media por ventana.
  Future<void> _extractWaveform() async {
    final path = widget.audioPath;
    if (path == null || path.isEmpty || !ToolsService().hasFfmpeg) return;
    final gen = ++_waveformGen;
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() > 80 * 1024 * 1024) {
        return;
      }
      if (!mounted) return;
      final result = await Process.run(
        ToolsService().ffmpegPath,
        ['-i', path, '-ac', '1', '-ar', '4000', '-f', 'f32le', '-'],
        stdoutEncoding: null,
      );
      if (gen != _waveformGen || !mounted) return;
      final bytes = result.stdout as Uint8List;
      final data = _computeEnergyBuckets(bytes, 1000);
      if (mounted && gen == _waveformGen) {
        setState(() => _waveformData = data);
      }
    } catch (e) {
      debugPrint('[LyricsDisplay] Error extracting waveform: $e');
    }
  }

  /// Divide el PCM float32 en `buckets` ventanas y devuelve la amplitud
  /// media (abs) de cada una — la "energía" por tramo de la canción.
  List<double> _computeEnergyBuckets(Uint8List bytes, int buckets) {
    if (bytes.length < 4) return [];
    final sampleCount = bytes.length ~/ 4;
    final byteData = ByteData.sublistView(bytes);
    final result = List<double>.filled(buckets, 0.0);
    for (var b = 0; b < buckets; b++) {
      final startSample = (b * sampleCount) ~/ buckets;
      final endSample = ((b + 1) * sampleCount) ~/ buckets;
      if (endSample <= startSample) continue;
      var sum = 0.0;
      for (var i = startSample; i < endSample; i++) {
        sum += byteData.getFloat32(i * 4, Endian.little).abs();
      }
      result[b] = sum / (endSample - startSample);
    }
    return result;
  }

  /// Progreso de la línea por energía acumulada del audio (igual que
  /// _getWaveformProgress de forawn_mobile). Devuelve -1 si no hay datos.
  double _getWaveformProgress(int displayIndex, Duration position) {
    final duration = widget.durationNotifier?.value;
    if (_waveformData.isEmpty ||
        duration == null ||
        duration.inMilliseconds == 0) {
      return -1.0;
    }
    final line = _lines[displayIndex];
    final startMs = line.timestamp.inMilliseconds;
    final endMs = displayIndex < _lines.length - 1
        ? _lines[displayIndex + 1].timestamp.inMilliseconds
        : duration.inMilliseconds;
    final currentMs = (position - widget.lyricsOffset).inMilliseconds;
    final totalSongMs = duration.inMilliseconds;

    if (currentMs <= startMs) return 0.0;
    if (currentMs >= endMs) return 1.0;

    final startIndex = (startMs * _waveformData.length / totalSongMs)
        .floor()
        .clamp(0, _waveformData.length - 1);
    final endIndex = (endMs * _waveformData.length / totalSongMs)
        .floor()
        .clamp(0, _waveformData.length - 1);
    final currentIndex = (currentMs * _waveformData.length / totalSongMs)
        .floor()
        .clamp(0, _waveformData.length - 1);

    if (startIndex >= endIndex) return -1.0;

    var totalEnergy = 0.0;
    var currentEnergy = 0.0;
    for (var i = startIndex; i <= endIndex; i++) {
      final energy = _waveformData[i].abs() + 0.05;
      totalEnergy += energy;
      if (i <= currentIndex) currentEnergy += energy;
    }
    if (totalEnergy == 0) return -1.0;
    return (currentEnergy / totalEnergy).clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(LyricsDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambiaron las lyrics o el audio (nueva canción), recrear keys y
    // resetear scroll y waveform
    if (oldWidget.lyrics != widget.lyrics ||
        oldWidget.audioPath != widget.audioPath) {
      _waveformData = [];
      _extractWaveform();
      // Recrear keys para los nuevos items (con gaps)
      _itemKeys.clear();
      for (var i = 0; i < _lines.length; i++) {
        _itemKeys[i] = GlobalKey();
      }

      // Resetear estado del botón de sync
      _showSyncButton = false;
      _lastAutoScrolledIndex = -1;
      _userHasScrolled = false;

      // Recargar preferencia de sweep (puede haber cambiado en Ajustes)
      _loadSweepSetting();

      // Scroll al inicio solo cuando cambia la canción
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) {
          _controller.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    widget.currentIndexNotifier.removeListener(_onIndexChanged);
    _controller.removeListener(_checkButtonVisibility);
    _controller.dispose();
    super.dispose();
  }

  void _checkButtonVisibility() {
    final displayIndex = _mapToDisplayIndex(widget.currentIndexNotifier.value);
    if (displayIndex < 0 || !_controller.hasClients) {
      if (_showSyncButton) setState(() => _showSyncButton = false);
      return;
    }

    final key = _itemKeys[displayIndex];
    // Si el item no está renderizado (context null), es probable que esté fuera de pantalla
    if (key?.currentContext == null) {
      if (!_showSyncButton) setState(() => _showSyncButton = true);
      return;
    }

    // Calcular si el item está visible en el viewport
    final context = key!.currentContext!;
    final renderObject = context.findRenderObject();
    if (renderObject == null) return;

    final viewport = RenderAbstractViewport.of(renderObject);

    // Obtenemos el offset necesario para centrar el item
    final targetOffset = viewport.getOffsetToReveal(renderObject, 0.5).offset;
    final currentOffset = _controller.offset;
    final viewportHeight = _controller.position.viewportDimension;

    // Si la distancia al centro es mayor a 1/3 de la pantalla, mostramos el botón
    final isFar = (currentOffset - targetOffset).abs() > viewportHeight / 3;

    if (_showSyncButton != isFar) {
      setState(() {
        _showSyncButton = isFar;
      });
    }
  }

  void _syncToCurrentLine() {
    final displayIndex = _mapToDisplayIndex(widget.currentIndexNotifier.value);
    if (displayIndex >= 0 && _controller.hasClients) {
      final key = _itemKeys[displayIndex];

      void scrollToTarget() {
        if (key?.currentContext != null) {
          Scrollable.ensureVisible(
            key!.currentContext!,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic,
            alignment: 0.5,
          );
        }
      }

      if (key?.currentContext == null) {
        // Si el item no está renderizado, saltamos a una posición estimada
        // Estimación: index * ~70px (altura promedio por línea + padding)
        final estimatedOffset = (displayIndex * 70.0).clamp(
          0.0,
          _controller.position.maxScrollExtent,
        );
        _controller.jumpTo(estimatedOffset);

        // Intentamos hacer el scroll fino después de un frame
        WidgetsBinding.instance.addPostFrameCallback((_) => scrollToTarget());
      } else {
        scrollToTarget();
      }

      _lastAutoScrolledIndex = displayIndex;
      _userHasScrolled = false;
      setState(() {
        _showSyncButton = false;
      });
    }
  }

  void _onIndexChanged() {
    final displayIndex = _mapToDisplayIndex(widget.currentIndexNotifier.value);
    if (displayIndex < 0 || !_controller.hasClients) return;

    // Si el usuario scrolleó, solo verificamos visibilidad
    if (_userHasScrolled) {
      _checkButtonVisibility();
      return;
    }

    // Comportamiento normal (Auto-scroll)
    // Verificamos si necesitamos hacer scroll
    if (displayIndex != _lastAutoScrolledIndex) {
      _lastAutoScrolledIndex = displayIndex;
      final key = _itemKeys[displayIndex];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
          alignment: 0.5,
        );
      } else {
        // En caso extremo que el auto-scroll tenga que saltar mucho
        final estimatedOffset = (displayIndex * 70.0).clamp(
          0.0,
          _controller.position.maxScrollExtent,
        );
        if ((_controller.offset - estimatedOffset).abs() > 500) {
          _controller.jumpTo(estimatedOffset);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (key?.currentContext != null) {
              Scrollable.ensureVisible(
                key!.currentContext!,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeInOutCubic,
                alignment: 0.5,
              );
            }
          });
        }
      }
    }
  }

  /// Progreso de la línea actual para el sweep, basado en tiempo
  /// (fallback de forawn_mobile sin waveform).
  double _lineProgress(int displayIndex, Duration position) {
    final line = _lines[displayIndex];
    final effectivePos = position - widget.lyricsOffset;
    final start = line.timestamp;

    final realDuration = displayIndex < _lines.length - 1
        ? _lines[displayIndex + 1].timestamp - start
        : null;

    // Duración estimada de canto basada en caracteres
    final estimatedMs = ((line.text.length / 12.0) * 1000).toInt() + 1500;
    var durationMs = estimatedMs;
    if (realDuration != null) {
      final realMs = realDuration.inMilliseconds;
      durationMs = estimatedMs < realMs ? estimatedMs : realMs;
      if (durationMs < 1000 && realMs > 1000) durationMs = 1000;
      if (durationMs > realMs) durationMs = realMs;
    }

    if (durationMs <= 0) return 0.0;
    if (effectivePos >= start + Duration(milliseconds: durationMs)) {
      return 1.0;
    }
    if (effectivePos <= start) return 0.0;
    return ((effectivePos - start).inMilliseconds / durationMs).clamp(
      0.0,
      1.0,
    );
  }

  /// Línea con sweep palabra por palabra (modo karaoke, forawn_mobile).
  Widget _buildKaraokeWords(
    TextStyle style,
    LyricLine line,
    Duration position,
    int displayIndex,
  ) {
    final effectivePos = position - widget.lyricsOffset;

    // Timestamps reales por palabra (SyncLRC <mm:ss.xx>): render exacto,
    // sin matemática por caracteres (igual que forawn_mobile).
    final words = line.words;
    if (words != null && words.isNotEmpty) {
      final endTime = displayIndex < _lines.length - 1
          ? _lines[displayIndex + 1].timestamp
          : line.timestamp + const Duration(seconds: 5);
      final wordWidgets = <Widget>[];
      for (var i = 0; i < words.length; i++) {
        final w = words[i];
        final wStart = w.timestamp;
        final wEnd = i < words.length - 1 ? words[i + 1].timestamp : endTime;

        double wordProgress = 0.0;
        if (effectivePos >= wEnd) {
          wordProgress = 1.0;
        } else if (effectivePos > wStart) {
          final durationMs = (wEnd - wStart).inMilliseconds;
          wordProgress = durationMs > 0
              ? ((effectivePos - wStart).inMilliseconds / durationMs)
                    .clamp(0.0, 1.0)
              : 1.0;
        }

        wordWidgets.add(
          _LyricWord(
            word: w.text + (i < words.length - 1 ? ' ' : ''),
            progress: wordProgress,
            style: style,
            activeColor: Colors.white,
            inactiveColor: Colors.white.withOpacity(0.3),
          ),
        );
      }
      return Wrap(
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 0.0,
        runSpacing: 4.0,
        children: wordWidgets,
      );
    }

    // Progreso por energía real del audio (waveform con ffmpeg) si está
    // disponible; si no, estimación por tiempo. Ambos suavizados con
    // 300 ms easeOutCubic (igual que el móvil).
    var lineProgress = _getWaveformProgress(displayIndex, position);
    if (lineProgress < 0) {
      lineProgress = _lineProgress(displayIndex, position);
    }
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: lineProgress, end: lineProgress),
      builder: (context, smoothProgress, _) =>
          _buildKaraokeFromProgress(style, line.text, smoothProgress),
    );
  }

  /// Matemática por caracteres con overlap (fallback sin timestamps).
  Widget _buildKaraokeFromProgress(
    TextStyle style,
    String text,
    double lineProgress,
  ) {
    final words = text.split(' ');
    final totalChars = text.length;
    final currentCharIndex = lineProgress * totalChars;
    final wordWidgets = <Widget>[];
    var charAccumulator = 0;

    const overlap = 0.5;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final wordLen = word.length;
      final wordStartChar = charAccumulator;
      final wordEndChar = wordStartChar + wordLen;

      double wordProgress = 0.0;
      if (currentCharIndex >= wordEndChar + overlap) {
        wordProgress = 1.0;
      } else if (currentCharIndex <= wordStartChar - overlap) {
        wordProgress = 0.0;
      } else {
        final localCurrent = currentCharIndex - (wordStartChar - overlap);
        final localTotal = wordLen + (overlap * 2);
        wordProgress = (localCurrent / localTotal).clamp(0.0, 1.0);
      }

      wordWidgets.add(
        _LyricWord(
          word: word + (i < words.length - 1 ? ' ' : ''),
          progress: wordProgress,
          style: style,
          activeColor: Colors.white,
          inactiveColor: Colors.white.withOpacity(0.3),
        ),
      );

      charAccumulator += wordLen + (i < words.length - 1 ? 1 : 0);
    }

    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0.0,
      runSpacing: 4.0,
      children: wordWidgets,
    );
  }

  /// Línea estática (palabras en un solo color) — mantiene el mismo
  /// layout Wrap que la línea karaoke para que no salte el texto.
  Widget _buildStaticWords(
    TextStyle style,
    String text, {
    required bool isCurrent,
  }) {
    final words = text.split(' ');
    final color = isCurrent
        ? Colors.white
        : Colors.white.withOpacity(0.5);
    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0.0,
      runSpacing: 4.0,
      children: [
        for (var i = 0; i < words.length; i++)
          Text(
            words[i] + (i < words.length - 1 ? ' ' : ''),
            style: style.copyWith(color: color),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Stack(
      children: [
        ShaderMask(
          shaderCallback: (rect) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0.0, 0.3, 0.7, 1.0],
            ).createShader(rect);
          },
          blendMode: BlendMode.dstIn,
          child: NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              // Si el usuario inicia un drag, desactivamos el auto-scroll
              if (notification.direction != ScrollDirection.idle) {
                _userHasScrolled = true;
              }
              return false;
            },
            child: ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.symmetric(vertical: 200),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                return ValueListenableBuilder<int?>(
                  valueListenable: widget.currentIndexNotifier,
                  builder: (context, currentIndex, _) {
                    final displayIndex = _mapToDisplayIndex(currentIndex);
                    final isCurrent = index == displayIndex;
                    final line = _lines[index];

                    final baseStyle = TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      color: isCurrent
                          ? Colors.white
                          : Colors.white.withOpacity(0.5),
                      height: 1.3,
                      letterSpacing: 0.5,
                      shadows: isCurrent
                          ? [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : [],
                    );

                    final Widget lineContent;
                    if (isCurrent && _isSweepEnabled) {
                      // Solo la línea actual se reconstruye con la posición
                      lineContent = ValueListenableBuilder<Duration>(
                        valueListenable: widget.positionNotifier,
                        builder: (context, position, _) {
                          return _buildKaraokeWords(
                            baseStyle,
                            line,
                            position,
                            index,
                          );
                        },
                      );
                    } else {
                      lineContent = _buildStaticWords(
                        baseStyle,
                        line.text,
                        isCurrent: isCurrent,
                      );
                    }

                    return MouseRegion(
                      cursor: widget.onTap != null
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      child: GestureDetector(
                        onTap: widget.onTap != null
                            ? () {
                                widget.onTap!(line.timestamp);
                              }
                            : null,
                        child: Container(
                          key: _itemKeys[index],
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          child: ImageFiltered(
                            imageFilter: isCurrent
                                ? ImageFilter.blur(sigmaX: 0, sigmaY: 0)
                                : ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                            child: lineContent,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),

        // Sync Button
        if (_showSyncButton)
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _syncToCurrentLine,
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sync, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          widget.getText(
                            'sync_lyrics',
                            fallback: 'Sincronizar',
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Palabra con relleno por progreso (modo karaoke, forawn_mobile).
class _LyricWord extends StatelessWidget {
  final String word;
  final double progress;
  final TextStyle style;
  final Color activeColor;
  final Color inactiveColor;

  const _LyricWord({
    required this.word,
    required this.progress,
    required this.style,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    if (progress >= 1.0) {
      return Text(word, style: style.copyWith(color: activeColor));
    } else if (progress <= 0.0) {
      return Text(word, style: style.copyWith(color: inactiveColor));
    }

    // Acelerador visual de progreso para que la última letra se ilumine
    final visualProgress = (progress * 1.25).clamp(0.0, 1.0);

    return ShaderMask(
      shaderCallback: (rect) {
        return LinearGradient(
          colors: [
            activeColor,
            activeColor.withOpacity(0.5),
            inactiveColor,
          ],
          stops: [
            (visualProgress - 0.2).clamp(0.0, 1.0),
            visualProgress,
            (visualProgress + 0.2).clamp(0.0, 1.0),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          tileMode: TileMode.clamp,
        ).createShader(rect);
      },
      blendMode: BlendMode.srcIn,
      child: Text(word, style: style.copyWith(color: Colors.white)),
    );
  }
}
