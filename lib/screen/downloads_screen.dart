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

class _DownloadsScreenState extends State<DownloadsScreen> with WindowListener {
  final DownloadManager _dm = DownloadManager();
  late final VoidCallback _dmListener;

  @override
  void dispose() {
    try {
      _dm.removeListener(_dmListener);
    } catch (_) {}
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);

    // define el listener correctamente
    _dmListener = () {
      if (mounted) setState(() {});
    };
    _dm.addListener(_dmListener);
  }

  Widget _buildTitleBar() {
    final get = widget.getText;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
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
                  color: Colors.black26,
                  alignment: Alignment.center,
                  child: const Icon(Icons.download, color: Colors.cyanAccent),
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
              onPressed: () async => await windowManager.minimize(),
            ),
            IconButton(
              tooltip: get('maximize', fallback: 'Maximize'),
              icon: const Icon(Icons.crop_square, size: 18),
              onPressed: () async {
                final isMax = await windowManager.isMaximized();
                if (isMax) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
            IconButton(
              tooltip: get('back', fallback: 'Back'),
              icon: const Icon(Icons.arrow_back, size: 18),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final get = widget.getText;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.download_for_offline,
            size: 56,
            color: Colors.white24,
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
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(DownloadTask t) {
    final get = widget.getText;
    return Card(
      color: Colors.black12,
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
                : const Text(
                    'Video',
                    style: TextStyle(fontSize: 12, color: Colors.blueGrey),
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
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'Courier',
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
                icon: const Icon(Icons.hourglass_top, color: Colors.white70),
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
    final get = widget.getText;
    final tasks = _dm.tasksReversed;
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 27, 27, 27),
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
                      itemBuilder: (_, i) => _buildTaskTile(tasks[i]),
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
                  onPressed: () => _dm.clearCompleted(),
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
  }
}
