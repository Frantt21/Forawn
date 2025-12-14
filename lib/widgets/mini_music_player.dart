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
  Offset _offset = const Offset(0, 0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Restringir offset si es muy grande
    _limitOffset();
  }

  void _limitOffset() {
    final screenSize = MediaQuery.of(context).size;
    const padding = 16.0;
    const expandedPlayerWidth = 380.0;
    const expandedPlayerHeight = 250.0;

    // IMPORTANTE: Siempre usar tamaños expandidos para los límites
    // Esto evita que el reproductor se salga de la pantalla al expandirse
    final maxLeftOffset = screenSize.width - expandedPlayerWidth - padding;
    final maxBottomOffset = screenSize.height - expandedPlayerHeight - padding;

    if (_offset.dx > maxLeftOffset || _offset.dx < -padding) {
      _offset = Offset(_offset.dx.clamp(-padding, maxLeftOffset), _offset.dy);
    }

    if (_offset.dy > maxBottomOffset || _offset.dy < -padding) {
      _offset = Offset(_offset.dx, _offset.dy.clamp(-padding, maxBottomOffset));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _musicPlayer.showMiniPlayer,
      builder: (context, showMini, _) {
        if (!showMini) return const SizedBox.shrink();

        final screenSize = MediaQuery.of(context).size;
        const minWidth = 200.0;
        const maxWidth = 380.0;

        // Posición base del mini player
        final baseLeft = 16.0 + _offset.dx;
        final baseBottom = 16.0 + _offset.dy;

        // Calcular si hay espacio suficiente para expandir a la derecha
        final spaceToRight = screenSize.width - baseLeft - minWidth;
        final expandLeft = spaceToRight < maxWidth - minWidth;

        // Ajustar left dinámicamente cuando se expande
        final finalLeft = _isHovering && expandLeft
            ? baseLeft - (maxWidth - minWidth)
            : baseLeft;

        return Positioned(
          bottom: baseBottom,
          left: finalLeft,
          child: MouseRegion(
            onEnter: (_) {
              setState(() => _isHovering = true);
            },
            onExit: (_) {
              setState(() => _isHovering = false);
            },
            child: GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  _offset = Offset(
                    _offset.dx + details.delta.dx,
                    _offset.dy - details.delta.dy,
                  );
                  _limitOffset();
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 0),
                curve: Curves.easeInOut,
                width: _isHovering ? 380 : 200,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color.fromARGB(225, 30, 30, 30),
                  borderRadius: BorderRadius.circular(12),
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
                  child: SingleChildScrollView(
                    child: _isHovering
                        ? _buildExpandedPlayer()
                        : _buildCollapsedPlayer(),
                  ),
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
                                  ? (widget.getText?.call(
                                          'no_song',
                                          fallback: 'No music',
                                        ) ??
                                        'No music')
                                  : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).textTheme.bodyLarge?.color,
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
                              color: Colors.purpleAccent,
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
        // Header con botón cerrar
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title.isEmpty
                                    ? (widget.getText?.call(
                                            'no_song',
                                            fallback: 'No Song',
                                          ) ??
                                          'No Song')
                                    : title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).textTheme.bodyLarge?.color,
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
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.close,
                color: Theme.of(context).iconTheme.color,
                size: 16,
              ),
              onPressed: () {
                _musicPlayer.showMiniPlayer.value = false;
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip:
                  widget.getText?.call(
                    'close_miniplayer',
                    fallback: 'Close (click on Player to show)',
                  ) ??
                  'Close (click on Player to show)',
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
                        value: position.inMilliseconds.toDouble().clamp(
                          0,
                          duration.inMilliseconds.toDouble(),
                        ),
                        activeColor: Colors.purpleAccent,
                        inactiveColor: Colors.grey[700],
                        onChanged: (value) {
                          _musicPlayer.player.seek(
                            Duration(milliseconds: value.toInt()),
                          );
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
                              color: Colors.purpleAccent,
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
                        : Colors.purpleAccent,
                    size: 18,
                  ),
                  onPressed: () {
                    final modes = LoopMode.values;
                    final currentIndex = modes.indexOf(mode);
                    final nextMode = modes[(currentIndex + 1) % modes.length];
                    _musicPlayer.loopMode.value = nextMode;
                  },
                  tooltip:
                      '${widget.getText?.call('loop', fallback: 'Loop') ?? 'Loop'}: ${mode.name}',
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
                    color: Colors.purpleAccent,
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
                    color: isShuffle ? Colors.purpleAccent : Colors.grey,
                    size: 18,
                  ),
                  onPressed: () {
                    _musicPlayer.isShuffle.value = !isShuffle;
                  },
                  tooltip:
                      widget.getText?.call('shuffle', fallback: 'Shuffle') ??
                      'Shuffle',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                );
              },
            ),

            // Expand button
            IconButton(
              icon: const Icon(
                Icons.expand_less,
                color: Colors.purpleAccent,
                size: 18,
              ),
              onPressed: () {
                widget.onExpandPressed();
              },
              tooltip:
                  widget.getText?.call('expand', fallback: 'Expand') ??
                  'Expand',
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
                        color: Colors.purpleAccent,
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
                          activeColor: Colors.purpleAccent,
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
