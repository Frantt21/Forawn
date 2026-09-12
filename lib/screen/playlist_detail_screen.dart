import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist_model.dart';
import '../models/song_model.dart';
import '../services/playlist_service.dart';
import '../services/global_music_player.dart';
import '../services/local_music_database.dart';
import '../widgets/app_title_bar.dart';
import '../widgets/add_songs_sheet.dart';
import '../widgets/playlist_dialogs.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;
  final bool isReadOnly;
  final String Function(String key, {String? fallback}) getText;
  final VoidCallback? onBack;

  /// Color ya cacheado de la playlist (leído ANTES de hacer push). Evita el
  /// retraso del color de fondo: la screen abre ya tintada en el primer frame
  /// en vez de empezar con el fallback y cambiar al llegar el async.
  final Color? initialColor;

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.getText,
    this.isReadOnly = false,
    this.onBack,
    this.initialColor,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  Color? _dominantColor;
  double _imageScale = 1.0;
  String? _lastImagePath;

  // Search
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  String _searchQuery = '';
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _lastImagePath = widget.playlist.imagePath;
    // El color se inyecta sincrónicamente desde la screen que abre esta
    // (sin retraso del primer frame); el async solo extrae si no había.
    if (widget.initialColor != null) {
      _dominantColor = widget.initialColor;
    } else {
      _loadCachedColorOrExtract();
    }
    PlaylistService().addListener(_onPlaylistChanged);
    // Inicializar animación de búsqueda
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _scrollController.addListener(_onScroll);
    _preloadSongMetadata();
  }

  /// Pre-cargar metadatos usando servicio global (limitado a 50)
  Future<void> _preloadSongMetadata() async {
    final paths = widget.playlist.songs.map((s) => s.filePath).toList();
    await LocalMusicDatabase().preloadBatch(paths.take(50).toList());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _animationController.dispose();
    PlaylistService().removeListener(_onPlaylistChanged);
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    // La imagen comienza a encogerse inmediatamente
    // Ajustar 600 según la altura del área de cabecera
    final newScale = (1.0 - (offset / 600)).clamp(0.5, 1.0);

    if (newScale != _imageScale) {
      if (mounted)
        setState(() {
          _imageScale = newScale;
        });
    }
  }

  void _onPlaylistChanged() {
    if (mounted) setState(() {});

    // Si la imagen cambió, recalcular color
    final currentPlaylist = _currentPlaylist;
    if (currentPlaylist.imagePath != _lastImagePath) {
      _lastImagePath = currentPlaylist.imagePath;
      _extractAndSaveColor();
    }
  }

  Playlist get _currentPlaylist {
    try {
      if (widget.isReadOnly)
        return widget.playlist; // Don't look up in service if virtual
      return PlaylistService().playlists.firstWhere(
        (p) => p.id == widget.playlist.id,
        orElse: () => widget.playlist,
      );
    } catch (e) {
      return widget.playlist;
    }
  }

  Future<void> _loadCachedColorOrExtract() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'playlist_color_${widget.playlist.id}';
      final cachedValue = prefs.getInt(cacheKey);

      if (cachedValue != null) {
        if (mounted) setState(() => _dominantColor = Color(cachedValue));
      } else {
        await _extractAndSaveColor();
      }
    } catch (e) {
      debugPrint("Error loading color: $e");
    }
  }

  Future<void> _extractAndSaveColor() async {
    final playlist = _currentPlaylist;
    if (playlist.imagePath == null) return;

    try {
      ImageProvider? provider;
      final path = playlist.imagePath!;

      if (path.startsWith('http')) {
        provider = NetworkImage(path);
      } else if (File(path).existsSync()) {
        provider = FileImage(File(path));
      }

      if (provider != null) {
        final paletteGenerator = await PaletteGenerator.fromImageProvider(
          provider,
          size: const Size(200, 200),
          maximumColorCount: 20,
        );

        final extractedColor =
            paletteGenerator.dominantColor?.color ??
            paletteGenerator.vibrantColor?.color ??
            Colors.purple;

        final darkened = _darkenColor(extractedColor, 0.4);

        if (mounted) {
          setState(() => _dominantColor = darkened);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('playlist_color_${playlist.id}', darkened.value);
        }
      }
    } catch (e) {
      debugPrint("Error extracting color: $e");
    }
  }

  Color _darkenColor(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    final darkened = hsl.withLightness(
      (hsl.lightness * (1 - amount)).clamp(0.0, 1.0),
    );
    return darkened.toColor();
  }

  Widget _buildSearchField(Color textColor) {
    return AnimatedBuilder(
      key: const ValueKey('search'),
      animation: _animationController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(
            (1 - _fadeAnimation.value) * 300,
            0,
          ), // Slide from right
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: TextStyle(color: textColor, fontSize: 16),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: widget.getText(
                  'search_songs',
                  fallback: 'Search songs...',
                ),
                hintStyle: TextStyle(
                  color: textColor.withOpacity(0.5),
                  fontSize: 16,
                ),
                prefixIcon: Icon(Icons.search, color: textColor, size: 20),
                filled: true,
                fillColor: textColor.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    24,
                  ), // Redondeado como botones, igual que forawn_mobile
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: textColor.withOpacity(0.7),
                          size: 20,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _currentPlaylist;
    // Para favoritos, fondo gris neutro (sin el morado)
    final themeColor = playlist.id == 'favorites'
        ? const Color(0xFF2C2C2E)
        : (_dominantColor ?? const Color(0xFF1C1C1E));
    final isDark = themeColor.computeLuminance() < 0.5;
    final textColor = isDark ? Colors.white : Colors.black;

    // Botones estilo forawn_mobile: color de acento = color de texto
    // (blanco en tema oscuro, negro en tema claro).
    final isFavorites = playlist.id == 'favorites';
    final buttonColor = textColor;
    final buttonTextColor = isDark ? Colors.black : Colors.white;

    // Filter songs
    final songs = playlist.songs.where((s) {
      if (_searchQuery.isEmpty) return true;
      return s.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          s.artist.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      backgroundColor: themeColor,
      body: Column(
        children: [
          // Misma title bar de la app, tintada con el color de la playlist.
          AppTitleBar(
            title: _isSearching
                ? _buildSearchField(textColor)
                : Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            tintColor: themeColor,
            windowBackgroundColor: themeColor,
            getText: widget.getText,
            // Botón back en la posición del botón de cerrar (X), igual que
            // settings/downloads. El leading se reserva para búsqueda/etc.
            onBack: () {
              if (_isSearching) {
                setState(() {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                  _animationController.reverse();
                });
              } else {
                if (widget.onBack != null) {
                  widget.onBack!();
                } else {
                  Navigator.pop(context);
                }
              }
            },
            leading: null,
            actions: [
              if (!_isSearching) ...[
                IconButton(
                  icon: const Icon(Icons.search, size: 20),
                  onPressed: () {
                    setState(() {
                      _isSearching = true;
                      _animationController.forward();
                    });
                  },
                ),
                if (!widget.isReadOnly)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (value) async {
                      if (value == 'edit') {
                        _showEditPlaylistDialog(context, playlist);
                      } else if (value == 'add') {
                        _showAddSongsDialog(context, playlist);
                      }
                    },
                    itemBuilder: (BuildContext context) {
                      return [
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, color: Colors.black54),
                              SizedBox(width: 8),
                              Text(
                                widget.getText(
                                  'edit_playlist',
                                  fallback: 'Edit Playlist',
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'add',
                          child: Row(
                            children: [
                              Icon(Icons.add, color: Colors.black54),
                              SizedBox(width: 8),
                              Text(
                                widget.getText(
                                  'add_songs',
                                  fallback: 'Add Songs',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ];
                    },
                  ),
              ],
            ],
          ),
          Expanded(
            child: Stack(
              children: [
                // Background flat color
                Positioned.fill(child: Container(color: themeColor)),

          CustomScrollView(
            controller: _scrollController,
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
                    child: Column(
                      children: [
                        // Portada con animación de tamaño
                        Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            width: 250 * _imageScale,
                            height: 250 * _imageScale,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.5),
                                  blurRadius: 30,
                                  offset: const Offset(0, 15),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: playlist.imagePath != null
                                  ? Image(
                                      image:
                                          playlist.getImageProvider() ??
                                          const NetworkImage(''),
                                      fit: BoxFit.cover,
                                    )
                                  : Container(
                                      color: playlist.id == 'favorites'
                                          ? Colors.purpleAccent
                                          : Colors.grey[800],
                                      child: Icon(
                                        playlist.id == 'favorites'
                                            ? Icons.favorite
                                            : Icons.music_note,
                                        size: 100 * _imageScale,
                                        color: Colors.white.withOpacity(0.5),
                                      ),
                                    ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        Text(
                          playlist.name,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        // Ignorar descripciones vacías o de solo espacios:
                        // un Text('') reserva su lineHeight y crea un gap
                        // extra entre el título y la línea de songs/duración.
                        if (playlist.description != null &&
                            playlist.description!.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              playlist.description!,
                              style: const TextStyle(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        const SizedBox(height: 16),
                        Text(
                          "${playlist.songs.length} ${playlist.songs.length == 1 ? widget.getText('song', fallback: 'Song') : widget.getText('songs', fallback: 'Songs')}${_playlistDurationSuffix(playlist.songs)}",
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 20),
                        // Action Buttons (estilo forawn_mobile):
                        // - Play: píldora primaria rellena
                        // - Favoritos: Shuffle como píldora secundaria
                        // - Otras playlist: Shuffle + Add como círculos
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildPrimaryPlayButton(
                              label: widget.getText(
                                'play',
                                fallback: 'Play',
                              ),
                              backgroundColor: buttonColor,
                              foregroundColor: buttonTextColor,
                              onPressed: playlist.songs.isEmpty
                                  ? null
                                  : () {
                                      final files = playlist.songs
                                          .map((s) => File(s.filePath))
                                          .toList();
                                      GlobalMusicPlayer().playPlaylist(
                                        files,
                                        0,
                                      );
                                    },
                            ),
                            const SizedBox(width: 12),
                            if (isFavorites)
                              _buildShufflePill(
                                label: widget.getText(
                                  'shuffle',
                                  fallback: 'Shuffle',
                                ),
                                color: buttonColor,
                                onPressed: playlist.songs.isEmpty
                                    ? null
                                    : () {
                                        final files = playlist.songs
                                            .map((s) => File(s.filePath))
                                            .toList();
                                        GlobalMusicPlayer().playPlaylist(
                                          files,
                                          Random().nextInt(files.length),
                                        );
                                        GlobalMusicPlayer().isShuffle.value =
                                            true;
                                      },
                              )
                            else ...[
                              _buildCircularButton(
                                icon: Icons.shuffle,
                                color: buttonColor,
                                onPressed: playlist.songs.isEmpty
                                    ? null
                                    : () {
                                        final files = playlist.songs
                                            .map((s) => File(s.filePath))
                                            .toList();
                                        GlobalMusicPlayer().playPlaylist(
                                          files,
                                          Random().nextInt(files.length),
                                        );
                                        GlobalMusicPlayer().isShuffle.value =
                                            true;
                                      },
                              ),
                              const SizedBox(width: 12),
                              _buildCircularButton(
                                icon: Icons.add,
                                color: buttonColor,
                                onPressed: () => _showAddSongsDialog(
                                  context,
                                  playlist,
                                ),
                              ),
                            ],
                          ],
                        ),
                        // Removed TextField from here
                      ],
                    ),
                  ),
                ),
              ),

              // Song List
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final song = songs[index];
                    return FutureBuilder<SongMetadata?>(
                      future: LocalMusicDatabase().getMetadata(song.filePath),
                      builder: (context, snapshot) {
                        final metadata = snapshot.data;
                        final title = metadata?.title ?? song.title;
                        final artist = metadata?.artist ?? song.artist;
                        final artwork = metadata?.artwork;

                        return ListTile(
                          key: ValueKey(song.id),
                          leading: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.grey[800],
                              image: artwork != null
                                  ? DecorationImage(
                                      image: MemoryImage(artwork),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: artwork == null
                                ? const Icon(
                                    Icons.music_note,
                                    color: Colors.white24,
                                  )
                                : null,
                          ),
                          title: Text(
                            title,
                            style: const TextStyle(color: Colors.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            artist,
                            style: const TextStyle(color: Colors.white70),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing:
                              (widget.isReadOnly && playlist.id != 'favorites')
                              ? null
                              : PopupMenuButton<String>(
                                  icon: const Icon(
                                    Icons.more_vert,
                                    color: Colors.white70,
                                  ),
                                  onSelected: (value) async {
                                    if (value == 'remove') {
                                      await PlaylistService()
                                          .removeSongFromPlaylist(
                                            playlist.id,
                                            song.id,
                                          );
                                    }
                                  },
                                  itemBuilder: (BuildContext context) =>
                                      <PopupMenuEntry<String>>[
                                        PopupMenuItem<String>(
                                          value: 'remove',
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.delete_outline,
                                                color: Colors.redAccent,
                                              ),
                                              SizedBox(width: 12),
                                              Text(
                                                widget.getText(
                                                  'remove_from_playlist',
                                                  fallback:
                                                      'Remove from playlist',
                                                ),
                                                style: TextStyle(
                                                  color: Colors.redAccent,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                ),
                          onTap: () {
                            final files = songs
                                .map((s) => File(s.filePath))
                                .toList();
                            GlobalMusicPlayer().playPlaylist(files, index);
                          },
                        );
                      },
                    );
                  },
                  childCount: songs.length,
                  addRepaintBoundaries: true,
                  addAutomaticKeepAlives: true,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
              ],
            ),
        ),
      ],
    ),
  );
  }

  Future<void> _showEditPlaylistDialog(
    BuildContext context,
    Playlist playlist,
  ) async {
    // Diálogo EDITAR unificado (ForawnDialog): mismo estilo y tamaño que
    // crear/agregar canciones.
    await showDialog(
      context: context,
      builder: (_) => PlaylistEditDialog(
        playlist: playlist,
        getText: widget.getText,
        accentColor: _getAccentColor(),
      ),
    );
  }

  /// Sufijo de duración total de la playlist (como forawn_mobile):
  /// " · 1:23:45". Vacío si ninguna canción tiene duración.
  String _playlistDurationSuffix(List<Song> songs) {
    var total = Duration.zero;
    var hasDuration = false;
    for (final song in songs) {
      if (song.duration != null) {
        total += song.duration!;
        hasDuration = true;
      }
    }
    if (!hasDuration) return '';
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    final seconds = total.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return hours > 0 ? ' · $hours:$mm:$ss' : ' · $mm:$ss';
  }

  /// Píldora primaria (Play) — mismo estilo que forawn_mobile.
  Widget _buildPrimaryPlayButton({
    required String label,
    required Color backgroundColor,
    required Color foregroundColor,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 44,
      width: 150,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(Icons.play_arrow, size: 24, color: foregroundColor),
        label: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: foregroundColor,
            fontWeight: FontWeight.bold,
            fontSize: 14,
            letterSpacing: 1.0,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          elevation: 2,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      ),
    );
  }

  /// Botón circular (Shuffle / Add) — mismo estilo que forawn_mobile.
  Widget _buildCircularButton({
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: color, size: 22),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
      ),
    );
  }

  /// Píldora secundaria (Shuffle en favoritos) — forawn_mobile.
  Widget _buildShufflePill({
    required String label,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 44,
      width: 130,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(Icons.shuffle, size: 20, color: color),
        label: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
            letterSpacing: 1.0,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: color.withOpacity(0.15),
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Future<void> _showAddSongsDialog(
    BuildContext context,
    Playlist playlist,
  ) async {
    return AddSongsDialog.show(
      context,
      playlist: playlist,
      getText: widget.getText,
      accentColor: _getAccentColor(),
    );
  }

  Color _getAccentColor() {
    final isFavorites = widget.playlist.id == 'favorites';
    final rawColor = isFavorites
        ? Colors.purpleAccent
        : (_dominantColor ?? Colors.purpleAccent);
    final hsl = HSLColor.fromColor(rawColor);

    // Ensure the color is bright enough for dark background bottom sheets
    if (hsl.lightness < 0.5) {
      return hsl.withLightness(0.6).toColor();
    }
    return rawColor;
  }
}

/// Widget stateful que cachea el artwork para evitar reconstrucciones
class _CachedSongArtwork extends StatefulWidget {
  final Song song;

  const _CachedSongArtwork({super.key, required this.song});

  @override
  State<_CachedSongArtwork> createState() => _CachedSongArtworkState();
}

class _CachedSongArtworkState extends State<_CachedSongArtwork>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // Mantener el estado vivo

  @override
  Widget build(BuildContext context) {
    super.build(context); // Requerido por AutomaticKeepAliveClientMixin

    // Si Song tiene artwork embebido, usarlo directamente
    if (widget.song.artworkData != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          widget.song.artworkData!,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
        ),
      );
    }

    // Si no, cargar desde servicio global UNA SOLA VEZ
    return FutureBuilder(
      future: LocalMusicDatabase().getMetadata(widget.song.filePath),
      builder: (context, snapshot) {
        final art = snapshot.data?.artwork;
        if (art != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.memory(art, width: 48, height: 48, fit: BoxFit.cover),
          );
        }

        return Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(Icons.music_note, color: Colors.grey),
        );
      },
    );
  }
}
