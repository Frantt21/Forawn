import 'package:flutter/material.dart';
import '../services/global_music_player.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class MiniMusicPlayer extends StatefulWidget {
  final Function() onExpandPressed;
  final TextGetter? getText;

  const MiniMusicPlayer({
    super.key,
    required this.onExpandPressed,
    this.getText,
  });

  @override
  State<MiniMusicPlayer> createState() => _MiniMusicPlayerState();
}

class _MiniMusicPlayerState extends State<MiniMusicPlayer> {
  final GlobalMusicPlayer _musicPlayer = GlobalMusicPlayer();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _musicPlayer.showMiniPlayer,
      builder: (context, showMini, _) {
        if (!showMini) return const SizedBox.shrink();

        return Positioned(
          bottom: 16,
          left: 16,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 280,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.cyanAccent, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
              children: [
                // Header with title and close button
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ValueListenableBuilder<String>(
                            valueListenable: _musicPlayer.currentTitle,
                            builder: (context, title, _) {
                              return Text(
                                title.isEmpty
                                    ? (widget.getText?.call('no_song',
                                            fallback: 'No Song') ??
                                        'No Song')
                                    : title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              );
                            },
                          ),
                          const SizedBox(height: 4),
                          ValueListenableBuilder<String>(
                            valueListenable: _musicPlayer.currentArtist,
                            builder: (context, artist, _) {
                              return Text(
                                artist,
                                style: const TextStyle(
                                  color: Colors.cyanAccent,
                                  fontSize: 10,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 18),
                      onPressed: () {
                        _musicPlayer.showMiniPlayer.value = false;
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Progress bar
                ValueListenableBuilder<Duration>(
                  valueListenable: _musicPlayer.position,
                  builder: (context, position, _) {
                    return ValueListenableBuilder<Duration>(
                      valueListenable: _musicPlayer.duration,
                      builder: (context, duration, _) {
                        double sliderValue = 0;
                        if (duration.inMilliseconds > 0) {
                          sliderValue = position.inMilliseconds /
                              duration.inMilliseconds;
                          sliderValue =
                              sliderValue.clamp(0.0, 1.0);
                        }

                        return SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 4,
                            ),
                          ),
                          child: Slider(
                            value: sliderValue,
                            onChanged: (value) {
                              if (duration.inMilliseconds > 0) {
                                final newPosition = Duration(
                                  milliseconds: (value *
                                          duration.inMilliseconds)
                                      .toInt(),
                                );
                                _musicPlayer.player.seek(newPosition);
                              }
                            },
                            activeColor: Colors.cyanAccent,
                            inactiveColor: Colors.white12,
                          ),
                        );
                      },
                    );
                  },
                ),

                // Time display
                ValueListenableBuilder<Duration>(
                  valueListenable: _musicPlayer.position,
                  builder: (context, position, _) {
                    return ValueListenableBuilder<Duration>(
                      valueListenable: _musicPlayer.duration,
                      builder: (context, duration, _) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(position),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 9,
                                ),
                              ),
                              Text(
                                _formatDuration(duration),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 9,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 8),

                // Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Play/Pause
                    ValueListenableBuilder<bool>(
                      valueListenable: _musicPlayer.isPlaying,
                      builder: (context, isPlaying, _) {
                        return IconButton(
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.cyanAccent,
                            size: 20,
                          ),
                          onPressed: () async {
                            if (isPlaying) {
                              await _musicPlayer.player.pause();
                            } else {
                              await _musicPlayer.player.resume();
                            }
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        );
                      },
                    ),

                    // Expand
                    IconButton(
                      icon: const Icon(
                        Icons.fullscreen,
                        color: Colors.cyanAccent,
                        size: 20,
                      ),
                      onPressed: widget.onExpandPressed,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),

                    // Volume
                    ValueListenableBuilder<double>(
                      valueListenable: _musicPlayer.volume,
                      builder: (context, volume, _) {
                        return IconButton(
                          icon: Icon(
                            volume > 0.5
                                ? Icons.volume_up
                                : volume > 0
                                    ? Icons.volume_down
                                    : Icons.volume_off,
                            color: Colors.cyanAccent,
                            size: 20,
                          ),
                          onPressed: () {
                            final newVolume = volume > 0 ? 0.0 : 1.0;
                            _musicPlayer.volume.value = newVolume;
                            _musicPlayer.player.setVolume(newVolume);
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      },
    );
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return "--:--";
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }
}
