import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import '../models/download_task.dart';
import '../services/download_manager.dart';
import 'downloads_screen.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class SpotifyScreen extends StatefulWidget {
  const SpotifyScreen({
    super.key,
    required this.getText,
    required this.currentLang,
    this.onRegisterFolderAction,
  });

  final String currentLang;
  final TextGetter getText;
  final Function(VoidCallback)? onRegisterFolderAction;

  @override
  State<SpotifyScreen> createState() => _SpotifyScreenState();
}

class _SpotifyScreenState extends State<SpotifyScreen> with WindowListener {
  List<Map<String, dynamic>> _canciones = [];
  final TextEditingController _controller = TextEditingController();
  // download manager
  final DownloadManager _dm = DownloadManager();

  late final VoidCallback _dmListener;
  Map<String, DownloadTask> _dmTasksBySource = {};
  final http.Client _http = http.Client();
  final Map<String, String> _imageCache = {};
  final double _inputHeight = 56;
  final bool _isDraggingHandle = false;
  SharedPreferences? _prefs;
  bool _searching = false;
  // UI logs para depurar (visualmente desactivado)
  final List<String> _uiLogs = [];

  List<Map<String, dynamic>> _recommendations = [];
  String? _lastSearchQuery;
  bool _loadingRecommendations = false;

  @override
  void dispose() {
    try {
      _dm.removeListener(_dmListener);
    } catch (_) {}
    windowManager.removeListener(this);
    _controller.dispose();
    _http.close();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadPrefs();
    _loadImageCache();

    // Register folder action
    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectDownloadFolder);
    }

    // registro listener del gestor de descargas
    _dmListener = () {
      final tasks = _dm.tasks;
      final map = <String, DownloadTask>{};
      for (final t in tasks) {
        if (t.sourceUrl.isNotEmpty) map[t.sourceUrl] = t;
        map[t.title] = t; // fallback por título
      }
      _dmTasksBySource = map;
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
      });
    };

    _dm.addListener(_dmListener);

    // cargar estado persistente del gestor de descargas
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dm.loadPersisted();
    });

    debugPrint('[SpotifyScreen] initState complete');
  }

  // imagenes
  Future<String?> buscarImagenPinterest(String nombre, String artista) async {
    final key =
        '${nombre.toLowerCase().trim()}|${artista.toLowerCase().trim()}';
    if (_imageCache.containsKey(key)) return _imageCache[key];
    try {
      final query = 'portada $nombre $artista';
      final url = Uri.parse(
        'https://api.dorratz.com/v2/pinterest?q=${Uri.encodeComponent(query)}',
      );
      final res = await _http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
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
        await _prefs!.setString('image_cache_json', jsonEncode(_imageCache));
        return img;
      }
    } catch (e) {
      debugPrint('[SpotifyScreen] buscarImagenPinterest error: $e');
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
      final res = await _http
          .get(
            Uri.parse(
              'https://api.dorratz.com/spotifysearch?query=${Uri.encodeComponent(query)}',
            ),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final cancelRaw = data['data'] as List<dynamic>? ?? [];
        final all = cancelRaw.whereType<Map<String, dynamic>>().toList();

        // Sort recommendations by popularity
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

        // Normalizar
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
          // Load images for recommendations
          Future.microtask(() async {
            await _assignImagesChunked(mapped, chunkSize: 4);
            if (mounted) setState(() {});
          });
        }
      }
    } catch (e) {
      debugPrint('[SpotifyScreen] recommendation fetch error: $e');
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

  // buscador
  Future<void> _buscarCanciones() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    // Save query as last search initially; we might update this with the artist later
    _prefs ??= await SharedPreferences.getInstance();
    // await _prefs!.setString('last_search_query', query);

    setState(() {
      _searching = true;
      _canciones = [];
      _recommendations = []; // Clear recommendations on new search
    });
    debugPrint('[SpotifyScreen] buscarCanciones: query="$query"');
    _uiLog('Buscar: $query');

    try {
      final res = await _http
          .get(
            Uri.parse(
              'https://api.dorratz.com/spotifysearch?query=${Uri.encodeComponent(query)}',
            ),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('[SpotifyScreen] spotifysearch status=${res.statusCode}');
      if (res.statusCode != 200) {
        throw Exception('search error ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final cancionesRaw = data['data'] as List<dynamic>? ?? [];
      final canciones = cancionesRaw.whereType<Map<String, dynamic>>().toList();
      debugPrint(
        '[SpotifyScreen] spotifysearch returned ${canciones.length} items',
      );

      final mapped = List<Map<String, dynamic>>.from(canciones);

      // Sort by popularity
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
        return popB.compareTo(popA); // Descending
      });

      // Validar si hay resultados para guardar el artista como semilla de recomendaciones
      if (mapped.isNotEmpty) {
        final top = mapped.first;
        final artist = top['artist'];
        if (artist != null && artist is String && artist.isNotEmpty) {
          await _prefs!.setString('last_search_query', artist);
          debugPrint(
            '[SpotifyScreen] Updated recommendation seed to artist: $artist',
          );
        } else {
          // Fallback to query if no artist
          await _prefs!.setString('last_search_query', query);
        }
      } else {
        await _prefs!.setString('last_search_query', query);
      }

      // Normalizar campos
      if (mapped.isNotEmpty) {
        debugPrint(
          '[SpotifyScreen] first item keys: ${mapped.first.keys.toList()}',
        );
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

      setState(() {
        _canciones = mapped;
      });

      // luego carga imágenes en segundo plano
      Future.microtask(() async {
        await _assignImagesChunked(mapped, chunkSize: 4);
        if (mounted) setState(() {});
      });

      final missingUrlCount = _canciones
          .where((c) => c['url'] == null || (c['url'] as String).isEmpty)
          .length;
      _uiLog('Resultados: ${_canciones.length}, sin url: $missingUrlCount');
      if (missingUrlCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.getText(
                'warning_missing_url',
                fallback: 'Algunas canciones no tienen URL',
              ),
            ),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[SpotifyScreen] buscarCanciones error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.getText('search_error', fallback: 'Error en búsqueda'),
            ),
          ),
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
      final end = (i + chunkSize).clamp(0, mapped.length);
      final chunk = mapped.sublist(i, end);
      final futures = <Future<void>>[];
      for (int j = 0; j < chunk.length; j++) {
        final idx = i + j;
        final c = mapped[idx];
        futures.add(() async {
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
        }());
      }
      await Future.wait(futures);
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.getText(
            'download_folder_set',
            fallback: 'Carpeta de descargas establecida',
          ),
        ),
      ),
    );
    debugPrint('[SpotifyScreen] download_folder saved: $norm');
  }

  // enlista descarga de una canción
  Future<void> _queueDownload(Map<String, dynamic> c) async {
    debugPrint('[SpotifyScreen] queueDownload for item: ${c.toString()}');
    final prefs = await SharedPreferences.getInstance();
    String? downloadFolder = prefs.getString('download_folder');

    if (downloadFolder == null || downloadFolder.isEmpty) {
      debugPrint('[SpotifyScreen] no download folder pref, asking user');
      final carpeta = await FilePicker.platform.getDirectoryPath();
      if (carpeta == null) {
        _uiLog('Descarga cancelada por usuario (no hay carpeta)');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.getText(
                'download_cancelled',
                fallback: 'Descarga cancelada',
              ),
            ),
          ),
        );
        return;
      }
      downloadFolder = p.normalize(carpeta);
      await prefs.setString('download_folder', downloadFolder);
      debugPrint(
        '[SpotifyScreen] user selected download folder: $downloadFolder',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.getText(
              'download_folder_set',
              fallback: 'Carpeta de descargas establecida',
            ),
          ),
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.getText(
              'download_folder_invalid',
              fallback: 'Carpeta inválida o sin permisos',
            ),
          ),
        ),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.getText('download_queued', fallback: 'Download queued'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;
    final prefsFolder = _prefs?.getString('download_folder');

    // Determine which list to show
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
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(12),
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
                                border: InputBorder.none,
                              ),
                              style: const TextStyle(fontSize: 14),
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) => _buscarCanciones(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.search),
                            label: Text(
                              get('search_button', fallback: 'Search'),
                            ),
                            onPressed: _buscarCanciones,
                            style: ElevatedButton.styleFrom(
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(10),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              backgroundColor: const Color.fromARGB(
                                255,
                                224,
                                64,
                                251,
                              ),
                              foregroundColor: Colors.black87,
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
                              const Icon(Icons.recommend, color: Colors.amber),
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
                            final c = listToShow[index];
                            final title =
                                (c['title'] ??
                                        get('untitled', fallback: 'Sin título'))
                                    .toString();
                            final duration = c['duration'] ?? '';
                            final imageUrl = (c['image'] ?? '').toString();
                            String artista = get(
                              'unknown_artist',
                              fallback: 'Artista desconocido',
                            );
                            String nombre = title;
                            if (title.contains(' - ')) {
                              final partes = title.split(' - ');
                              artista = partes.isNotEmpty ? partes[0] : artista;
                              nombre = partes.length > 1
                                  ? partes[1]
                                  : partes[0];
                            }

                            DownloadTask? task;
                            final src = (c['url'] ?? '').toString();
                            if (src.isNotEmpty) task = _dmTasksBySource[src];
                            task ??= _dmTasksBySource[title];

                            Widget statusChip() {
                              if (task == null) {
                                return const SizedBox.shrink();
                              }
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
                                      color: Colors.orange[700],
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

                            return Card(
                              child: ListTile(
                                leading: imageUrl.isNotEmpty
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.network(
                                          imageUrl,
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : const Icon(Icons.music_note),
                                title: Text(nombre),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('$artista • $duration'),
                                    if (task != null &&
                                        task.errorMessage != null &&
                                        task.errorMessage!.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(
                                          'Error: ${task.errorMessage}',
                                          style: const TextStyle(
                                            color: Colors.redAccent,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    statusChip(),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.download),
                                      onPressed: () => _queueDownload(c),
                                    ),
                                  ],
                                ),
                              ),
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
      floatingActionButton: FloatingActionButton(
        tooltip: get('open_downloads', fallback: 'Downloads'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DownloadsScreen(
              getText: widget.getText,
              currentLang: widget.currentLang,
            ),
          ),
        ),
        backgroundColor: const Color.fromARGB(255, 224, 64, 251),
        foregroundColor: Colors.black87,
        child: const Icon(Icons.download),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}
