import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/global_music_player.dart';
import '../services/global_theme_service.dart';
import '../services/global_keyboard_service.dart';
import '../screen/player_screen.dart';

typedef TextGetter = String Function(String key, {String? fallback});

/// GlobalKey del Navigator raíz de la app.
///
/// [MiniPlayerHost] se monta en `MaterialApp.builder`, por ENCIMA del
/// Navigator, así que su context no puede hacer `Navigator.of(context)`.
/// Todas las navegaciones desde el MiniPlayer usan esta key.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Estado global de visibilidad del MiniPlayer.
///
/// El MiniPlayer es un componente ÚNICO montado en la raíz de la app
/// ([MiniPlayerHost]). Su visibilidad se controla con dos señales:
///
/// - [playerTabActive]: `true` cuando la tab/screen activa es la del
///   reproductor de música (MusicPlayerScreen) o sus subrutas como
///   PlaylistDetailScreen. Lo actualiza main.dart al navegar.
/// - [fullPlayerOpen]: `true` mientras el reproductor completo
///   (PlayerScreen) está abierto sobre el music player.
/// - [blockedByOverlay]: `true` mientras haya una screen opaca de la app
///   (p.ej. Settings) abierta sobre el music player.
class MiniPlayerVisibility {
  static final ValueNotifier<bool> playerTabActive = ValueNotifier(false);
  static final ValueNotifier<bool> fullPlayerOpen = ValueNotifier(false);
  static final ValueNotifier<bool> blockedByOverlay = ValueNotifier(false);

  /// Señal idempotente: el último valor escrito gana. A diferencia de un
  /// contador push/pop, no puede desincronizarse si un dispose no se
  /// empareja exactamente con su initState (hot reload, cierre por
  /// gesture/gesto del sistema, etc.).
  static void setFullPlayerOpen(bool open) => fullPlayerOpen.value = open;

  /// `true` mientras la tab Home del music player muestra su degradado de
  /// acento. La title bar de main.dart escucha esta señal (junto con el
  /// color en [homeGradientColor]) para teñirse y fundirse con el degradado
  /// del fondo.
  static final ValueNotifier<bool> homeTabGradientActive = ValueNotifier(
    false,
  );

  /// Color actual del degradado de la tab Home (calculado por
  /// MusicPlayerScreen). La title bar lo usa como tinte de fondo.
  static final ValueNotifier<Color> homeGradientColor = ValueNotifier(
    const Color(0xFF6A1B9A),
  );

  // ------------------------------------------------------------------
  // Bloqueo por overlays (diálogos, bottom sheets, menús contextuales).
  //
  // El MiniPlayerHost vive en MaterialApp.builder, POR ENCIMA del
  // Navigator: cualquier ruta modal (showDialog, showMenu,
  // showModalBottomSheet, etc.) se renderiza dentro del Navigator y por
  // tanto QUEDA POR DEBAJO del miniplayer. Como no se puede reordenar el
  // z-order desde fuera, los modales ocultan el miniplayer mientras
  // están abiertos — el miniplayer se desliza hacia abajo rápido y
  // regresa al cerrarlos.
  //
  // Dos fuentes pueden bloquear y se combinan con OR:
  //  - manual: señales explícitas (p.ej. Settings en main.dart).
  //  - rutas modales: contadas por [MiniPlayerModalObserver].
  // ------------------------------------------------------------------
  static bool _manualOverlayBlocked = false;
  static int _modalRouteCount = 0;

  static void setOverlayBlocked(bool blocked) {
    _manualOverlayBlocked = blocked;
    _recomputeOverlay();
  }

  static void _modalRoutePushed() {
    _modalRouteCount++;
    _recomputeOverlay();
  }

  static void _modalRoutePopped() {
    if (_modalRouteCount > 0) _modalRouteCount--;
    _recomputeOverlay();
  }

  static void _recomputeOverlay() {
    blockedByOverlay.value = _manualOverlayBlocked || _modalRouteCount > 0;
  }

  static bool get isVisible =>
      playerTabActive.value && !fullPlayerOpen.value;

  MiniPlayerVisibility._();
}

/// NavigatorObserver que detecta rutas modales (diálogos, menús, bottom
/// sheets) para ocultar el MiniPlayer mientras estén abiertas. Regístralo
/// en `MaterialApp.navigatorObservers`.
class MiniPlayerModalObserver extends NavigatorObserver {
  bool _isModalRoute(Route<dynamic> route) =>
      route is RawDialogRoute || route is PopupRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isModalRoute(route)) MiniPlayerVisibility._modalRoutePushed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isModalRoute(route)) MiniPlayerVisibility._modalRoutePopped();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isModalRoute(route)) MiniPlayerVisibility._modalRoutePopped();
  }
}

/// Host único del MiniPlayer para toda la app.
///
/// Se monta UNA sola vez (en MaterialApp.builder, sobre el Navigator) y se
/// muestra solo en el screen del reproductor de música y en las screens
/// que se abren desde él (p.ej. el detalle de playlist). Ninguna screen
/// instancia su propio MiniPlayer.
class MiniPlayerHost extends StatelessWidget {
  final TextGetter getText;

  const MiniPlayerHost({super.key, required this.getText});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: MiniPlayerVisibility.playerTabActive,
      builder: (context, tabActive, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: MiniPlayerVisibility.fullPlayerOpen,
          builder: (context, fullPlayerOpen, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: MiniPlayerVisibility.blockedByOverlay,
              builder: (context, blocked, _) {
                final visible = tabActive && !fullPlayerOpen && !blocked;
                // Al abrirse el reproductor completo (que entra desde abajo),
                // el miniplayer se desliza hacia abajo y se desvanece; al
                // cerrarlo regresa desde abajo a su posición.
                //
                // Cuando lo oculta un modal (menú/diálogo), el hide es corto
                // (200ms) para que se sienta inmediato; el regreso siempre es
                // de 450ms acompañando la animación del player.
                final hideDuration = fullPlayerOpen
                    ? const Duration(milliseconds: 450)
                    : const Duration(milliseconds: 200);
                return ClipRect(
                  child: AnimatedSlide(
                    offset: visible ? Offset.zero : const Offset(0, 1.1),
                    duration: visible
                        ? const Duration(milliseconds: 450)
                        : hideDuration,
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: visible ? 1.0 : 0.0,
                      duration: visible
                          ? const Duration(milliseconds: 450)
                          : hideDuration,
                      curve: Curves.easeOutCubic,
                      child: IgnorePointer(
                        ignoring: !visible,
                        // El host vive en MaterialApp.builder, FUERA de todo
                        // Material/Scaffold. Sin un ancestro Material, los Text
                        // heredan el DefaultTextStyle de fallback (subrayado
                        // amarillo). MaterialType.transparency pinta la
                        // tipografía correcta sin añadir fondo.
                        child: Material(
                          type: MaterialType.transparency,
                          child: MiniPlayer(getText: getText),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class MiniPlayer extends StatefulWidget {
  final TextGetter getText;

  const MiniPlayer({Key? key, required this.getText}) : super(key: key);

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final GlobalMusicPlayer _musicPlayer = GlobalMusicPlayer();

  @override
  Widget build(BuildContext context) {
    // Hide if no song is loaded (listen to title and art)
    return ValueListenableBuilder<String>(
      valueListenable: _musicPlayer.currentTitle,
      builder: (context, currentTitle, _) {
        return ValueListenableBuilder<Uint8List?>(
          valueListenable: _musicPlayer.currentArt,
          builder: (context, currentArt, _) {
            if (currentTitle.isEmpty && currentArt == null) {
              return const SizedBox.shrink();
            }

            return _buildContent(context, currentTitle, currentArt);
          },
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, String title, Uint8List? art) {
    return ValueListenableBuilder<Color?>(
      valueListenable: GlobalThemeService().dominantColor,
      builder: (context, dominantColor, _) {
        return GestureDetector(
          onVerticalDragUpdate: (details) {
            // Si arrastra hacia arriba (delta negativo), abrir reproductor
            if (details.primaryDelta! < -5) {
              _openFullPlayer();
            }
          },
          onTap: _openFullPlayer,
          child: Container(
            height: 70,
            decoration: BoxDecoration(
              // Shadow moved to outer container for proper rendering
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
              borderRadius: BorderRadius.circular(24),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  // Blur Effect (mismo sigma que forawn_mobile)
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                  // Content
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeInOut,
                    decoration: BoxDecoration(
                      // Misma transparencia que forawn_mobile, sin borde.
                      color: (dominantColor ?? const Color(0xFF2D2D2D))
                          .withOpacity(0.7),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Stack(
                      children: [
                        // Progress background layer (como forawn_mobile):
                        // banda blanca 5% que crece con el avance de la
                        // pista, de borde a borde del miniplayer.
                        Positioned.fill(
                          child: ValueListenableBuilder<Duration>(
                            valueListenable: _musicPlayer.duration,
                            builder: (context, duration, _) {
                              return ValueListenableBuilder<Duration>(
                                valueListenable: _musicPlayer.position,
                                builder: (context, position, __) {
                                  final progress = duration.inMilliseconds > 0
                                      ? (position.inMilliseconds /
                                            duration.inMilliseconds)
                                          .clamp(0.0, 1.0)
                                      : 0.0;
                                  return Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: progress,
                                      child: Container(
                                        color: Colors.white.withOpacity(0.05),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        // Content
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              // Artwork
                              Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Hero(
                                  tag: 'mini_player_art',
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: AspectRatio(
                                      aspectRatio: 1,
                                      child: AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 300),
                                        transitionBuilder: (
                                          Widget child,
                                          Animation<double> animation,
                                        ) {
                                          return FadeTransition(
                                            opacity: animation,
                                            child: ScaleTransition(
                                              scale: animation,
                                              child: child,
                                            ),
                                          );
                                        },
                                        key: ValueKey(
                                          art.hashCode,
                                        ), // Force rebuild on art change
                                        child: art != null
                                            ? Image.memory(
                                                art,
                                                key: ValueKey(art.hashCode),
                                                fit: BoxFit.cover,
                                              )
                                            : Container(
                                                key: const ValueKey(
                                                  'placeholder',
                                                ),
                                                color: Colors.grey[850],
                                                child: const Icon(
                                                  Icons.music_note,
                                                  color: Colors.white54,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              // Title/Artist
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title.isEmpty
                                            ? widget.getText(
                                                'no_song',
                                                fallback: 'No Song',
                                              )
                                            : title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      ValueListenableBuilder<String>(
                                        valueListenable:
                                            _musicPlayer.currentArtist,
                                        builder: (context, artist, _) {
                                          return Text(
                                            artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // Controls
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ValueListenableBuilder<bool>(
                                    valueListenable: _musicPlayer.isPlaying,
                                    builder: (context, isPlaying, _) {
                                      return IconButton(
                                        icon: Icon(
                                          isPlaying
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          color: Colors.white,
                                        ),
                                        onPressed: () {
                                          GlobalKeyboardService()
                                              .requestTogglePlayPause();
                                        },
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.skip_next_rounded,
                                      color: Colors.white,
                                    ),
                                    onPressed: () {
                                      GlobalKeyboardService().requestPlayNext();
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openFullPlayer() {
    // Ocultar el miniplayer de inmediato (antes incluso de que el
    // initState del PlayerScreen repita la señal).
    MiniPlayerVisibility.setFullPlayerOpen(true);
    appNavigatorKey.currentState?.push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 450),
        pageBuilder: (context, animation, secondaryAnimation) =>
            PlayerScreen(getText: widget.getText),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
      ),
    ).whenComplete(() => MiniPlayerVisibility.setFullPlayerOpen(false));
  }
}
