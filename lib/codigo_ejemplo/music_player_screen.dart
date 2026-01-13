// lib/screens/music_player_screen.dart
import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/language_service.dart';
import '../services/playlist_service.dart';
import '../models/song.dart';
import '../models/playback_state.dart';
import '../widgets/lyrics_sheet.dart';
import 'package:audiotags/audiotags.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../services/foranly_service.dart';
import '../services/metadata_service.dart';
import '../services/saf_helper.dart';
import '../services/music_library_service.dart'; // Added
import '../services/music_metadata_cache.dart'; // Added
import 'dart:typed_data';

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  final AudioPlayerService _player = AudioPlayerService();
  String? _lastSongId;

  @override
  void initState() {
    super.initState();
    // Listener vacío o para debug si es necesario,
    // pero ya no necesitamos lógica aquí para el UI básico
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<Song?>(
        stream: _player.currentSongStream,
        builder: (context, snapshot) {
          final song = snapshot.data;

          if (song == null) {
            // Manejar caso null pero mostrando UI base o loader
            return Container(
              color: Colors.black,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            );
          }

          return Stack(
            children: [
              // Fondo con blur
              _buildBackground(song),

              // Contenido Principal
              SafeArea(
                child: Column(
                  children: [
                    // Header
                    _buildHeader(context),

                    // Contenido central (Artwork o Lyrics)
                    Expanded(
                      child: GestureDetector(
                        onHorizontalDragEnd: (details) {
                          if (details.primaryVelocity! < 0) {
                            _player.skipToNext();
                          } else if (details.primaryVelocity! > 0) {
                            _player.skipToPrevious();
                          }
                        },
                        onVerticalDragEnd: (details) {
                          if (details.primaryVelocity! > 500) {
                            Navigator.of(context).pop();
                          }
                        },
                        child: _buildArtwork(song),
                      ),
                    ),

                    // Info de canción y Controles
                    _buildControls(song),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBackground(Song song) {
    // Usar color cacheado si está disponible
    final backgroundColor = song.dominantColor != null
        ? Color(song.dominantColor!)
        : Colors.grey[900]!;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [backgroundColor, Colors.black],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! > 0) {
          Navigator.of(context).pop();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.white,
                size: 32,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),

            // Título dinámico
            Text(
              LanguageService().getText('now_playing').toUpperCase(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),

            // Menú de opciones
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              color: Colors.grey[900],
              onSelected: (value) async {
                final currentSong = await _player.currentSongStream.first;
                if (currentSong == null) return;

                switch (value) {
                  case 'like':
                    // Toggle favoritos usando el servicio
                    final isLiked = PlaylistService().isLiked(currentSong.id);
                    await PlaylistService().toggleLike(currentSong.id);

                    // if (mounted) {
                    //   ScaffoldMessenger.of(context).showSnackBar(
                    //     SnackBar(
                    //       content: Text(
                    //         isLiked
                    //             ? LanguageService().getText(
                    //                 'removed_from_favorites',
                    //               )
                    //             : LanguageService().getText(
                    //                 'added_to_favorites',
                    //               ),
                    //       ),
                    //       backgroundColor: isLiked
                    //           ? Colors.grey[700]
                    //           : Colors.purpleAccent,
                    //     ),
                    //   );
                    // }
                    break;
                  case 'add_to_playlist':
                    // Mostrar diálogo de agregar a playlist
                    if (mounted) {
                      _showAddToPlaylistDialog(context, currentSong);
                    }
                    break;
                  case 'update_metadata':
                    if (mounted) {
                      _showMetadataSearchDialog(context, currentSong);
                    }
                    break;
                }
              },
              itemBuilder: (context) {
                // Obtener canción actual para verificar estado
                final currentSong = _player.currentSong;
                final isLiked = currentSong != null
                    ? PlaylistService().isLiked(currentSong.id)
                    : false;

                return [
                  PopupMenuItem(
                    value: 'like',
                    child: Row(
                      children: [
                        Icon(
                          isLiked ? Icons.favorite : Icons.favorite_border,
                          color: isLiked ? Colors.purpleAccent : Colors.white,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          isLiked
                              ? LanguageService().getText(
                                  'remove_from_favorites',
                                )
                              : LanguageService().getText('add_to_favorites'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'add_to_playlist',
                    child: Row(
                      children: [
                        const Icon(Icons.playlist_add, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(
                          LanguageService().getText('add_to_playlist'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'update_metadata',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_note, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(
                          LanguageService().getText('update_metadata'),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtwork(Song song) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: AspectRatio(
          aspectRatio: 1,
          child: Hero(
            tag: 'artwork_${song.id}',
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AnimatedSwitcher(
                  duration: const Duration(
                    milliseconds: 350,
                  ), // Un poco más rápido para slide
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    // Animación para el elemento que ENTRA (Nueva canción)
                    // Viene desde la derecha (Offset 1, 0) hacia el centro (0, 0)
                    final inAnimation =
                        Tween<Offset>(
                          begin: const Offset(1.0, 0.0),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutQuad,
                          ),
                        );

                    // Animación para el elemento que SALE (Canción anterior)
                    // Va del centro (0, 0) hacia la izquierda (Offset -1, 0)
                    // Como la animación de salida va de 1.0 a 0.0, definimos el Tween
                    // de tal forma que en 1.0 esté en 0 (centro) y en 0.0 esté en -1 (izquierda)
                    final outAnimation =
                        Tween<Offset>(
                          begin: const Offset(-1.0, 0.0),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeInQuad,
                          ),
                        );

                    // Decidir qué animación usar comparando la key
                    if (child.key == ValueKey(song.id)) {
                      return SlideTransition(
                        position: inAnimation,
                        child: child,
                      );
                    } else {
                      return SlideTransition(
                        position: outAnimation,
                        child: child,
                      );
                    }
                  },
                  child: song.artworkData != null
                      ? Image.memory(
                          song.artworkData!,
                          key: ValueKey(song.id),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                        )
                      : Container(
                          key: const ValueKey('placeholder'),
                          color: const Color(0xFF2C2C2C),
                          child: const Icon(
                            Icons.music_note,
                            size: 80,
                            color: Colors.white24,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Título y Artista
          Text(
            song.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26, // Más grande
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            song.artist,
            style: const TextStyle(color: Colors.white60, fontSize: 18),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          const SizedBox(height: 30),

          // Slider de Progreso
          StreamBuilder<PlaybackProgress>(
            stream: _player.progressStream,
            builder: (context, snapshot) {
              final progress = snapshot.data ?? PlaybackProgress.zero();

              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white.withOpacity(0.2),
                    ),
                    child: Slider(
                      value: progress.position.inMilliseconds.toDouble().clamp(
                        0.0,
                        progress.duration.inMilliseconds.toDouble(),
                      ),
                      min: 0.0,
                      max: progress.duration.inMilliseconds.toDouble() > 0
                          ? progress.duration.inMilliseconds.toDouble()
                          : 1.0,
                      onChanged: (value) {
                        _player.seek(Duration(milliseconds: value.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          progress.formattedPosition,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          progress.formattedDuration,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 10),

          // Botones de Control
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Shuffle Toggle
              StreamBuilder<bool>(
                stream: _player.shuffleModeStream,
                builder: (context, snapshot) {
                  final isShuffle = snapshot.data ?? false;
                  return IconButton(
                    icon: Icon(
                      Icons.shuffle,
                      color: isShuffle ? Colors.purpleAccent : Colors.white,
                    ),
                    onPressed: _player.toggleShuffle,
                  );
                },
              ),

              // Previous
              IconButton(
                icon: const Icon(
                  Icons.skip_previous_rounded,
                  color: Colors.white,
                  size: 42,
                ),
                onPressed: _player.skipToPrevious,
              ),

              // Play/Pause
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final state = snapshot.data ?? PlayerState.idle;
                  final isPlaying = state == PlayerState.playing;
                  final isBuffering =
                      state == PlayerState.buffering ||
                      state == PlayerState.loading;

                  return Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: IconButton(
                      icon: isBuffering
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 40,
                              color: Colors.black,
                            ),
                      onPressed: isPlaying ? _player.pause : _player.play,
                    ),
                  );
                },
              ),

              // Next
              IconButton(
                icon: const Icon(
                  Icons.skip_next_rounded,
                  color: Colors.white,
                  size: 42,
                ),
                onPressed: _player.skipToNext,
              ),

              // Repeat Mode
              StreamBuilder<RepeatMode>(
                stream: _player.repeatModeStream,
                builder: (context, snapshot) {
                  final mode = snapshot.data ?? RepeatMode.off;
                  IconData icon;
                  Color color;

                  switch (mode) {
                    case RepeatMode.one:
                      icon = Icons.repeat_one_rounded;
                      color = Colors.purpleAccent;
                      break;
                    case RepeatMode.all:
                      icon = Icons.repeat_rounded;
                      color = Colors.purpleAccent;
                      break;
                    case RepeatMode.off:
                      icon = Icons.repeat_rounded;
                      color = Colors.white38;
                      break;
                  }

                  return IconButton(
                    icon: Icon(icon, color: color),
                    onPressed: _player.toggleRepeat,
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Botón de Lyrics translúcido
          GestureDetector(
            onTap: () {
              _showLyricsSheet(context, song);
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lyrics, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        LanguageService().getText('show_lyrics'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Mostrar Lyrics Sheet
  void _showLyricsSheet(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => LyricsSheet(song: song, player: _player),
    );
  }

  // Mostrar diálogo para agregar a playlist
  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showDialog(
      context: context,
      builder: (context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 500),
              decoration: BoxDecoration(
                color: Colors.grey[900]!.withOpacity(0.95),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                  width: 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Título
                    Text(
                      LanguageService().getText('add_to_playlist'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Botón de nueva playlist
                    InkWell(
                      onTap: () {
                        Navigator.pop(context);
                        // TODO: Mostrar diálogo de crear playlist con la canción
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              LanguageService().getText('feature_coming_soon'),
                            ),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.purpleAccent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.purpleAccent.withOpacity(0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Colors.purpleAccent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.add_circle_outline,
                                color: Colors.purpleAccent,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              LanguageService().getText('new_playlist'),
                              style: const TextStyle(
                                color: Colors.purpleAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Lista de playlists
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: PlaylistService().playlists.map((playlist) {
                            // Verificar si la canción ya está en la playlist
                            final songExists = playlist.songs.any(
                              (s) => s.id == song.id,
                            );

                            return InkWell(
                              onTap: songExists
                                  ? null
                                  : () async {
                                      await PlaylistService().addSongToPlaylist(
                                        playlist.id,
                                        song,
                                      );
                                      if (mounted) {
                                        Navigator.pop(context);
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              LanguageService()
                                                  .getText('added_to')
                                                  .replaceFirst(
                                                    '%s',
                                                    playlist.name,
                                                  ),
                                            ),
                                            backgroundColor:
                                                Colors.purpleAccent,
                                          ),
                                        );
                                      }
                                    },
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: songExists
                                      ? Colors.white.withOpacity(0.03)
                                      : Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    // Imagen de la playlist
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1C1C1E),
                                        borderRadius: BorderRadius.circular(8),
                                        image: playlist.imagePath != null
                                            ? DecorationImage(
                                                image:
                                                    File(
                                                      playlist.imagePath!,
                                                    ).existsSync()
                                                    ? FileImage(
                                                        File(
                                                          playlist.imagePath!,
                                                        ),
                                                      )
                                                    : NetworkImage(
                                                            playlist.imagePath!,
                                                          )
                                                          as ImageProvider,
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                      ),
                                      child: playlist.imagePath == null
                                          ? const Icon(
                                              Icons.music_note,
                                              color: Colors.white54,
                                              size: 24,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 16),
                                    // Info de la playlist
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            playlist.name,
                                            style: TextStyle(
                                              color: songExists
                                                  ? Colors.white54
                                                  : Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "${playlist.songs.length} ${LanguageService().getText('songs')}",
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.5,
                                              ),
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Indicador si ya existe
                                    if (songExists)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.check_circle,
                                              color: Colors.green,
                                              size: 16,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              LanguageService().getText(
                                                'added',
                                              ),
                                              style: const TextStyle(
                                                color: Colors.green,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Botón cerrar
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          LanguageService().getText('cancel'),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
  // --- Metadata Update Feature ---

  void _showMetadataSearchDialog(BuildContext context, Song song) {
    final titleController = TextEditingController(text: song.title);
    final artistController = TextEditingController(text: song.artist);
    bool isLoading = false;
    Map<String, dynamic>? searchResult;
    String? errorMessage;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.all(24),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 500),
                  decoration: BoxDecoration(
                    color: Colors.grey[900]!.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                LanguageService().getText('update_metadata'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white54,
                                ),
                                onPressed: () => Navigator.pop(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: titleController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: LanguageService().getText('song'),
                              labelStyle: const TextStyle(
                                color: Colors.white70,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Colors.white.withOpacity(0.3),
                                ),
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Colors.purpleAccent,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: artistController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: LanguageService()
                                  .getText('playlist_desc')
                                  .replaceAll(
                                    'Descripción',
                                    'Artista',
                                  ), // Fallback
                              hintText: 'Artista',
                              labelStyle: const TextStyle(
                                color: Colors.white70,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Colors.white.withOpacity(0.3),
                                ),
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderSide: BorderSide(
                                  color: Colors.purpleAccent,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            icon: isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.search),
                            label: Text(LanguageService().getText('search')),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purpleAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: isLoading
                                ? null
                                : () async {
                                    setState(() {
                                      isLoading = true;
                                      errorMessage = null;
                                      searchResult = null;
                                    });
                                    final result = await ForanlyService()
                                        .searchMetadata(
                                          titleController.text,
                                          artistController.text,
                                        );
                                    setState(() {
                                      isLoading = false;
                                      searchResult = result;
                                      if (result == null) {
                                        errorMessage = LanguageService()
                                            .getText('no_results');
                                      }
                                    });
                                  },
                          ),
                          if (errorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                errorMessage!,
                                style: const TextStyle(color: Colors.redAccent),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          if (searchResult != null) ...[
                            const SizedBox(height: 20),
                            const Divider(color: Colors.white24),
                            const SizedBox(height: 10),
                            Text(
                              LanguageService().getText('results'),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 10),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child:
                                    searchResult!['albumArt'] != null &&
                                        searchResult!['albumArt']['data'] !=
                                            null
                                    ? Image.memory(
                                        Uint8List.fromList(
                                          List<int>.from(
                                            searchResult!['albumArt']['data'],
                                          ),
                                        ),
                                        width: 50,
                                        height: 50,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(
                                              Icons.music_note,
                                              color: Colors.white,
                                            ),
                                      )
                                    : (searchResult!['albumArtUrl'] != null
                                          ? Image.network(
                                              searchResult!['albumArtUrl'],
                                              width: 50,
                                              height: 50,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                    Icons.music_note,
                                                    color: Colors.white,
                                                  ),
                                            )
                                          : const Icon(
                                              Icons.music_note,
                                              color: Colors.white,
                                              size: 50,
                                            )),
                              ),
                              title: Text(
                                searchResult!['title'] ?? 'Unknown',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                searchResult!['artist'] ?? 'Unknown',
                                style: const TextStyle(color: Colors.white70),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.check_circle,
                                  color: Colors.greenAccent,
                                  size: 32,
                                ),
                                onPressed: () {
                                  _applyMetadata(context, song, searchResult!);
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _applyMetadata(
    BuildContext context,
    Song song,
    Map<String, dynamic> metadata,
  ) async {
    // 1. Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Colors.purpleAccent),
      ),
    );

    try {
      // 2. Download artwork if URL provided (and not already bytes)
      List<int>? artworkBytes;

      if (metadata['albumArt'] != null &&
          metadata['albumArt']['data'] != null) {
        artworkBytes = List<int>.from(metadata['albumArt']['data']);
      } else if (metadata['albumArtUrl'] != null) {
        try {
          final resp = await http
              .get(Uri.parse(metadata['albumArtUrl']))
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            artworkBytes = resp.bodyBytes;
          }
        } catch (e) {
          print('Error downloading artwork: $e');
        }
      }

      // 3. Write tags using AudioTags
      String path = song.filePath;
      bool isSaf = path.startsWith('content://');

      File? tempFile;
      String targetPath = path;

      if (isSaf) {
        // Create temp file
        final tempDir = await getTemporaryDirectory();
        final tempName = 'temp_${DateTime.now().millisecondsSinceEpoch}.mp3';
        tempFile = File('${tempDir.path}/$tempName');

        // Copy content from SAF to temp
        final success = await SafHelper.copyUriToFile(path, tempFile.path);
        if (!success) throw Exception("Failed to copy SAF file to temp");

        targetPath = tempFile.path;
      } else {
        if (path.startsWith('file://')) {
          targetPath = path.replaceFirst('file://', '');
        }
        if (!File(targetPath).existsSync()) {
          throw Exception("File not found at $targetPath");
        }
      }

      // Update Tags
      final tag = Tag(
        title: metadata['title'],
        trackArtist: metadata['artist'],
        album: metadata['album'],
        year: int.tryParse(metadata['year']?.toString() ?? ''),
        trackNumber: int.tryParse(metadata['trackNumber']?.toString() ?? ''),
        pictures: artworkBytes != null
            ? [
                Picture(
                  bytes: Uint8List.fromList(artworkBytes),
                  mimeType: MimeType.jpeg,
                  pictureType: PictureType.coverFront,
                ),
              ]
            : [],
      );

      await AudioTags.write(targetPath, tag);

      if (isSaf && tempFile != null) {
        // Write back to SAF
        final success = await SafHelper.overwriteFileFromPath(path, targetPath);
        if (!success) throw Exception("Failed to write back to SAF file");

        // Cleanup
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      // 4. Update Cache & UI
      // CRITICAL: Delete ALL cache layers for this song FIRST
      final cacheKey = song.filePath.hashCode.toString();

      // Delete from persistent cache
      await MusicMetadataCache.delete(cacheKey);

      // Delete from MetadataService memory cache
      MetadataService().clearCacheEntry(cacheKey);

      // Now reload fresh metadata from the file we just modified
      await MetadataService().loadMetadata(
        id: cacheKey,
        filePath: song.filePath.startsWith('content://') ? null : song.filePath,
        safUri: song.filePath.startsWith('content://') ? song.filePath : null,
        forceReload: true,
      );

      // Update Player UI
      await AudioPlayerService().refreshCurrentSongMetadata();

      // Notify Library to update song in list
      MusicLibraryService.onMetadataUpdated.value = song.filePath;
      // Force trigger even if same path (hacky but safer for re-edits)
      // MusicLibraryService.onMetadataUpdated.notifyListeners(); // Not accessible on ValueNotifier easily without extending

      if (mounted) {
        // Close Loading
        Navigator.of(context).pop();
        // Close Search Dialog
        Navigator.of(context).pop();
        // Close Menu (optional, usually implied)

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(LanguageService().getText('metadata_updated')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close Loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${LanguageService().getText('metadata_update_error')}: $e',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      print('Metadata update error: $e');
    }
  }
}
