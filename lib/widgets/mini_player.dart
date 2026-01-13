import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/global_music_player.dart';
import '../services/global_theme_service.dart';
import '../services/global_keyboard_service.dart';
import '../screen/player_screen.dart';

typedef TextGetter = String Function(String key, {String? fallback});

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
              Navigator.of(context).push(
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) =>
                      PlayerScreen(getText: widget.getText),
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
                        const begin = Offset(0.0, 1.0);
                        const end = Offset.zero;
                        const curve = Curves.easeOutCubic;

                        var tween = Tween(
                          begin: begin,
                          end: end,
                        ).chain(CurveTween(curve: curve));

                        return SlideTransition(
                          position: animation.drive(tween),
                          child: child,
                        );
                      },
                ),
              );
            }
          },
          onTap: () {
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    PlayerScreen(getText: widget.getText),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      const begin = Offset(0.0, 1.0);
                      const end = Offset.zero;
                      const curve = Curves.easeInOut;

                      var tween = Tween(
                        begin: begin,
                        end: end,
                      ).chain(CurveTween(curve: curve));

                      return SlideTransition(
                        position: animation.drive(tween),
                        child: child,
                      );
                    },
              ),
            );
          },
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
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    color: (dominantColor ?? const Color(0xFF2D2D2D))
                        .withOpacity(0.7),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                  ), // Matching example padding
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
                                duration: const Duration(milliseconds: 300),
                                transitionBuilder:
                                    (
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
                                        key: const ValueKey('placeholder'),
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
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title.isEmpty ? "No Song" : title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              ValueListenableBuilder<String>(
                                valueListenable: _musicPlayer.currentArtist,
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
              ),
            ),
          ),
        );
      },
    );
  }
}
