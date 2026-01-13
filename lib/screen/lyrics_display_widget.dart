import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/synced_lyrics.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class LyricsDisplay extends StatefulWidget {
  final SyncedLyrics lyrics;
  final ValueNotifier<int?> currentIndexNotifier;
  final TextGetter getText;
  final TextAlign textAlign;

  const LyricsDisplay({
    super.key,
    required this.lyrics,
    required this.currentIndexNotifier,
    required this.getText,
    this.textAlign = TextAlign.center,
  });

  @override
  State<LyricsDisplay> createState() => _LyricsDisplayState();
}

class _LyricsDisplayState extends State<LyricsDisplay> {
  late ScrollController _controller;
  final Map<int, GlobalKey> _itemKeys = {};

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    widget.currentIndexNotifier.addListener(_onIndexChanged);

    // Crear keys para cada item
    for (int i = 0; i < widget.lyrics.lineCount; i++) {
      _itemKeys[i] = GlobalKey();
    }

    // Scroll al inicio después de que el widget se construya
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) {
        _controller.jumpTo(0);
      }
    });
  }

  @override
  void didUpdateWidget(LyricsDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambiaron las lyrics (nueva canción), resetear scroll
    if (oldWidget.lyrics != widget.lyrics) {
      // Recrear keys para los nuevos items
      _itemKeys.clear();
      for (int i = 0; i < widget.lyrics.lineCount; i++) {
        _itemKeys[i] = GlobalKey();
      }

      // Scroll al inicio
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
    _controller.dispose();
    super.dispose();
  }

  void _onIndexChanged() {
    final index = widget.currentIndexNotifier.value;
    if (index != null && _controller.hasClients) {
      final key = _itemKeys[index];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
          alignment: 0.5, // Centrar en la pantalla
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
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
      child: ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.symmetric(vertical: 200),
        itemCount: widget.lyrics.lineCount,
        itemBuilder: (context, index) {
          return ValueListenableBuilder<int?>(
            valueListenable: widget.currentIndexNotifier,
            builder: (context, currentIndex, _) {
              final isCurrent = index == currentIndex;

              return Container(
                key: _itemKeys[index],
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: ImageFiltered(
                  imageFilter: isCurrent
                      ? ImageFilter.blur(sigmaX: 0, sigmaY: 0)
                      : ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontSize: 28, // Tamaño fijo para todas las líneas
                      fontWeight: FontWeight.w600, // Mismo peso para todos
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
                    ),
                    textAlign: widget.textAlign,
                    child: Text(
                      widget.lyrics.lines[index].text,
                      textAlign: widget.textAlign,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
