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
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _musicPlayer.showMiniPlayer,
      builder: (context, showMini, _) {
        if (!showMini) return const SizedBox.shrink();

        return Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: Center(
            child: MouseRegion(
              onEnter: (_) {
                setState(() => _isHovering = true);
              },
              onExit: (_) {
                setState(() => _isHovering = false);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                width: _isHovering ? 380 : 200,
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
                child: Material(
                  color: Colors.transparent,
                  child: _isHovering
                      ? _buildExpandedPlayer()
                      : _buildCollapsedPlayer(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Mini player recogido - solo título y tiempo
  Widget _buildCollapsedPlayer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Título y tiempo en una sola línea
        ValueListenableBuilder<String>(
          valueListenable: _musicPlayer.currentTitle,
          builder: (context, title, _) {
            return ValueListenableBuilder<Duration>(
              valueListenable: _musicPlayer.position,
              builder: (context, position, _) {
                return ValueListenableBuilder<Duration>(
                  valueListenable: _musicPlayer.duration,
                  builder: (context, duration, _) {
                    String timeStr =
                        '${_formatTime(position)} / ${_formatTime(duration)}';
                    return SizedBox(
                      height: 24,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              title.isEmpty
                                  ? (widget.getText?.call('no_song',
                                          fallback: 'No music') ??
                                      'No music')
                                  : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            timeStr,
                            style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ],
    );
  }

  // Mini player expandido - todos los controles
  Widget _buildExpandedPlayer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Título y artista
        ValueListenableBuilder<String>(
          valueListenable: _musicPlayer.currentTitle,
          builder: (context, title, _) {
            return ValueListenableBuilder<String>(
              valueListenable: _musicPlayer.currentArtist,
              builder: (context, artist, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title.isEmpty
                          ? (widget.getText?.call('no_song',
                                  fallback: 'No Song') ??
                              'No Song')
                          : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      artist.isEmpty ? 'Unknown' : artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
        const SizedBox(height: 8),

        // Progress bar
        ValueListenableBuilder<Duration>(
          valueListenable: _musicPlayer.position,
          builder: (context, position, _) {
            return ValueListenableBuilder<Duration>(
              valueListenable: _musicPlayer.duration,
              builder: (context, duration, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                      ),
                      child: Slider(
                        min: 0,
                        max: duration.inMilliseconds.toDouble(),
                        value: position.inMilliseconds
                            .toDouble()
                            .clamp(0, duration.inMilliseconds.toDouble()),
                        activeColor: Colors.cyanAccent,
                        inactiveColor: Colors.grey[700],
                        onChanged: (value) {
                          _musicPlayer.player
                              .seek(Duration(milliseconds: value.toInt()));
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatTime(position),
                            style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 10,
                            ),
                          ),
                          Text(
                            _formatTime(duration),
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
        const SizedBox(height: 8),

        // Controles principales
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Loop button
            ValueListenableBuilder<LoopMode>(
              valueListenable: _musicPlayer.loopMode,
              builder: (context, mode, _) {
                return IconButton(
                  icon: Icon(
                    mode == LoopMode.off
                        ? Icons.repeat
                        : mode == LoopMode.all
                            ? Icons.repeat
                            : Icons.repeat_one,
                    color: mode == LoopMode.off
                        ? Colors.grey
                        : Colors.cyanAccent,
                    size: 18,
                  ),
                  onPressed: () {
                    final modes = LoopMode.values;
                    final currentIndex = modes.indexOf(mode);
                    final nextMode = modes[(currentIndex + 1) % modes.length];
                    _musicPlayer.loopMode.value = nextMode;
                  },
                  tooltip: 'Loop: ${mode.name}',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                );
              },
            ),

            // Play/Pause
            ValueListenableBuilder<bool>(
              valueListenable: _musicPlayer.isPlaying,
              builder: (context, isPlaying, _) {
                return IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.cyanAccent,
                    size: 24,
                  ),
                  onPressed: () async {
                    if (isPlaying) {
                      await _musicPlayer.player.pause();
                    } else {
                      await _musicPlayer.player.resume();
                    }
                  },
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                );
              },
            ),

            // Shuffle button
            ValueListenableBuilder<bool>(
              valueListenable: _musicPlayer.isShuffle,
              builder: (context, isShuffle, _) {
                return IconButton(
                  icon: Icon(
                    Icons.shuffle,
                    color: isShuffle ? Colors.cyanAccent : Colors.grey,
                    size: 18,
                  ),
                  onPressed: () {
                    _musicPlayer.isShuffle.value = !isShuffle;
                  },
                  tooltip: 'Shuffle',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                );
              },
            ),

            // Expand button
            IconButton(
              icon: const Icon(
                Icons.expand_less,
                color: Colors.cyanAccent,
                size: 18,
              ),
              onPressed: () {
                widget.onExpandPressed();
              },
              tooltip: 'Expand',
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(4),
            ),

            // Volume control
            ValueListenableBuilder<double>(
              valueListenable: _musicPlayer.volume,
              builder: (context, vol, _) {
                return SizedBox(
                  width: 80,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        vol > 0 ? Icons.volume_up : Icons.volume_off,
                        color: Colors.cyanAccent,
                        size: 14,
                      ),
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: 1,
                          value: vol,
                          onChanged: (value) {
                            _musicPlayer.volume.value = value;
                          },
                          activeColor: Colors.cyanAccent,
                          inactiveColor: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  String _formatTime(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return '$twoDigitMinutes:$twoDigitSeconds';
  }
}
