import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../services/download_manager.dart';
import '../models/download_task.dart';

typedef TextGetter = String Function(String key, {String? fallback});

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({
    super.key,
    required this.getText,
    required this.currentLang,
  });

  final String currentLang;
  final TextGetter getText;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen>
    with WindowListener, WidgetsBindingObserver {
  final DownloadManager _dm = DownloadManager();
  late final VoidCallback _dmListener;
  bool _listenerAdded = false;
  bool _observerAdded = false;

  @override
  void dispose() {
    try {
      if (_listenerAdded) {
        _dm.removeListener(_dmListener);
        _listenerAdded = false;
      }
    } catch (e) {
      debugPrint('[DownloadsScreen] Error removing listener: $e');
    }
    try {
      if (_observerAdded) {
        WidgetsBinding.instance.removeObserver(this);
        _observerAdded = false;
      }
    } catch (e) {
      debugPrint('[DownloadsScreen] Error removing observer: $e');
    }
    try {
      windowManager.removeListener(this);
    } catch (e) {
      debugPrint('[DownloadsScreen] Error removing window listener: $e');
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      try {
        if (_listenerAdded) {
          _dm.removeListener(_dmListener);
          _listenerAdded = false;
        }
      } catch (e) {
        debugPrint('[DownloadsScreen] Error pausing listener: $e');
      }
    } else if (state == AppLifecycleState.resumed) {
      try {
        if (!_listenerAdded) {
          _dm.addListener(_dmListener);
          _listenerAdded = true;
        }
      } catch (e) {
        debugPrint('[DownloadsScreen] Error resuming listener: $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    try {
      windowManager.addListener(this);
    } catch (e) {
      debugPrint('[DownloadsScreen] Error adding window listener: $e');
    }

    try {
      WidgetsBinding.instance.addObserver(this);
      _observerAdded = true;
    } catch (e) {
      debugPrint('[DownloadsScreen] Error adding observer: $e');
    }

    // define el listener correctamente
    _dmListener = () {
      try {
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {});
            }
          });
        }
      } catch (e) {
        debugPrint('[DownloadsScreen] Error in listener callback: $e');
      }
    };

    try {
      _dm.addListener(_dmListener);
      _listenerAdded = true;
    } catch (e) {
      debugPrint('[DownloadsScreen] Error adding listener: $e');
    }
  }

  Widget _buildTitleBar() {
    try {
      final get = widget.getText;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) {
          try {
            windowManager.startDragging();
          } catch (e) {
            debugPrint('[DownloadsScreen] Error starting drag: $e');
          }
        },
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: Colors.transparent,
          child: Row(
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    color: Theme.of(context).cardTheme.color?.withOpacity(0.5),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.download,
                      color: Theme.of(context).iconTheme.color,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  get('downloads_title', fallback: 'Downloads'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: get('minimize', fallback: 'Minimize'),
                icon: const Icon(Icons.remove, size: 18),
                onPressed: () {
                  try {
                    windowManager.minimize();
                  } catch (e) {
                    debugPrint('[DownloadsScreen] Error minimizing: $e');
                  }
                },
              ),
              IconButton(
                tooltip: get('maximize', fallback: 'Maximize'),
                icon: const Icon(Icons.crop_square, size: 18),
                onPressed: () async {
                  try {
                    final isMax = await windowManager.isMaximized();
                    if (isMax) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  } catch (e) {
                    debugPrint('[DownloadsScreen] Error maximizing: $e');
                  }
                },
              ),
              IconButton(
                tooltip: get('back', fallback: 'Back'),
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: () {
                  try {
                    Navigator.of(context).maybePop();
                  } catch (e) {
                    debugPrint('[DownloadsScreen] Error popping: $e');
                  }
                },
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      debugPrint('[DownloadsScreen] Error building title bar: $e');
      return Container(
        height: 42,
        color: Colors.black26,
        child: const Center(child: Text('Title bar error')),
      );
    }
  }

  Widget _buildEmpty() {
    final get = widget.getText;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.download_for_offline,
            size: 56,
            color: Theme.of(context).iconTheme.color?.withOpacity(0.24),
          ),
          const SizedBox(height: 12),
          Text(
            get('no_downloads', fallback: 'No downloads'),
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            get(
              'no_downloads_desc',
              fallback: 'Queued and completed downloads will appear here.',
            ),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(
                context,
              ).textTheme.bodyMedium?.color?.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(DownloadTask t) {
    final get = widget.getText;
    return Card(
      color: Theme.of(context).cardTheme.color,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: t.image.isNotEmpty
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  t.image,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.music_note),
                ),
              )
            : const Icon(Icons.music_note, size: 48),
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            t.type == TaskType.audio
                ? Text(t.artist, style: const TextStyle(fontSize: 12))
                : Text(
                    'Video',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                    ),
                  ),
            if (t.errorMessage != null && t.errorMessage!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6.0),
                child: Text(
                  'Error: ${t.errorMessage}',
                  style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6.0),
                child: Row(
                  children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        child: t.status == DownloadStatus.running
                            ? LinearProgressIndicator(
                                value: t.progress,
                                minHeight: 6,
                              )
                            : t.status == DownloadStatus.completed
                            ? LinearProgressIndicator(
                                value: 1.0,
                                minHeight: 6,
                                color: Colors.green,
                              )
                            : LinearProgressIndicator(
                                value: t.progress.clamp(0.0, 1.0),
                                minHeight: 6,
                                color: Colors.grey,
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      (t.status == DownloadStatus.running)
                          ? '${(t.progress * 100).toStringAsFixed(1)}%'
                          : t.statusString(),
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'Courier',
                        color: Theme.of(context).textTheme.bodyMedium?.color,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Botón de bypass (solo para tareas de audio de Spotify)
            if (t.type == TaskType.audio &&
                t.sourceUrl.toLowerCase().contains('spotify') &&
                (t.status == DownloadStatus.queued ||
                    t.status == DownloadStatus.failed))
              Tooltip(
                message: t.bypassSpotifyApi
                    ? get(
                        'bypass_active',
                        fallback: 'Bypass Spotify API (Active)',
                      )
                    : get('bypass_inactive', fallback: 'Use Spotify API'),
                child: IconButton(
                  icon: Icon(
                    t.bypassSpotifyApi ? Icons.flash_off : Icons.flash_on,
                    color: t.bypassSpotifyApi
                        ? Colors.orangeAccent
                        : Colors.grey,
                    size: 20,
                  ),
                  onPressed: () =>
                      DownloadManager().toggleBypassSpotifyApi(t.id),
                ),
              ),
            if (t.status == DownloadStatus.running)
              IconButton(
                tooltip: get('cancel2', fallback: 'Cancel'),
                icon: const Icon(Icons.cancel, color: Colors.orangeAccent),
                onPressed: () => DownloadManager().cancelTask(t.id),
              )
            else if (t.status == DownloadStatus.failed)
              IconButton(
                tooltip: get('retry', fallback: 'Retry'),
                icon: const Icon(Icons.refresh, color: Colors.cyanAccent),
                onPressed: () => DownloadManager().retryTask(t.id),
              )
            else if (t.status == DownloadStatus.completed)
              IconButton(
                tooltip: get('open_file', fallback: 'Open'),
                icon: const Icon(Icons.open_in_new, color: Colors.greenAccent),
                onPressed: t.localPath != null
                    ? () => _openFile(t.localPath!)
                    : null,
              )
            else
              IconButton(
                tooltip: get('queue', fallback: 'Queued'),
                icon: Icon(
                  Icons.hourglass_top,
                  color: Theme.of(context).iconTheme.color?.withOpacity(0.7),
                ),
                onPressed: null,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFile(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        final dir = Directory(path).parent.path;
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    try {
      final get = widget.getText;
      final tasks = _dm.tasksReversed;
      return Scaffold(
        backgroundColor: const Color.fromARGB(255, 34, 34, 34),
        body: Column(
          children: [
            _buildTitleBar(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: tasks.isEmpty
                    ? _buildEmpty()
                    : ListView.separated(
                        itemCount: tasks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _safeTaskTile(tasks[i]),
                      ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.transparent,
              child: Row(
                children: [
                  Text(
                    '${get('download_count', fallback: 'Total')}: ${_dm.tasks.length}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      try {
                        _dm.clearCompleted();
                      } catch (e) {
                        debugPrint(
                          '[DownloadsScreen] Error clearing completed: $e',
                        );
                      }
                    },
                    icon: const Icon(Icons.delete_sweep, size: 18),
                    label: Text(get('clear_completed', fallback: 'Clear')),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } catch (e, st) {
      debugPrint('[DownloadsScreen] Build error: $e\n$st');
      return Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 16),
              Text(
                'Error loading downloads',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                e.toString(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.color?.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  try {
                    Navigator.of(context).pop();
                  } catch (_) {}
                },
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _safeTaskTile(DownloadTask t) {
    try {
      return _buildTaskTile(t);
    } catch (e) {
      debugPrint('[DownloadsScreen] Error building task tile: $e');
      return Card(
        color: Theme.of(context).cardTheme.color,
        child: ListTile(
          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('Error loading task details'),
          trailing: const Icon(Icons.warning, color: Colors.orangeAccent),
        ),
      );
    }
  }
}
