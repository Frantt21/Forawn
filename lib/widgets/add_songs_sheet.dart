import 'package:flutter/material.dart';

import '../models/playlist_model.dart';
import '../models/song_model.dart';
import '../services/global_music_player.dart';
import '../services/local_music_database.dart';
import '../services/playlist_service.dart';
import 'forawn_dialog.dart';

typedef TextGetter = String Function(String key, {String? fallback});

/// Diálogo "Agregar canciones" a una playlist — réplica del AddSongsSheet
/// de forawn_mobile pero en contenedor unificado [ForawnDialog] (diálogo,
/// NO drag container): header, búsqueda, contador de seleccionadas con
/// chips Todas/Ninguna, lista con artwork + checkbox y acciones
/// Cancelar/Agregar abajo. Mismo estilo y tamaño que el resto de diálogos.
class AddSongsDialog extends StatefulWidget {
  final Playlist playlist;
  final TextGetter getText;
  final Color? accentColor;

  const AddSongsDialog({
    super.key,
    required this.playlist,
    required this.getText,
    this.accentColor,
  });

  /// Mantiene la API [show] del antiguo AddSongsSheet para no tocar los
  /// puntos de llamada.
  static Future<void> show(
    BuildContext context, {
    required Playlist playlist,
    required TextGetter getText,
    Color? backgroundColor,
    Color? accentColor,
  }) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (_) => AddSongsDialog(
        playlist: playlist,
        getText: getText,
        accentColor: accentColor,
      ),
    );
  }

  @override
  State<AddSongsDialog> createState() => _AddSongsDialogState();
}

class _AddSongsDialogState extends State<AddSongsDialog> {
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

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor ?? Colors.purpleAccent;

    return ForawnDialog(
      title: widget.getText('add_songs', fallback: 'Agregar canciones'),
      cancelLabel: widget.getText('cancel', fallback: 'Cancelar'),
      confirmLabel: widget.getText('add', fallback: 'Agregar'),
      accentColor: accent,
      confirmEnabled: _selectedSongs.isNotEmpty && !_isLoading,
      onConfirm: _addSelectedSongs,
      children: [
        // Search bar (estilo inputs de forawn_mobile).
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
          ),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            cursorColor: accent,
            decoration: InputDecoration(
              hintText: widget.getText('search', fallback: 'Buscar'),
              hintStyle: TextStyle(
                color: Colors.white.withOpacity(0.2),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 13,
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
                        size: 20,
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
        const SizedBox(height: 12),

        // Contador de seleccionadas + Todas/Ninguna.
        Row(
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
            _SelectionChip(
              label: widget.getText('select_all', fallback: 'Todas'),
              enabled: _filteredSongs.isNotEmpty &&
                  _selectedSongs.length != _filteredSongs.length,
              onTap: () =>
                  setState(() => _selectedSongs.addAll(_filteredSongs)),
            ),
            const SizedBox(width: 8),
            _SelectionChip(
              label: widget.getText('deselect_all', fallback: 'Ninguna'),
              enabled: _selectedSongs.isNotEmpty,
              onTap: () => setState(() => _selectedSongs.clear()),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Lista de canciones (alto fijo: el diálogo nunca cambia de tamaño).
        Container(
          height: 320,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(16),
          ),
          child: _isLoading
              ? Center(child: CircularProgressIndicator(color: accent))
              : _availableSongs.isEmpty
                  ? _emptyState(
                      icon: Icons.library_music_outlined,
                      message: widget.getText(
                        'no_songs_to_add',
                        fallback: 'No hay canciones para agregar',
                      ),
                    )
                  : _filteredSongs.isEmpty
                      ? _emptyState(
                          icon: Icons.search_off,
                          message: widget.getText(
                            'no_results',
                            fallback: 'Sin resultados',
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _filteredSongs.length,
                          itemBuilder: (context, index) {
                            final song = _filteredSongs[index];
                            final isSelected = _selectedSongs.contains(song);

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
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                color: isSelected
                                    ? accent.withOpacity(0.05)
                                    : Colors.transparent,
                                child: Row(
                                  children: [
                                    _SongArtwork(song: song),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            song.title,
                                            style: TextStyle(
                                              color: isSelected
                                                  ? accent.withOpacity(0.8)
                                                  : Colors.white,
                                              fontSize: 15,
                                              fontWeight: isSelected
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            song.artist,
                                            style: TextStyle(
                                              color: Colors.white
                                                  .withOpacity(0.5),
                                              fontSize: 13,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Transform.scale(
                                      scale: 1.0,
                                      child: Checkbox(
                                        value: isSelected,
                                        onChanged: (value) {
                                          setState(() {
                                            if (value == true) {
                                              _selectedSongs.add(song);
                                            } else {
                                              _selectedSongs.remove(song);
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
    );
  }

  Widget _emptyState({required IconData icon, required String message}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip Todas/Ninguna del contador de seleccionadas.
class _SelectionChip extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _SelectionChip({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        decoration: BoxDecoration(
          color: enabled
              ? Colors.white.withOpacity(0.2)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? Colors.white : Colors.white30,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      ),
    );
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
          width: 44,
          height: 44,
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
            child: Image.memory(art, width: 44, height: 44, fit: BoxFit.cover),
          );
        }

        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(Icons.music_note, color: Colors.grey, size: 20),
        );
      },
    );
  }
}
