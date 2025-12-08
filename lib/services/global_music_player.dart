import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class GlobalMusicPlayer {
  static final GlobalMusicPlayer _instance = GlobalMusicPlayer._internal();

  factory GlobalMusicPlayer() {
    return _instance;
  }

  GlobalMusicPlayer._internal();

  final AudioPlayer player = AudioPlayer();
  final ValueNotifier<bool> isPlaying = ValueNotifier(false);
  final ValueNotifier<bool> showMiniPlayer = ValueNotifier(false);
  final ValueNotifier<String> currentTitle = ValueNotifier('');
  final ValueNotifier<String> currentArtist = ValueNotifier('');
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<double> volume = ValueNotifier(1.0);

  void dispose() {
    isPlaying.dispose();
    showMiniPlayer.dispose();
    currentTitle.dispose();
    currentArtist.dispose();
    position.dispose();
    duration.dispose();
    volume.dispose();
  }
}
