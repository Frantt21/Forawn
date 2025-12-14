import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'config/api_config.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class R34Screen extends StatefulWidget {
  final TextGetter getText;
  final String currentLang;
  final Function(VoidCallback)? onRegisterFolderAction;
  final Function(String)? onNavigate;

  const R34Screen({
    super.key,
    required this.getText,
    required this.currentLang,
    this.onRegisterFolderAction,
    this.onNavigate,
  });

  @override
  State<R34Screen> createState() => _R34ScreenState();
}

class _R34ScreenState extends State<R34Screen> with WindowListener {
  final TextEditingController _queryController = TextEditingController();
  bool _loading = false;
  String _status = '';
  List<_R34Item> _results = [];
  String? _saveFolder;
  SharedPreferences? _prefs;

  static const _prefsKey = 'r34_save_folder';
  bool _acceptedAdultWarning = false;

  double _inputHeight = 72;
  bool _isDraggingHandle = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _loadFolderPref();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowWarning());
    if (widget.onRegisterFolderAction != null) {
      widget.onRegisterFolderAction!(_selectFolder);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _loadFolderPref() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final f = _prefs!.getString(_prefsKey);
      if (f != null && f.isNotEmpty) {
        _saveFolder = f;
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _selectFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    _saveFolder = p.normalize(dir);
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(_prefsKey, _saveFolder!);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _status =
          '${widget.getText('save_folder_set', fallback: 'Save folder set')}: $_saveFolder';
    });
  }

  Future<void> _maybeShowWarning() async {
    if (_acceptedAdultWarning) return;
    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        title: Row(
          children: [
            const Icon(Icons.warning, color: Colors.purpleAccent),
            const SizedBox(width: 8),
            Text(
              widget.getText('adult_warning_title', fallback: 'Adult content'),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        content: Text(
          widget.getText(
            'adult_warning_message',
            fallback:
                'This section may display explicit adult images. You must be of legal age in your jurisdiction to proceed.',
          ),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              widget.getText('cancel', fallback: 'Cancel'),
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purpleAccent,
              foregroundColor: Colors.white,
            ),
            child: Text(widget.getText('accept', fallback: 'I am 18+')),
          ),
        ],
      ),
    );
    if (accept == true) {
      _acceptedAdultWarning = true;
    } else {
      if (mounted) widget.onNavigate?.call('home');
    }
  }

  String _buildApiUrl(String q) {
    final encoded = Uri.encodeComponent(q);
    return '${ApiConfig.dorratzBaseUrl}/v2/rule34-s?q=$encoded';
  }

  Future<void> _search() async {
    final q = _queryController.text.trim();
    if (q.isEmpty) {
      setState(
        () => _status = widget.getText(
          'enter_query',
          fallback: 'Enter a search query',
        ),
      );
      return;
    }

    if (!_acceptedAdultWarning) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          title: Row(
            children: [
              const Icon(Icons.warning, color: Colors.purpleAccent),
              const SizedBox(width: 8),
              Text(
                widget.getText(
                  'adult_warning_title',
                  fallback: 'Adult content',
                ),
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
          content: Text(
            widget.getText(
              'adult_warning_confirm',
              fallback:
                  'Search results may include explicit images. Do you wish to continue?',
            ),
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                widget.getText('cancel', fallback: 'Cancel'),
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purpleAccent,
                foregroundColor: Colors.white,
              ),
              child: Text(widget.getText('continue', fallback: 'Continue')),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      _acceptedAdultWarning = true;
    }

    setState(() {
      _loading = true;
      _status = '';
      _results = [];
    });

    try {
      final url = _buildApiUrl(q);
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final parsed = jsonDecode(res.body);

      final List<dynamic> items;
      if (parsed is List) {
        items = parsed;
      } else if (parsed is Map &&
          parsed.containsKey('data') &&
          parsed['data'] is List) {
        items = parsed['data'] as List<dynamic>;
      } else if (parsed is Map) {
        items = [parsed];
      } else {
        items = [];
      }

      final extracted = <_R34Item>[];
      for (final e in items) {
        if (e is Map) {
          final imageUrl =
              (e['imageUrl'] ?? e['image_url'] ?? e['image'] ?? e['url'])
                  ?.toString();
          final title = (e['title'] ?? e['tags'] ?? e['postId'] ?? '')
              ?.toString();
          if (imageUrl != null && imageUrl.isNotEmpty) {
            extracted.add(_R34Item(imageUrl: imageUrl, title: title ?? ''));
          }
        }
      }

      if (extracted.isEmpty) {
        if (!mounted) return;
        setState(() {
          _results = [];
          _status = widget.getText('no_results', fallback: 'No results');
        });
        return;
      }

      final rnd = Random();
      final chosen = <_R34Item>[];
      final indices = <int>{};
      final max = min(40, extracted.length);
      while (chosen.length < max) {
        final idx = rnd.nextInt(extracted.length);
        if (indices.add(idx)) chosen.add(extracted[idx]);
      }

      if (!mounted) return;
      setState(() {
        _results = chosen;
        _status =
            '${widget.getText('results_count', fallback: 'Results')}: ${_results.length}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status =
            '${widget.getText('search_error', fallback: 'Search error')}: ${e.toString()}';
      });
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _confirmAndDownload(_R34Item item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        title: Row(
          children: [
            const Icon(Icons.download, color: Colors.purpleAccent),
            const SizedBox(width: 8),
            Text(
              widget.getText(
                'download_confirm_title',
                fallback: 'Download image',
              ),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        content: Text(
          widget.getText(
            'download_confirm_message',
            fallback: 'This image may be explicit. Do you want to download it?',
          ),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              widget.getText('cancel', fallback: 'Cancel'),
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purpleAccent,
              foregroundColor: Colors.white,
            ),
            child: Text(widget.getText('download', fallback: 'Download')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _downloadItem(item);
    }
  }

  Future<void> _downloadItem(_R34Item item) async {
    try {
      setState(
        () =>
            _status = widget.getText('downloading', fallback: 'Downloading...'),
      );
      final res = await http
          .get(Uri.parse(item.imageUrl))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

      final bytes = res.bodyBytes;
      String folder = _saveFolder ?? '';
      if (folder.isEmpty) {
        final picked = await FilePicker.platform.getDirectoryPath();
        if (picked == null) {
          setState(
            () => _status = widget.getText(
              'save_cancelled',
              fallback: 'Save cancelled',
            ),
          );
          return;
        }
        folder = p.normalize(picked);
        _saveFolder = folder;
        try {
          _prefs ??= await SharedPreferences.getInstance();
          await _prefs!.setString(_prefsKey, _saveFolder!);
        } catch (_) {}
      }

      final ext = _guessExtensionFromBytes(bytes) ?? '.jpg';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeTitle = item.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final filename =
          'r34_${safeTitle.length > 40 ? safeTitle.substring(0, 40) : safeTitle}_$timestamp$ext';
      final path = p.join(folder, filename);
      final f = File(path);
      await f.create(recursive: true);
      await f.writeAsBytes(bytes);
      setState(
        () => _status =
            '${widget.getText('saved_to', fallback: 'Saved to')}: $path',
      );
    } catch (e) {
      setState(
        () => _status =
            '${widget.getText('download_error', fallback: 'Download error')}: ${e.toString()}',
      );
    }
  }

  String? _guessExtensionFromBytes(Uint8List bytes) {
    if (bytes.length >= 4) {
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) return '.jpg';
      if (bytes[0] == 0x89 && bytes[1] == 0x50) return '.png';
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        return '.gif';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final get = widget.getText;

    final Color scaffoldBg = Colors.transparent;

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardTheme.color,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Stack(
                        children: [
                          Column(
                            children: [
                              SizedBox(
                                height: _inputHeight,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    12,
                                    12,
                                    40,
                                  ),
                                  child: TextField(
                                    controller: _queryController,
                                    expands: true,
                                    maxLines: null,
                                    minLines: null,
                                    textAlignVertical: TextAlignVertical.top,
                                    textInputAction: TextInputAction.search,
                                    decoration: InputDecoration(
                                      border: InputBorder.none,
                                      hintText: get(
                                        'query_hint',
                                        fallback: 'e.g. Bulma',
                                      ),
                                      hintStyle: Theme.of(
                                        context,
                                      ).inputDecorationTheme.hintStyle,
                                      contentPadding: EdgeInsets.zero,
                                      isDense: true,
                                    ),
                                    style: const TextStyle(fontSize: 15),
                                    onSubmitted: (_) => _search(),
                                  ),
                                ),
                              ),
                            ],
                          ),

                          // Drag Handle (Center Bottom)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onVerticalDragStart: (_) =>
                                  setState(() => _isDraggingHandle = true),
                              onVerticalDragUpdate: (details) {
                                setState(() {
                                  _inputHeight =
                                      (_inputHeight + details.delta.dy).clamp(
                                        60.0,
                                        300.0,
                                      );
                                });
                              },
                              onVerticalDragEnd: (_) =>
                                  setState(() => _isDraggingHandle = false),
                              child: Container(
                                height: 24,
                                alignment: Alignment.center,
                                child: Container(
                                  width: 40,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: _isDraggingHandle
                                        ? Colors.white.withOpacity(0.5)
                                        : Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Search Button (Right Bottom)
                          Positioned(
                            bottom: 8,
                            right: 8,
                            child: IconButton(
                              onPressed: _loading ? null : _search,
                              icon: _loading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.search,
                                      color: Colors.white,
                                    ),
                              style: IconButton.styleFrom(
                                backgroundColor: const Color.fromARGB(
                                  255,
                                  239,
                                  147,
                                  255,
                                ).withOpacity(0.2),
                                hoverColor: const Color.fromARGB(
                                  255,
                                  239,
                                  147,
                                  255,
                                ).withOpacity(0.4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    if (_status.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _status,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),

                    const SizedBox(height: 12),

                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          if (_loading) {
                            return const Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Colors.purpleAccent,
                              ),
                            );
                          }

                          if (_results.isEmpty) {
                            // Si no hay resultados y no se está cargando
                            // Podríamos mostrar un mensaje inicial si query está vacío,
                            // pero por ahora mantendremos "No results" consistente con el resto.
                            return Center(
                              child: Text(
                                get('no_results', fallback: 'No results'),
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                ),
                              ),
                            );
                          }

                          final crossAxisCount = constraints.maxWidth > 1200
                              ? 5
                              : 3;
                          return GridView.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: 0.75,
                                ),
                            itemCount: _results.length,
                            itemBuilder: (context, index) {
                              final item = _results[index];
                              return _resultCard(item);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(_R34Item item) {
    final get = widget.getText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              color: Colors.black12,
              child: Image.network(
                item.imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Center(child: Icon(Icons.broken_image)),
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: get('download', fallback: 'Download'),
              icon: const Icon(Icons.download, size: 18),
              onPressed: () => _confirmAndDownload(item),
            ),
          ],
        ),
      ],
    );
  }
}

class _R34Item {
  final String imageUrl;
  final String title;
  _R34Item({required this.imageUrl, required this.title});
}
