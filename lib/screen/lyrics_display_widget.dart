import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../models/synced_lyrics.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class LyricsDisplay extends StatefulWidget {
  final SyncedLyrics lyrics;
  final ValueNotifier<int?> currentIndexNotifier;
  final ValueNotifier<Duration> positionNotifier;
  final TextGetter getText;
  final TextAlign textAlign;
  final Function(Duration)? onTap;

  const LyricsDisplay({
    super.key,
    required this.lyrics,
    required this.currentIndexNotifier,
    required this.positionNotifier,
    required this.getText,
    this.textAlign = TextAlign.center,
    this.onTap,
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

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_checkButtonVisibility);
    widget.currentIndexNotifier.addListener(_onIndexChanged);

    // Crear keys para cada item
    for (int i = 0; i < widget.lyrics.lineCount; i++) {
      _itemKeys[i] = GlobalKey();
    }
  }

  @override
  void didUpdateWidget(LyricsDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambiaron las lyrics (nueva canción), recrear keys y resetear scroll
    if (oldWidget.lyrics != widget.lyrics) {
      // Recrear keys para los nuevos items
      _itemKeys.clear();
      for (int i = 0; i < widget.lyrics.lineCount; i++) {
        _itemKeys[i] = GlobalKey();
      }

      // Resetear estado del botón de sync
      _showSyncButton = false;
      _lastAutoScrolledIndex = -1;
      _userHasScrolled = false;

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
    final index = widget.currentIndexNotifier.value;
    if (index == null || !_controller.hasClients) {
      if (_showSyncButton) setState(() => _showSyncButton = false);
      return;
    }

    final key = _itemKeys[index];
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
    // ignore: unnecessary_null_comparison
    if (viewport == null) return;

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
    final index = widget.currentIndexNotifier.value;
    if (index != null && _controller.hasClients) {
      final key = _itemKeys[index];

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
        final estimatedOffset = (index * 70.0).clamp(
          0.0,
          _controller.position.maxScrollExtent,
        );
        _controller.jumpTo(estimatedOffset);

        // Intentamos hacer el scroll fino después de un frame
        WidgetsBinding.instance.addPostFrameCallback((_) => scrollToTarget());
      } else {
        scrollToTarget();
      }

      _lastAutoScrolledIndex = index;
      _userHasScrolled = false;
      setState(() {
        _showSyncButton = false;
      });
    }
  }

  void _onIndexChanged() {
    final index = widget.currentIndexNotifier.value;
    if (index == null || !_controller.hasClients) return;

    // Si el usuario scrolleó, solo verificamos visibilidad
    if (_userHasScrolled) {
      _checkButtonVisibility();
      return;
    }

    // Comportamiento normal (Auto-scroll)
    // Verificamos si necesitamos hacer scroll
    if (index != _lastAutoScrolledIndex) {
      _lastAutoScrolledIndex = index;
      final key = _itemKeys[index];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
          alignment: 0.5,
        );
      } else {
        // En caso extremo que el auto-scroll tenga que saltar mucho
        final estimatedOffset = (index * 70.0).clamp(
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
              itemCount: widget.lyrics.lineCount,
              itemBuilder: (context, index) {
                return ValueListenableBuilder<int?>(
                  valueListenable: widget.currentIndexNotifier,
                  builder: (context, currentIndex, _) {
                    final isCurrent = index == currentIndex;

                    return MouseRegion(
                      cursor: widget.onTap != null
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      child: GestureDetector(
                        onTap: widget.onTap != null
                            ? () {
                                final timestamp =
                                    widget.lyrics.lines[index].timestamp;
                                widget.onTap!(timestamp);
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
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 300),
                              style: TextStyle(
                                fontSize:
                                    28, // Tamaño fijo para todas las líneas
                                fontWeight:
                                    FontWeight.w600, // Mismo peso para todos
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
