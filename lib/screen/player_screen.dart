import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/global_music_player.dart';
import '../services/music_history.dart';

import '../services/global_theme_service.dart';
import '../services/local_music_database.dart';
import '../models/synced_lyrics.dart';

import 'lyrics_display_widget.dart';
import 'package:window_manager/window_manager.dart';

import '../main.dart' show gUseNativeFrame, gShowWindowButtons, gMacTrafficLightInset;
import '../services/metadata_service.dart';
import '../services/innertube_service.dart';
import '../services/playlist_service.dart';
import '../widgets/mini_player.dart' show MiniPlayerVisibility;
import '../models/song_model.dart';
import 'package:file_picker/file_picker.dart';
import '../models/lyrics_search_result.dart';
import '../services/lyrics_service.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class PlayerScreen extends StatefulWidget {
  final TextGetter getText;

  const PlayerScreen({super.key, required this.getText});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WindowListener {
  final GlobalMusicPlayer _musicPlayer = GlobalMusicPlayer();
  late AudioPlayer _player;
  late FocusNode _focusNode;

  // Local state
  bool _showPlaylist = false;
  bool _useBlurBackground = false;
  bool _toggleLocked = false;

  // Posición de la barra de progreso durante un arrastre
  // (en segundos). Mientras se arrastra se muestra esta
  // posición; el seek se aplica al soltar (onChangeEnd).
  double? _dragSeekValue;

  // Animación de corazón al dar like con doble tap en la
  // portada (misma función que forawn_mobile).
  bool _showHeartAnimation = false;

  // Modo de artwork expandido de fondo (forawn_mobile).
  bool _isFullArtworkMode = true;

  // Artwork online de alta resolución (Deezer) para el modo extendido:
  // se usa cuando el artwork embebido del MP3 es pequeño o falta. Los
  // bytes se precargan para que la imagen no "salte" al cambiar de canción.
  Uint8List? _onlineArtworkBytes;
  String? _artworkLoadPath;

  // UI colors/state
  Color? _dominantColor;
  Uint8List? _currentArt;
  String _currentTitle = '';
  String _currentArtist = '';

  // Lyrics Sync
  Duration _lyricsOffset = Duration.zero;
  final ValueNotifier<int?> _lyricIndexNotifier = ValueNotifier(null);

  // Playlist management
  List<FileSystemEntity> _files = [];
  List<FileSystemEntity> _filteredFiles = [];
  final TextEditingController _searchController = TextEditingController();
  final Set<int> _playedIndices = {};

  Future<void> _minimize() async => await windowManager.minimize();
  Future<void> _maximizeRestore() async {
    final isMax = await windowManager.isMaximized();
    if (isMax) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  void onWindowMaximize() {
    setState(() {});
  }

  @override
  void onWindowUnmaximize() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // El reproductor completo está abierto: ocultar el MiniPlayer global.
    MiniPlayerVisibility.setFullPlayerOpen(true);
    if (!gUseNativeFrame) {
      windowManager.addListener(this);
    }
    _focusNode = FocusNode();
    _player = _musicPlayer.player;

    // Sync initial state
    _useBlurBackground = GlobalThemeService().blurBackground.value;
    _dominantColor =
        GlobalThemeService().dominantColor.value; // Use global color directly
    _files = List<FileSystemEntity>.from(_musicPlayer.filesList.value);
    _filteredFiles = _files;

    // Sync song info
    _currentTitle = _musicPlayer.currentTitle.value;
    _currentArtist = _musicPlayer.currentArtist.value;
    _currentArt = _musicPlayer.currentArt.value;

    // Listeners
    GlobalThemeService().blurBackground.addListener(_onBlurChanged);
    GlobalThemeService().dominantColor.addListener(
      _onColorChanged,
    ); // Listen to global color
    _musicPlayer.filesList.addListener(_onFilesChanged);
    _musicPlayer.currentArt.addListener(_onArtChanged);
    _musicPlayer.currentTitle.addListener(_onTitleChanged);
    _musicPlayer.currentArtist.addListener(_onArtistChanged);
    _musicPlayer.currentFilePath.addListener(_loadSavedOffset);
    _musicPlayer.position.addListener(_updateLyricIndex);
    _loadSavedOffset(); // Initial load
    _loadArtworkMode();
    // Cargar el artwork online cacheado (al re-entrar la canción no
    // cambia, así que sin esto se perdería la calidad de 1000 px).
    _loadOnlineArtwork();

    // Keyboard listeners are handled by RawKeyboardListener in build
  }

  @override
  void dispose() {
    // Restaurar el MiniPlayer global al cerrar el reproductor completo.
    MiniPlayerVisibility.setFullPlayerOpen(false);
    GlobalThemeService().blurBackground.removeListener(_onBlurChanged);
    GlobalThemeService().dominantColor.removeListener(_onColorChanged);
    _musicPlayer.filesList.removeListener(_onFilesChanged);
    _musicPlayer.currentArt.removeListener(_onArtChanged);
    _musicPlayer.currentTitle.removeListener(_onTitleChanged);
    _musicPlayer.currentTitle.removeListener(_onTitleChanged);
    _musicPlayer.currentArtist.removeListener(_onArtistChanged);
    _musicPlayer.currentFilePath.removeListener(_loadSavedOffset);
    _musicPlayer.position.removeListener(_updateLyricIndex);
    _lyricIndexNotifier.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onColorChanged() {
    if (mounted) {
      setState(() => _dominantColor = GlobalThemeService().dominantColor.value);
    }
  }

  void _onBlurChanged() {
    if (mounted)
      setState(
        () => _useBlurBackground = GlobalThemeService().blurBackground.value,
      );
  }

  void _onFilesChanged() {
    if (mounted) {
      setState(() {
        _files = List<FileSystemEntity>.from(_musicPlayer.filesList.value);
        _filterFiles(_searchController.text);
      });
    }
  }

  Future<void> _onArtChanged() async {
    final art = _musicPlayer.currentArt.value;
    if (mounted) {
      setState(() => _currentArt = art);
      // Color is handled by _onColorChanged via GlobalThemeService
    }
  }

  void _onTitleChanged() {
    if (mounted) {
      setState(() {
        _currentTitle = _musicPlayer.currentTitle.value;
        // Reset para la nueva canción; se recarga el artwork online.
        _onlineArtworkBytes = null;
      });
      _loadOnlineArtwork();
    }
  }

  void _onArtistChanged() {
    if (mounted)
      setState(() => _currentArtist = _musicPlayer.currentArtist.value);
  }

  Color _adjustColorForControls(Color? color) {
    if (color == null) return Colors.white;
    // Return the color itself if possible, but ensuring it's visible on dark background
    // If background is transparent/black, we want bright colors.
    // Use HSL to guarantee brightness
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness < 0.3) {
      return hsl.withLightness(0.6).toColor();
    }
    return color;
  }

  Color _getContrastColor(Color color) {
    return color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  }

  /// Formato corto de tiempos del player: solo mm:ss (sin horas),
  /// incluso en pistas larguísimas (100:00 en vez de 1:00:00).
  String _formatDurationShort(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    final minutes = duration.inMinutes;
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  /// Barra de progreso del player, encima de los botones: barra larga
  /// (con margen lateral) y los tiempos en los extremos, debajo.
  Widget _buildProgressBar() {
    return ValueListenableBuilder<Duration>(
      valueListenable: _musicPlayer.position,
      builder: (context, position, _) {
        final duration = _musicPlayer.duration.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Barra: ancho máximo generoso (mucho más larga que antes).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: SizedBox(
                  height: 28,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      // Sin dot: thumb invisible (radio 0) y sin overlay,
                      // igual que la barra de volumen.
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 0,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 0,
                      ),
                      // Sin padding lateral interno.
                      padding: EdgeInsets.zero,
                      activeTrackColor: _adjustColorForControls(
                        _dominantColor,
                      ),
                      inactiveTrackColor: Colors.white10,
                      thumbColor: _adjustColorForControls(_dominantColor),
                    ),
                    child: Slider(
                      value: (_dragSeekValue ??
                              position.inSeconds.toDouble())
                          .clamp(0.0, duration.inSeconds.toDouble()),
                      max: duration.inSeconds.toDouble() > 0
                          ? duration.inSeconds.toDouble()
                          : 1.0,
                      // Durante el arrastre solo se muestra la posición
                      // del dedo; el seek se aplica al soltar.
                      onChanged: (v) => setState(() {
                        _dragSeekValue = v;
                      }),
                      onChangeEnd: (v) {
                        _player.seek(Duration(seconds: v.toInt()));
                        setState(() {
                          _dragSeekValue = null;
                        });
                      },
                    ),
                  ),
                ),
              ),
            ),
            // Timestamps: posición a la izquierda, duración a la derecha,
            // justo debajo de la barra y con los mismos márgenes.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      // Durante el arrastre se muestra la posición del
                      // dedo en vez de la reproducción.
                      _formatDurationShort(
                        _dragSeekValue != null
                            ? Duration(seconds: _dragSeekValue!.toInt())
                            : position,
                      ),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      _formatDurationShort(duration),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _togglePlaylist() {
    if (_toggleLocked) return;
    _toggleLocked = true;
    setState(() => _showPlaylist = !_showPlaylist);
    Future.delayed(
      const Duration(milliseconds: 350),
      () => _toggleLocked = false,
    );
  }

  void _filterFiles(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredFiles = _files;
      } else {
        _filteredFiles = _files.where((file) {
          final fileName = p.basename(file.path).toLowerCase();
          return fileName.contains(query.toLowerCase());
        }).toList();
      }
    });
  }

  // --- Metadata Editing ---
  /// Diálogo de edición de metadatos con el diseño de forawn_mobile
  /// (selector de fuente Deezer/YouTube Music, búsqueda con múltiples
  /// resultados y aplicación inline), pero como Dialog y no drag-container.
  void _showEditMetadataDialog(BuildContext parentContext) {
    final filePath = _musicPlayer.currentFilePath.value;
    if (filePath.isEmpty) {
      debugPrint('[PlayerScreen] No file selected to edit metadata');
      return;
    }
    final song = _getCurrentSong();
    final accent = song.dominantColor != null
        ? Color(song.dominantColor!)
        : const Color(0xFFD046FF);

    final titleController = TextEditingController(
      text: _musicPlayer.currentTitle.value,
    );
    final artistController = TextEditingController(
      text: _musicPlayer.currentArtist.value,
    );

    bool isLoading = false;
    List<Map<String, dynamic>> searchResults = [];
    String? errorMessage;
    String selectedSource = 'Deezer';

    showDialog(
      context: parentContext,
      barrierDismissible: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setStateDialog) => Dialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        widget.getText(
                          'update_metadata',
                          fallback: 'Update metadata',
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close, color: Colors.grey),
                        splashRadius: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Selector de fuente (igual que forawn_mobile).
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setStateDialog(() {
                              selectedSource = 'Deezer';
                              searchResults = [];
                              errorMessage = null;
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: selectedSource == 'Deezer'
                                    ? accent.withOpacity(0.2)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.horizontal(
                                  left: const Radius.circular(12),
                                  right: Radius.circular(
                                    selectedSource == 'Deezer' ? 12 : 0,
                                  ),
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                widget.getText(
                                  'deezer_precise',
                                  fallback: 'Deezer (More Precise)',
                                ),
                                style: TextStyle(
                                  color: selectedSource == 'Deezer'
                                      ? accent
                                      : Colors.white70,
                                  fontWeight: selectedSource == 'Deezer'
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setStateDialog(() {
                              selectedSource = 'Server';
                              searchResults = [];
                              errorMessage = null;
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: selectedSource == 'Server'
                                    ? accent.withOpacity(0.2)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.horizontal(
                                  right: const Radius.circular(12),
                                  left: Radius.circular(
                                    selectedSource == 'Server' ? 12 : 0,
                                  ),
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                widget.getText(
                                  'youtube_music_source',
                                  fallback: 'YouTube Music',
                                ),
                                style: TextStyle(
                                  color: selectedSource == 'Server'
                                      ? accent
                                      : Colors.white70,
                                  fontWeight: selectedSource == 'Server'
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _buildStyledTextField(
                    controller: titleController,
                    label: widget.getText('metadata_title', fallback: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  _buildStyledTextField(
                    controller: artistController,
                    label: widget.getText('metadata_artist', fallback: 'Artist'),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: isLoading
                          ? null
                          : () async {
                              setStateDialog(() {
                                isLoading = true;
                                errorMessage = null;
                                searchResults = [];
                              });

                              try {
                                if (selectedSource == 'Deezer') {
                                  final results = await MetadataService()
                                      .searchMetadataMulti(
                                        titleController.text,
                                        artistController.text,
                                      );
                                  setStateDialog(() {
                                    isLoading = false;
                                    searchResults = results;
                                    if (results.isEmpty) {
                                      errorMessage = widget.getText(
                                        'no_results',
                                        fallback: 'No results',
                                      );
                                    }
                                  });
                                } else {
                                  // YouTube Music vía Innertube: metadatos
                                  // limpios del resultado, sin servidores
                                  // propios (igual que forawn_mobile).
                                  final query =
                                      '${titleController.text} ${artistController.text}'
                                          .trim();
                                  final tracks = await InnertubeService()
                                      .searchTracks(query, limit: 5);
                                  final results = tracks
                                      .map(
                                        (t) => {
                                          'title': t.rawTitle,
                                          'artist': t.channel,
                                          'album': t.album,
                                          'albumArtUrl': t.thumbnailUrl,
                                          'source': 'YouTube Music',
                                        },
                                      )
                                      .toList();
                                  setStateDialog(() {
                                    isLoading = false;
                                    searchResults = results;
                                    if (results.isEmpty) {
                                      errorMessage = widget.getText(
                                        'no_results',
                                        fallback: 'No results',
                                      );
                                    }
                                  });
                                }
                              } catch (e) {
                                setStateDialog(() {
                                  isLoading = false;
                                  errorMessage = 'Error: $e';
                                });
                              }
                            },
                      icon: isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.search, color: Colors.white),
                      label: Text(
                        widget.getText('search', fallback: 'Search'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                    ),
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
                  if (searchResults.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Divider(color: Colors.white24),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.getText('results', fallback: 'Results')} '
                      '(${searchResults.length})',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    ...searchResults.map((result) {
                      final artUrl = result['albumArtUrl'] as String?;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: artUrl != null && artUrl.isNotEmpty
                                ? Image.network(
                                    artUrl,
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.music_note,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.music_note,
                                    color: Colors.white,
                                    size: 48,
                                  ),
                          ),
                          title: Text(
                            result['title']?.toString() ?? 'Unknown',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${result['artist'] ?? 'Unknown'} • ${result['album'] ?? ''}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.check_circle,
                              color: Colors.greenAccent,
                              size: 30,
                            ),
                            onPressed: () {
                              Navigator.pop(dialogContext);
                              _showConfirmationDialog(
                                parentContext,
                                filePath,
                                _trackMetadataFromResult(result),
                              );
                            },
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Convierte un resultado crudo de búsqueda en TrackMetadata para el
  /// flujo de confirmación/aplicación existente.
  TrackMetadata _trackMetadataFromResult(Map<String, dynamic> result) {
    return TrackMetadata(
      title: result['title']?.toString() ?? '',
      artist: result['artist']?.toString() ?? '',
      album: result['album']?.toString() ?? '',
      year: result['year']?.toString(),
      albumArtUrl: result['albumArtUrl']?.toString(),
      hasAlbumArt: result['albumArtUrl'] != null,
    );
  }

  Widget _buildStyledTextField({
    required TextEditingController controller,
    required String label,
  }) {
    // Estilo de inputs de forawn_mobile: contenedor blanco 5%, radio 16,
    // sin borde, cursor de color acento.
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        cursorColor: const Color(0xFFD046FF),
        decoration: InputDecoration(
          hintText: label,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }

  void _showConfirmationDialog(
    BuildContext parentContext,
    String filePath,
    TrackMetadata metadata,
  ) {
    showDialog(
      context: parentContext,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.getText(
                      'confirm_update',
                      fallback: 'Apply Metadata?',
                    ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close, color: Colors.grey),
                    splashRadius: 20,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (metadata.albumArtUrl != null &&
                  metadata.albumArtUrl!.isNotEmpty)
                Center(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        metadata.albumArtUrl!,
                        height: 160,
                        width: 160,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              // Info container
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoRow(
                      widget.getText('metadata_title', fallback: 'Title'),
                      metadata.title,
                    ),
                    const SizedBox(height: 8),
                    _buildInfoRow(
                      widget.getText('metadata_artist', fallback: 'Artist'),
                      metadata.artist,
                    ),
                    if (metadata.album.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _buildInfoRow(
                        widget.getText('metadata_album', fallback: 'Album'),
                        metadata.album,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: Colors.white24),
                        ),
                      ),
                      child: Text(widget.getText('cancel', fallback: 'Cancel')),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        final scaffoldMessenger = ScaffoldMessenger.of(
                          parentContext,
                        );
                        Navigator.pop(dialogContext);

                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              widget.getText(
                                'updating',
                                fallback: 'Updating metadata...',
                              ),
                            ),
                            backgroundColor: const Color(0xFF2C2C2E),
                          ),
                        );

                        final success = await MetadataService()
                            .updateFileMetadata(filePath, metadata);

                        if (success) {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                widget.getText(
                                  'updated',
                                  fallback: 'Metadata updated! Reloading...',
                                ),
                              ),
                              backgroundColor: Colors.green,
                            ),
                          );

                          // Invalidar caché de BD local para obligar a leer cambios del archivo
                          await LocalMusicDatabase().invalidateMetadata(
                            filePath,
                          );

                          await GlobalMusicPlayer().refreshLibrary();
                          // Forzar actualización de UI para la canción actual
                          if (mounted) {
                            await GlobalMusicPlayer()
                                .verifyCurrentSongMetadata();
                          }
                        } else {
                          scaffoldMessenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                widget.getText(
                                  'error_updating',
                                  fallback: 'Error updating metadata',
                                ),
                              ),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD046FF),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        widget.getText('apply', fallback: 'Apply'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 60,
          child: Text(
            '$label:',
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  // --- Playlist Logic ---

  Song _getCurrentSong() {
    final path = _musicPlayer.currentFilePath.value;
    try {
      return _musicPlayer.songsList.value.firstWhere((s) => s.filePath == path);
    } catch (_) {
      // Fallback si no está en la lista cargada (ej. archivo externo)
      return Song(
        id: path.hashCode.toString(),
        title: _musicPlayer.currentTitle.value,
        artist: _musicPlayer.currentArtist.value,
        filePath: path,
        duration: Duration(seconds: _musicPlayer.duration.value.inSeconds),
        album: "",
      );
    }
  }

  void _showAddToPlaylistDialog(BuildContext parentContext) {
    final song = _getCurrentSong();
    final playlists = PlaylistService().playlists;

    showDialog(
      context: parentContext,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 350,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.getText('add_playlist', fallback: "Add to Playlist"),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              Material(
                color: Colors.purpleAccent.withOpacity(0.1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: Colors.purpleAccent.withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    Navigator.pop(context);
                    _showCreatePlaylistDialog();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.purpleAccent.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.add,
                            color: Colors.purpleAccent,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          widget.getText(
                            'create_playlist',
                            fallback: "Create Playlist",
                          ),
                          style: const TextStyle(
                            color: Colors.purpleAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    final alreadyIn = playlist.songs.any(
                      (s) =>
                          s.filePath == song.filePath, // Check by path is safer
                    );

                    return Material(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: alreadyIn
                            ? null
                            : () {
                                PlaylistService().addSongToPlaylist(
                                  playlist.id,
                                  song,
                                );
                                Navigator.pop(context);
                                ScaffoldMessenger.of(
                                  parentContext,
                                ).showSnackBar(
                                  // Use parentContext
                                  SnackBar(
                                    content: Text(
                                      widget.getText(
                                        'added_to_playlist',
                                        fallback: 'Added to {name}',
                                      ).replaceFirst('{name}', playlist.name),
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    backgroundColor: Colors.grey[900],
                                  ),
                                );
                              },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: Colors.grey[850],
                                  borderRadius: BorderRadius.circular(8),
                                  image: playlist.imagePath != null
                                      ? DecorationImage(
                                          image: FileImage(
                                            File(playlist.imagePath!),
                                          ),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: playlist.imagePath == null
                                    ? const Icon(
                                        Icons.queue_music,
                                        color: Colors.white54,
                                        size: 24,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      playlist.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w500,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${playlist.songs.length} ${widget.getText('songs', fallback: 'songs')}',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.5),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (alreadyIn)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E3A25),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.check_circle,
                                        color: Color(0xFF4CAF50),
                                        size: 14,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        widget.getText(
                                          'added',
                                          fallback: "Added",
                                        ),
                                        style: const TextStyle(
                                          color: Color(0xFF4CAF50),
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      widget.getText('cancel', fallback: "Cancel"),
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    String? selectedImagePath;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(
              widget.getText('create_playlist', fallback: "Create Playlist"),
              style: const TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () async {
                    FilePickerResult? result = await FilePicker.pickFiles(type: FileType.image);
                    if (result != null) {
                      setDialogState(() {
                        selectedImagePath = result.files.single.path;
                      });
                    }
                  },
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(12),
                      image: selectedImagePath != null
                          ? DecorationImage(
                              image: FileImage(File(selectedImagePath!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: selectedImagePath == null
                        ? const Icon(
                            Icons.add_photo_alternate,
                            color: Colors.white54,
                            size: 40,
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 16),
                // Inputs estilo forawn_mobile (blanco 5%, radio 16, sin borde).
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TextField(
                    controller: nameController,
                    cursorColor: Colors.purpleAccent,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: widget.getText('name', fallback: "Name"),
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      border: InputBorder.none,
                      prefixIcon: Icon(
                        Icons.queue_music_rounded,
                        color: Colors.white.withOpacity(0.5),
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TextField(
                    controller: descController,
                    maxLines: 3,
                    cursorColor: Colors.purpleAccent,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: widget.getText(
                        'description',
                        fallback: "Description",
                      ),
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  widget.getText('cancel', fallback: "Cancel"),
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () {
                  if (nameController.text.isNotEmpty) {
                    PlaylistService().createPlaylist(
                      nameController.text,
                      description: descController.text,
                      imagePath: selectedImagePath,
                    );
                    Navigator.pop(context);
                    // Re-open add dialog? Maybe simpler to just close.
                  }
                },
                child: Text(
                  widget.getText('create', fallback: "Create"),
                  style: const TextStyle(color: Colors.purpleAccent),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // --- Playback Logic (Simplified duplication of MusicPlayerScreen logic for robustness) ---

  int _getNextShuffleIndex() {
    final availableIndices = List.generate(
      _files.length,
      (i) => i,
    ).where((i) => !_playedIndices.contains(i)).toList();

    if (availableIndices.isEmpty) {
      _playedIndices.clear();
      return Random().nextInt(_files.length);
    }
    return availableIndices[Random().nextInt(availableIndices.length)];
  }

  void _playFile(int index, {int? transitionDirection}) {
    if (index < 0 || index >= _files.length) return;
    _playedIndices.add(index);
    final file = _files[index] as File;

    debugPrint('[PlayerScreen] _playFile: index=$index, path=${file.path}');

    // 1. Set explicit direction if provided, otherwise infer or default to 1 (next)
    if (transitionDirection != null) {
      _musicPlayer.transitionDirection.value = transitionDirection;
    } else {
      final previousIdx = _musicPlayer.currentIndex.value;
      if (previousIdx != null) {
        // Fallback: simple comparison, though less reliable with shuffle
        _musicPlayer.transitionDirection.value = index > previousIdx ? 1 : -1;
      }
    }

    // 2. Update global state IMMEDIATELY (synchronous, no await)
    _musicPlayer.currentFilePath.value = file.path;
    _musicPlayer.currentIndex.value = index;
    _musicPlayer.isPlaying.value = true;

    // 3. Try to get metadata from pre-loaded songsList (instant, no I/O)
    final songs = _musicPlayer.songsList.value;
    final matchingSong = songs
        .where((s) => s.filePath == file.path)
        .firstOrNull;
    if (matchingSong != null) {
      _musicPlayer.currentTitle.value = matchingSong.title;
      _musicPlayer.currentArtist.value = matchingSong.artist;
      _musicPlayer.currentArt.value = matchingSong.artworkData;
      // Update theme color from pre-cached dominantColor (instant, no I/O)
      if (matchingSong.dominantColor != null) {
        GlobalThemeService().updateDominantColor(
          Color(matchingSong.dominantColor!),
        );
      }
    } else {
      // Fallback to filename if song not in preloaded list
      _musicPlayer.currentTitle.value = p.basenameWithoutExtension(file.path);
      _musicPlayer.currentArtist.value = 'Unknown Artist';
    }

    // 4. Audio operations - fire and forget (non-blocking)
    _player.stop().then((_) {
      _player.play(DeviceFileSource(file.path)).catchError((e) {
        debugPrint("Error playing file: $e");
      });
    });

    // 5. Background tasks (non-blocking)
    MusicHistory().addToHistory(file);
    // savePlayerState se llama automáticamente en el listener de pausa

    debugPrint('[PlayerScreen] _playFile: completed with metadata');
  }

  void _playPrevious() {
    // Delegate to GlobalMusicPlayer which handles SQL history and consistent Shuffle logic
    _musicPlayer.playPrevious();
  }

  void _playNext() {
    final currentIndex = _musicPlayer.currentIndex.value ?? 0;
    if (_files.isEmpty) return;
    int newIndex;

    // Check Shuffle
    if (_musicPlayer.isShuffle.value == true) {
      newIndex = _getNextShuffleIndex();
    } else {
      newIndex = currentIndex + 1;
      if (newIndex >= _files.length) newIndex = 0;
    }
    _playFile(newIndex, transitionDirection: 1);
  }

  void _togglePlayPause() async {
    if (_musicPlayer.isPlaying.value) {
      await _musicPlayer.pauseActive();
    } else {
      await _musicPlayer.resumeActive();
    }
  }

  // --- Modo de artwork expandido (forawn_mobile) ---

  Future<void> _loadArtworkMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool('full_artwork_mode');
      if (mounted && saved != null) {
        setState(() => _isFullArtworkMode = saved);
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Error loading artwork mode: $e');
    }
  }

  Future<void> _toggleArtworkMode() async {
    setState(() => _isFullArtworkMode = !_isFullArtworkMode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('full_artwork_mode', _isFullArtworkMode);
    } catch (e) {
      debugPrint('[PlayerScreen] Error saving artwork mode: $e');
    }
  }

  // --- Gestos en la portada (forawn_mobile) ---

  void _handleHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < 0) {
      _playNext();
    } else if (velocity > 0) {
      _playPrevious();
    }
  }

  void _handleVerticalSwipe(DragEndDetails details) {
    if ((details.primaryVelocity ?? 0) > 500) {
      Navigator.of(context).pop();
    }
  }

  void _handleDoubleTapLike() {
    final song = _getCurrentSong();
    PlaylistService().toggleLike(song.id);
    setState(() => _showHeartAnimation = true);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeartAnimation = false);
    });
  }

  /// Corazón animado al dar like (forawn_mobile).
  Widget _buildHeartOverlay() {
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _showHeartAnimation ? 1.0 : 0.0,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.5, end: _showHeartAnimation ? 1.2 : 0.5),
            duration: const Duration(milliseconds: 400),
            curve: Curves.elasticOut,
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: Icon(
                  Icons.favorite_rounded,
                  color: _adjustColorForControls(_dominantColor),
                  size: 100,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Carga el artwork online de alta resolución (Deezer) para el modo
  /// extendido. Prioridad: bytes ya descargados en la DB (sin red, sin
  /// parpadeo) → embebido si es grande → descargar y cachear. Así, tras la
  /// primera reproducción de una canción siempre se usa la máxima calidad
  /// desde el primer frame.
  Future<void> _loadOnlineArtwork() async {
    final path = _musicPlayer.currentFilePath.value;
    if (path.isEmpty) return;
    _artworkLoadPath = path;

    try {
      final meta = await LocalMusicDatabase().getMetadata(path);

      // 1. Bytes del artwork online ya descargados: aplicar directo (sin red)
      final cachedBytes = meta?.onlineArtworkData;
      if (cachedBytes != null && cachedBytes.isNotEmpty) {
        await _applyOnlineArtworkBytes(path, cachedBytes);
        return;
      }

      // 2. Si el artwork embebido ya es grande, no hace falta buscar online
      final art = _currentArt;
      if (art != null && await _isArtworkLargeEnough(art)) return;

      // 3. URL cacheada: descargar los bytes una vez y guardarlos en la DB
      final cachedUrl = meta?.onlineArtworkUrl;
      if (cachedUrl != null && cachedUrl.isNotEmpty) {
        await _downloadAndCacheArtwork(
            path, _upscaleDeezerArtwork(cachedUrl));
        return;
      }

      // 4. Buscar en Deezer, cachear la URL y descargar los bytes
      final metadata = await MetadataService().searchMetadata(
        _currentTitle,
        _currentArtist,
      );
      if (metadata?.albumArtUrl != null && metadata!.albumArtUrl!.isNotEmpty) {
        await LocalMusicDatabase().updateOnlineArtworkUrl(
          path,
          metadata.albumArtUrl!,
        );
        await _downloadAndCacheArtwork(
            path, _upscaleDeezerArtwork(metadata.albumArtUrl!));
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Error loading online artwork: $e');
    }
  }

  /// Descarga los bytes del artwork online, los guarda en la DB y los aplica.
  Future<void> _downloadAndCacheArtwork(String path, String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return;
      await LocalMusicDatabase().updateOnlineArtworkData(path, res.bodyBytes);
      await _applyOnlineArtworkBytes(path, res.bodyBytes);
    } catch (e) {
      debugPrint('[PlayerScreen] Error downloading online artwork: $e');
    }
  }

  /// Aplica los bytes del artwork online en el estado SOLO si la canción
  /// sigue siendo la actual. Decodifica la imagen ANTES (precache) para que
  /// el intercambio no muestre un frame en blanco (parpadeo).
  Future<void> _applyOnlineArtworkBytes(String path, Uint8List bytes) async {
    final ctx = context;
    try {
      await precacheImage(MemoryImage(bytes), ctx);
    } catch (_) {}
    if (mounted && _artworkLoadPath == path) {
      setState(() => _onlineArtworkBytes = bytes);
    }
  }

  /// Sube la resolución del artwork de Deezer (500x500 -> 1000x1000)
  /// para el modo extendido; otras URLs se dejan tal cual.
  String _upscaleDeezerArtwork(String url) {
    if (url.contains('dzcdn.net')) {
      return url
          .replaceAll('500x500', '1000x1000')
          .replaceAll('250x250', '1000x1000');
    }
    return url;
  }

  /// True si el artwork embebido tiene al menos 700 px de ancho
  /// (suficiente para el modo extendido sin verse pixelado).
  Future<bool> _isArtworkLargeEnough(Uint8List bytes) async {
    try {
      final codec = await instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      frame.image.dispose();
      codec.dispose();
      return width >= 700;
    } catch (_) {
      return false;
    }
  }

  /// Imagen de máxima calidad para el modo extendido. Siempre devuelve el
  /// MISMO tipo de widget (Container + MemoryImage): cuando llegan los bytes
  /// del artwork online solo cambia la fuente de la imagen, así el
  /// AnimatedSwitcher no reinicia la transición ni la imagen "salta".
  Widget _buildFullArtworkImage() {
    final bytes = _onlineArtworkBytes ?? _currentArt!;
    return Container(
      key: ValueKey(_currentTitle),
      decoration: BoxDecoration(
        image: DecorationImage(
          image: MemoryImage(bytes),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  /// Área de gestos transparente para el modo de artwork expandido
  /// (la portada es el fondo; los gestos se capturan aquí).
  Widget _buildFullArtworkGestureArea() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: _handleHorizontalSwipe,
      onVerticalDragEnd: _handleVerticalSwipe,
      onDoubleTap: _handleDoubleTapLike,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const SizedBox.expand(),
          _buildHeartOverlay(),
        ],
      ),
    );
  }

  /// Fondo de artwork expandido (forawn_mobile): portada edge-to-edge en
  /// la mitad superior, fundida con el color dominante oscurecido abajo,
  /// más viñeta para el contraste de los controles.
  Widget _buildFullArtworkBackground() {
    final rawColor = _dominantColor ?? const Color(0xFF1C1C1E);
    final hsl = HSLColor.fromColor(rawColor);
    final baseColor = hsl
        .withLightness((hsl.lightness * 0.4).clamp(0.0, 1.0))
        .toColor();

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Color sólido dominante oscurecido
          AnimatedContainer(
            duration: const Duration(milliseconds: 1000),
            color: baseColor,
          ),
          // 2. Zona superior: artwork fundido por máscara + degradado a
          // pantalla completa, desenfocados JUNTOS al abrir lyrics (así no
          // queda un degradado nítido sobre el fondo borroso).
          ValueListenableBuilder<bool>(
            valueListenable: _musicPlayer.showLyrics,
            builder: (context, showLyrics, _) {
              return TweenAnimationBuilder<double>(
                tween: Tween(
                  begin: 0,
                  end: showLyrics ? 24 : 0,
                ),
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeInOut,
                builder: (context, sigma, child) {
                  return ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: sigma,
                      sigmaY: sigma,
                    ),
                    child: child,
                  );
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 2a. Artwork edge-to-edge en la mitad superior, con
                    // máscara que lo funde a transparente ANTES del borde
                    // de su caja: ese borde queda invisible (sin costura de
                    // píxeles en modo maximizado).
                    Align(
                      alignment: Alignment.topCenter,
                      child: FractionallySizedBox(
                        heightFactor: 0.65,
                        widthFactor: 1.0,
                        child: ShaderMask(
                          // dstIn: conserva el color del artwork y usa solo
                          // el alpha del degradado como máscara (srcIn
                          // reemplazaría el color por el del shader → blanco).
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (bounds) => LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: const [
                              Colors.white,
                              Colors.white,
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.82, 1.0],
                          ).createShader(bounds),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 800),
                            child: _buildFullArtworkImage(),
                          ),
                        ),
                      ),
                    ),
                    // 2b. Degradado a pantalla completa: oscurece arriba y
                    // funde la portada con el color base (difuminado como
                    // forawn_mobile). Al ser full-screen no tiene borde de
                    // capa → sin separación visible en maximizado; además
                    // queda dentro del blur para desenfocarse con todo.
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 1000),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.5),
                            Colors.transparent,
                            baseColor.withOpacity(0.85),
                            baseColor,
                          ],
                          stops: const [0.0, 0.4, 0.82, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // 4. Viñeta inferior para contraste de los controles
          IgnorePointer(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: 0.5,
                widthFactor: 1.0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.0),
                        Colors.black.withOpacity(0.7),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleKeyboardEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.f9) _playPrevious();
    if (event.logicalKey == LogicalKeyboardKey.f10) _togglePlayPause();
    if (event.logicalKey == LogicalKeyboardKey.f11) _playNext();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Important: Use transparent/black scaffold to let logic draw background
      backgroundColor: Colors.black,
      body: RawKeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKey: _handleKeyboardEvent,
        child: Stack(
          children: [
            // GLOBAL BACKGROUND
            // Modo artwork expandido (forawn_mobile): la portada llena la
            // parte superior y se funde con el color dominante abajo.
            if (_isFullArtworkMode && _currentArt != null)
              Positioned.fill(child: _buildFullArtworkBackground())
            else if (_useBlurBackground && _currentArt != null)
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 800),
                  child: ImageFiltered(
                    key: ValueKey(_currentTitle),
                    imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: Container(
                      decoration: BoxDecoration(
                        image: DecorationImage(
                          image: MemoryImage(_currentArt!),
                          fit: BoxFit.cover,
                        ),
                      ),
                      child: Container(
                        color: _dominantColor != null
                            ? _dominantColor!.withOpacity(0.75)
                            : Colors.black.withOpacity(0.8),
                      ),
                    ),
                  ),
                ),
              )
            else if (!_useBlurBackground)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeInOut,
                  color: _dominantColor != null
                      ? _dominantColor!.withOpacity(0.1)
                      : Colors.black,
                ),
              ),

            // Row Layout
            Row(
              children: [
                // Main Player Area
                Expanded(
                  flex: 3,
                  child: Stack(
                    children: [
                      // Content (Background moved to root)

                      // Content
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: _musicPlayer.showLyrics,
                              builder: (context, showLyrics, _) {
                                return Expanded(
                                  child: IndexedStack(
                                    index: showLyrics ? 0 : 1,
                                    sizing: StackFit.expand,
                                    children: [
                                      // Lyrics View
                                      IgnorePointer(
                                        ignoring: !showLyrics,
                                        child: AnimatedSlide(
                                          offset: showLyrics
                                              ? Offset.zero
                                              : const Offset(0, 0.04),
                                          duration: const Duration(
                                            milliseconds: 350,
                                          ),
                                          curve: Curves.easeOutCubic,
                                          child: AnimatedOpacity(
                                            opacity: showLyrics ? 1.0 : 0.0,
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            curve: Curves.easeInOut,
                                            child: SizedBox.expand(
                                              child: Column(
                                                key: const ValueKey(
                                                  'lyrics_column_view',
                                                ),
                                              children: [
                                                // HEADER ROW: Artwork + Info + Controls
                                                // Al mostrar lyrics, baja desde arriba
                                                // (donde estaba el artwork grande); al
                                                // volver al player, sube hacia fuera.
                                                AnimatedSlide(
                                                  offset: showLyrics
                                                      ? Offset.zero
                                                      : const Offset(0, -0.25),
                                                  duration: const Duration(
                                                    milliseconds: 450,
                                                  ),
                                                  curve: Curves.easeInOutCubic,
                                                  child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        left: 0,
                                                        right: 0,
                                                        top: 40,
                                                        bottom: 10,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      // Artwork (Small)
                                                      Container(
                                                        width: 80,
                                                        height: 80,
                                                        decoration: BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                8,
                                                              ),
                                                          image:
                                                              _currentArt !=
                                                                  null
                                                              ? DecorationImage(
                                                                  image: MemoryImage(
                                                                    _currentArt!,
                                                                  ),
                                                                  fit: BoxFit
                                                                      .cover,
                                                                )
                                                              : null,
                                                          color: Colors.white12,
                                                        ),
                                                        child:
                                                            _currentArt == null
                                                            ? const Icon(
                                                                Icons
                                                                    .music_note,
                                                                color: Colors
                                                                    .white54,
                                                              )
                                                            : null,
                                                      ),
                                                      const SizedBox(width: 16),

                                                      // Info: Title + Artist
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Text(
                                                              _currentTitle
                                                                      .isEmpty
                                                                  ? widget.getText(
                                                                      'no_song',
                                                                      fallback:
                                                                          'No Song',
                                                                    )
                                                                  : _currentTitle,
                                                              style: const TextStyle(
                                                                fontSize: 20,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                color: Colors
                                                                    .white,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                            const SizedBox(
                                                              height: 4,
                                                            ),
                                                            Text(
                                                              _currentArtist,
                                                              style: TextStyle(
                                                                fontSize: 16,
                                                                color: _adjustColorForControls(
                                                                  _dominantColor,
                                                                ),
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                          ],
                                                        ),
                                                      ),

                                                      const SizedBox(width: 16),

                                                      // Mini Controls
                                                      Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          IconButton(
                                                            icon: Icon(
                                                              Icons
                                                                  .skip_previous_rounded,
                                                              color: _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                            ),
                                                            onPressed:
                                                                _playPrevious,
                                                          ),
                                                          Container(
                                                            decoration: BoxDecoration(
                                                              color: _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                              shape: BoxShape
                                                                  .circle,
                                                            ),
                                                            child: IconButton(
                                                              icon: ValueListenableBuilder<bool>(
                                                                valueListenable:
                                                                    _musicPlayer
                                                                        .isPlaying,
                                                                builder: (ctx, isPlaying, _) => Icon(
                                                                  isPlaying
                                                                      ? Icons
                                                                            .pause_rounded
                                                                      : Icons
                                                                            .play_arrow_rounded,
                                                                  color: _getContrastColor(
                                                                    _adjustColorForControls(
                                                                      _dominantColor,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                              onPressed:
                                                                  _togglePlayPause,
                                                            ),
                                                          ),
                                                          IconButton(
                                                            icon: Icon(
                                                              Icons
                                                                  .skip_next_rounded,
                                                              color: _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                            ),
                                                            onPressed:
                                                                _playNext,
                                                          ),
                                                          // Lyrics Toggle (to exit view)
                                                          IconButton(
                                                            icon: const Icon(
                                                              Icons.lyrics,
                                                            ),
                                                            color:
                                                                _adjustColorForControls(
                                                                  _dominantColor,
                                                                ),
                                                            onPressed: () =>
                                                                _musicPlayer
                                                                        .showLyrics
                                                                        .value =
                                                                    false,
                                                            tooltip: widget.getText(
                                                              'hide_lyrics',
                                                              fallback:
                                                                  'Hide Lyrics',
                                                            ),
                                                          ),
                                                          PopupMenuButton<
                                                            String
                                                          >(
                                                            color: const Color(
                                                              0xFF2C2C2E,
                                                            ),
                                                            shape: RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    15,
                                                                  ),
                                                            ),
                                                            elevation: 4,
                                                            icon: Icon(
                                                              Icons.more_vert,
                                                              color: _adjustColorForControls(
                                                                _dominantColor,
                                                              ),
                                                            ),
                                                            onSelected: (value) async {
                                                              if (value ==
                                                                  'synchronize') {
                                                                _showSyncDialog();
                                                              } else if (value ==
                                                                  'search_lyrics') {
                                                                _showSearchLyricsDialog();
                                                              } else if (value ==
                                                                  'remove_lyrics') {
                                                                final title =
                                                                    _musicPlayer
                                                                        .currentTitle
                                                                        .value;
                                                                final artist =
                                                                    _musicPlayer
                                                                        .currentArtist
                                                                        .value;
                                                                await LyricsService()
                                                                    .deleteLyrics(
                                                                      title,
                                                                      artist,
                                                                    );
                                                                _musicPlayer
                                                                        .currentLyrics
                                                                        .value =
                                                                    null;
                                                              }
                                                            },
                                                            itemBuilder:
                                                                (
                                                                  BuildContext
                                                                  context,
                                                                ) =>
                                                                    <
                                                                      PopupMenuEntry<
                                                                        String
                                                                      >
                                                                    >[
                                                                      PopupMenuItem<
                                                                        String
                                                                      >(
                                                                        value:
                                                                            'synchronize',
                                                                        child: Row(
                                                                          children: [
                                                                            const Icon(
                                                                              Icons.timer,
                                                                              color: Colors.white70,
                                                                            ),
                                                                            const SizedBox(
                                                                              width: 8,
                                                                            ),
                                                                            Text(
                                                                              widget.getText(
                                                                                'synchronize',
                                                                                fallback: 'Sincronizar',
                                                                              ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                      PopupMenuItem<
                                                                        String
                                                                      >(
                                                                        value:
                                                                            'search_lyrics',
                                                                        child: Row(
                                                                          children: [
                                                                            const Icon(
                                                                              Icons.search,
                                                                              color: Colors.white70,
                                                                            ),
                                                                            const SizedBox(
                                                                              width: 8,
                                                                            ),
                                                                            Text(
                                                                              widget.getText(
                                                                                'search_lyrics',
                                                                                fallback: 'Buscar lyrics',
                                                                              ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                      PopupMenuItem<
                                                                        String
                                                                      >(
                                                                        value:
                                                                            'remove_lyrics',
                                                                        child: Row(
                                                                          children: [
                                                                            const Icon(
                                                                              Icons.delete,
                                                                              color: Colors.white70,
                                                                            ),
                                                                            const SizedBox(
                                                                              width: 8,
                                                                            ),
                                                                            Text(
                                                                              widget.getText(
                                                                                'remove_lyrics',
                                                                                fallback: 'Eliminar lyrics',
                                                                              ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                    ],
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                ),

                                                const Divider(
                                                  color: Colors.white12,
                                                  height: 30,
                                                ),

                                                // LYRICS AREA
                                                Expanded(
                                                  child: ValueListenableBuilder<SyncedLyrics?>(
                                                    valueListenable:
                                                        _musicPlayer
                                                            .currentLyrics,
                                                    builder: (context, lyrics, _) {
                                                      if (lyrics == null ||
                                                          !lyrics.hasLyrics) {
                                                        return Center(
                                                          child: Text(
                                                            widget.getText(
                                                              'no_lyrics',
                                                              fallback:
                                                                  'No Lyrics Found',
                                                            ),
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white54,
                                                                  fontSize: 18,
                                                                ),
                                                          ),
                                                        );
                                                      }
                                                      return LyricsDisplay(
                                                        key: ValueKey(
                                                          _musicPlayer
                                                              .currentFilePath
                                                              .value,
                                                        ),
                                                        lyrics: lyrics,
                                                        currentIndexNotifier:
                                                            _lyricIndexNotifier,
                                                        positionNotifier:
                                                            _musicPlayer
                                                                .position,
                                                        getText: widget.getText,
                                                        textAlign:
                                                            TextAlign.start,
                                                        onTap: (timestamp) {
                                                          _player.seek(
                                                            timestamp +
                                                                _lyricsOffset,
                                                          );
                                                        },
                                                        lyricsOffset:
                                                            _lyricsOffset,
                                                        audioPath:
                                                            _musicPlayer
                                                                .currentFilePath
                                                                .value,
                                                        durationNotifier:
                                                            _musicPlayer
                                                                .duration,
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        ),
                                      ),

                                      // Cover Art View
                                      IgnorePointer(
                                        ignoring: showLyrics,
                                        // Al pasar a lyrics, la vista del player
                                        // sube y se encoge hacia la posición del
                                        // header de lyrics (morph de artwork +
                                        // título + artista).
                                        child: AnimatedSlide(
                                          offset: showLyrics
                                              ? const Offset(0, -0.22)
                                              : Offset.zero,
                                          duration: const Duration(
                                            milliseconds: 450,
                                          ),
                                          curve: Curves.easeInOutCubic,
                                          child: AnimatedScale(
                                            scale: showLyrics ? 0.55 : 1.0,
                                            duration: const Duration(
                                              milliseconds: 450,
                                            ),
                                            curve: Curves.easeInOutCubic,
                                            child: AnimatedOpacity(
                                              opacity: showLyrics ? 0.0 : 1.0,
                                              duration: const Duration(
                                                milliseconds: 300,
                                              ),
                                              curve: Curves.easeInOut,

                                          child: Column(
                                            key: const ValueKey('cover_art'),
                                            children: [
                                              const Spacer(),
                                              Flexible(
                                                flex: 12,
                                                // En modo artwork expandido la portada es el
                                                // fondo; aquí va un área de gestos transparente.
                                                child: _isFullArtworkMode
                                                    ? _buildFullArtworkGestureArea()
                                                    : AspectRatio(
                                                  aspectRatio: 1,
                                                  child: ValueListenableBuilder<bool>(
                                                    valueListenable: ValueNotifier(
                                                      true,
                                                    ), // Dummy wrapper to minimize changes if needed or just remove it.
                                                    builder: (context, _, __) {
                                                      return Container(
                                                        decoration: BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                20,
                                                              ),
                                                          // Sin sombra: el
                                                          // artwork se muestra
                                                          // limpio.
                                                          color: Colors.white12,
                                                        ),
                                                        child: ClipRRect(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                20,
                                                              ),
                                                          child: AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      350,
                                                                ),
                                                            switchInCurve: Curves
                                                                .easeOutQuad,
                                                            switchOutCurve:
                                                                Curves
                                                                    .easeInQuad,
                                                            transitionBuilder: (child, animation) {
                                                              // Determine direction from GlobalMusicPlayer
                                                              // 1 = Next (Enter from Right), -1 = Prev (Enter from Left)
                                                              final direction =
                                                                  _musicPlayer
                                                                      .transitionDirection
                                                                      .value;

                                                              // Calculate offsets based on direction
                                                              final inBegin =
                                                                  Offset(
                                                                    direction
                                                                        .toDouble(),
                                                                    0.0,
                                                                  );
                                                              final outEnd = Offset(
                                                                -direction
                                                                    .toDouble(),
                                                                0.0,
                                                              );

                                                              final inAnimation =
                                                                  Tween<Offset>(
                                                                    begin:
                                                                        inBegin,
                                                                    end: Offset
                                                                        .zero,
                                                                  ).animate(
                                                                    CurvedAnimation(
                                                                      parent:
                                                                          animation,
                                                                      curve: Curves
                                                                          .easeOutQuad,
                                                                    ),
                                                                  );

                                                              final outAnimation =
                                                                  Tween<Offset>(
                                                                    begin:
                                                                        outEnd, // Start at -1 if dir=1 (Wait, no. Start at 0, end at -1)
                                                                    // BUT for exit, we map t=1->0 to Position.
                                                                    // We want child to move FROM 0 TO -1.
                                                                    // At t=1 (start), pos should be 0.
                                                                    // At t=0 (end), pos should be -1.
                                                                    // So Tween(begin: -1, end: 0) works because lerp(-1,0,1)=0, lerp(-1,0,0)=-1.
                                                                    // IF direction=1 (Next), we want exit to Left (-1). So Tween(-1, 0).
                                                                    // IF direction=-1 (Prev), we want exit to Right (1). So Tween(1, 0).
                                                                    end: Offset
                                                                        .zero,
                                                                  ).animate(
                                                                    CurvedAnimation(
                                                                      parent:
                                                                          animation,
                                                                      curve: Curves
                                                                          .easeInQuad,
                                                                    ),
                                                                  );

                                                              if (child.key ==
                                                                  ValueKey(
                                                                    _currentTitle,
                                                                  )) {
                                                                return SlideTransition(
                                                                  position:
                                                                      inAnimation,
                                                                  child: child,
                                                                );
                                                              } else {
                                                                return SlideTransition(
                                                                  position:
                                                                      outAnimation,
                                                                  child: child,
                                                                );
                                                              }
                                                            },
                                                            child: GestureDetector(
                                                              key: ValueKey(
                                                                _currentTitle,
                                                              ),
                                                              behavior:
                                                                  HitTestBehavior
                                                                      .opaque,
                                                              // Gestos en la portada (forawn_mobile):
                                                              // swipe horizontal (cambiar canción),
                                                              // swipe vertical abajo (cerrar) y
                                                              // doble click (dar like).
                                                              onHorizontalDragEnd:
                                                                  _handleHorizontalSwipe,
                                                              onVerticalDragEnd:
                                                                  _handleVerticalSwipe,
                                                              onDoubleTap:
                                                                  _handleDoubleTapLike,
                                                              child: Stack(
                                                                fit: StackFit
                                                                    .expand,
                                                                children: [
                                                                  Container(
                                                                    width: double
                                                                        .infinity,
                                                                    height: double
                                                                        .infinity,
                                                                    decoration:
                                                                        _currentArt !=
                                                                            null
                                                                        ? BoxDecoration(
                                                                            image:
                                                                                DecorationImage(
                                                                                  image:
                                                                                      MemoryImage(
                                                                                        _currentArt!,
                                                                                      ),
                                                                                  fit:
                                                                                      BoxFit
                                                                                          .cover,
                                                                                  filterQuality:
                                                                                      FilterQuality
                                                                                          .high,
                                                                                ),
                                                                          )
                                                                        : null,
                                                                    child:
                                                                        _currentArt ==
                                                                            null
                                                                        ? const Icon(
                                                                            Icons
                                                                                .music_note,
                                                                            size:
                                                                                120,
                                                                            color:
                                                                                Colors
                                                                                    .white12,
                                                                          )
                                                                        : null,
                                                                  ),
                                                                  // Corazón animado al dar like
                                                                  _buildHeartOverlay(),
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                _currentTitle.isEmpty
                                                    ? widget.getText(
                                                        'no_song',
                                                        fallback: 'No Song',
                                                      )
                                                    : _currentTitle,
                                                style: const TextStyle(
                                                  fontSize: 28,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white,
                                                ),
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                _currentArtist,
                                                style: TextStyle(
                                                  fontSize: 18,
                                                  color:
                                                      _adjustColorForControls(
                                                        _dominantColor,
                                                      ),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                                textAlign: TextAlign.center,
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
                              },
                            ),

                            ValueListenableBuilder<bool>(
                              valueListenable: _musicPlayer.showLyrics,
                              builder: (context, showLyrics, _) {
                                return AnimatedSwitcher(
                                  duration: const Duration(
                                    milliseconds: 400,
                                  ),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: (child, animation) {
                                    // Los controles suben al pasar a lyrics
                                    // (se mueven hacia el header) y entran
                                    // desde abajo al volver al player.
                                    return SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0, 0.4),
                                        end: Offset.zero,
                                      ).animate(
                                        CurvedAnimation(
                                          parent: animation,
                                          curve: Curves.easeOutCubic,
                                        ),
                                      ),
                                      child: FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: showLyrics
                                      ? const SizedBox.shrink()
                                      : Column(
                                          key: const ValueKey(
                                            'player_controls',
                                          ),
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const SizedBox(height: 24),
                                            // Controls
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    // Shuffle Toggle (estilo forawn_mobile)
                                                    IconButton(
                                                      icon: Icon(
                                                        Icons.shuffle,
                                                        color:
                                                            _musicPlayer
                                                                .isShuffle
                                                                .value
                                                            ? _adjustColorForControls(
                                                                _dominantColor,
                                                              )
                                                            : Colors.white54,
                                                        size: 24,
                                                      ),
                                                      onPressed: () {
                                                        _musicPlayer
                                                                .isShuffle
                                                                .value =
                                                            !_musicPlayer
                                                                .isShuffle
                                                                .value;
                                                        setState(() {});
                                                      },
                                                    ),
                                                    const SizedBox(width: 8),
                                                    // Loop Toggle (estilo forawn_mobile)
                                                    IconButton(
                                                      icon: Icon(
                                                        _musicPlayer
                                                                    .loopMode
                                                                    .value ==
                                                                LoopMode.one
                                                            ? Icons
                                                                  .repeat_one_rounded
                                                            : Icons
                                                                  .repeat_rounded,
                                                        color:
                                                            _musicPlayer
                                                                    .loopMode
                                                                    .value !=
                                                                LoopMode.off
                                                            ? _adjustColorForControls(
                                                                _dominantColor,
                                                              )
                                                            : Colors.white54,
                                                        size: 24,
                                                      ),
                                                      onPressed: () {
                                                        final modes = [
                                                          LoopMode.off,
                                                          LoopMode.all,
                                                          LoopMode.one,
                                                        ];
                                                        final idx = modes
                                                            .indexOf(
                                                              _musicPlayer
                                                                  .loopMode
                                                                  .value,
                                                            );
                                                        _musicPlayer
                                                                .loopMode
                                                                .value =
                                                            modes[(idx + 1) %
                                                                modes.length];
                                                        setState(() {});
                                                      },
                                                    ),
                                                    const SizedBox(width: 16),
                                                    // Previous (estilo forawn_mobile: icono grande)
                                                    IconButton(
                                                      icon: Icon(
                                                        Icons
                                                            .skip_previous_rounded,
                                                        size: 56,
                                                        color:
                                                            _adjustColorForControls(
                                                              _dominantColor,
                                                            ),
                                                      ),
                                                      onPressed: _playPrevious,
                                                    ),
                                                    const SizedBox(width: 16),
                                                    // Play/Pause grande sin círculo, con spinner de
                                                    // carga (estilo forawn_mobile).
                                                    IconButton(
                                                      iconSize: 80,
                                                      padding: EdgeInsets.zero,
                                                      constraints:
                                                          const BoxConstraints(),
                                                      icon:
                                                          ValueListenableBuilder<
                                                              PlayerState
                                                          >(
                                                        valueListenable:
                                                            _musicPlayer
                                                                .playerState,
                                                        builder: (ctx, state,
                                                            _) {
                                                          final isLoading =
                                                              state ==
                                                                      PlayerState
                                                                          .stopped &&
                                                                  _musicPlayer
                                                                      .currentFilePath
                                                                      .value
                                                                      .isNotEmpty;
                                                          final isPlaying =
                                                              _musicPlayer
                                                                  .isPlaying
                                                                  .value;
                                                          return isLoading
                                                              ? SizedBox(
                                                                  width: 80,
                                                                  height: 80,
                                                                  child:
                                                                      Center(
                                                                    child:
                                                                        SizedBox(
                                                                      width: 36,
                                                                      height:
                                                                          36,
                                                                      child:
                                                                          CircularProgressIndicator(
                                                                        strokeWidth:
                                                                            3,
                                                                        color:
                                                                            _adjustColorForControls(
                                                                              _dominantColor,
                                                                            ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                )
                                                              : Icon(
                                                                  isPlaying
                                                                      ? Icons
                                                                          .pause_rounded
                                                                      : Icons
                                                                          .play_arrow_rounded,
                                                                  color:
                                                                      _adjustColorForControls(
                                                                        _dominantColor,
                                                                      ),
                                                                  size: 80,
                                                                );
                                                        },
                                                      ),
                                                      onPressed:
                                                          _togglePlayPause,
                                                    ),
                                                    const SizedBox(width: 16),
                                                    // Next (estilo forawn_mobile: icono grande)
                                                    IconButton(
                                                      icon: Icon(
                                                        Icons.skip_next_rounded,
                                                        size: 56,
                                                        color:
                                                            _adjustColorForControls(
                                                              _dominantColor,
                                                            ),
                                                      ),
                                                      onPressed: _playNext,
                                                    ),
                                                    const SizedBox(width: 12),
                                                    // Lyrics Toggle
                                                    ValueListenableBuilder<
                                                      bool
                                                    >(
                                                      valueListenable:
                                                          _musicPlayer
                                                              .showLyrics,
                                                      builder: (context, showLyrics, _) {
                                                        return IconButton(
                                                          icon: Icon(
                                                            showLyrics
                                                                ? Icons.lyrics
                                                                : Icons
                                                                      .lyrics_outlined,
                                                            color:
                                                                _adjustColorForControls(
                                                                  _dominantColor,
                                                                ),
                                                            size: 24,
                                                          ),
                                                          onPressed: () =>
                                                              _musicPlayer
                                                                      .showLyrics
                                                                      .value =
                                                                  !showLyrics,
                                                        );
                                                      },
                                                    ),
                                                    const SizedBox(width: 8),
                                                    // Heart / Like: adopta el color del acento
                                                    AnimatedBuilder(
                                                      animation:
                                                          PlaylistService(),
                                                      builder: (context, _) {
                                                        final song =
                                                            _getCurrentSong();
                                                        final isLiked =
                                                            PlaylistService()
                                                                .isLiked(
                                                                  song.id,
                                                                );
                                                        return IconButton(
                                                          tooltip: widget.getText(
                                                            isLiked
                                                                ? 'remove_favorites'
                                                                : 'add_favorites',
                                                            fallback: isLiked
                                                                ? 'Remove from favorites'
                                                                : 'Add to favorites',
                                                          ),
                                                          icon: Icon(
                                                            isLiked
                                                                ? Icons.favorite
                                                                : Icons
                                                                    .favorite_border,
                                                            color:
                                                                _adjustColorForControls(
                                                                  _dominantColor,
                                                                ),
                                                            size: 24,
                                                          ),
                                                          onPressed: () {
                                                            PlaylistService()
                                                                .toggleLike(
                                                                  song.id,
                                                                );
                                                            setState(() {});
                                                          },
                                                        );
                                                      },
                                                    ),
                                                      ],
                                                    ),

                                                const SizedBox(height: 8),

                                                // Progress Bar (encima de los
                                                // botones): barra larga con el
                                                // tiempo transcurrido y la duración
                                                // en los extremos, debajo (mm:ss).
                                                _buildProgressBar(),

                                                const SizedBox(height: 8),


                                              ],
                                            ),
                                          ],
                                        ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Playlist Sidebar (Flat Design)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: _showPlaylist ? 350 : 0,
                  color: Colors
                      .transparent, // Transparent to show global background
                  child: Offstage(
                    offstage: !_showPlaylist,
                    child: Column(
                      children: [
                        // Simple Header
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: Colors.white12,
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.queue_music,
                                color: Colors.white,
                                size: 24,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                widget.getText(
                                  'playlist_title',
                                  fallback: 'Start List',
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: Colors.white,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  size: 20,
                                  color: Colors.white70,
                                ),
                                onPressed: () =>
                                    setState(() => _showPlaylist = false),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          // Contenedor estilo forawn_mobile (blanco 5%, radio 16).
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: TextField(
                              controller: _searchController,
                              onChanged: _filterFiles,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                              cursorColor: const Color(0xFFD046FF),
                              decoration: InputDecoration(
                                isCollapsed: true,
                                hintText: widget.getText(
                                  'search_song',
                                  fallback: 'Search in list...',
                                ),
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                  fontSize: 16,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                border: InputBorder.none,
                                prefixIcon: Icon(
                                  Icons.search,
                                  size: 20,
                                  color: Colors.white.withOpacity(0.5),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _filteredFiles.length,
                            itemBuilder: (context, index) {
                              final file = _filteredFiles[index] as File;
                              final name = p.basename(file.path);
                              final isPlaying =
                                  _musicPlayer.currentFilePath.value ==
                                  file.path;
                              return Material(
                                color: isPlaying
                                    ? Colors.white.withOpacity(0.1)
                                    : Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    final realIndex = _files.indexOf(file);
                                    if (realIndex != -1) _playFile(realIndex);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        if (isPlaying)
                                          const Padding(
                                            padding: EdgeInsets.only(right: 12),
                                            child: Icon(
                                              Icons.equalizer,
                                              color: Colors.white,
                                              size: 16,
                                            ),
                                          )
                                        else
                                          const Padding(
                                            padding: EdgeInsets.only(right: 12),
                                            child: Text(
                                              "•",
                                              style: TextStyle(
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ),
                                        Expanded(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: isPlaying
                                                  ? Colors.white
                                                  : Colors.white70,
                                              fontWeight: isPlaying
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Toggle Strip
                Container(
                  width: 40,
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          _showPlaylist
                              ? Icons.chevron_right
                              : Icons.chevron_left,
                          color: Colors.white60,
                        ),
                        onPressed: _togglePlaylist,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Custom AppBar (Matching Settings Style)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => windowManager.startDragging(),
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  color: Colors.transparent,
                  child: Row(
                    children: [
                      // Espacio para traffic lights nativos en macOS
                      if (gMacTrafficLightInset > 0)
                        SizedBox(width: gMacTrafficLightInset),
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            color: Colors.black26,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.music_note,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.getText(
                            'music_player_title',
                            fallback: 'Music Player',
                          ),
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                        ),
                      ),
                      // Dots menu (añadir a playlist / editar metadatos):
                      // movido a la title bar.
                      PopupMenuButton<String>(
                        color: const Color(0xFF2C2C2E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                        elevation: 4,
                        icon: const Icon(
                          Icons.more_vert,
                          size: 18,
                          color: Colors.white,
                        ),
                        onSelected: (value) async {
                          if (value == 'edit_metadata') {
                            _showEditMetadataDialog(context);
                          } else if (value == 'add_playlist') {
                            _showAddToPlaylistDialog(context);
                          } else if (value == 'toggle_artwork_mode') {
                            _toggleArtworkMode();
                          }
                        },
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(
                            value: 'add_playlist',
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.playlist_add,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  widget.getText(
                                    'add_playlist',
                                    fallback: 'Añadir a playlist',
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'edit_metadata',
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.edit,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  widget.getText(
                                    'edit_metadata',
                                    fallback: 'Editar metadatos',
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'toggle_artwork_mode',
                            child: Row(
                              children: [
                                Icon(
                                  _isFullArtworkMode
                                      ? Icons.crop_square
                                      : Icons.fullscreen,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  widget.getText(
                                    _isFullArtworkMode
                                        ? 'square_artwork_mode'
                                        : 'full_artwork_mode',
                                    fallback: _isFullArtworkMode
                                        ? 'Square Mode'
                                        : 'Full Mode',
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // Botón de volumen: popover con la barra de volumen
                      // sincronizada con GlobalMusicPlayer.
                      _PlayerVolumeButton(
                        getText: widget.getText,
                        iconColor: Colors.white,
                      ),
                      if (gShowWindowButtons) ...[
                        IconButton(
                          tooltip: widget.getText(
                            'minimize',
                            fallback: 'Minimize',
                          ),
                          icon: const Icon(
                            Icons.remove,
                            size: 18,
                            color: Colors.white,
                          ),
                          onPressed: _minimize,
                        ),
                        IconButton(
                          tooltip: widget.getText(
                            'maximize',
                            fallback: 'Maximize',
                          ),
                          icon: const Icon(
                            Icons.crop_square,
                            size: 18,
                            color: Colors.white,
                          ),
                          onPressed: _maximizeRestore,
                        ),
                      ],
                      IconButton(
                        tooltip: widget.getText('back', fallback: 'Back'),
                        icon: const Icon(
                          Icons.arrow_back,
                          size: 18,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Lyrics Synchronization Logic ---

  Future<void> _loadSavedOffset() async {
    final path = _musicPlayer.currentFilePath.value;
    if (path.isEmpty) return;

    final songId = path.hashCode.toString();
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOffsetMs = prefs.getInt('lyrics_offset_$songId') ?? 0;
      if (mounted) {
        setState(() {
          _lyricsOffset = Duration(milliseconds: savedOffsetMs);
        });
        _updateLyricIndex();
      }
    } catch (e) {
      debugPrint('[PlayerScreen] Error loading lyrics offset: $e');
    }
  }

  void _updateLyricIndex() {
    final lyrics = _musicPlayer.currentLyrics.value;
    if (lyrics == null || !lyrics.hasLyrics) {
      if (_lyricIndexNotifier.value != null && lyrics == null) {
        _lyricIndexNotifier.value = null;
      }
      return;
    }
    final pos = _musicPlayer.position.value;
    final effectivePos = pos - _lyricsOffset;
    final index = lyrics.getCurrentLineIndex(effectivePos);

    if (index != _lyricIndexNotifier.value) {
      _lyricIndexNotifier.value = index;
    }
  }

  Future<void> _adjustOffset(int milliseconds) async {
    setState(() {
      _lyricsOffset += Duration(milliseconds: milliseconds);
    });
    _updateLyricIndex();

    final path = _musicPlayer.currentFilePath.value;
    if (path.isEmpty) return;
    final songId = path.hashCode.toString();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('lyrics_offset_$songId', _lyricsOffset.inMilliseconds);
    } catch (e) {
      debugPrint('[PlayerScreen] Error saving lyrics offset: $e');
    }
  }

  Widget _buildSyncButton(
    String label,
    int ms,
    Color accent,
    VoidCallback onTap,
  ) {
    final isNegative = ms < 0;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            // Colores del diálogo de forawn_mobile: rojo para adelantar,
            // verde para atrasar.
            backgroundColor: isNegative
                ? Colors.red.withOpacity(0.15)
                : Colors.green.withOpacity(0.15),
            foregroundColor: isNegative ? Colors.redAccent : Colors.greenAccent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  void _showSyncDialog() {
    // Acento igual que en forawn_mobile: color dominante de la canción,
    // aclarado si es muy oscuro; fallback al acento de la app.
    Color accent = _adjustColorForControls(_dominantColor);
    if (accent == Colors.white) accent = const Color(0xFFD046FF);

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(24),
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header (mismo layout que forawn_mobile): icono del timer
                  // en contenedor acento 20% + título + subtítulo.
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.timer, color: accent, size: 24),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.getText(
                                'synchronization',
                                fallback: 'Synchronization',
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.getText(
                                'adjust_lyrics_time',
                                fallback: 'Adjust lyrics timing',
                              ),
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Vista previa de lyrics en vivo (posición + offset
                  // actuales), igual que en forawn_mobile.
                  ValueListenableBuilder<Duration>(
                    valueListenable: _musicPlayer.position,
                    builder: (context, position, _) {
                      final lyrics = _musicPlayer.currentLyrics.value;
                      final lines = lyrics?.lines ?? const [];
                      final index = (lyrics != null && lyrics.hasLyrics)
                          ? (lyrics.getCurrentLineIndex(
                                  position - _lyricsOffset,
                                ) ??
                                -1)
                          : -1;
                      final currentText = (index >= 0 && index < lines.length)
                          ? lines[index].text
                          : '';
                      final nextText = (index + 1 < lines.length)
                          ? lines[index + 1].text
                          : '';

                      return Column(
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  currentText.isEmpty ? '...' : currentText,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    height: 1.3,
                                  ),
                                ),
                                if (nextText.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    nextText,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Offset actual (contenedor oscuro, valor en acento).
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '${widget.getText('offset', fallback: 'Offset')}: ',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.6),
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  '${_lyricsOffset.inMilliseconds}ms',
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),

                  // Botones de ajuste (-500/-100/+100/+500). El diálogo NO
                  // se cierra: se actualiza en el mismo frame (igual que
                  // en forawn_mobile).
                  Row(
                    children: [
                      _buildSyncButton('-500ms', -500, accent, () {
                        _adjustOffset(-500);
                        setDialogState(() {});
                      }),
                      _buildSyncButton('-100ms', -100, accent, () {
                        _adjustOffset(-100);
                        setDialogState(() {});
                      }),
                      _buildSyncButton('+100ms', 100, accent, () {
                        _adjustOffset(100);
                        setDialogState(() {});
                      }),
                      _buildSyncButton('+500ms', 500, accent, () {
                        _adjustOffset(500);
                        setDialogState(() {});
                      }),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Done button (ancho completo, acento).
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        widget.getText('done', fallback: 'Done'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _showSearchLyricsDialog() {
    final title = _musicPlayer.currentTitle.value;
    final artist = _musicPlayer.currentArtist.value;
    final searchController = TextEditingController(text: '$title $artist');

    List<LyricsSearchResult>? results;
    bool isLoading = false;
    String? error;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            Future<void> performSearch() async {
              final query = searchController.text.trim();
              if (query.isEmpty) return;

              setState(() {
                isLoading = true;
                error = null;
                results = null;
              });

              try {
                // FocusScope.of(context).unfocus(); // Opcional: ocultar teclado
                final res = await LyricsService().searchLyrics(query);
                if (context.mounted) {
                  setState(() {
                    results = res;
                    isLoading = false;
                  });
                }
              } catch (e) {
                if (context.mounted) {
                  setState(() {
                    error = e.toString();
                    isLoading = false;
                  });
                }
              }
            }

            return Dialog(
              backgroundColor: const Color(0xFF1C1C1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Container(
                width: 500, // Fixed width for desktop/large screens
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                  minWidth: 300,
                  maxWidth: 500,
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Text(
                          widget.getText(
                            'search_lyrics_title',
                            fallback: 'Buscar Letra',
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                            ),
                            onPressed: () => Navigator.pop(context),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Input estilo forawn_mobile (blanco 5%, radio 16, sin borde).
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: TextField(
                        controller: searchController,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                        cursorColor: const Color(0xFFD046FF),
                        onSubmitted: (_) => performSearch(),
                        decoration: InputDecoration(
                          hintText: widget.getText(
                            'song_artist_hint',
                            fallback: 'Canción Artista...',
                          ),
                          hintStyle: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(
                              Icons.search,
                              color: Color(0xFFD046FF),
                            ),
                            onPressed: performSearch,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: isLoading
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFFD046FF),
                              ),
                            )
                          : error != null
                          ? Center(
                              child: Text(
                                error!,
                                style: const TextStyle(color: Colors.redAccent),
                                textAlign: TextAlign.center,
                              ),
                            )
                          : results == null
                          ? Center(
                              child: Text(
                                widget.getText(
                                  'search_results_placeholder',
                                  fallback: 'Busca para ver resultados',
                                ),
                                style: const TextStyle(color: Colors.white38),
                              ),
                            )
                          : results!.isEmpty
                          ? Center(
                              child: Text(
                                widget.getText(
                                  'no_results_found',
                                  fallback: 'No se encontraron resultados',
                                ),
                                style: const TextStyle(color: Colors.white38),
                              ),
                            )
                          : ListView.separated(
                              itemCount: results!.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final item = results![index];
                                return InkWell(
                                  onTap: () async {
                                    // Guardar
                                    await LyricsService().saveManualLyrics(
                                      title,
                                      artist,
                                      item.syncedLyrics.isNotEmpty
                                          ? item.syncedLyrics
                                          : item.plainLyrics,
                                    );

                                    // Actualizar player
                                    final newLyrics = SyncedLyrics.fromLRC(
                                      songTitle: title,
                                      artist: artist,
                                      lrcContent: item.syncedLyrics.isNotEmpty
                                          ? item.syncedLyrics
                                          : item.plainLyrics,
                                    );
                                    _musicPlayer.currentLyrics.value =
                                        newLyrics;

                                    Navigator.pop(context);
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2C2C2E),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.white10,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.library_music,
                                            color: Colors.white70,
                                            size: 20,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.trackName,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                item.artistName,
                                                style: const TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 12,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (item.synced)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8.0,
                                            ),
                                            child: Container(
                                              padding: const EdgeInsets.all(4),
                                              decoration: const BoxDecoration(
                                                color: Color(
                                                  0xFF1DB954,
                                                ), // Spotify Green ish
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.access_time,
                                                color: Colors.black,
                                                size: 14,
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
      },
    );
  }
}
/// Botón de volumen para la title bar del PlayerScreen. Al hacer clic
/// despliega un mini contenedor (del tamaño de su contenido) con la barra
/// de volumen sincronizada con GlobalMusicPlayer.
class _PlayerVolumeButton extends StatefulWidget {
  final String Function(String key, {String? fallback}) getText;
  final Color iconColor;

  const _PlayerVolumeButton({
    required this.getText,
    required this.iconColor,
  });

  @override
  State<_PlayerVolumeButton> createState() => _PlayerVolumeButtonState();
}

class _PlayerVolumeButtonState extends State<_PlayerVolumeButton> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;

  bool get _open => _entry != null;

  void _toggle() {
    if (_open) {
      _close();
    } else {
      _openPopover();
    }
  }

  void _openPopover() {
    _entry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            // Tap fuera para cerrar (sin bloquear visualmente).
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _close,
              ),
            ),
            CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              offset: const Offset(0, 8),
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  // Tamaño fijo: ancho justo para icono + slider, alto
                  // compacto (el popover no debe estirarse).
                  width: 176,
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.08),
                    ),
                  ),
                  child: ValueListenableBuilder<double>(
                    valueListenable: GlobalMusicPlayer().volume,
                    builder: (context, vol, _) {
                      final muted = GlobalMusicPlayer().isMuted.value;
                      final effective = muted ? 0.0 : vol;
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          InkWell(
                            onTap: () => _setVolume(effective > 0 ? 0.0 : 1.0),
                            customBorder: const CircleBorder(),
                            child: Icon(
                              effective <= 0.0
                                  ? Icons.volume_off_rounded
                                  : effective < 0.5
                                      ? Icons.volume_down_rounded
                                      : Icons.volume_up_rounded,
                              size: 20,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 100,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                              ),
                              child: Slider(
                                value: effective.clamp(0.0, 1.0),
                                onChanged: _setVolume,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    setState(() {});
  }

  void _setVolume(double v) {
    final player = GlobalMusicPlayer();
    player.volume.value = v;
    player.isMuted.value = v <= 0.0;
    player.player.setVolume(v);
    player.saveVolume(v);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: IconButton(
        tooltip: widget.getText('volume', fallback: 'Volume'),
        icon: Icon(
          Icons.volume_up_rounded,
          size: 20,
          color: widget.iconColor,
        ),
        onPressed: _toggle,
      ),
    );
  }
}
