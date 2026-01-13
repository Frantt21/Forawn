// lib/screen/video_downloader.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import '../models/download_task.dart';
import '../services/download_manager.dart';
import 'downloads_screen.dart';
import '../widgets/elegant_notification.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class VideoDownloaderScreen extends StatefulWidget {
  const VideoDownloaderScreen({
    super.key,
    required this.getText,
    required this.currentLang,
    this.onRegisterFolderAction,
  });

  final String currentLang;
  final TextGetter getText;
  final void Function(VoidCallback)? onRegisterFolderAction;

  @override
  State<VideoDownloaderScreen> createState() => _VideoDownloaderScreenState();
}

class _VideoDownloaderScreenState extends State<VideoDownloaderScreen>
    with WindowListener {
  final TextEditingController _controller = TextEditingController();
  // DownloadManager handles queue now
  String? _downloadFolder;
  SharedPreferences? _prefs;

  // UI state
  bool _loadingMeta = false;
  bool _probingFormats = false;
  String? _videoTitle;
  String? _thumbnailUrl;
  Uint8List? _thumbnailBytes;
  List<Map<String, dynamic>> _formats = [];
  Map<String, String> _formatLabels = {}; // format_id -> label
  final ValueNotifier<Map<String, String>> _formatLabelsNotifier =
      ValueNotifier({});
  String? _selectedFormatId;

  @override
  void initState() {
    super.initState();
    try {
      windowManager.addListener(this);
    } catch (e) {
      debugPrint('[VideoDownloaderScreen] Error adding window listener: $e');
    }

    try {
      _loadPrefs();
    } catch (e) {
      debugPrint('[VideoDownloaderScreen] Error loading prefs: $e');
    }

    if (widget.onRegisterFolderAction != null) {
      try {
        widget.onRegisterFolderAction!(_selectDownloadFolder);
      } catch (e) {
        debugPrint(
          '[VideoDownloaderScreen] Error registering folder action: $e',
        );
      }
    }
  }

  @override
  void dispose() {
    try {
      windowManager.removeListener(this);
    } catch (e) {
      debugPrint('[VideoDownloaderScreen] Error removing window listener: $e');
    }
    try {
      _controller.dispose();
    } catch (e) {
      debugPrint('[VideoDownloaderScreen] Error disposing controller: $e');
    }
    try {
      _formatLabelsNotifier.dispose();
    } catch (e) {
      debugPrint('[VideoDownloaderScreen] Error disposing format labels: $e');
    }
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final folder = _prefs!.getString('video_download_folder');
      if (folder != null && folder.isNotEmpty) _downloadFolder = folder;
    } catch (_) {}
  }

  Future<void> _selectDownloadFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    _downloadFolder = p.normalize(path);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString('video_download_folder', _downloadFolder!);
    setState(() {});

    showElegantNotification(
      context,
      widget.getText(
        'download_folder_set',
        fallback: 'Video download folder set',
      ),
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.folder_open,
      iconColor: Colors.blue,
    );
  }

  bool _isValidUrl(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    try {
      final u = Uri.parse(t);
      return u.hasScheme && u.isAbsolute;
    } catch (_) {
      return false;
    }
  }

  // --- Process runner / yt-dlp integration ---
  String _findBaseDir() {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      if (Directory(p.join(exeDir, 'tools')).existsSync()) return exeDir;
    } catch (_) {}
    final currentDir = Directory.current.path;
    if (Directory(p.join(currentDir, 'tools')).existsSync()) return currentDir;

    final candidates = <String>[
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Debug'),
      p.join(currentDir, 'build', 'windows', 'runner', 'Debug'),
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Release'),
      p.join(currentDir, 'build', 'windows', 'runner', 'Release'),
      p.normalize(p.current),
    ];
    for (final base in candidates) {
      if (Directory(p.join(base, 'tools')).existsSync()) return base;
    }
    return '';
  }

  String _findToolsDir() =>
      _findBaseDir().isEmpty ? '' : p.join(_findBaseDir(), 'tools');

  Future<int> _runProcessStreamed({
    required String executable,
    required List<String> arguments,
    String? workingDirectory,
    void Function(String)? onStdout,
    void Function(String)? onStderr,
    void Function(String)? onProgressLine,
    bool runInShell = false,
  }) async {
    final proc = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: runInShell,
    );

    void handle(
      Stream<List<int>> stream,
      void Function(String)? handler, {
      bool progress = false,
    }) {
      final buffer = BytesBuilder();
      stream.listen(
        (chunk) {
          buffer.add(chunk);
          final bytes = buffer.toBytes();
          int lastNewline = -1;
          for (int i = 0; i < bytes.length; i++) {
            if (bytes[i] == 10) lastNewline = i;
          }
          if (lastNewline >= 0) {
            final lineBytes = bytes.sublist(0, lastNewline + 1);
            final remaining = bytes.sublist(lastNewline + 1);
            buffer.clear();
            if (remaining.isNotEmpty) buffer.add(remaining);
            String line;
            try {
              line = const Utf8Decoder(allowMalformed: true).convert(lineBytes);
            } catch (_) {
              line = latin1.decode(lineBytes, allowInvalid: true);
            }
            line = line.replaceAll('\r\n', '\n').trimRight();
            if (handler != null && line.isNotEmpty) handler(line);
            if (progress && onProgressLine != null && line.isNotEmpty) {
              onProgressLine(line);
            }
          }
        },
        onDone: () {
          final rem = buffer.toBytes();
          if (rem.isNotEmpty) {
            String tail;
            try {
              tail = const Utf8Decoder(allowMalformed: true).convert(rem);
            } catch (_) {
              tail = latin1.decode(rem, allowInvalid: true);
            }
            tail = tail.replaceAll('\r\n', '\n').trimRight();
            if (handler != null && tail.isNotEmpty) handler(tail);
            if (progress && onProgressLine != null && tail.isNotEmpty) {
              onProgressLine(tail);
            }
          }
        },
        onError: (err, _) {
          if (handler != null) handler('Stream error: $err');
        },
        cancelOnError: true,
      );
    }

    handle(proc.stdout, onStdout, progress: true);
    handle(proc.stderr, onStderr, progress: true);
    final code = await proc.exitCode;
    return code;
  }

  // --- parse yt-dlp -j output line-by-line and return FIRST valid JSON object ---
  Future<Map<String, dynamic>?> _ytdlpMetadata({
    required String toolsDir,
    required String url,
    required void Function(String) logger,
  }) async {
    final ytdlp = p.join(toolsDir, 'yt-dlp.exe');
    // Optimization: Add --flat-playlist if we suspect playlist, but simplest is standard -j
    final args = [url, '-j', '--no-playlist', '--ignore-errors'];
    final outBuf = StringBuffer();
    final code = await _runProcessStreamed(
      executable: ytdlp,
      arguments: args,
      workingDirectory: toolsDir,
      onStdout: (l) => outBuf.writeln(l),
      onStderr: (l) => logger('yt-dlp meta err: $l'),
      onProgressLine: (l) => logger('meta: $l'),
      runInShell: false,
    );
    if (code != 0) {
      logger('yt-dlp metadata exit code $code');
      return null;
    }

    final out = outBuf.toString();
    if (out.trim().isEmpty) return null;

    final lines = out
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    for (final line in lines) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        } else {
          logger('Skipping non-object JSON metadata line');
        }
      } catch (e) {
        logger('JSON parse error for a metadata line: $e');
      }
    }

    logger('No valid JSON metadata found in yt-dlp output');
    return null;
  }

  // parse formats list into a user-presentable list
  Future<List<Map<String, dynamic>>> _probeFormats(
    String url,
    void Function(String) logger,
  ) async {
    final toolsDir = _findToolsDir();
    final List<Map<String, dynamic>> res = [];
    if (toolsDir.isEmpty) return res;
    final meta = await _ytdlpMetadata(
      toolsDir: toolsDir,
      url: url,
      logger: logger,
    );
    if (meta == null) return res;
    final formats = meta['formats'] as List<dynamic>? ?? [];
    for (final f in formats.whereType<Map<String, dynamic>>()) {
      final it = <String, dynamic>{
        'format_id': f['format_id'],
        'ext': f['ext'],
        'height': f['height'],
        'width': f['width'],
        'format_note': f['format_note'],
        'acodec': f['acodec'],
        'vcodec': f['vcodec'],
        'filesize': f['filesize'],
      };
      res.add(it);
    }
    // sort: prefer highest resolution first
    res.sort((a, b) {
      final ah = (a['height'] ?? 0) is int
          ? (a['height'] ?? 0) as int
          : int.tryParse('${a['height'] ?? 0}') ?? 0;
      final bh = (b['height'] ?? 0) is int
          ? (b['height'] ?? 0) as int
          : int.tryParse('${b['height'] ?? 0}') ?? 0;
      return bh.compareTo(ah);
    });
    return res;
  }

  String _formatLabel(Map<String, dynamic> f) {
    final height = (f['height'] is int)
        ? f['height'] as int
        : (int.tryParse('${f['height'] ?? 0}') ?? 0);
    final width = (f['width'] is int)
        ? f['width'] as int
        : (int.tryParse('${f['width'] ?? 0}') ?? 0);
    final ext = f['ext']?.toString() ?? '';
    final size = f['filesize'];
    String sizeStr = '';
    if (size is int && size > 0) {
      final mb = size / (1024 * 1024);
      sizeStr = ' • ${mb.toStringAsFixed(1)} MB';
    }
    if (height == 0 &&
        (f['acodec'] != null &&
            (f['vcodec'] == null || f['vcodec'] == 'none'))) {
      return 'Audio • ${f['acodec'] ?? ''}$sizeStr';
    }
    return height > 0
        ? '${height}p • $width×$height px • $ext$sizeStr'
        : 'Unknown • $ext$sizeStr';
  }

  // Queue management -> Sent to DownloadManager
  Future<void> _addToQueue(String url, String title, {String? formatId}) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final task = DownloadTask(
      id: id,
      title: title,
      artist: '',
      image: _thumbnailUrl ?? '',
      sourceUrl: url,
      type: TaskType.video,
      formatId: formatId,
    );
    DownloadManager().addTask(task);
    showElegantNotification(
      context,
      widget.getText('added_to_queue', fallback: 'Added to download queue'),
      backgroundColor: const Color(0xFF2C2C2C),
      textColor: Colors.white,
      icon: Icons.check_circle_outline,
      iconColor: Colors.green,
    );
  }

  // UI actions
  Future<void> _onInspectUrl() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    if (!_isValidUrl(url)) {
      showElegantNotification(
        context,
        widget.getText('invalid_url', fallback: 'Invalid URL'),
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
      return;
    }

    final toolsDir = _findToolsDir();
    if (toolsDir.isEmpty) {
      showElegantNotification(
        context,
        widget.getText('tools_not_found', fallback: 'Tools not found'),
        backgroundColor: const Color(0xFFE53935),
        textColor: Colors.white,
        icon: Icons.error_outline,
        iconColor: Colors.white,
      );
      return;
    }

    setState(() {
      _loadingMeta = true;
      _videoTitle = null;
      _thumbnailBytes = null;
      _thumbnailUrl = null;
      _formats = [];
      _formatLabels = {};
      _selectedFormatId = null;
      _formatLabelsNotifier.value = {};
    });

    try {
      final meta = await _ytdlpMetadata(
        toolsDir: toolsDir,
        url: url,
        logger: (_) {},
      );
      if (meta == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.getText(
                'meta_error',
                fallback: 'Could not fetch metadata',
              ),
            ),
          ),
        );
        setState(() => _loadingMeta = false);
        return;
      }

      final title = (meta['title'] ?? url).toString();
      final thumbUrl = meta['thumbnail'] as String?;

      Uint8List? thumbBytes;
      if (thumbUrl != null && thumbUrl.isNotEmpty) {
        try {
          final uri = Uri.tryParse(thumbUrl);
          if (uri != null) {
            final client = HttpClient();
            final req = await client.getUrl(uri);
            final resp = await req.close();
            if (resp.statusCode == 200) {
              thumbBytes = await consolidateHttpClientResponseBytes(resp);
            }
            client.close();
          }
        } catch (_) {}
      }

      setState(() {
        _videoTitle = title;
        _thumbnailUrl = thumbUrl;
        _thumbnailBytes = thumbBytes;
        _loadingMeta = false;
        _probingFormats = true;
      });

      // Probe formats and update ValueNotifier as results arrive.
      unawaited(
        _probeFormats(url, (s) {})
            .then((formats) {
              final Map<String, String> labels = {};
              for (final f in formats) {
                try {
                  final fid = f['format_id']?.toString() ?? '';
                  if (fid.isEmpty) continue;
                  labels[fid] = _formatLabel(f);
                } catch (_) {}
              }
              _formats = formats;
              _formatLabels = labels;
              _formatLabelsNotifier.value = Map<String, String>.from(labels);
              setState(() {
                _probingFormats = false;
              });
            })
            .catchError((_) {
              _formats = [];
              _formatLabels = {};
              _formatLabelsNotifier.value = {};
              setState(() {
                _probingFormats = false;
              });
            }),
      );

      // Show dialog immediately; it will reactively update when notifier changes.
      await _showFormatsDialog(url);
    } catch (e) {
      setState(() {
        _loadingMeta = false;
        _probingFormats = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.getText('inspect_error', fallback: 'Error inspecting')}: $e',
          ),
        ),
      );
    }
  }

  Future<void> _showFormatsDialog(String url) async {
    String? chosenFormat = _selectedFormatId;
    final sel = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setStateDialog) {
            return AlertDialog(
              backgroundColor: Theme.of(context).cardTheme.color,
              title: Text(
                widget.getText(
                  'choose_resolution',
                  fallback: 'Choose resolution',
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_videoTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          if (_thumbnailBytes != null)
                            Container(
                              width: 100,
                              height: 56,
                              color: Theme.of(context).cardTheme.color,
                              child: Image.memory(
                                _thumbnailBytes!,
                                fit: BoxFit.cover,
                              ),
                            )
                          else
                            Container(
                              width: 100,
                              height: 56,
                              color: Theme.of(context).cardTheme.color,
                              child: Icon(
                                Icons.image,
                                color: Theme.of(
                                  context,
                                ).iconTheme.color?.withOpacity(0.24),
                              ),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _videoTitle!,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 6),
                  // Reactive dropdown: updates when _formatLabelsNotifier changes
                  ValueListenableBuilder<Map<String, String>>(
                    valueListenable: _formatLabelsNotifier,
                    builder: (ctx3, labels, _) {
                      if (_probingFormats && labels.isEmpty) {
                        return Row(
                          children: [
                            const CircularProgressIndicator(strokeWidth: 2),
                            const SizedBox(width: 8),
                            Text(
                              widget.getText(
                                'probing_formats',
                                fallback: 'Probing available formats...',
                              ),
                            ),
                          ],
                        );
                      }
                      if (labels.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            widget.getText(
                              'no_formats_yet',
                              fallback: 'No formats available',
                            ),
                          ),
                        );
                      }
                      // ensure chosenFormat has a sensible default
                      if (chosenFormat == null ||
                          !labels.containsKey(chosenFormat)) {
                        chosenFormat = labels.keys.first;
                      }
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: chosenFormat,
                          dropdownColor: Colors.grey[900],
                          items: labels.entries.map((e) {
                            return DropdownMenuItem<String>(
                              value: e.key,
                              child: Text(
                                e.value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (v) =>
                              setStateDialog(() => chosenFormat = v),
                        ),
                      );
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(widget.getText('cancel', fallback: 'Cancel')),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(widget.getText('download', fallback: 'Download')),
                ),
              ],
            );
          },
        );
      },
    );

    if (sel == true) {
      final title = _videoTitle ?? url;
      await _addToQueue(url, title, formatId: chosenFormat);
      setState(() => _selectedFormatId = chosenFormat);
    }
  }

  void _showFormatsDialogWrapper() {
    if (_videoTitle == null) return;
    _showFormatsDialog(_controller.text.trim());
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
              debugPrint('[VideoDownloaderScreen] Navigation error: $e\n$st');
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
      debugPrint('[VideoDownloaderScreen] openDownloads error: $e\n$st');
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

  // UI
  @override
  Widget build(BuildContext context) {
    final get = widget.getText;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // URL input + inspect button
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: InputDecoration(
                          hintText: get(
                            'video_url_label',
                            fallback: 'YouTube URL',
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
                        onSubmitted: (_) => _onInspectUrl(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: _loadingMeta
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.search, color: Colors.white),
                      onPressed: _loadingMeta ? null : _onInspectUrl,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withOpacity(0.2),
                        padding: const EdgeInsets.all(8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Preview: thumbnail + title + actions
              if (_loadingMeta)
                Center(
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      const CircularProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(
                        get('loading_meta', fallback: 'Fetching metadata...'),
                      ),
                    ],
                  ),
                ),
              if (!_loadingMeta &&
                  (_videoTitle != null || _thumbnailBytes != null))
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withOpacity(0.04)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 160,
                        height: 90,
                        color: Colors.black26,
                        child: _thumbnailBytes != null
                            ? Image.memory(_thumbnailBytes!, fit: BoxFit.cover)
                            : Center(
                                child: Icon(
                                  Icons.image,
                                  color: Theme.of(
                                    context,
                                  ).iconTheme.color?.withOpacity(0.24),
                                ),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _videoTitle ??
                                  get('no_title', fallback: 'Untitled'),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.download),
                              label: Text(
                                get(
                                  'choose_resolution',
                                  fallback: 'Choose resolution',
                                ),
                              ),
                              onPressed: _showFormatsDialogWrapper,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),

              if (_probingFormats)
                Row(
                  children: [
                    const CircularProgressIndicator(strokeWidth: 2),
                    const SizedBox(width: 8),
                    Text(
                      get(
                        'probing_formats',
                        fallback: 'Probing available formats...',
                      ),
                    ),
                  ],
                ),

              if (!_probingFormats && !_loadingMeta && _videoTitle == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.video_library,
                          size: 48,
                          color: Theme.of(
                            context,
                          ).iconTheme.color?.withOpacity(0.24),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          get(
                            'enter_url_desc',
                            fallback: 'Enter a YouTube URL to start',
                          ),
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.color?.withOpacity(0.54),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'video_downloads_fab',
        tooltip: get('open_downloads', fallback: 'Downloads'),
        onPressed: _openDownloadsScreen,
        backgroundColor: const Color.fromARGB(255, 224, 64, 251),
        foregroundColor: Colors.black87,
        child: const Icon(Icons.download),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}
