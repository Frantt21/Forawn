import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../models/song_model.dart';
import '../services/playlist_service.dart';
import '../services/global_music_player.dart';
import '../services/local_music_database.dart';

typedef TextGetter = String Function(String key, {String? fallback});

/// Bottom sheet "Agregar canciones" — réplica del AddSongsSheet de
/// forawn_mobile: drag handle, header con cierre, búsqueda, contador de
/// seleccionadas con chips Todas/Ninguna, lista con artwork + checkbox y
/// acciones flotantes (Cancelar / Agregar) al fondo.
class AddSongsSheet extends StatefulWidget {
  final Playlist playlist;
  final TextGetter getText;

  final Color? backgroundColor;
  final Color? accentColor;

  const AddSongsSheet({
    super.key,
    required this.playlist,
    required this.getText,
    this.backgroundColor,
    this.accentColor,
  });

  static Future<void> show(
    BuildContext context, {
    required Playlist playlist,
    required TextGetter getText,
    Color? backgroundColor,
    Color? accentColor,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddSongsSheet(
        playlist: playlist,
        getText: getText,
        backgroundColor: backgroundColor,
        accentColor: accentColor,
      ),
    );
  }

  @override
  State<AddSongsSheet> createState() => _AddSongsSheetState();
}

class _AddSongsSheetState extends State<AddSongsSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<Song> _availableSongs = [];
  List<Song> _filteredSongs = [];
  final Set<Song> _selectedSongs = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSongs() async {
    // Asegurar que la librería global esté cargada (barato si ya lo está).
    try {
      await GlobalMusicPlayer().loadLibraryIfNeeded();
    } catch (_) {}

    final allSongs = GlobalMusicPlayer().songsList.value;
    final playlistSongIds = widget.playlist.songs.map((s) => s.id).toSet();

    _availableSongs =
        allSongs.where((s) => !playlistSongIds.contains(s.id)).toList();
    _filteredSongs = List.from(_availableSongs);

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _filterSongs(String query) {
    if (query.isEmpty) {
      setState(() {
        _filteredSongs = List.from(_availableSongs);
      });
      return;
    }

    final lowerQuery = query.toLowerCase();
    setState(() {
      _filteredSongs = _availableSongs.where((song) {
        return song.title.toLowerCase().contains(lowerQuery) ||
            song.artist.toLowerCase().contains(lowerQuery);
      }).toList();
    });
  }

  Future<void> _addSelectedSongs() async {
    if (_selectedSongs.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      for (final song in _selectedSongs) {
        await PlaylistService().addSongToPlaylist(widget.playlist.id, song);
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF2C2C2E),
            content: Text(
              '${_selectedSongs.length} ${widget.getText(
                'songs_added',
                fallback: 'canciones agregadas',
              )}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildBottomFloatingActions(BuildContext context) {
    if (_availableSongs.isEmpty || _isLoading) return const SizedBox.shrink();

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? Colors.grey[900],
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  widget.getText('cancel', fallback: 'Cancelar'),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.accentColor ?? Colors.purpleAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  disabledBackgroundColor:
                      (widget.accentColor ?? Colors.purpleAccent)
                          .withOpacity(0.3),
                ),
                onPressed: _selectedSongs.isEmpty ? null : _addSelectedSongs,
                child: Text(
                  widget.getText('add', fallback: 'Agregar'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final accent = widget.accentColor ?? Colors.purpleAccent;

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) {
        return BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              color: widget.backgroundColor ?? Colors.grey[900],
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: Column(
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.getText('add_songs', fallback: 'Agregar canciones'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.05),
                        ),
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),

                // Search bar
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      cursorColor: accent,
                      decoration: InputDecoration(
                        hintText: widget.getText('search', fallback: 'Buscar'),
                        hintStyle: TextStyle(
                          color: Colors.white.withOpacity(0.2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        border: InputBorder.none,
                        prefixIcon: Icon(
                          Icons.search,
                          color: Colors.white.withOpacity(0.5),
                          size: 20,
                        ),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: Icon(
                                  Icons.clear,
                                  color: Colors.white.withOpacity(0.5),
                                ),
                                onPressed: () {
                                  _searchController.clear();
                                  _filterSongs('');
                                },
                              )
                            : null,
                      ),
                      onChanged: _filterSongs,
                    ),
                  ),
                ),

                // Selected count and actions row (siempre visible para evitar saltos)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_selectedSongs.length} ${widget.getText('selected', fallback: 'seleccionadas')}',
                          style: TextStyle(
                            color: accent,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Select All Button
                      GestureDetector(
                        onTap: (_filteredSongs.isEmpty ||
                                _selectedSongs.length == _filteredSongs.length)
                            ? null
                            : () {
                                setState(() {
                                  _selectedSongs.addAll(_filteredSongs);
                                });
                              },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: (_filteredSongs.isEmpty ||
                                    _selectedSongs.length ==
                                        _filteredSongs.length)
                                ? Colors.white.withOpacity(0.05)
                                : Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            widget.getText('select_all', fallback: 'Todas'),
                            style: TextStyle(
                              color: (_filteredSongs.isEmpty ||
                                      _selectedSongs.length ==
                                          _filteredSongs.length)
                                  ? Colors.white30
                                  : Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Deselect All Button
                      GestureDetector(
                        onTap: _selectedSongs.isEmpty
                            ? null
                            : () {
                                setState(() {
                                  _selectedSongs.clear();
                                });
                              },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _selectedSongs.isEmpty
                                ? Colors.white.withOpacity(0.05)
                                : Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            widget.getText('deselect_all', fallback: 'Ninguna'),
                            style: TextStyle(
                              color: _selectedSongs.isEmpty
                                  ? Colors.white30
                                  : Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Songs list
                Expanded(
                  child: _isLoading
                      ? Center(
                          child: CircularProgressIndicator(color: accent),
                        )
                      : _availableSongs.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.library_music_outlined,
                                    size: 64,
                                    color: Colors.white.withOpacity(0.2),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    widget.getText(
                                      'no_songs_to_add',
                                      fallback:
                                          'No hay canciones para agregar',
                                    ),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : _filteredSongs.isEmpty
                              ? Center(
                                  child: Text(
                                    widget.getText(
                                      'no_results',
                                      fallback: 'Sin resultados',
                                    ),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  controller: controller,
                                  padding: EdgeInsets.only(
                                    bottom: 100 + bottomInset,
                                  ),
                                  itemCount: _filteredSongs.length,
                                  itemBuilder: (context, index) {
                                    final song = _filteredSongs[index];
                                    final isSelected =
                                        _selectedSongs.contains(song);

                                    return InkWell(
                                      onTap: () {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedSongs.remove(song);
                                          } else {
                                            _selectedSongs.add(song);
                                          }
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 24,
                                          vertical: 8,
                                        ),
                                        color: isSelected
                                            ? accent.withOpacity(0.05)
                                            : Colors.transparent,
                                        child: Row(
                                          children: [
                                            _SongArtwork(song: song),
                                            const SizedBox(width: 16),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    song.title,
                                                    style: TextStyle(
                                                      color: isSelected
                                                          ? accent
                                                              .withOpacity(0.8)
                                                          : Colors.white,
                                                      fontSize: 15,
                                                      fontWeight: isSelected
                                                          ? FontWeight.bold
                                                          : FontWeight.normal,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    song.artist,
                                                    style: TextStyle(
                                                      color: Colors.white
                                                          .withOpacity(0.5),
                                                      fontSize: 13,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Transform.scale(
                                              scale: 1.1,
                                              child: Checkbox(
                                                value: isSelected,
                                                onChanged: (value) {
                                                  setState(() {
                                                    if (value == true) {
                                                      _selectedSongs.add(song);
                                                    } else {
                                                      _selectedSongs
                                                          .remove(song);
                                                    }
                                                  });
                                                },
                                                activeColor: accent,
                                                checkColor: Colors.white,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                side: BorderSide(
                                                  color: Colors.white
                                                      .withOpacity(0.3),
                                                  width: 1.5,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    Widget child = Stack(
      children: [
        _buildContent(context),
        if (!_isLoading && _availableSongs.isNotEmpty)
          _buildBottomFloatingActions(context),
      ],
    );

    if (animation != null) {
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final curvedValue = Curves.easeOutCubic.transform(animation.value);
          return Transform.scale(
            scale: 0.95 + (0.05 * curvedValue),
            child: child,
          );
        },
        child: child,
      );
    }

    return child;
  }
}

/// Artwork de la fila: usa el embebido en Song o lo resuelve desde la BD local.
class _SongArtwork extends StatelessWidget {
  final Song song;

  const _SongArtwork({required this.song});

  @override
  Widget build(BuildContext context) {
    if (song.artworkData != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          song.artworkData!,
          width: 50,
          height: 50,
          fit: BoxFit.cover,
        ),
      );
    }

    return FutureBuilder(
      future: LocalMusicDatabase().getMetadata(song.filePath),
      builder: (context, snapshot) {
        final art = snapshot.data?.artwork;
        if (art != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.memory(art, width: 50, height: 50, fit: BoxFit.cover),
          );
        }

        return Container(
          width: 50,
          height: 50,
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
