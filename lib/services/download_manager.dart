import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_task.dart';
import '../config/api_config.dart';
import 'lyrics_service.dart';
import 'spotify_metadata_service.dart';

class DownloadManager extends ChangeNotifier {
  static final DownloadManager _instance = DownloadManager._internal();
  factory DownloadManager() => _instance;
  DownloadManager._internal();

  final List<DownloadTask> _tasks = [];
  final Map<String, Process> _runningProcs = {}; // keyed por taskId
  final int maxConcurrent = 2;

  SharedPreferences? _prefs;
  bool _loadingPersisted = false;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  List<DownloadTask> get tasksReversed => List.unmodifiable(_tasks.reversed);

  // Método para refrescar el estado de UI globalmente
  void refreshStatus() {
    debugPrint('[DownloadManager] refreshStatus called - notifying listeners');
    notifyListeners();
  }

  // persistencia y carga
  Future<void> loadPersisted() async {
    if (_loadingPersisted) return;
    _loadingPersisted = true;
    debugPrint('[DownloadManager] loadPersisted start');
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString('download_tasks_json');
    if (raw != null && raw.isNotEmpty) {
      try {
        final List decoded = jsonDecode(raw) as List;
        _tasks
          ..clear()
          ..addAll(
            decoded.map(
              (e) => DownloadTask.fromJson(e as Map<String, dynamic>),
            ),
          );
        debugPrint(
          '[DownloadManager] loaded ${_tasks.length} tasks from prefs',
        );
      } catch (e) {
        debugPrint('[DownloadManager] error decoding persisted tasks: $e');
      }
    } else {
      debugPrint('[DownloadManager] no persisted tasks found');
    }
    notifyListeners();
    _loadingPersisted = false;
    Future.microtask(() => _scheduleQueue());
  }

  Future<void> _savePersisted() async {
    _prefs ??= await SharedPreferences.getInstance();
    final enc = jsonEncode(_tasks.map((t) => t.toJson()).toList());
    await _prefs!.setString('download_tasks_json', enc);
    debugPrint('[DownloadManager] persisted ${_tasks.length} tasks');
  }

  // actualizador atomico de tareas
  Future<void> _updateTask(
    DownloadTask task, {
    DownloadStatus? status,
    double? progress,
    String? errorMessage,
    String? localPath,
    DateTime? startedAt,
    DateTime? finishedAt,
  }) async {
    if (status != null) task.status = status;
    if (progress != null) task.progress = progress;
    if (errorMessage != null) task.errorMessage = errorMessage;
    if (localPath != null) task.localPath = localPath;
    if (startedAt != null) task.startedAt = startedAt;
    if (finishedAt != null) task.finishedAt = finishedAt;
    debugPrint(
      '[DownloadManager] _updateTask persist ${task.id} status=${task.status} progress=${task.progress} error=${task.errorMessage}',
    );
    await _savePersisted();
    notifyListeners();
  }

  // API
  void addTask(DownloadTask t) {
    debugPrint(
      '[DownloadManager] addTask ${t.id} "${t.title}" source="${t.sourceUrl}"',
    );
    _tasks.add(t);
    notifyListeners();
    _savePersisted();
    Future.microtask(() => _scheduleQueue());
  }

  void clearCompleted() {
    final before = _tasks.length;
    _tasks.removeWhere(
      (t) =>
          t.status == DownloadStatus.completed ||
          t.status == DownloadStatus.cancelled ||
          t.status == DownloadStatus.failed,
    );
    if (_tasks.length != before) {
      debugPrint(
        '[DownloadManager] clearCompleted removed ${before - _tasks.length} tasks',
      );
      notifyListeners();
      _savePersisted();
    } else {
      debugPrint('[DownloadManager] clearCompleted nothing to remove');
    }
  }

  // eliminar solo tareas fallidas
  void clearFailed() {
    final before = _tasks.length;
    _tasks.removeWhere((t) => t.status == DownloadStatus.failed);
    if (_tasks.length != before) {
      debugPrint(
        '[DownloadManager] clearFailed removed ${before - _tasks.length} tasks',
      );
      notifyListeners();
      _savePersisted();
    } else {
      debugPrint('[DownloadManager] clearFailed nothing to remove');
    }
  }

  void retryTask(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx >= 0) {
      final old = _tasks[idx];
      final retry = DownloadTask(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: old.title,
        artist: old.artist,
        image: old.image,
        sourceUrl: old.sourceUrl,
        type: old.type,
        formatId: old.formatId,
        bypassSpotifyApi: old.bypassSpotifyApi, // Preservar el bypass flag
      );
      debugPrint(
        '[DownloadManager] retryTask: re-enqueue ${old.id} -> ${retry.id} (bypass: ${retry.bypassSpotifyApi})',
      );
      addTask(retry);
    } else {
      debugPrint('[DownloadManager] retryTask: task not found $id');
    }
  }

  void cancelTask(String id) {
    final tIndex = _tasks.indexWhere((x) => x.id == id);
    if (tIndex < 0) {
      debugPrint('[DownloadManager] cancelTask: not found $id');
      return;
    }
    final t = _tasks[tIndex];

    final proc = _runningProcs[id];
    if (proc != null) {
      try {
        proc.kill(ProcessSignal.sigkill);
        debugPrint('[DownloadManager] kill proc for task $id');
      } catch (e) {
        debugPrint('[DownloadManager] error killing proc for $id: $e');
      }
      _runningProcs.remove(id);
    } else {
      debugPrint('[DownloadManager] no running proc for $id');
    }

    _updateTask(
      t,
      status: DownloadStatus.cancelled,
      progress: 0.0,
      finishedAt: DateTime.now(),
    );
    Future.microtask(() => _scheduleQueue());
  }

  /// Cambia el flag de bypass de Spotify API para una tarea
  void toggleBypassSpotifyApi(String id) {
    final tIndex = _tasks.indexWhere((x) => x.id == id);
    if (tIndex < 0) {
      debugPrint('[DownloadManager] toggleBypass: not found $id');
      return;
    }
    final t = _tasks[tIndex];

    // Solo permitir cambiar el bypass en tareas que no estén corriendo
    if (t.status == DownloadStatus.running) {
      debugPrint(
        '[DownloadManager] toggleBypass: cannot change bypass on running task $id',
      );
      return;
    }

    t.bypassSpotifyApi = !t.bypassSpotifyApi;
    debugPrint(
      '[DownloadManager] toggleBypass: task $id bypass now ${t.bypassSpotifyApi}',
    );
    _savePersisted();
    notifyListeners();
  }

  // cola de programación
  void _scheduleQueue() {
    final running = _tasks
        .where((t) => t.status == DownloadStatus.running)
        .length;
    final queued = _tasks
        .where((t) => t.status == DownloadStatus.queued)
        .toList();
    final canStart = maxConcurrent - running;
    debugPrint(
      '[DownloadManager] scheduleQueue running=$running queued=${queued.length} canStart=$canStart',
    );
    debugPrint(
      '[DownloadManager] status counts queued=${_tasks.where((t) => t.status == DownloadStatus.queued).length} running=${_tasks.where((t) => t.status == DownloadStatus.running).length} completed=${_tasks.where((t) => t.status == DownloadStatus.completed).length} failed=${_tasks.where((t) => t.status == DownloadStatus.failed).length}',
    );
    for (var i = 0; i < canStart && i < queued.length; i++) {
      _startTask(queued[i]);
    }
  }

  // ejecutor de tarea
  Future<void> _startTask(DownloadTask t) async {
    debugPrint('[DownloadManager] _startTask begin ${t.id} "${t.title}"');
    await _updateTask(
      t,
      status: DownloadStatus.running,
      progress: 0.0,
      startedAt: DateTime.now(),
    );

    try {
      final toolsDir = _findToolsDir();
      debugPrint('[DownloadManager] toolsDir="$toolsDir"');

      final downloadFolder = await _ensureDownloadFolder(t.type);
      debugPrint('[DownloadManager] downloadFolder="$downloadFolder"');

      final safeBase = t.title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .replaceAll(RegExp(r'\s+'), '_');

      // Video handling
      if (t.type == TaskType.video) {
        final outputTemplate = p.join(downloadFolder, '$safeBase.%(ext)s');
        debugPrint(
          '[DownloadManager] starting yt-dlp video download for ${t.id} output="$outputTemplate" formatId=${t.formatId}',
        );

        final exitSuccess = await _ytDlpDownloadWithProgress(
          taskId: t.id,
          toolsDir: toolsDir,
          queryOrUrl: t.sourceUrl,
          outputFilePathTemplate: outputTemplate,
          formatId: t.formatId,
          extractAudio: false,
          onProgressLine: (line) async {
            final pval = _parseYtdlpPercent(line);
            if (pval != null) {
              await _updateTask(t, progress: pval);
            }
          },
        );

        if (!exitSuccess) {
          await _updateTask(
            t,
            status: DownloadStatus.failed,
            progress: 0.0,
            errorMessage: 'yt-dlp video download failed',
            finishedAt: DateTime.now(),
          );
          Future.microtask(() => _scheduleQueue());
          return;
        }

        // Find output file
        final dir = Directory(downloadFolder);
        final files = dir
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith(safeBase))
            .toList();
        if (files.isEmpty) {
          await _updateTask(
            t,
            status: DownloadStatus.completed,
            progress: 1.0,
            errorMessage: 'File not found but download ok',
            finishedAt: DateTime.now(),
          );
        } else {
          files.sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
          await _updateTask(
            t,
            status: DownloadStatus.completed,
            progress: 1.0,
            localPath: files.first.path,
            finishedAt: DateTime.now(),
          );
        }
        Future.microtask(() => _scheduleQueue());
        return;
      }

      // Verificar si se debe saltar la API de Spotify
      if (!t.bypassSpotifyApi) {
        // Prueba descarga directa con spotify direct API
        debugPrint('[DownloadManager] trying spotify direct for task ${t.id}');
        final spotifyDirect = await _trySpotifyDirectDownload(
          t,
          downloadFolder,
          safeBase,
        );
        if (spotifyDirect) {
          final path = p.join(downloadFolder, '$safeBase.mp3');
          await _updateTask(
            t,
            localPath: path,
            progress: 1.0,
            status: DownloadStatus.completed,
            finishedAt: DateTime.now(),
          );
          debugPrint(
            '[DownloadManager] spotify direct success ${t.id} -> ${t.localPath}',
          );

          // Descargar lyrics en segundo plano
          _downloadLyricsInBackground(t.title, t.artist);

          Future.microtask(() => _scheduleQueue());
          return;
        }
        debugPrint(
          '[DownloadManager] spotify direct did not return file for ${t.id}',
        );
      } else {
        debugPrint(
          '[DownloadManager] bypassing spotify direct API for task ${t.id} (bypass flag set)',
        );
      }

      // Fallback a yt-dlp
      // Construir plantilla de salida
      if (toolsDir.isEmpty) {
        throw Exception('tools dir not found and spotify direct failed');
      }

      final ffmpegExe = p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe');
      final hasFfmpeg = File(ffmpegExe).existsSync();
      final outputTemplate = hasFfmpeg
          ? p.join(downloadFolder, '$safeBase.mp3')
          : p.join(downloadFolder, '$safeBase.%(ext)s');

      // construir query o url
      String ytQueryOrUrl = '';
      final lowerSrc = (t.sourceUrl ?? '').toLowerCase();
      if (lowerSrc.contains('open.spotify.com') ||
          lowerSrc.contains('spotify:track')) {
        final cleanTitle = t.title
            .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
            .trim();
        final cleanArtist = (t.artist ?? '')
            .toString()
            .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
            .trim();
        final search = '$cleanTitle $cleanArtist'.trim();
        final safeSearch = search.replaceAll(RegExp(r'\s+'), ' ').trim();
        ytQueryOrUrl = safeSearch.isNotEmpty ? safeSearch : (t.sourceUrl ?? '');
        debugPrint(
          '[DownloadManager] converted Spotify URL to search string: $ytQueryOrUrl',
        );
      } else {
        ytQueryOrUrl = t.sourceUrl ?? '';
      }

      debugPrint(
        '[DownloadManager] starting yt-dlp for ${t.id} output="$outputTemplate" hasFfmpeg=$hasFfmpeg query="$ytQueryOrUrl"',
      );

      final exitSuccess = await _ytDlpDownloadWithProgress(
        taskId: t.id,
        toolsDir: toolsDir,
        queryOrUrl: ytQueryOrUrl,
        outputFilePathTemplate: outputTemplate,
        extractAudio: true, // Audio task always extracts audio
        onProgressLine: (line) async {
          final pval = _parseYtdlpPercent(line);
          if (pval != null) {
            await _updateTask(t, progress: pval * (hasFfmpeg ? 0.9 : 1.0));
          }
        },
      );

      if (!exitSuccess) {
        await _updateTask(
          t,
          status: DownloadStatus.failed,
          progress: 0.0,
          errorMessage: 'yt-dlp failed or returned non-zero exit code',
          finishedAt: DateTime.now(),
        );
        debugPrint(
          '[DownloadManager] yt-dlp reported failure for task ${t.id}',
        );
        Future.microtask(() => _scheduleQueue());
        return;
      }

      // resultados de yt-dlp
      final dir = Directory(downloadFolder);
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith(safeBase))
          .toList();
      if (files.isEmpty) {
        await _updateTask(
          t,
          status: DownloadStatus.failed,
          progress: 0.0,
          errorMessage: 'yt-dlp reported success but no output file was found',
          finishedAt: DateTime.now(),
        );
        debugPrint(
          '[DownloadManager] no output file found for task ${t.id} after yt-dlp',
        );
        Future.microtask(() => _scheduleQueue());
        return;
      }

      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      final found = files.first;
      debugPrint('[DownloadManager] yt-dlp produced file: ${found.path}');

      if (p.extension(found.path).toLowerCase() == '.mp3') {
        // Intentar enriquecer metadatos con Spotify
        try {
          debugPrint(
            '[DownloadManager] Attempting to enrich metadata from Spotify',
          );

          // El título de Spotify siempre viene como "Artista - Título"
          // Extraemos la parte después del " - " que es el título real
          String searchTitle = t.title;

          if (searchTitle.contains(' - ')) {
            final parts = searchTitle.split(' - ');
            // Tomar la última parte (después del último " - ")
            searchTitle = parts.last.trim();
          }

          debugPrint('[DownloadManager] Searching Spotify for: $searchTitle');

          // Buscar solo con el título de la canción
          final spotifyMetadata = await SpotifyMetadataService().searchMetadata(
            searchTitle,
            null, // No pasar artista para búsqueda más amplia
          );

          if (spotifyMetadata != null) {
            debugPrint(
              '[DownloadManager] Found Spotify metadata: ${spotifyMetadata.title} by ${spotifyMetadata.artist}',
            );

            // Usar ffmpeg para escribir metadatos
            final ffmpegExe = p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe');
            if (File(ffmpegExe).existsSync()) {
              final tempPath = '${found.path}.temp.mp3';

              final args = [
                '-i',
                found.path,
                '-c',
                'copy',
                '-metadata',
                'title=${spotifyMetadata.title}',
                '-metadata',
                'artist=${spotifyMetadata.artist}',
                '-metadata',
                'album=${spotifyMetadata.album}',
                if (spotifyMetadata.year != null) '-metadata',
                if (spotifyMetadata.year != null)
                  'date=${spotifyMetadata.year}',
                if (spotifyMetadata.trackNumber != null) '-metadata',
                if (spotifyMetadata.trackNumber != null)
                  'track=${spotifyMetadata.trackNumber}',
                '-y',
                tempPath,
              ];

              debugPrint('[DownloadManager] Writing metadata with ffmpeg');
              final result = await Process.run(ffmpegExe, args);

              if (result.exitCode == 0) {
                // Reemplazar archivo original con el que tiene metadatos
                await File(found.path).delete();
                await File(tempPath).rename(found.path);
                debugPrint('[DownloadManager] Metadata written successfully');

                // Descargar y escribir portada si está disponible
                if (spotifyMetadata.albumArtUrl != null) {
                  try {
                    debugPrint('[DownloadManager] Downloading album art');
                    final artworkBytes = await SpotifyMetadataService()
                        .downloadAlbumArt(spotifyMetadata.albumArtUrl);

                    if (artworkBytes != null) {
                      final artworkPath = '${found.path}.jpg';
                      await File(artworkPath).writeAsBytes(artworkBytes);

                      final tempPath2 = '${found.path}.temp2.mp3';
                      final artArgs = [
                        '-i',
                        found.path,
                        '-i',
                        artworkPath,
                        '-map',
                        '0:0',
                        '-map',
                        '1:0',
                        '-c',
                        'copy',
                        '-id3v2_version',
                        '3',
                        '-metadata:s:v',
                        'title=Album cover',
                        '-metadata:s:v',
                        'comment=Cover (front)',
                        '-y',
                        tempPath2,
                      ];

                      final artResult = await Process.run(ffmpegExe, artArgs);
                      if (artResult.exitCode == 0) {
                        await File(found.path).delete();
                        await File(tempPath2).rename(found.path);
                        debugPrint(
                          '[DownloadManager] Album art embedded successfully',
                        );
                      }

                      // Limpiar archivo temporal de artwork
                      try {
                        await File(artworkPath).delete();
                      } catch (_) {}
                    }
                  } catch (e) {
                    debugPrint(
                      '[DownloadManager] Error embedding album art: $e',
                    );
                  }
                }
              } else {
                debugPrint('[DownloadManager] ffmpeg failed: ${result.stderr}');
                // Limpiar archivo temporal si falló
                try {
                  if (File(tempPath).existsSync()) {
                    await File(tempPath).delete();
                  }
                } catch (_) {}
              }
            }
          } else {
            debugPrint('[DownloadManager] No Spotify metadata found');
          }
        } catch (e) {
          debugPrint('[DownloadManager] Error enriching metadata: $e');
        }

        await _updateTask(
          t,
          localPath: found.path,
          progress: 1.0,
          status: DownloadStatus.completed,
          finishedAt: DateTime.now(),
        );
        debugPrint(
          '[DownloadManager] task completed (mp3) ${t.id} -> ${t.localPath}',
        );

        // Descargar lyrics en segundo plano
        _downloadLyricsInBackground(t.title, t.artist);

        Future.microtask(() {
          _scheduleQueue();
          refreshStatus();
        });
        return;
      }

      // convertir a mp3 si es necesario
      if (hasFfmpeg) {
        debugPrint('[DownloadManager] converting ${found.path} to mp3');
        final converted = await _convertToMp3(
          taskId: t.id,
          ffmpegExePath: ffmpegExe,
          inputPath: found.path,
          outputPath: p.join(downloadFolder, '$safeBase.mp3'),
          onProgressLine: (ln) async {
            final pct = _parseFfmpegPercent(ln, null);
            if (pct != null) {
              await _updateTask(t, progress: 0.9 + pct * 0.1);
            }
          },
        );
        if (converted) {
          try {
            if (File(found.path).existsSync()) File(found.path).deleteSync();
          } catch (e) {
            debugPrint(
              '[DownloadManager] could not delete temp file ${found.path}: $e',
            );
          }
          final outp = p.join(downloadFolder, '$safeBase.mp3');
          await _updateTask(
            t,
            localPath: outp,
            progress: 1.0,
            status: DownloadStatus.completed,
            finishedAt: DateTime.now(),
          );
          debugPrint(
            '[DownloadManager] converted and completed ${t.id} -> ${t.localPath}',
          );

          // Descargar lyrics en segundo plano
          _downloadLyricsInBackground(t.title, t.artist);

          Future.microtask(() {
            _scheduleQueue();
            refreshStatus();
          });
          return;
        } else {
          throw Exception('conversion failed');
        }
      } else {
        await _updateTask(
          t,
          localPath: found.path,
          progress: 1.0,
          status: DownloadStatus.completed,
          finishedAt: DateTime.now(),
        );
        debugPrint(
          '[DownloadManager] completed without conversion ${t.id} -> ${t.localPath}',
        );

        // Descargar lyrics en segundo plano
        _downloadLyricsInBackground(t.title, t.artist);

        Future.microtask(() {
          _scheduleQueue();
          refreshStatus();
        });
        return;
      }
    } catch (e, st) {
      debugPrint('[DownloadManager] task ${t.id} exception: $e\n$st');

      if (t.status == DownloadStatus.running) {
        await _updateTask(
          t,
          status: DownloadStatus.failed,
          progress: 0.0,
          errorMessage: e.toString(),
          finishedAt: DateTime.now(),
        );
      } else {
        await _savePersisted();
        notifyListeners();
      }
      Future.microtask(() {
        _scheduleQueue();
        refreshStatus();
      });
    }
  }

  // spotify descarga directa
  Future<bool> _trySpotifyDirectDownload(
    DownloadTask t,
    String downloadFolder,
    String safeBase,
  ) async {
    try {
      final encodedUrl = Uri.encodeComponent(t.sourceUrl ?? '');
      final apiUrl = '${ApiConfig.dorratzBaseUrl}/spotifydl?url=$encodedUrl';
      debugPrint('[DownloadManager] spotifydl request: $apiUrl');
      final res = await http
          .get(Uri.parse(apiUrl))
          .timeout(const Duration(seconds: 12));
      debugPrint('[DownloadManager] spotifydl status: ${res.statusCode}');
      if (res.statusCode != 200) {
        debugPrint('[DownloadManager] spotifydl non-200 body: ${res.body}');
        return false;
      }
      final Map<String, dynamic> info = jsonDecode(res.body);
      debugPrint(
        '[DownloadManager] spotifydl response keys: ${info.keys.toList()}',
      );
      final downloadUrl = info['download_url'] as String?;
      if (downloadUrl == null || downloadUrl.isEmpty) {
        debugPrint('[DownloadManager] spotifydl missing download_url');
        return false;
      }

      debugPrint('[DownloadManager] fetching download_url: $downloadUrl');
      final audioRes = await http.get(Uri.parse(downloadUrl));
      debugPrint(
        '[DownloadManager] download_url status: ${audioRes.statusCode}',
      );
      if (audioRes.statusCode != 200) {
        debugPrint('[DownloadManager] download_url fetch failed');
        return false;
      }

      final outPath = p.join(downloadFolder, '$safeBase.mp3');
      final f = File(outPath);
      await f.writeAsBytes(audioRes.bodyBytes, flush: true);
      debugPrint('[DownloadManager] spotify direct saved file: $outPath');
      return true;
    } catch (e, st) {
      debugPrint('[DownloadManager] spotify direct error: $e\n$st');
      return false;
    }
  }

  // ayudantes de búsqueda
  DownloadTask? findTaskBySource(String source) {
    try {
      return _tasks.firstWhere((t) => t.sourceUrl == source);
    } catch (_) {
      return null;
    }
  }

  DownloadTask? findTaskByTitle(String title) {
    try {
      return _tasks.firstWhere((t) => t.title == title);
    } catch (_) {
      return null;
    }
  }

  // utilidades de herramientas
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

  String _findToolsDir() {
    final base = _findBaseDir();
    return base.isEmpty ? '' : p.join(base, 'tools');
  }

  List<String> _checkTools(String toolsDir) {
    final missing = <String>[];
    if (!File(p.join(toolsDir, 'yt-dlp.exe')).existsSync()) {
      missing.add('yt-dlp.exe');
    }
    if (!File(p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe')).existsSync()) {
      missing.add('ffmpeg.exe (recommended for mp3)');
    }
    return missing;
  }

  Future<String> _ensureDownloadFolder(TaskType type) async {
    _prefs ??= await SharedPreferences.getInstance();

    String? folder;
    if (type == TaskType.video) {
      folder = _prefs!.getString('video_download_folder');
    }

    if (folder == null || folder.isEmpty) {
      folder = _prefs!.getString('download_folder');
    }

    if (folder != null && folder.isNotEmpty) return folder;

    String home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    final dl = p.join(home, 'Downloads', 'Forawn');
    final dir = Directory(dl);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    await _prefs!.setString('download_folder', dl);
    debugPrint('[DownloadManager] default download folder set to $dl');
    return dl;
  }

  Future<int> _runProcessStreamed({
    required String taskId,
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    void Function(String)? onStdout,
    void Function(String)? onStderr,
    void Function(String)? onProgressLine,
  }) async {
    debugPrint(
      '[DownloadManager] runProcessStreamed task=$taskId exec=${p.basename(executable)} args=${arguments.join(' ')} cwd=$workingDirectory',
    );
    final proc = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    _runningProcs[taskId] = proc;

    void handleStream(
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
            if (onStdout != null && tail.isNotEmpty) onStdout(tail);
            if (onProgressLine != null && tail.isNotEmpty) onProgressLine(tail);
          }
        },
        onError: (err, _) {
          if (onStderr != null) onStderr('Stream error: $err');
        },
        cancelOnError: true,
      );
    }

    handleStream(proc.stdout, onStdout, progress: true);
    handleStream(proc.stderr, onStderr, progress: true);

    final code = await proc.exitCode;
    _runningProcs.remove(taskId);
    debugPrint(
      '[DownloadManager] process ${p.basename(executable)} exitCode=$code for task $taskId',
    );
    return code;
  }

  double? _parseYtdlpPercent(String line) {
    final re = RegExp(r'(\d{1,3}\.\d+|\d{1,3})%\b');
    final m = re.firstMatch(line);
    if (m != null) return double.tryParse(m.group(1)!)! / 100.0;
    final re2 = RegExp(r'\[download\].*?(\d{1,3}\.\d+|\d{1,3})%');
    final m2 = re2.firstMatch(line);
    if (m2 != null) return double.tryParse(m2.group(1)!)! / 100.0;
    return null;
  }

  double? _parseFfmpegPercent(String line, int? durationSeconds) {
    final re = RegExp(r'time=(\d{2}:\d{2}:\d{2}(?:\.\d+)?)');
    final m = re.firstMatch(line);
    if (m != null && durationSeconds != null && durationSeconds > 0) {
      final secs = _timeStringToSeconds(m.group(1)!);
      return secs / durationSeconds;
    }
    return null;
  }

  int _timeStringToSeconds(String t) {
    final parts = t.split(':').map((s) => s.trim()).toList();
    if (parts.length == 3) {
      final h = double.tryParse(parts[0]) ?? 0.0;
      final m = double.tryParse(parts[1]) ?? 0.0;
      final s = double.tryParse(parts[2]) ?? 0.0;
      return (h * 3600 + m * 60 + s).round();
    } else if (parts.length == 2) {
      final m = double.tryParse(parts[0]) ?? 0.0;
      final s = double.tryParse(parts[1]) ?? 0.0;
      return (m * 60 + s).round();
    }
    return 0;
  }

  Future<bool> _ytDlpDownloadWithProgress({
    required String taskId,
    required String toolsDir,
    required String queryOrUrl,
    required String outputFilePathTemplate,
    required void Function(String) onProgressLine,
    String? formatId,
    bool extractAudio = false,
  }) async {
    final ytdlp = p.join(toolsDir, 'yt-dlp.exe');
    final ffmpegExe = p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe');
    final hasYtdlp = File(ytdlp).existsSync();
    if (!hasYtdlp) {
      debugPrint('[DownloadManager] yt-dlp not found at $ytdlp');
      return false;
    }

    final searchArg =
        (queryOrUrl.startsWith('http') || queryOrUrl.startsWith('https'))
        ? queryOrUrl
        : 'ytsearch1:$queryOrUrl';

    final args = <String>[
      searchArg,
      '-o',
      outputFilePathTemplate,
      '--no-playlist',
      '--ignore-errors',
      '--no-warnings',
      '--newline',
      '--no-post-overwrites', // Evitar post-procesar archivos existentes
      '--add-header',
      'User-Agent: Mozilla/5.0',
      '--add-header',
      'Referer: https://www.youtube.com',
      // Embeber metadatos en el archivo
      '--embed-metadata',
      '--embed-thumbnail',
      '--convert-thumbnails', 'jpg',
      // Parsear título para extraer artista y canción
      '--parse-metadata', 'title:%(artist)s - %(title)s',
      '--parse-metadata', 'title:%(title)s',
    ];

    if (extractAudio && File(ffmpegExe).existsSync()) {
      args.addAll([
        '--extract-audio',
        '--audio-format',
        'mp3',
        '--ffmpeg-location',
        ffmpegExe,
        // Asegurar que los metadatos se embeben en el MP3
        '--embed-thumbnail',
        '--add-metadata',
      ]);
    }

    if (formatId != null && formatId.isNotEmpty) {
      args.addAll(['-f', formatId]);
    } else if (!extractAudio) {
      // Default for video if no format selected: best video+audio
      args.addAll(['-f', 'bestvideo+bestaudio/best']);
    }

    debugPrint('[DownloadManager] yt-dlp args: ${args.join(' ')}');

    final exitCode = await _runProcessStreamed(
      taskId: taskId,
      executable: ytdlp,
      arguments: args,
      workingDirectory: toolsDir,
      onStdout: (l) {
        debugPrint('[yt-dlp stdout] $l');
      },
      onStderr: (l) {
        debugPrint('[yt-dlp stderr] $l');
      },
      onProgressLine: onProgressLine,
    );

    debugPrint('[DownloadManager] yt-dlp exitCode=$exitCode for task $taskId');
    return exitCode == 0;
  }

  Future<bool> _convertToMp3({
    required String taskId,
    required String ffmpegExePath,
    required String inputPath,
    required String outputPath,
    void Function(String)? onProgressLine,
  }) async {
    if (!File(ffmpegExePath).existsSync()) {
      debugPrint('[DownloadManager] ffmpeg not found at $ffmpegExePath');
      return false;
    }
    final args = [
      '-y',
      '-i',
      inputPath,
      '-vn',
      '-ar',
      '44100',
      '-ac',
      '2',
      '-b:a',
      '192k',
      outputPath,
    ];
    final exitCode = await _runProcessStreamed(
      taskId: taskId,
      executable: ffmpegExePath,
      arguments: args,
      workingDirectory: p.dirname(ffmpegExePath),
      onStdout: (l) {
        debugPrint('[ffmpeg stdout] $l');
      },
      onStderr: (l) {
        debugPrint('[ffmpeg stderr] $l');
        if (onProgressLine != null) onProgressLine(l);
      },
      onProgressLine: onProgressLine,
    );
    debugPrint('[DownloadManager] ffmpeg exitCode=$exitCode for task $taskId');
    return exitCode == 0;
  }

  /// Descarga lyrics en segundo plano sin bloquear
  void _downloadLyricsInBackground(String title, String artist) {
    if (title.isEmpty) return;

    // Ejecutar en segundo plano sin esperar
    Future.microtask(() async {
      try {
        debugPrint(
          '[DownloadManager] Downloading lyrics for: $title - $artist',
        );
        final lyrics = await LyricsService().fetchLyrics(title, artist);
        if (lyrics != null) {
          debugPrint(
            '[DownloadManager] Lyrics downloaded successfully: ${lyrics.lineCount} lines',
          );
        } else {
          debugPrint('[DownloadManager] No lyrics found for: $title - $artist');
        }
      } catch (e) {
        debugPrint('[DownloadManager] Error downloading lyrics: $e');
      }
    });
  }
}
