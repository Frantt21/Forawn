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
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PlayerScreen(getText: widget.getText),
              ),
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 70,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Colors.transparent,
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  color: (dominantColor ?? const Color(0xFF1C1C1E)).withOpacity(
                    0.50,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      // Artwork
                      Hero(
                        tag: 'mini_player_art',
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            image: art != null
                                ? DecorationImage(
                                    image: MemoryImage(art),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                            color: Colors.grey[850],
                          ),
                          child: art == null
                              ? const Icon(
                                  Icons.music_note,
                                  color: Colors.white54,
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Title/Artist
                      Expanded(
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
                            const SizedBox(height: 2),
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
                                  size: 28,
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
                              size: 28,
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
