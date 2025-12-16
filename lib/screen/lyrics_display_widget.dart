import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/synced_lyrics.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class LyricsDisplay extends StatefulWidget {
  final SyncedLyrics lyrics;
  final ValueNotifier<int?> currentIndexNotifier;
  final TextGetter getText;

  const LyricsDisplay({
    super.key,
    required this.lyrics,
    required this.currentIndexNotifier,
    required this.getText,
  });

  @override
  State<LyricsDisplay> createState() => _LyricsDisplayState();
}

class _LyricsDisplayState extends State<LyricsDisplay> {
  late FixedExtentScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = FixedExtentScrollController(
      initialItem: widget.currentIndexNotifier.value ?? 0,
    );
    widget.currentIndexNotifier.addListener(_onIndexChanged);
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
      if ((_controller.selectedItem - index).abs() > 10) {
        _controller.jumpToItem(index);
      } else {
        _controller.animateToItem(
          index,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOutCubic,
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
          stops: [0.0, 0.2, 0.8, 1.0],
        ).createShader(rect);
      },
      blendMode: BlendMode.dstIn,
      child: ListWheelScrollView.useDelegate(
        controller: _controller,
        itemExtent: 70,
        diameterRatio: 100, // Ratio alto para que se vea plano
        perspective: 0.0001,
        physics: const NeverScrollableScrollPhysics(),
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: widget.lyrics.lineCount,
          builder: (context, index) {
            return ValueListenableBuilder<int?>(
              valueListenable: widget.currentIndexNotifier,
              builder: (context, currentIndex, _) {
                final isCurrent = index == currentIndex;

                return Center(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontSize: isCurrent ? 34 : 22,
                      fontWeight: isCurrent
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isCurrent
                          ? Colors.white
                          : Colors.white.withOpacity(0.5),
                      height: 1.2,
                      letterSpacing: 0.5,
                      shadows: isCurrent
                          ? [
                              BoxShadow(
                                color: Colors.purpleAccent.withOpacity(0.6),
                                blurRadius: 20,
                                spreadRadius: 2,
                              ),
                              const Shadow(
                                color: Colors.black87,
                                blurRadius: 4,
                                offset: Offset(2, 2),
                              ),
                            ]
                          : [],
                    ),
                    textAlign: TextAlign.center,
                    child: Text(
                      widget.lyrics.lines[index].text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
