import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/playlist_service.dart';
import '../services/language_service.dart';
import 'artwork_container.dart';

/// Opciones disponibles en el bottom sheet
enum SongOption { like, addToPlaylist, removeFromPlaylist, delete }

/// Widget reutilizable para mostrar opciones de una canción en un bottom sheet
///
/// Uso:
/// ```dart
/// await SongOptionsBottomSheet.show(
///   context: context,
///   song: song,
///   options: [SongOption.like, SongOption.addToPlaylist],
///   onOptionSelected: (option) {
///     // Manejar opción seleccionada
///   },
/// );
/// ```
class SongOptionsBottomSheet extends StatelessWidget {
  final Song song;
  final List<SongOption> options;
  final Function(SongOption)? onOptionSelected;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onRemove;

  const SongOptionsBottomSheet({
    super.key,
    required this.song,
    this.options = const [SongOption.like, SongOption.addToPlaylist],
    this.onOptionSelected,
    this.onAddToPlaylist,
    this.onRemove,
  });

  /// Método estático para mostrar el bottom sheet
  static Future<void> show({
    required BuildContext context,
    required Song song,
    List<SongOption> options = const [
      SongOption.like,
      SongOption.addToPlaylist,
    ],
    Function(SongOption)? onOptionSelected,
    VoidCallback? onAddToPlaylist,
    VoidCallback? onRemove,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SongOptionsBottomSheet(
        song: song,
        options: options,
        onOptionSelected: onOptionSelected,
        onAddToPlaylist: onAddToPlaylist,
        onRemove: onRemove,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLiked = PlaylistService().isLiked(song.id);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          // Header con información de la canción
          ListTile(
            leading: ArtworkContainer.song(
              artworkData: song.artworkData,
              size: 50,
              borderRadius: 4,
            ),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          const Divider(color: Colors.white24),

          // Opciones
          ...options.map((option) => _buildOption(context, option, isLiked)),

          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildOption(BuildContext context, SongOption option, bool isLiked) {
    switch (option) {
      case SongOption.like:
        return ListTile(
          leading: Icon(
            isLiked ? Icons.favorite : Icons.favorite_border,
            color: isLiked ? Colors.purpleAccent : Colors.white,
          ),
          title: Text(
            isLiked
                ? LanguageService().getText('remove_from_favorites')
                : LanguageService().getText('add_to_favorites'),
            style: const TextStyle(color: Colors.white),
          ),
          onTap: () async {
            await PlaylistService().toggleLike(song.id);
            if (context.mounted) Navigator.pop(context);
            onOptionSelected?.call(SongOption.like);
          },
        );

      case SongOption.addToPlaylist:
        return ListTile(
          leading: const Icon(Icons.playlist_add, color: Colors.white),
          title: Text(
            LanguageService().getText('add_to_playlist'),
            style: const TextStyle(color: Colors.white),
          ),
          onTap: () {
            Navigator.pop(context);
            onAddToPlaylist?.call();
            onOptionSelected?.call(SongOption.addToPlaylist);
          },
        );

      case SongOption.removeFromPlaylist:
        return ListTile(
          leading: const Icon(
            Icons.remove_circle_outline,
            color: Colors.redAccent,
          ),
          title: Text(
            LanguageService().getText('remove_from_playlist'),
            style: const TextStyle(color: Colors.white),
          ),
          onTap: () {
            Navigator.pop(context);
            onRemove?.call();
            onOptionSelected?.call(SongOption.removeFromPlaylist);
          },
        );

      case SongOption.delete:
        return ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
          title: Text(
            LanguageService().getText('delete'),
            style: const TextStyle(color: Colors.white),
          ),
          onTap: () {
            Navigator.pop(context);
            onOptionSelected?.call(SongOption.delete);
          },
        );
    }
  }
}
