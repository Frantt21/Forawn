// spotify_screen.dart
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

class SpotifyScreen extends StatefulWidget {
  const SpotifyScreen({
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
  State<SpotifyScreen> createState() => _SpotifyScreenState();
}

class _SpotifyScreenState extends State<SpotifyScreen>
    with WindowListener, WidgetsBindingObserver {
  List<Map<String, dynamic>> _canciones = [];
  final TextEditingController _controller = TextEditingController();
  final DownloadManager _dm = DownloadManager();
  late final VoidCallback _dmListener;
  Map<String, DownloadTask> _dmTasksBySource = {};
  final http.Client _http = http.Client();
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
      debugPrint('[SpotifyScreen] Error adding window listener: $e');
    }

    try {
      _loadPrefs();
    } catch (e) {
      debugPrint('[SpotifyScreen] Error loading prefs: $e');
    }

    try {
      _loadImageCache();
    } catch (e) {
      debugPrint('[SpotifyScreen] Error loading image cache: $e');
    }

    if (widget.onRegisterFolderAction != null) {
      try {
        widget.onRegisterFolderAction!(_selectDownloadFolder);
      } catch (e) {
        debugPrint('[SpotifyScreen] Error registering folder action: $e');
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
          debugPrint('[SpotifyScreen] Error in dm listener: $e');
        }
      };

      _dm.addListener(_dmListener);
      WidgetsBinding.instance.addObserver(this);
    } catch (e) {
      debugPrint('[SpotifyScreen] Error setting up download manager: $e');
    }
    debugPrint('[SpotifyScreen] initState complete');
  }

  @override
  void dispose() {
    try {
      _dm.removeListener(_dmListener);
    } catch (e) {
      debugPrint('[SpotifyScreen] Error removing dm listener: $e');
    }
    try {
      windowManager.removeListener(this);
    } catch (e) {
      debugPrint('[SpotifyScreen] Error removing window listener: $e');
    }
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (e) {
      debugPrint('[SpotifyScreen] Error removing observer: $e');
    }
    try {
      _controller.dispose();
    } catch (e) {
      debugPrint('[SpotifyScreen] Error disposing controller: $e');
    }
    // Don't close HTTP client - let pending requests complete naturally
    // Closing it forcefully causes "Connection closed" errors in debug mode
    // The client will be garbage collected when no longer referenced
    // try {
    //   _http.close();
    // } catch (e) {
    //   debugPrint('[SpotifyScreen] Error closing http: $e');
    // }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      if (state == AppLifecycleState.paused) {
        try {
          _dm.removeListener(_dmListener);
        } catch (e) {
          debugPrint('[SpotifyScreen] Error pausing dm listener: $e');
        }
      } else if (state == AppLifecycleState.resumed) {
        try {
          _dm.addListener(_dmListener);
        } catch (e) {
          debugPrint('[SpotifyScreen] Error resuming dm listener: $e');
        }
      }
    } catch (e) {
      debugPrint('[SpotifyScreen] Error in didChangeAppLifecycleState: $e');
    }
  }

  // -------------------------
  // Helper: GET seguro
  // -------------------------
  Future<http.Response?> _safeGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final res = await _http.get(uri).timeout(timeout);
      return res;
    } on TimeoutException catch (e, st) {
      debugPrint('[SpotifyScreen] Timeout GET $uri: $e\n$st');
      return null;
    } on SocketException catch (e, st) {
      debugPrint('[SpotifyScreen] SocketException GET $uri: $e\n$st');
      return null;
    } on HttpException catch (e, st) {
      // This catches "Connection closed before full header was received"
      debugPrint('[SpotifyScreen] HttpException GET $uri: $e\n$st');
      return null;
    } catch (e, st) {
      // Catch any other errors including connection closed during dispose
      if (e.toString().contains('Connection closed') ||
          e.toString().contains('Socket is closed')) {
        debugPrint(
          '[SpotifyScreen] Connection closed (widget likely disposed): $uri',
        );
        return null;
      }
      debugPrint('[SpotifyScreen] Unknown error GET $uri: $e\n$st');
      return null;
    }
  }

  Future<String?> buscarImagenPinterest(String nombre, String artista) async {
    final key =
        '${nombre.toLowerCase().trim()}|${artista.toLowerCase().trim()}';
    if (_imageCache.containsKey(key)) return _imageCache[key];
    try {
      final query = 'portada $nombre $artista';
      final url = Uri.parse(
        '${ApiConfig.dorratzBaseUrl}/v2/pinterest?q=${Uri.encodeComponent(query)}',
      );
      final res = await _safeGet(url, timeout: const Duration(seconds: 8));
      if (res == null) return null;
      if (res.statusCode != 200) {
        debugPrint(
          '[SpotifyScreen] buscarImagenPinterest non-200: ${res.statusCode}',
        );
        return null;
      }
      final parsed = jsonDecode(res.body);
      String? img;
      if (parsed is List && parsed.isNotEmpty) {
        final first = parsed.first;
        if (first is Map<String, dynamic>) {
          img =
              first['image_large_url'] ??
              first['image_small_url'] ??
              first['image_medium_url'];
        }
      } else if (parsed is Map<String, dynamic>) {
        img =
            parsed['image_large_url'] ??
            parsed['image_small_url'] ??
            parsed['image_medium_url'];
      }
      if (img != null && img.isNotEmpty) {
        _imageCache[key] = img;
        _prefs ??= await SharedPreferences.getInstance();
        try {
          await _prefs!.setString('image_cache_json', jsonEncode(_imageCache));
        } catch (e) {
          debugPrint('[SpotifyScreen] failed saving image cache: $e');
        }
        return img;
      }
    } catch (e, st) {
      debugPrint('[SpotifyScreen] buscarImagenPinterest error: $e\n$st');
    }
    return null;
  }

  void _uiLog(String s) {
    debugPrint('[SpotifyScreen UI] $s');
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
      debugPrint('[SpotifyScreen] loaded prefs');
      final last = _prefs!.getString('last_search_query');
      if (last != null && last.isNotEmpty) {
        _lastSearchQuery = last;
        _fetchRecommendations(last);
      }
    } catch (e) {
      debugPrint('[SpotifyScreen] loadPrefs error: $e');
    }
  }

  Future<void> _fetchRecommendations(String query) async {
    if (_loadingRecommendations) return;
    setState(() => _loadingRecommendations = true);

    try {
      final uri = Uri.parse(
        '${ApiConfig.dorratzBaseUrl}/spotifysearch?query=${Uri.encodeComponent(query)}',
      );
      final res = await _safeGet(uri, timeout: const Duration(seconds: 10));
      if (res == null) {
        debugPrint(
          '[SpotifyScreen] recommendation fetch returned null for $query',
        );
        if (mounted) setState(() => _loadingRecommendations = false);
        return;
      }
      if (res.statusCode != 200) {
        debugPrint(
          '[SpotifyScreen] recommendation fetch non-200 ${res.statusCode}',
        );
        if (mounted) setState(() => _loadingRecommendations = false);
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cancelRaw = data['data'] as List<dynamic>? ?? [];
      final all = cancelRaw.whereType<Map<String, dynamic>>().toList();

      all.sort((a, b) {
        int getPop(dynamic p) {
          if (p is int) return p;
          if (p is String) {
            final cleaned = p.replaceAll('%', '').trim();
            return int.tryParse(cleaned) ?? 0;
          }
          return 0;
        }

        final popA = getPop(a['popularity']);
        final popB = getPop(b['popularity']);
        return popB.compareTo(popA);
      });

      final limited = all.take(5).toList();
      final mapped = List<Map<String, dynamic>>.from(limited);

      for (var m in mapped) {
        if ((m['url'] == null ||
            (m['url'] is String && (m['url'] as String).isEmpty))) {
          if (m.containsKey('uri')) {
            m['url'] = m['uri'];
          } else if (m.containsKey('link')) {
            m['url'] = m['link'];
          }
        }
      }

      if (mounted) {
        setState(() {
          _recommendations = mapped;
        });
        Future.microtask(() async {
          await _assignImagesChunked(mapped, chunkSize: 4);
          if (mounted) setState(() {});
        });
      }
    } catch (e, st) {
      debugPrint('[SpotifyScreen] recommendation fetch error: $e\n$st');
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
        debugPrint(
          '[SpotifyScreen] image cache loaded ${_imageCache.length} entries',
        );
      }
    } catch (e) {
      debugPrint('[SpotifyScreen] loadImageCache error: $e');
    }
  }

  Future<void> _buscarCanciones() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    _prefs ??= await SharedPreferences.getInstance();

    setState(() {
      _searching = true;
      _canciones = [];
      _recommendations = [];
    });
    debugPrint('[SpotifyScreen] buscarCanciones: query="$query"');
    _uiLog('Buscar: $query');

    try {
      final uri = Uri.parse(
        '${ApiConfig.dorratzBaseUrl}/spotifysearch?query=${Uri.encodeComponent(query)}',
      );
      final res = await _safeGet(uri, timeout: const Duration(seconds: 10));
      if (res == null) {
        debugPrint(
          '[SpotifyScreen] buscarCanciones: request failed for $query',
        );
        if (mounted) setState(() => _searching = false);
        return;
      }
      if (res.statusCode != 200) {
        debugPrint(
          '[SpotifyScreen] buscarCanciones: non-200 ${res.statusCode}',
        );
        if (mounted) setState(() => _searching = false);
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cancionesRaw = data['data'] as List<dynamic>? ?? [];
      final canciones = cancionesRaw.whereType<Map<String, dynamic>>().toList();
      debugPrint(
        '[SpotifyScreen] spotifysearch returned ${canciones.length} items',
      );

      final mapped = List<Map<String, dynamic>>.from(canciones);

      mapped.sort((a, b) {
        int getPop(dynamic p) {
          if (p is int) return p;
          if (p is String) {
            final cleaned = p.replaceAll('%', '').trim();
            return int.tryParse(cleaned) ?? 0;
          }
          return 0;
        }

        final popA = getPop(a['popularity']);
        final popB = getPop(b['popularity']);
        return popB.compareTo(popA);
      });

      if (mapped.isNotEmpty) {
        final top = mapped.first;
        final artist = top['artist'];
        if (artist != null && artist is String && artist.isNotEmpty) {
          await _prefs!.setString('last_search_query', artist);
          debugPrint(
            '[SpotifyScreen] Updated recommendation seed to artist: $artist',
          );
        } else {
          await _prefs!.setString('last_search_query', query);
        }
      } else {
        await _prefs!.setString('last_search_query', query);
      }

      for (var m in mapped) {
        if ((m['url'] == null ||
            (m['url'] is String && (m['url'] as String).isEmpty))) {
          if (m.containsKey('uri')) {
            m['url'] = m['uri'];
            debugPrint('[SpotifyScreen] normalized uri -> url for item');
          } else if (m.containsKey('link')) {
            m['url'] = m['link'];
            debugPrint('[SpotifyScreen] normalized link -> url for item');
          }
        }
      }

      if (mounted) {
        setState(() {
          _canciones = mapped;
        });
      }

      Future.microtask(() async {
        await _assignImagesChunked(mapped, chunkSize: 4);
        if (mounted) setState(() {});
      });

      final missingUrlCount = _canciones
          .where((c) => c['url'] == null || (c['url'] as String).isEmpty)
          .length;
      _uiLog('Resultados: ${_canciones.length}, sin url: $missingUrlCount');
      if (missingUrlCount > 0) {
        showElegantNotification(
          context,
          widget.getText(
            'warning_missing_url',
            fallback: 'Algunas canciones no tienen URL',
          ),
          backgroundColor: const Color(0xFFFFA500),
          textColor: Colors.white,
          icon: Icons.warning_amber,
          iconColor: Colors.white,
        );
      }
    } catch (e, st) {
      debugPrint('[SpotifyScreen] buscarCanciones error: $e\n$st');
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
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _assignImagesChunked(
    List<Map<String, dynamic>> mapped, {
    int chunkSize = 4,
  }) async {
    for (int i = 0; i < mapped.length; i += chunkSize) {
      if (!mounted) return;
      final end = (i + chunkSize).clamp(0, mapped.length);
      final chunk = mapped.sublist(i, end);
      final futures = <Future<void>>[];
      for (int j = 0; j < chunk.length; j++) {
        final idx = i + j;
        final c = mapped[idx];
        futures.add(() async {
          if (!mounted) return;
          try {
            final title = (c['title'] ?? '').toString();
            String artista = widget.getText('artist_label', fallback: 'Artist');
            String nombre = title;
            if (title.contains(' - ')) {
              final partes = title.split(' - ').map((s) => s.trim()).toList();
              artista = partes.isNotEmpty
                  ? partes[0]
                  : widget.getText('artist_label', fallback: 'Artist');
              nombre = partes.length > 1
                  ? partes[1]
                  : (partes.isNotEmpty ? partes[0] : title);
            }
            final img = await buscarImagenPinterest(nombre, artista);
            c['image'] = img ?? '';
          } catch (e, st) {
            debugPrint(
              '[SpotifyScreen] _assignImagesChunked image fetch error: $e\n$st',
            );
            c['image'] = '';
          }
        }());
      }
      await Future.wait(futures);
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<void> _selectDownloadFolder() async {
    debugPrint('[SpotifyScreen] _selectDownloadFolder called');
    final carpeta = await FilePicker.platform.getDirectoryPath();
    if (carpeta == null) {
      _uiLog('Seleccionar carpeta cancelada por usuario');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final norm = p.normalize(carpeta);
    await prefs.setString('download_folder', norm);
    _uiLog('Carpeta guardada: $norm');
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
    debugPrint('[SpotifyScreen] download_folder saved: $norm');
  }

  Future<void> _queueDownload(Map<String, dynamic> c) async {
    debugPrint('[SpotifyScreen] queueDownload for item: ${c.toString()}');
    final prefs = await SharedPreferences.getInstance();
    String? downloadFolder = prefs.getString('download_folder');

    if (downloadFolder == null || downloadFolder.isEmpty) {
      debugPrint('[SpotifyScreen] no download folder pref, asking user');
      final carpeta = await FilePicker.platform.getDirectoryPath();
      if (carpeta == null) {
        _uiLog('Descarga cancelada por usuario (no hay carpeta)');
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
      debugPrint(
        '[SpotifyScreen] user selected download folder: $downloadFolder',
      );
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

    try {
      final dir = Directory(downloadFolder);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final testFile = File(p.join(downloadFolder, '.forawn_write_test'));
      testFile.writeAsStringSync('ok');
      testFile.deleteSync();
      debugPrint('[SpotifyScreen] folder writable test OK');
    } catch (e) {
      debugPrint('[SpotifyScreen] download folder writable test failed: $e');
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

    final task = DownloadTask(
      id: id,
      title: nombre,
      artist: artista,
      image: imageUrl,
      sourceUrl: url,
    );

    debugPrint(
      '[SpotifyScreen] enqueuing task ${task.id} title="${task.title}" url="${task.sourceUrl}" image="${task.image}"',
    );
    _uiLog('Encolada: ${task.title}');
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
      // Verificar que el contexto es válido
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
              debugPrint('[SpotifyScreen] Navigation error: $e\n$st');
              if (mounted) {
                showElegantNotification(
                  context,
                  widget.getText(
                    'error_opening_downloads',
                    fallback: 'No se pudo abrir Descargas',
                  ),
                  backgroundColor: const Color(0xFFE53935),
                  textColor: Colors.white,
                  icon: Icons.error_outline,
                  iconColor: Colors.white,
                );
              }
            });
      }
    } catch (e, st) {
      debugPrint('[SpotifyScreen] openDownloads error: $e\n$st');
      if (mounted) {
        showElegantNotification(
          context,
          widget.getText(
            'error_opening_downloads',
            fallback: 'No se pudo abrir Descargas',
          ),
          backgroundColor: const Color(0xFFE53935),
          textColor: Colors.white,
          icon: Icons.error_outline,
          iconColor: Colors.white,
        );
      }
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
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
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

                      // Lista protegida con LayoutBuilder y Image.network seguro
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
                            String artista = get(
                              'unknown_artist',
                              fallback: 'Artista desconocido',
                            );
                            if (title.contains(' - ')) {
                              final partes = title.split(' - ');
                              artista = partes.isNotEmpty ? partes[0] : artista;
                            }

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
                                // Si el ancho disponible es demasiado pequeño, evita construir el ListTile
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
                                                  const Icon(
                                                    Icons.music_note,
                                                    color: Colors.white54,
                                                  ),
                                              loadingBuilder:
                                                  (ctx, child, progress) {
                                                    if (progress == null)
                                                      return child;
                                                    return const SizedBox(
                                                      width: 48,
                                                      height: 48,
                                                      child: Center(
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                            ),
                                                      ),
                                                    );
                                                  },
                                            ),
                                          )
                                        : const Icon(
                                            Icons.music_note,
                                            size: 40,
                                            color: Colors.white54,
                                          ),
                                  ),
                                  title: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  subtitle: Text(
                                    artista,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white54,
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
}
