// music_downloader_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import '../main.dart' show gUseNativeFrame;
import '../models/download_task.dart';
import '../widgets/elegant_notification.dart';
import '../services/download_manager.dart';
import '../services/innertube_service.dart';
import 'downloads_screen.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class MusicDownloaderScreen extends StatefulWidget {
  const MusicDownloaderScreen({
    super.key,
    required this.getText,
    required this.currentLang,
    this.onRegisterFolderAction,
    this.onNavigate,
  });

  final String currentLang;
  final TextGetter getText;
  final Function(VoidCallback)? onRegisterFolderAction;
  final Function(String screenId)? onNavigate;

  @override
  State<MusicDownloaderScreen> createState() => _MusicDownloaderScreenState();
}

class _MusicDownloaderScreenState extends State<MusicDownloaderScreen>
    with WindowListener, WidgetsBindingObserver {
  List<Map<String, dynamic>> _canciones = [];
  final TextEditingController _controller = TextEditingController();
  final DownloadManager _dm = DownloadManager();
  late final VoidCallback _dmListener;
  Map<String, DownloadTask> _dmTasksBySource = {};
  final Map<String, String> _imageCache = {};
  SharedPreferences? _prefs;
  bool _searching = false;
  final List<String> _uiLogs = [];
  List<Map<String, dynamic>> _recommendations = [];
  String? _lastSearchQuery;
  bool _loadingRecommendations = false;

  // Estado de carga de playlist (URL de YouTube/YT Music o Spotify).
  bool _loadingPlaylist = false;
  String? _playlistName;
  final List<Map<String, dynamic>> _playlistTracks = [];
  int _playlistResolved = 0;
  int _playlistFailed = 0;
  bool _playlistAbort = false;
  bool _resolveDialogOpen = false;

  /// Estado por pista durante la resolución de una playlist de Spotify; se
  /// muestra en el diálogo de progreso. `_resolveRevision` notifica cada
  /// cambio para reconstruir el diálogo mientras esté abierto.
  final List<_TrackResolveState> _resolveStates = [];
  final ValueNotifier<int> _resolveRevision = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    try {
      if (!gUseNativeFrame) {
        windowManager.addListener(this);
      }
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error adding window listener: $e');
    }

    try {
      _loadPrefs();
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error loading prefs: $e');
    }

    try {
      _loadImageCache();
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error loading image cache: $e');
    }

    if (widget.onRegisterFolderAction != null) {
      try {
        widget.onRegisterFolderAction!(_selectDownloadFolder);
      } catch (e) {
        debugPrint(
          '[MusicDownloaderScreen] Error registering folder action: $e',
        );
      }
    }

    try {
      _dmListener = () {
        try {
          final tasks = _dm.tasks;
          final map = <String, DownloadTask>{};
          for (final t in tasks) {
            if (t.sourceUrl.isNotEmpty) map[t.sourceUrl] = t;
            // Removed mapping by title to avoid false positives on duplicates
          }
          _dmTasksBySource = map;
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {});
          });
        } catch (e) {
          debugPrint('[MusicDownloaderScreen] Error in dm listener: $e');
        }
      };

      _dm.addListener(_dmListener);
      WidgetsBinding.instance.addObserver(this);
    } catch (e) {
      debugPrint(
        '[MusicDownloaderScreen] Error setting up download manager: $e',
      );
    }
    debugPrint('[MusicDownloaderScreen] initState complete');
  }

  @override
  void dispose() {
    try {
      _dm.removeListener(_dmListener);
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error removing dm listener: $e');
    }
    try {
      if (!gUseNativeFrame) {
        windowManager.removeListener(this);
      }
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error removing window listener: $e');
    }
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error removing observer: $e');
    }
    try {
      _controller.dispose();
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error disposing controller: $e');
    }
    try {
      _resolveRevision.dispose();
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] Error disposing resolve notifier: $e');
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      if (state == AppLifecycleState.paused) {
        try {
          _dm.removeListener(_dmListener);
        } catch (e) {
          debugPrint('[MusicDownloaderScreen] Error pausing dm listener: $e');
        }
      } else if (state == AppLifecycleState.resumed) {
        try {
          _dm.addListener(_dmListener);
        } catch (e) {
          debugPrint('[MusicDownloaderScreen] Error resuming dm listener: $e');
        }
      }
    } catch (e) {
      debugPrint(
        '[MusicDownloaderScreen] Error in didChangeAppLifecycleState: $e',
      );
    }
  }

  // Helper para formatear texto a Title Case
  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    if (text.length <= 3)
      return text.toUpperCase(); // Para siglas como BTS, AC/DC

    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }

  Future<Map<String, dynamic>?> _safeGetJson(
    Uri uri, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    debugPrint('[MusicDownloaderScreen] _safeGetJson starting for: $uri');

    try {
      debugPrint('[MusicDownloaderScreen] Making HTTP GET request...');

      final response = await http
          .get(uri)
          .timeout(
            timeout,
            onTimeout: () {
              debugPrint('[MusicDownloaderScreen] Request timed out');
              throw TimeoutException('Request timeout');
            },
          );

      debugPrint(
        '[MusicDownloaderScreen] Response received: ${response.statusCode}',
      );

      if (response.statusCode == 200) {
        debugPrint('[MusicDownloaderScreen] Parsing JSON response...');
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        debugPrint('[MusicDownloaderScreen] JSON parsed successfully');
        return data;
      } else {
        debugPrint(
          '[MusicDownloaderScreen] Non-200 status code: ${response.statusCode}',
        );
        return null;
      }
    } on SocketException catch (e, st) {
      debugPrint(
        '[MusicDownloaderScreen] Network error (SocketException): $e\n$st',
      );
      return null;
    } on TimeoutException catch (e, st) {
      debugPrint('[MusicDownloaderScreen] Timeout error: $e\n$st');
      return null;
    } on http.ClientException catch (e, st) {
      debugPrint('[MusicDownloaderScreen] HTTP client error: $e\n$st');
      return null;
    } on FormatException catch (e, st) {
      debugPrint('[MusicDownloaderScreen] JSON parse error: $e\n$st');
      return null;
    } catch (e, st) {
      debugPrint('[MusicDownloaderScreen] Unexpected error: $e\n$st');
      return null;
    }
  }

  void _uiLog(String s) {
    debugPrint('[MusicDownloaderScreen UI] $s');
    _uiLogs.add(s);
    if (_uiLogs.length > 200) _uiLogs.removeAt(0);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _loadPrefs() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      debugPrint('[MusicDownloaderScreen] loaded prefs');
      final last = _prefs!.getString('last_search_query');
      if (last != null && last.isNotEmpty) {
        _lastSearchQuery = last;
        // Disabled automatic recommendation loading to prevent crashes
        // User can manually search to load recommendations
        debugPrint(
          '[MusicDownloaderScreen] Last search query: $last (auto-load disabled)',
        );
      }
    } catch (e, st) {
      debugPrint('[MusicDownloaderScreen] loadPrefs error: $e\n$st');
    }
  }

  Future<void> _fetchRecommendations(String query) async {
    if (_loadingRecommendations) return;
    if (!mounted) return;

    setState(() => _loadingRecommendations = true);

    try {
      final tracks = await InnertubeService().searchTracks(query, limit: 5);

      if (!mounted) {
        setState(() => _loadingRecommendations = false);
        return;
      }

      debugPrint('[MusicDownloaderScreen] Found ${tracks.length} results');

      final canciones = _processInnertubeResults(tracks);

      if (mounted) {
        setState(() {
          _recommendations = canciones;
        });
      }
    } catch (e, st) {
      debugPrint('[MusicDownloaderScreen] recommendation fetch error: $e\n$st');
    } finally {
      if (mounted) setState(() => _loadingRecommendations = false);
    }
  }

  Future<void> _loadImageCache() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final stored = _prefs!.getString('image_cache_json');
      if (stored != null && stored.isNotEmpty) {
        final Map<String, dynamic> decoded = jsonDecode(stored);
        decoded.forEach((k, v) {
          if (v is String && v.isNotEmpty) _imageCache[k] = v;
        });
      }
    } catch (e) {
      debugPrint('[MusicDownloaderScreen] loadImageCache error: $e');
    }
  }

  Future<void> _buscarCanciones() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    // Si la entrada es una playlist de YouTube/YT Music o Spotify, carga la
    // lista de pistas en lugar de buscar.
    if (InnertubeService.playlistKind(query) != PlaylistKind.none) {
      await _loadPlaylist(query);
      return;
    }

    if (!mounted) return;

    try {
      _prefs ??= await SharedPreferences.getInstance();
    } catch (e, st) {
      debugPrint('[MusicDownloaderScreen] Error loading prefs: $e\n$st');
    }

    if (!mounted) return;

    setState(() {
      _searching = true;
      _canciones = [];
      _recommendations = [];
    });

    debugPrint('[MusicDownloaderScreen] buscarCanciones: query="$query"');

    try {
      debugPrint('[MusicDownloaderScreen] Searching via Innertube: "$query"');

      final tracks = await InnertubeService().searchTracks(query, limit: 100);

      if (!mounted) {
        debugPrint('[MusicDownloaderScreen] Widget unmounted after fetch');
        return;
      }

      debugPrint('[MusicDownloaderScreen] Found ${tracks.length} results');

      final canciones = _processInnertubeResults(tracks);

      final mapped = List<Map<String, dynamic>>.from(canciones);

      debugPrint('[MusicDownloaderScreen] Mapped ${mapped.length} songs');

      if (mapped.isNotEmpty) {
        try {
          final top = mapped.first;
          final artist = top['artist'];
          if (artist != null && artist is String && artist.isNotEmpty) {
            await _prefs!.setString('last_search_query', artist);
          } else {
            await _prefs!.setString('last_search_query', query);
          }
        } catch (e, st) {
          debugPrint(
            '[MusicDownloaderScreen] Error saving last query: $e\n$st',
          );
        }
      } else {
        try {
          await _prefs!.setString('last_search_query', query);
        } catch (e, st) {
          debugPrint('[MusicDownloaderScreen] Error saving query: $e\n$st');
        }
      }

      if (mounted) {
        setState(() {
          _canciones = mapped;
        });
        debugPrint(
          '[MusicDownloaderScreen] UI updated with ${mapped.length} songs',
        );
      }
    } catch (e, st) {
      debugPrint(
        '[MusicDownloaderScreen] buscarCanciones CRITICAL error: $e\n$st',
      );
      if (mounted) {
        showElegantNotification(
          context,
          widget.getText('error', fallback: 'Error: $e'),
          backgroundColor: const Color(0xFFE53935),
          textColor: Colors.white,
          icon: Icons.error_outline,
          iconColor: Colors.white,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _searching = false);
        debugPrint('[MusicDownloaderScreen] Search completed');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Playlists (YouTube / YT Music / Spotify)
  // ---------------------------------------------------------------------------

  Future<void> _loadPlaylist(String input) async {
    final kind = InnertubeService.playlistKind(input);
    if (kind == PlaylistKind.none) return;

    setState(() {
      _searching = false;
      _loadingPlaylist = true;
      _canciones = [];
      _recommendations = [];
      _playlistName = null;
      _playlistTracks.clear();
      _playlistResolved = 0;
      _playlistFailed = 0;
    });

    try {
      if (kind == PlaylistKind.youtube) {
        await _loadYoutubePlaylist(input);
      } else {
        await _loadSpotifyPlaylist(input);
      }
    } catch (e, st) {
      debugPrint('[MusicDownloaderScreen] playlist error: $e\n$st');
      if (mounted) {
        showElegantNotification(
          context,
          widget.getText(
            'playlist_error',
            fallback: 'No se pudo cargar la playlist',
          ),
          backgroundColor: const Color(0xFFE53935),
          textColor: Colors.white,
          icon: Icons.error_outline,
          iconColor: Colors.white,
        );
      }
    } finally {
      if (mounted) setState(() => _loadingPlaylist = false);
    }
  }

  Future<void> _loadYoutubePlaylist(String input) async {
    final playlist = await InnertubeService().fetchPlaylist(input);
    if (!mounted) return;
    final canciones = _processInnertubeResults(playlist.tracks);
    setState(() {
      _playlistName = playlist.name;
      _playlistTracks
        ..clear()
        ..addAll(canciones);
      _canciones = List<Map<String, dynamic>>.from(canciones);
    });
    debugPrint(
      '[MusicDownloaderScreen] YT playlist "${playlist.name}": ${canciones.length} pistas',
    );
  }

  /// Spotify: el embed solo da título+artistas; cada pista se resuelve a su
  /// vídeo exacto buscando "<título> <artistas>" en YT Music (que devuelve el
  /// videoId, artwork cuadrado y metadatos limpios para la descarga).
  ///
  /// Mientras resuelve, muestra un diálogo con el estado por pista; puede
  /// cancelarse o enviarse a segundo plano (la resolución continúa).
  Future<void> _loadSpotifyPlaylist(String input) async {
    final playlist = await InnertubeService().fetchSpotifyPlaylist(input);
    if (!mounted) return;

    _playlistAbort = false;
    setState(() {
      _playlistName = playlist.name;
      _playlistTracks.clear();
      _playlistResolved = 0;
      _playlistFailed = 0;
      _resolveStates
        ..clear()
        ..addAll([
          for (final t in playlist.spotifyTracks)
            _TrackResolveState(t.title, t.artists),
        ]);
    });

    // El diálogo aparece si la resolución tarda más de ~600 ms (para listas
    // diminutas no molesta) y se cierra solo al terminar.
    final dialogTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || !_loadingPlaylist || _resolveDialogOpen) return;
      _openResolveDialog();
    });

    // Cola de resolución con concurrencia limitada.
    final pending = List<SpotifyPlaylistTrack>.from(playlist.spotifyTracks);
    final results = <Map<String, dynamic>>[];

    void bump() => _resolveRevision.value++;

    Future<void> worker() async {
      while (pending.isNotEmpty && mounted && !_playlistAbort) {
        final index = playlist.spotifyTracks.length - pending.length;
        final track = pending.removeAt(0);
        if (index < 0 || index >= _resolveStates.length) continue;
        final state = _resolveStates[index];
        state.status = _ResolveStatus.resolving;
        bump();

        final query = '${track.title} ${track.artists}'.trim();
        try {
          final found = await InnertubeService().searchTracks(query, limit: 1);
          if (found.isNotEmpty) {
            final mapped = _processInnertubeResults(found);
            if (mapped.isNotEmpty) {
              results.add(mapped.first);
              state.status = _ResolveStatus.done;
              bump();
              if (mounted) {
                setState(() {
                  _playlistTracks.add(mapped.first);
                  _playlistResolved++;
                });
              }
              continue;
            }
          }
          state.status = _ResolveStatus.failed;
          bump();
          if (mounted) setState(() => _playlistFailed++);
        } catch (_) {
          state.status = _ResolveStatus.failed;
          bump();
          if (mounted) setState(() => _playlistFailed++);
        }
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    dialogTimer.cancel();

    // Cierra el diálogo si sigue abierto (éxito o cancelación).
    if (_resolveDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      _resolveDialogOpen = false;
    }

    if (!mounted || _playlistAbort) return;
    setState(() {
      _canciones = List<Map<String, dynamic>>.from(_playlistTracks);
    });
    debugPrint(
      '[MusicDownloaderScreen] Spotify playlist "${playlist.name}": '
      '${results.length}/${playlist.spotifyTracks.length} resueltas',
    );
  }

  /// Abre el diálogo de progreso de resolución (no acumulativo).
  void _openResolveDialog() {
    if (_resolveDialogOpen || !mounted) return;
    _resolveDialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PlaylistResolveDialog(
        name: _playlistName ?? '',
        states: _resolveStates,
        revision: _resolveRevision,
        onCancel: () {
          _playlistAbort = true;
          if (_resolveDialogOpen) {
            Navigator.of(context, rootNavigator: true).pop();
            _resolveDialogOpen = false;
          }
        },
        onBackground: () {
          if (_resolveDialogOpen) {
            Navigator.of(context, rootNavigator: true).pop();
            _resolveDialogOpen = false;
          }
        },
      ),
    ).whenComplete(() {
      _resolveDialogOpen = false;
    });
  }

  /// Encola la descarga de todas las pistas de la playlist cargada.
  Future<void> _queuePlaylistDownload() async {
    if (_playlistTracks.isEmpty) return;

    // Asegura carpeta de descargas (misma lógica que _queueDownload).
    final prefs = await SharedPreferences.getInstance();
    String? downloadFolder = prefs.getString('download_folder');
    if (downloadFolder == null || downloadFolder.isEmpty) {
      final carpeta = await FilePicker.getDirectoryPath();
      if (carpeta == null) {
        showElegantNotification(
          context,
          widget.getText('download_cancelled', fallback: 'Descarga cancelada'),
          backgroundColor: const Color(0xFFE53935),
          textColor: Colors.white,
          icon: Icons.cancel,
          iconColor: Colors.white,
        );
        return;
      }
      downloadFolder = p.normalize(carpeta);
      await prefs.setString('download_folder', downloadFolder);
    }

    var queued = 0;
    for (final c in _playlistTracks) {
      final src = (c['url'] ?? '').toString();
      // Evita duplicar pistas ya encoladas/descargadas.
      if (src.isNotEmpty && _dmTasksBySource.containsKey(src)) continue;
      await _queueDownload(c, silent: true);
      queued++;
    }

    if (mounted) {
      showElegantNotification(
        context,
        '$queued ${widget.getText(
          'playlist_queued',
          fallback: 'canciones en cola de descarga',
        )}',
        backgroundColor: const Color(0xFF2C2C2C),
        textColor: Colors.white,
        icon: Icons.playlist_add_check,
        iconColor: Colors.green,
      );
    }
  }

  Future<void> _selectDownloadFolder() async {
    final carpeta = await FilePicker.getDirectoryPath();
    if (carpeta == null) return;
    final prefs = await SharedPreferences.getInstance();
    final norm = p.normalize(carpeta);
    await prefs.setString('download_folder', norm);
    if (mounted) setState(() {});
    showElegantNotification(
      context,
      widget.getText(
        'download_folder_set',
        fallback: 'Carpeta de descargas establecida',
      ),
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.folder_open,
      iconColor: Colors.blue,
    );
  }

  Future<void> _queueDownload(
    Map<String, dynamic> c, {
    bool silent = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    String? downloadFolder = prefs.getString('download_folder');

    if (downloadFolder == null || downloadFolder.isEmpty) {
      final carpeta = await FilePicker.getDirectoryPath();
      if (carpeta == null) {
        showElegantNotification(
          context,
          widget.getText('download_cancelled', fallback: 'Descarga cancelada'),
          backgroundColor: const Color(0xFFE53935),
          textColor: Colors.white,
          icon: Icons.cancel,
          iconColor: Colors.white,
        );
        return;
      }
      downloadFolder = p.normalize(carpeta);
      await prefs.setString('download_folder', downloadFolder);
    }

    try {
      final dir = Directory(downloadFolder);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (e) {
      showElegantNotification(
        context,
        widget.getText(
          'download_folder_invalid',
          fallback: 'Carpeta inválida o sin permisos',
        ),
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
      return;
    }

    final title = (c['title'] ?? 'Unknown').toString();

    // Prioritizar el artista que ya viene en los metadatos procesados
    String artista = (c['artist'] != null && c['artist'].toString().isNotEmpty)
        ? c['artist'].toString()
        : widget.getText('unknown_artist', fallback: 'Unknown artist');

    // Solo intentar parsear del título si realmente no tenemos artista
    if ((artista == 'Unknown artist' ||
            artista == 'Artista desconocido' ||
            artista == 'Unknown') &&
        title.contains(' - ')) {
      final partes = title.split(' - ');
      if (partes.isNotEmpty && partes[0].trim().isNotEmpty) {
        artista = partes[0].trim();
      }
    }
    final nombre = title;
    final imageUrl = (c['image'] ?? '').toString();
    // URL exacta de la pista resuelta por Innertube (`watch?v=VIDEOID`):
    // garantiza que el archivo descargado corresponde al resultado mostrado
    // en la lista, en lugar de una búsqueda que yt-dlp resuelve por su cuenta.
    final exactUrl = (c['url'] ?? '').toString();
    final url = exactUrl.isNotEmpty
        ? exactUrl
        : '$nombre $artista'.trim();
    final id = DateTime.now().millisecondsSinceEpoch.toString();

    // Use bypassSpotifyApi = true to enforce direct yt-dlp handling as we are providing YouTube URL/Search
    final task = DownloadTask(
      id: id,
      title: nombre,
      artist: artista,
      image: imageUrl,
      sourceUrl: url,
      bypassSpotifyApi: true,
    );

    debugPrint(
      '[MusicDownloaderScreen] enqueuing task ${task.id} title="${task.title}"',
    );
    DownloadManager().addTask(task);
    if (silent) return; // En modo playlist, la notificación es global.
    showElegantNotification(
      context,
      widget.getText('download_queued', fallback: 'Download queued'),
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.check_circle_outline,
      iconColor: Colors.green,
    );
  }

  void _openDownloadsScreen() {
    if (!mounted) return;
    try {
      if (mounted && context.mounted) {
        Navigator.of(context)
            .push(
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    DownloadsScreen(
                      getText: widget.getText,
                      currentLang: widget.currentLang,
                    ),
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
              ),
            )
            .catchError((e, st) {
              debugPrint('[MusicDownloaderScreen] Navigation error: $e\n$st');
            });
      }
    } catch (e, st) {
      debugPrint('[MusicDownloaderScreen] openDownloads error: $e\n$st');
    }
  }

  void _openPlayerScreen() {
    if (widget.onNavigate != null) widget.onNavigate!('player');
  }

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;

    List<Map<String, dynamic>> listToShow = _canciones;
    bool displayingRecommendations = false;
    if (_canciones.isEmpty && !_searching && _recommendations.isNotEmpty) {
      listToShow = _recommendations;
      displayingRecommendations = true;
    }
    // Playlist de Spotify en resolución: muestra las pistas ya resueltas.
    if (_canciones.isEmpty &&
        _playlistTracks.isNotEmpty &&
        displayingRecommendations == false) {
      listToShow = _playlistTracks;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    // Search bar (estilo forawn_mobile: sin borde)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              cursorColor: Colors.purpleAccent,
                              decoration: InputDecoration(
                                hintText: get(
                                  'song_or_artist_label',
                                  fallback:
                                      'Canción, artista o URL de playlist',
                                ),
                                hintStyle: TextStyle(
                                  color: Colors.white.withOpacity(0.3),
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                isDense: true,
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) => _buscarCanciones(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.search, color: Colors.white),
                            onPressed: _buscarCanciones,
                            style: IconButton.styleFrom(
                              backgroundColor: const Color.fromARGB(
                                255,
                                224,
                                64,
                                251,
                              ).withOpacity(0.3),
                              padding: const EdgeInsets.all(8),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    if (_searching)
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text(
                                'Buscando canciones...',
                                style: TextStyle(fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (_loadingPlaylist)
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(
                                _playlistName != null
                                    ? '$_playlistName'
                                    : get(
                                        'loading_playlist',
                                        fallback: 'Cargando playlist...',
                                      ),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_playlistTracks.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  '$_playlistResolved resueltas'
                                  '${_playlistFailed > 0 ? ' • $_playlistFailed fallidas' : ''}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withOpacity(0.6),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                    else if (listToShow.isEmpty && _loadingRecommendations)
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 8),
                              Text(
                                get(
                                  'loading_recommendations',
                                  fallback: 'Cargando recomendaciones...',
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (listToShow.isEmpty)
                      Expanded(
                        child: Center(
                          child: Text(
                            get('no_songs_ui', fallback: 'No hay canciones'),
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      )
                    else ...[
                      if (_playlistName != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '$_playlistName (${listToShow.length})',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.playlist_add, size: 18),
                                label: Text(
                                  get(
                                    'download_all',
                                    fallback: 'Descargar todo',
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: _loadingPlaylist
                                    ? null
                                    : _queuePlaylistDownload,
                              ),
                            ],
                          ),
                        )
                      else if (displayingRecommendations &&
                          _lastSearchQuery != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const SizedBox(width: 8),
                              Text(
                                '${get('recommendations_for', fallback: 'Recomendaciones basadas en')}: $_lastSearchQuery',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),

                      const SizedBox(height: 12),

                      Expanded(
                        child: ListView.builder(
                          itemCount: listToShow.length,
                          itemBuilder: (context, index) {
                            if (index >= listToShow.length)
                              return const SizedBox.shrink();
                            final c = listToShow[index];
                            final title =
                                (c['title'] ??
                                        get('untitled', fallback: 'Sin título'))
                                    .toString();
                            final imageUrl = (c['image'] ?? '').toString();
                            final artista =
                                (c['artist'] ??
                                        get(
                                          'unknown_artist',
                                          fallback: 'Artista desconocido',
                                        ))
                                    .toString();

                            DownloadTask? task;
                            final src = (c['url'] ?? '').toString();
                            if (src.isNotEmpty) task = _dmTasksBySource[src];
                            // Do not fallback to title lookup

                            Widget statusChip() {
                              if (task == null) return const SizedBox.shrink();
                              switch (task.status) {
                                case DownloadStatus.queued:
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[700],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      widget.getText(
                                        'queued',
                                        fallback: 'Queued',
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  );
                                case DownloadStatus.running:
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.blue[700],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '${(task.progress * 100).toStringAsFixed(1)}%',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  );
                                case DownloadStatus.completed:
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.green[700],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      widget.getText(
                                        'completed_label',
                                        fallback: 'Completed',
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  );
                                case DownloadStatus.failed:
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.red[700],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      widget.getText(
                                        'failed_label',
                                        fallback: 'Failed',
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  );
                                case DownloadStatus.cancelled:
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[800],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      widget.getText(
                                        'cancelled_label',
                                        fallback: 'Cancelled',
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  );
                              }
                            }

                            return LayoutBuilder(
                              builder: (context, constraints) {
                                if (constraints.maxWidth < 80) {
                                  return const SizedBox(height: 56);
                                }

                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  minLeadingWidth: 56,
                                  leading: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: imageUrl.isNotEmpty
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            child: Image.network(
                                              imageUrl,
                                              width: 48,
                                              height: 48,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  Icon(
                                                    Icons.music_note,
                                                    color: Theme.of(context)
                                                        .iconTheme
                                                        .color
                                                        ?.withOpacity(0.54),
                                                  ),
                                            ),
                                          )
                                        : Icon(
                                            Icons.music_note,
                                            size: 40,
                                            color: Theme.of(context)
                                                .iconTheme
                                                .color
                                                ?.withOpacity(0.54),
                                          ),
                                  ),
                                  title: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.color
                                          ?.withOpacity(0.7),
                                    ),
                                  ),
                                  subtitle: Text(
                                    artista,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.color
                                          ?.withOpacity(0.54),
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      statusChip(),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(Icons.download),
                                        onPressed: () => _queueDownload(c),
                                        tooltip: widget.getText(
                                          'download',
                                          fallback: 'Download',
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () {
                                    if (widget.onNavigate != null)
                                      widget.onNavigate!('music');
                                  },
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FloatingActionButton(
              tooltip: widget.getText('local_player_title', fallback: 'Player'),
              onPressed: _openPlayerScreen,
              backgroundColor: Colors.purple[700],
              foregroundColor: Colors.white,
              mini: true,
              heroTag: 'spotify_player_fab',
              child: const Icon(Icons.music_note),
            ),
            const SizedBox(height: 16),
            FloatingActionButton(
              tooltip: widget.getText('open_downloads', fallback: 'Downloads'),
              onPressed: _openDownloadsScreen,
              backgroundColor: const Color.fromARGB(255, 224, 64, 251),
              foregroundColor: Colors.black87,
              heroTag: 'spotify_downloads_fab',
              child: const Icon(Icons.download),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  // Procesa resultados de Innertube (youtubei/v1). El título/artista se limpia
  // con las MISMAS reglas que aplica la cadena --replace-in-metadata de
  // yt-dlp al incrustar metadatos en el archivo, así la lista de resultados y
  // las etiquetas del archivo descargado siempre coinciden.
  List<Map<String, dynamic>> _processInnertubeResults(
    List<InnertubeTrack> tracks,
  ) {
    final canciones = <Map<String, dynamic>>[];
    for (final track in tracks) {
      try {
        final rawTitle = track.rawTitle;
        final channel = track.channel;

        // YT Music trae metadatos ya limpios; el fallback WEB requiere la
        // limpieza de ruido con las MISMAS reglas que la cadena de yt-dlp.
        final title = track.cleanMetadata
            ? rawTitle
            : InnertubeService.cleanTitle(rawTitle);
        final artist = track.cleanMetadata
            ? (channel.isNotEmpty ? channel : 'Unknown artist')
            : InnertubeService.artistFor(channel, rawTitle);

        if (title.isEmpty) continue;

        canciones.add({
          'title': title,
          'artist': artist,
          'album': track.album,
          'image': track.thumbnailUrl,
          // URL exacta de la pista (`watch?v=VIDEOID`) devuelta por
          // Innertube — dominio music.youtube.com para resultados de YT Music.
          'url': track.watchUrlForDownload,
          'duration_ms': track.durationMs,
          'video_id': track.videoId,
        });
      } catch (e, st) {
        debugPrint(
          '[MusicDownloaderScreen] Error parsing Innertube item: $e\n$st',
        );
      }
    }
    return canciones;
  }
}

/// Estado de una pista durante la resolución de una playlist de Spotify.
enum _ResolveStatus { pending, resolving, done, failed }

class _TrackResolveState {
  _TrackResolveState(this.title, this.artist);

  final String title;
  final String artist;
  _ResolveStatus status = _ResolveStatus.pending;

  String get label => artist.isEmpty ? title : '$title — $artist';
}

/// Diálogo de progreso de resolución de playlist de Spotify: muestra una
/// barra global y el estado de cada pista (pendiente / resolviendo / lista /
/// fallida) en tiempo real.
class _PlaylistResolveDialog extends StatelessWidget {
  const _PlaylistResolveDialog({
    required this.name,
    required this.states,
    required this.revision,
    required this.onCancel,
    required this.onBackground,
  });

  final String name;
  final List<_TrackResolveState> states;
  final ValueNotifier<int> revision;
  final VoidCallback onCancel;
  final VoidCallback onBackground;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(name, overflow: TextOverflow.ellipsis, maxLines: 1),
      content: SizedBox(
        width: 420,
        height: 340,
        child: ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (context, _, __) {
            final total = states.length;
            final done = states
                .where((s) =>
                    s.status == _ResolveStatus.done ||
                    s.status == _ResolveStatus.failed)
                .length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$done / $total',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: total == 0 ? null : done / total,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: states.length,
                    itemBuilder: (context, index) {
                      final s = states[index];
                      final Widget leading;
                      switch (s.status) {
                        case _ResolveStatus.pending:
                          leading = Icon(
                            Icons.schedule,
                            size: 18,
                            color: Theme.of(context)
                                .iconTheme
                                .color
                                ?.withOpacity(0.4),
                          );
                          break;
                        case _ResolveStatus.resolving:
                          leading = const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                          break;
                        case _ResolveStatus.done:
                          leading = const Icon(
                            Icons.check_circle,
                            size: 18,
                            color: Colors.green,
                          );
                          break;
                        case _ResolveStatus.failed:
                          leading = const Icon(
                            Icons.error_outline,
                            size: 18,
                            color: Colors.redAccent,
                          );
                          break;
                      }
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: leading,
                        title: Text(
                          s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: s.status == _ResolveStatus.failed
                                ? Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.color
                                    ?.withOpacity(0.45)
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: onBackground,
          child: const Text('Continuar en segundo plano'),
        ),
      ],
    );
  }
}
