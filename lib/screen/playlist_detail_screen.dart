import 'dart:io';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

import '../models/playlist_model.dart';
import '../models/song_model.dart';
import '../services/playlist_service.dart';
import '../services/global_music_player.dart';
import '../services/global_metadata_service.dart';
// For GlobalTheme/etc if needed? No, avoid circle if possible.

/// Pantalla de detalles de Playlist (Versión Desktop/Windows)
class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  Color? _dominantColor;
  double _imageScale = 1.0;
  String? _lastImagePath;

  // Search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _lastImagePath = widget.playlist.imagePath;
    PlaylistService().addListener(_onPlaylistChanged);
    _loadCachedColorOrExtract();
    _scrollController.addListener(_onScroll);
    _preloadSongMetadata();
  }

  /// Pre-cargar metadatos usando servicio global (limitado a 50)
  Future<void> _preloadSongMetadata() async {
    final paths = widget.playlist.songs.map((s) => s.filePath).toList();
    await GlobalMetadataService().preloadBatch(paths, limit: 50);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    PlaylistService().removeListener(_onPlaylistChanged);
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final newScale = (1.0 - (offset / 600)).clamp(0.5, 1.0);
    if (newScale != _imageScale) {
      setState(() => _imageScale = newScale);
    }
  }

  void _onPlaylistChanged() {
    if (mounted) {
      final updatedPlaylist = _currentPlaylist;
      if (updatedPlaylist.imagePath != _lastImagePath) {
        _lastImagePath = updatedPlaylist.imagePath;
        _loadCachedColorOrExtract();
      }
      // Recargar metadatos si hay nuevas canciones
      _preloadSongMetadata();
      setState(() {});
    }
  }

  Playlist get _currentPlaylist {
    try {
      return PlaylistService().playlists.firstWhere(
        (p) => p.id == widget.playlist.id,
      );
    } catch (e) {
      return widget.playlist;
    }
  }

  Future<void> _loadCachedColorOrExtract() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = 'playlist_color_${widget.playlist.id}';
    final cachedColorValue = prefs.getInt(cacheKey);

    if (cachedColorValue != null) {
      if (mounted) setState(() => _dominantColor = Color(cachedColorValue));
    } else {
      await _extractDominantColor();
    }
  }

  Future<void> _extractDominantColor() async {
    try {
      ImageProvider? imageProvider;
      final currentPlaylist = _currentPlaylist;

      if (currentPlaylist.imagePath != null) {
        if (currentPlaylist.imagePath!.startsWith('http')) {
          imageProvider = NetworkImage(currentPlaylist.imagePath!);
        } else if (File(currentPlaylist.imagePath!).existsSync()) {
          imageProvider = FileImage(File(currentPlaylist.imagePath!));
        }
      }

      if (imageProvider != null) {
        final paletteGenerator = await PaletteGenerator.fromImageProvider(
          imageProvider,
          size: const Size(200, 200),
          maximumColorCount: 20,
        );

        final extractedColor =
            paletteGenerator.dominantColor?.color ??
            paletteGenerator.vibrantColor?.color ??
            Colors.purple;

        final darkenedColor = _darkenColor(extractedColor, 0.4);

        final prefs = await SharedPreferences.getInstance();
        final cacheKey = 'playlist_color_${currentPlaylist.id}';
        await prefs.setInt(cacheKey, darkenedColor.value);

        if (mounted) setState(() => _dominantColor = darkenedColor);
      }
    } catch (e) {
      // ignore
    }
  }

  Color _darkenColor(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    final darkened = hsl.withLightness(
      (hsl.lightness * (1 - amount)).clamp(0.0, 1.0),
    );
    return darkened.toColor();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _currentPlaylist;
    final themeColor = _dominantColor ?? const Color(0xFF1C1C1E);

    // Filter songs
    final songs = playlist.songs.where((s) {
      if (_searchQuery.isEmpty) return true;
      return s.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          s.artist.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      backgroundColor: Colors.black, // Or transparent if needed
      body: Stack(
        children: [
          // Background gradient
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [themeColor.withOpacity(0.6), Colors.black],
                  stops: const [0.0, 0.6],
                ),
              ),
            ),
          ),

          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                expandedHeight: 300,
                backgroundColor: Colors.transparent,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(
                  background: Padding(
                    padding: const EdgeInsets.only(top: 80, bottom: 20),
                    child: Center(
                      child: Transform.scale(
                        scale: _imageScale,
                        child: _buildPlaylistImage(playlist),
                      ),
                    ),
                  ),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => _showEditPlaylistDialog(context, playlist),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => _showAddSongsDialog(context, playlist),
                  ),
                ],
              ),

              // Playlist Info
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        playlist.name,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (playlist.description != null)
                        Text(
                          playlist.description!,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        "${playlist.songs.length} Songs",
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.grey,
                          ),
                          hintText: "Search in playlist",
                          hintStyle: const TextStyle(color: Colors.grey),
                          fillColor: Colors.white.withOpacity(0.1),
                          filled: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        style: const TextStyle(color: Colors.white),
                        onChanged: (val) => setState(() => _searchQuery = val),
                      ),
                    ],
                  ),
                ),
              ),

              // Song List
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final song = songs[index];
                    return ListTile(
                      key: ValueKey(song.id), // Prevent rebuilds on scroll
                      leading: _buildSongArt(song),
                      title: Text(
                        song.title,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        song.artist,
                        style: const TextStyle(color: Colors.grey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.remove_circle_outline,
                          color: Colors.redAccent,
                        ),
                        onPressed: () => PlaylistService()
                            .removeSongFromPlaylist(playlist.id, song.id),
                      ),
                      onTap: () {
                        // Play Logic
                        final files = songs
                            .map((s) => File(s.filePath))
                            .toList();
                        GlobalMusicPlayer().playPlaylist(files, index);
                      },
                    );
                  },
                  childCount: songs.length,
                  addRepaintBoundaries:
                      true, // Evita repintar widgets fuera de vista
                  addAutomaticKeepAlives: true, // Mantiene widgets en memoria
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistImage(Playlist playlist) {
    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20),
        ],
        image: playlist.imagePath != null
            ? DecorationImage(
                image: playlist.getImageProvider() ?? const NetworkImage(''),
                fit: BoxFit.cover,
              )
            : null,
        color: Colors.grey[800],
      ),
      child: playlist.imagePath == null
          ? const Icon(Icons.music_note, size: 80, color: Colors.white24)
          : null,
    );
  }

  Widget _buildSongArt(Song song) {
    // Usar un widget stateful que cachee el artwork
    return _CachedSongArtwork(key: ValueKey(song.id), song: song);
  }

  Future<void> _showEditPlaylistDialog(
    BuildContext context,
    Playlist playlist,
  ) async {
    final nameController = TextEditingController(text: playlist.name);
    final descController = TextEditingController(text: playlist.description);
    String? selectedImagePath = playlist.imagePath;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1C1C1E),
              title: const Text(
                "Edit Playlist",
                style: TextStyle(color: Colors.white),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () async {
                        final picker = ImagePicker();
                        final image = await picker.pickImage(
                          source: ImageSource.gallery,
                        );
                        if (image != null)
                          setState(() => selectedImagePath = image.path);
                      },
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(8),
                          image: selectedImagePath != null
                              ? DecorationImage(
                                  image: File(selectedImagePath!).existsSync()
                                      ? FileImage(File(selectedImagePath!))
                                      : NetworkImage(selectedImagePath!)
                                            as ImageProvider,
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: selectedImagePath == null
                            ? const Icon(Icons.add_a_photo, color: Colors.white)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "Name",
                        labelStyle: TextStyle(color: Colors.grey),
                      ),
                    ),
                    TextField(
                      controller: descController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "Description",
                        labelStyle: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Cancel"),
                ),
                TextButton(
                  onPressed: () {
                    if (nameController.text.isNotEmpty) {
                      PlaylistService().updatePlaylist(
                        playlist.id,
                        name: nameController.text,
                        description: descController.text,
                        imagePath: selectedImagePath,
                      );
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAddSongsDialog(
    BuildContext context,
    Playlist playlist,
  ) async {
    // Obtener todas las canciones desde el servicio global
    final allSongs = GlobalMusicPlayer().songsList.value;

    if (allSongs.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay canciones en la librería. Carga una carpeta primero.',
          ),
        ),
      );
      return;
    }

    // Filtrar canciones que ya están en la playlist
    final playlistSongIds = playlist.songs.map((s) => s.id).toSet();
    final availableSongs = allSongs
        .where((s) => !playlistSongIds.contains(s.id))
        .toList();

    final Set<String> selectedPaths = {};

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1C1C1E),
              title: Text(
                "Add Songs (${availableSongs.length} available)",
                style: const TextStyle(color: Colors.white),
              ),
              content: SizedBox(
                width: 500,
                height: 400,
                child: availableSongs.isEmpty
                    ? const Center(
                        child: Text(
                          "No new songs found",
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: availableSongs.length,
                        itemBuilder: (context, index) {
                          final song = availableSongs[index];
                          final isSelected = selectedPaths.contains(
                            song.filePath,
                          );

                          return ListTile(
                            title: Text(
                              song.title,
                              style: const TextStyle(color: Colors.white),
                              maxLines: 1,
                            ),
                            subtitle: Text(
                              song.artist,
                              style: const TextStyle(color: Colors.white70),
                              maxLines: 1,
                            ),
                            leading: Icon(
                              isSelected
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color: isSelected
                                  ? Colors.purpleAccent
                                  : Colors.grey,
                            ),
                            onTap: () {
                              setState(() {
                                if (isSelected) {
                                  selectedPaths.remove(song.filePath);
                                } else {
                                  selectedPaths.add(song.filePath);
                                }
                              });
                            },
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Cancel"),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    if (selectedPaths.isNotEmpty) {
                      for (final path in selectedPaths) {
                        final file = File(path);
                        // Create song model
                        final song = await Song.fromFile(file);
                        if (song != null) {
                          await PlaylistService().addSongToPlaylist(
                            playlist.id,
                            song,
                          );
                        }
                      }
                    }
                  },
                  child: Text("Add (${selectedPaths.length})"),
                ),
              ],
            );
          },
        );
      },
    );
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
      future: GlobalMetadataService().get(widget.song.filePath),
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
