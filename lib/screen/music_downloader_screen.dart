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
import '../config/api_config.dart';
import '../models/download_task.dart';
import '../widgets/elegant_notification.dart';
import '../services/download_manager.dart';
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

  @override
  void initState() {
    super.initState();
    try {
      windowManager.addListener(this);
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
            map[t.title] = t;
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
      windowManager.removeListener(this);
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
      final uri = Uri.parse(
        '${ApiConfig.foranlyBackendPrimary}/youtube/search',
      ).replace(queryParameters: {'q': query, 'limit': '5'});
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (!mounted) {
        setState(() => _loadingRecommendations = false);
        return;
      }

      Map<String, dynamic>? data;
      if (response.statusCode == 200) {
        data = jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        debugPrint(
          '[MusicDownloaderScreen] Reco fetch failed: ${response.statusCode}',
        );
        data = null;
      }

      if (data == null) {
        debugPrint(
          '[MusicDownloaderScreen] Failed to fetch recommendations: null response',
        );
        if (mounted) setState(() => _loadingRecommendations = false);
        return;
      }

      final resultsRaw = data['results'] as List<dynamic>? ?? [];

      debugPrint('[MusicDownloaderScreen] Found ${resultsRaw.length} results');

      final canciones = _processSearchResults(resultsRaw);

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
      final uri = Uri.parse(
        '${ApiConfig.foranlyBackendPrimary}/youtube/search',
      ).replace(queryParameters: {'q': query, 'limit': '20'});

      debugPrint('[MusicDownloaderScreen] Fetching from URI: $uri');

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      debugPrint(
        '[MusicDownloaderScreen] Response received: ${response.statusCode}',
      );

      Map<String, dynamic>? data;
      if (response.statusCode == 200) {
        data = jsonDecode(response.body) as Map<String, dynamic>;

        // Verificar si el backend devolvió un error
        if (data.containsKey('error')) {
          debugPrint('[MusicDownloaderScreen] Backend error: ${data['error']}');
          if (mounted) {
            setState(() => _searching = false);
            showElegantNotification(
              context,
              widget.getText(
                'backend_error',
                fallback: 'Error del servidor: ${data['error']}',
              ),
              backgroundColor: const Color(0xFFE53935),
              textColor: Colors.white,
              icon: Icons.error_outline,
              iconColor: Colors.white,
            );
          }
          return;
        }
      } else {
        data = null;
      }

      if (!mounted) {
        debugPrint('[MusicDownloaderScreen] Widget unmounted after fetch');
        return;
      }

      if (data == null) {
        debugPrint('[MusicDownloaderScreen] Response is null - network error');
        if (mounted) {
          setState(() => _searching = false);
          showElegantNotification(
            context,
            widget.getText(
              'network_error',
              fallback: 'Error de red. Verifica tu conexión.',
            ),
            backgroundColor: const Color(0xFFE53935),
            textColor: Colors.white,
            icon: Icons.wifi_off,
            iconColor: Colors.white,
          );
        }
        return;
      }

      debugPrint('[MusicDownloaderScreen] Response received, parsing data...');

      final resultsRaw = data['results'] as List<dynamic>? ?? [];

      debugPrint('[MusicDownloaderScreen] Found ${resultsRaw.length} results');

      final canciones = _processSearchResults(resultsRaw);

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

  Future<void> _selectDownloadFolder() async {
    final carpeta = await FilePicker.platform.getDirectoryPath();
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

  Future<void> _queueDownload(Map<String, dynamic> c) async {
    final prefs = await SharedPreferences.getInstance();
    String? downloadFolder = prefs.getString('download_folder');

    if (downloadFolder == null || downloadFolder.isEmpty) {
      final carpeta = await FilePicker.platform.getDirectoryPath();
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
    String artista = widget.getText(
      'unknown_artist',
      fallback: 'Unknown artist',
    );
    if (title.contains(' - ')) {
      final partes = title.split(' - ');
      artista = partes.isNotEmpty ? partes[0] : artista;
    }
    final nombre = title;
    final imageUrl = (c['image'] ?? '').toString();
    final url = c['url']?.toString() ?? nombre;
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
              MaterialPageRoute(
                builder: (_) => DownloadsScreen(
                  getText: widget.getText,
                  currentLang: widget.currentLang,
                ),
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
                    // Search bar
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardTheme.color,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              decoration: InputDecoration(
                                hintText: get(
                                  'song_or_artist_label',
                                  fallback:
                                      'Nombre de la canción o del artista',
                                ),
                                hintStyle: Theme.of(
                                  context,
                                ).inputDecorationTheme.hintStyle,
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                isDense: true,
                              ),
                              style: const TextStyle(fontSize: 15),
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
                      if (displayingRecommendations && _lastSearchQuery != null)
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
                            task ??= _dmTasksBySource[title];

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

  // Función auxiliar para detectar inversión con validación cruzada
  List<Map<String, dynamic>> _processSearchResults(List<dynamic> resultsRaw) {
    // Primer paso: mapear todos los resultados con datos crudos
    final rawMapped = resultsRaw
        .map((item) {
          try {
            if (item is! Map<String, dynamic>) return null;
            final r = item;
            return {
              'rawTitle': r['title'] ?? '',
              'parsedSong': r['parsedSong'] ?? '',
              'parsedArtist': r['parsedArtist'] ?? '',
              'author': r['author'] ?? '',
              'thumbnail': r['thumbnail'] ?? '',
              'url': r['url'] ?? '',
              'duration': r['duration'] ?? 0,
            };
          } catch (e) {
            return null;
          }
        })
        .where((m) => m != null)
        .cast<Map<String, dynamic>>()
        .toList();

    // Segundo paso: detectar inversiones usando validación cruzada
    final canciones = rawMapped
        .map((item) {
          try {
            final String rawTitle = item['rawTitle'];
            String parsedSong = item['parsedSong'];
            String parsedArtist = item['parsedArtist'];
            final String author = item['author'];

            // DETECCIÓN DE INVERSIÓN CON VALIDACIÓN CRUZADA
            String finalParsedSong = parsedSong;
            String finalParsedArtist = parsedArtist;

            // Método 1: Si la canción tiene múltiples artistas pero el artista no
            final artistHasMultiple =
                parsedArtist.contains(',') ||
                parsedArtist.contains('&') ||
                parsedArtist.toLowerCase().contains('ft.');
            final songHasMultiple =
                parsedSong.contains(',') ||
                parsedSong.contains('&') ||
                parsedSong.toLowerCase().contains('ft.');

            if (songHasMultiple &&
                !artistHasMultiple &&
                parsedArtist.isNotEmpty) {
              debugPrint(
                '[MusicDownloaderScreen] ⚠️ Detected inverted fields (multiple artists), swapping...',
              );
              finalParsedArtist = parsedSong;
              finalParsedSong = parsedArtist;
            }
            // Método 2: Validación cruzada con otras canciones
            else {
              // Contar cuántas otras canciones tienen el mismo parsedArtist
              int matchingArtists = rawMapped.where((other) {
                return other != item &&
                    other['parsedArtist'].toString().toLowerCase() ==
                        parsedSong.toLowerCase();
              }).length;

              // Si al menos 2 otras canciones tienen como artista lo que esta tiene como canción,
              // probablemente están invertidos
              if (matchingArtists >= 2 && parsedArtist.isNotEmpty) {
                debugPrint(
                  '[MusicDownloaderScreen] ⚠️ Detected inverted fields (cross-validation: $matchingArtists matches), swapping...',
                );
                finalParsedArtist = parsedSong;
                finalParsedSong = parsedArtist;
              }
            }

            final title = finalParsedSong.isNotEmpty
                ? _toTitleCase(finalParsedSong)
                : rawTitle;
            String artist = finalParsedArtist.isNotEmpty
                ? finalParsedArtist
                : (author.isNotEmpty ? author : 'Unknown artist');
            artist = _toTitleCase(artist);

            return {
              'title': title,
              'artist': artist,
              'album': 'YouTube',
              'image': item['thumbnail'],
              'url': item['url'],
              'popularity': '100',
              'duration_ms': (item['duration'] is int)
                  ? (item['duration'] as int) * 1000
                  : 0,
            };
          } catch (e, st) {
            debugPrint('[MusicDownloaderScreen] Error parsing item: $e\n$st');
            return <String, dynamic>{};
          }
        })
        .where((m) => m.isNotEmpty)
        .toList();

    return List<Map<String, dynamic>>.from(canciones);
  }
}
