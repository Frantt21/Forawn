import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_task.dart';

import 'local_music_database.dart';
import 'lyrics_service.dart';
import 'tools_service.dart';

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
  DateTime _lastPersist = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _persistDebounce;

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
    // Notificar a la UI SIEMPRE (barata); persistir con throttle: serializar
    // 200+ tareas a JSON en cada línea de progreso de yt-dlp satura el event
    // loop y hace que la barra salte (0% → 65% → 90%). El estado terminal se
    // persiste inmediato para no perder el historial.
    notifyListeners();
    _schedulePersist(
      force: status == DownloadStatus.completed ||
          status == DownloadStatus.failed ||
          status == DownloadStatus.cancelled,
    );
  }

  void _schedulePersist({bool force = false}) {
    if (force) {
      _persistDebounce?.cancel();
      _persistDebounce = null;
      _lastPersist = DateTime.now();
      unawaited(_savePersisted());
      return;
    }
    final since = DateTime.now().difference(_lastPersist);
    if (since >= const Duration(seconds: 2)) {
      _lastPersist = DateTime.now();
      unawaited(_savePersisted());
      return;
    }
    // Trailing flush: garantiza que el último progreso quede guardado.
    _persistDebounce ??= Timer(const Duration(seconds: 2), () {
      _persistDebounce = null;
      _lastPersist = DateTime.now();
      unawaited(_savePersisted());
    });
  }

  // API
  void addTask(DownloadTask t) {
    debugPrint(
      '[DownloadManager] addTask ${t.id} "${t.title}" source="${t.sourceUrl}"',
    );
    // Si ya existe una tarea TERMINADA para la misma URL, reemplazarla:
    // evita acumular fallidas viejas con errores desactualizados (p.ej. el
    // bot-check de YouTube ya resuelto) para la misma pista.
    final sameUrl = t.sourceUrl.isNotEmpty
        ? _tasks.indexWhere(
            (x) =>
                x.sourceUrl == t.sourceUrl &&
                x.status != DownloadStatus.running &&
                x.status != DownloadStatus.queued,
          )
        : -1;
    if (sameUrl >= 0) {
      _tasks.removeAt(sameUrl);
      debugPrint(
        '[DownloadManager] addTask: replaced previous finished task at $sameUrl',
      );
    }
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
      // Reintentar REPLAZA la tarea fallida en vez de encolar una copia:
      // si no, las fallidas viejas se acumulan en el historial para siempre
      // (y vuelven a mostrar su error antiguo aunque la nueva descarga
      // ya haya tenido éxito).
      _tasks.removeAt(idx);
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
        '[DownloadManager] retryTask: replace ${old.id} -> ${retry.id} (bypass: ${retry.bypassSpotifyApi})',
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

  /// Reporta el progreso SOLO si sube respecto al último valor notificado de
  /// la tarea. yt-dlp emite el progreso de CADA archivo por separado (video
  /// + audio en descargas multi-formato: 100% → 2% al empezar el audio), y
  /// sin este guard la barra de la UI retrocede.
  void _reportProgress(DownloadTask t, double value) {
    final v = value.clamp(0.0, 1.0);
    if (v > t.progress) {
      unawaited(
        _updateTask(t, progress: v),
      );
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
      final toolsDir = ToolsService().toolsDir;
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

        final (exitSuccess, ytDlpError) = await _ytDlpDownloadWithProgress(
          taskId: t.id,
          toolsDir: toolsDir,
          queryOrUrl: t.sourceUrl,
          outputFilePathTemplate: outputTemplate,
          formatId: t.formatId,
          extractAudio: false,
          onProgressLine: (line) async {
            final pval = _parseYtdlpPercent(line);
            if (pval != null) {
              _reportProgress(t, pval);
            }
          },
        );

        if (!exitSuccess) {
          await _updateTask(
            t,
            status: DownloadStatus.failed,
            progress: 0.0,
            errorMessage: ytDlpError.isNotEmpty
                ? 'yt-dlp: $ytDlpError'
                : 'yt-dlp video download failed',
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

      // DIRECT DOWNLOAD IS DISABLED - ALWAYS USE YT-DLP
      // The direct download mechanism relied on Spotify APIs which are being removed.
      debugPrint('[DownloadManager] Using yt-dlp for task ${t.id}');

      // Fallback a yt-dlp
      // Construir plantilla de salida
      if (toolsDir.isEmpty) {
        throw Exception('tools dir not found and spotify direct failed');
      }

      final ffmpegExe = ToolsService().ffmpegPath;
      final hasFfmpeg = ToolsService().hasFfmpeg;
      final outputTemplate = hasFfmpeg
          ? p.join(downloadFolder, '$safeBase.mp3')
          : p.join(downloadFolder, '$safeBase.%(ext)s');

      // construir query o url
      String ytQueryOrUrl = '';
      final lowerSrc = t.sourceUrl.toLowerCase();
      if (lowerSrc.contains('open.spotify.com') ||
          lowerSrc.contains('spotify:track')) {
        final cleanTitle = t.title
            .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
            .trim();
        final cleanArtist = t.artist
            .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
            .trim();
        final search = '$cleanTitle $cleanArtist'.trim();
        final safeSearch = search.replaceAll(RegExp(r'\s+'), ' ').trim();
        ytQueryOrUrl = safeSearch.isNotEmpty ? safeSearch : t.sourceUrl;
        debugPrint(
          '[DownloadManager] converted Spotify URL to search string: $ytQueryOrUrl',
        );
      } else {
        ytQueryOrUrl = t.sourceUrl;
      }

      debugPrint(
        '[DownloadManager] starting yt-dlp for ${t.id} output="$outputTemplate" hasFfmpeg=$hasFfmpeg query="$ytQueryOrUrl"',
      );

      final (exitSuccess, ytDlpError) = await _ytDlpDownloadWithProgress(
        taskId: t.id,
        toolsDir: toolsDir,
        queryOrUrl: ytQueryOrUrl,
        outputFilePathTemplate: outputTemplate,
        extractAudio: true, // Audio task always extracts audio
        onProgressLine: (line) async {
          final pval = _parseYtdlpPercent(line);
          if (pval != null) {
            _reportProgress(t, pval * (hasFfmpeg ? 0.9 : 1.0));
          }
        },
      );

      if (!exitSuccess) {
        // yt-dlp puede salir con código != 0 aunque el archivo SÍ se haya
        // producido (--ignore-errors: falla un postprocesado tras descargar,
        // p.ej. embed-thumbnail en webm). Si hay output real, no marcar
        // failed: la descarga en sí tuvo éxito y el error de metadatos es
        // secundario.
        final dirChk = Directory(downloadFolder);
        final produced = dirChk
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith(safeBase))
            .toList();
        if (produced.isNotEmpty) {
          debugPrint(
            '[DownloadManager] yt-dlp exitCode!=0 but output exists for ${t.id} — treating as completed',
          );
        } else {
          await _updateTask(
            t,
            status: DownloadStatus.failed,
            progress: 0.0,
            errorMessage: ytDlpError.isNotEmpty
                ? 'yt-dlp: $ytDlpError'
                : 'yt-dlp failed or returned non-zero exit code',
            finishedAt: DateTime.now(),
          );
          debugPrint(
            '[DownloadManager] yt-dlp reported failure for task ${t.id}',
          );
          Future.microtask(() => _scheduleQueue());
          return;
        }
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
        // Los metadatos (título, artista, álbum, fecha) ya vienen incrustados
        // por yt-dlp desde Innertube/YouTube vía ffmpeg (--embed-metadata
        // --parse-metadata). No se sobrescriben con Deezer/Spotify.
        //
        // La miniatura del vídeo suele ser 16:9 y se ve recortada en
        // contenedores cuadrados: reemplazarla por el artwork CUADRADO de
        // YT Music (t.image, w1200-h1200) cuando esté disponible.
        await _embedSquareCoverIfAvailable(found.path, t.image);
        await _invalidatePlayerMetadataCache(found.path);
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
              _reportProgress(t, 0.9 + pct * 0.1);
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
          await _invalidatePlayerMetadataCache(outp);
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
        await _invalidatePlayerMetadataCache(found.path);
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

  List<String> _checkTools(String toolsDir) {
    final missing = <String>[];
    if (!ToolsService().hasYtDlp) {
      missing.add('yt-dlp');
    }
    if (!ToolsService().hasFfmpeg) {
      missing.add('ffmpeg (recommended for mp3)');
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

  Future<(bool, String)> _ytDlpDownloadWithProgress({
    required String taskId,
    required String toolsDir,
    required String queryOrUrl,
    required String outputFilePathTemplate,
    required void Function(String) onProgressLine,
    String? formatId,
    bool extractAudio = false,
  }) async {
    final ytdlp = ToolsService().ytDlpPath;
    final ffmpegExe = ToolsService().ffmpegPath;
    final hasYtdlp = File(ytdlp).existsSync();
    if (!hasYtdlp) {
      debugPrint('[DownloadManager] yt-dlp not found at $ytdlp');
      return (false, 'yt-dlp no encontrado');
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
      // UA por sitio: YouTube genérico; TikTok/IG/etc. navegador móvil.
      'User-Agent: ${TaskTypePlatformX.uaForSite(queryOrUrl)}',
      // Cliente ANDROID para YouTube: el cliente web/visionos dispara el
      // bot-check "Sign in to confirm you're not a bot" (verificado con el
      // nightly 2026.09.16); el cliente android extrae y descarga sin
      // cookies. Vacío en otros sitios (no es un extractor-args válido).
      if (TaskTypePlatformX.extractorArgsForSite(searchArg).isNotEmpty) ...[
        '--extractor-args',
        TaskTypePlatformX.extractorArgsForSite(searchArg),
      ],
      // Sin Referer fijo: el descargador acepta URLs de cualquier sitio
      // soportado por yt-dlp (YouTube, Instagram, TikTok, Twitter, etc.) y
      // un Referer de YouTube en otros dominios puede provocar 403.
      // Embeber metadatos de Innertube/YouTube en el archivo mediante ffmpeg.
      //
      // Estrategia (verificada empíricamente):
      //  1. artist <= canal de YouTube (fuente más confiable)
      //  2. Si el título trae "Artista - Canción" (o con – — |), extraer ambos;
      //     si no matchea, se conservan artist=canal y title=titulo crudo.
      //  3. Limpiar sufijos de canales tipo "- Topic" y ruido del título
      //     (Official Video, Lyric Video, HD, 4K, Remaster, MV, etc.)
      '--embed-metadata',
      '--embed-thumbnail',
      '--convert-thumbnails', 'jpg',
      '--parse-metadata', r'channel:(?P<artist>.*)',
      '--parse-metadata',
      r'title:(?P<artist>[^-|]+?)\s+[-–—|]\s+(?P<title>.+)',
      '--replace-in-metadata', 'artist',
      r'\s*[-–—]?\s*(Topic|VEVO|Official)\s*$',
      '',
      '--replace-in-metadata', 'title',
      r'\s*[([][^)\]]*([Oo]fficial|[Ll]yric|[Aa]udio [Vv]ersion|[Aa]udio|[Vv]ideo|[Hh][Dd]|4K|[Rr]emaster|[Ee]xplicit|[Vv]isualizer|MV|M/V)[^)\]]*[)]\]\s*',
      ' ',
      '--replace-in-metadata', 'title', r'^\s+|\s+$', '',
      '--replace-in-metadata', 'title', r'\s{2,}', ' ',
    ];

    // ffmpeg SIEMPRE que exista: la pista de VIDEO lo necesita para el merge
    // (bv*+ba) y para --embed-metadata/--embed-thumbnail/--convert-thumbnails
    // (antes solo se pasaba en extractAudio, por eso toda descarga de video
    // fallaba con "ffmpeg not found" aunque existiera en tools/).
    if (File(ffmpegExe).existsSync()) {
      args.addAll(['--ffmpeg-location', ffmpegExe]);
    }

    if (extractAudio && File(ffmpegExe).existsSync()) {
      args.addAll([
        '--extract-audio',
        '--audio-format',
        'mp3',
        '--audio-quality',
        '0', // Mejor calidad (320kbps para mp3)
        '--ffmpeg-location',
        ffmpegExe,
        '--embed-thumbnail',
        '--add-metadata',
      ]);
    }

    if (formatId != null && formatId.isNotEmpty) {
      if (TaskTypePlatformX.hasEphemeralFormatIds(queryOrUrl)) {
        // Sitios con format_ids efímeros (Instagram, TikTok): el ID mostrado
        // en el diálogo viene de UNA extracción y puede no existir en la
        // nueva extracción de la descarga ("Requested format is not
        // available"). Descartamos el ID y seleccionamos por ALTURA: yt-dlp
        // elige el mejor formato <= altura objetivo con audio fallback.
        final h = int.tryParse(RegExp(r'(\d{3,4})p').firstMatch(formatId)?.group(1) ?? '');
        args.addAll([
          '-f',
          h != null
              ? 'bv*[ext=mp4][height<=$h]+ba[ext=m4a]/b[ext=mp4][height<=$h]/b[height<=$h]/b'
              : 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b',
        ]);
      } else {
        args.addAll(['-f', formatId]);
      }
    } else if (!extractAudio) {
      // Default for video if no format selected: best video+audio.
      // Se prefieren pistas mp4/m4a: el contenedor webm final de
      // bestvideo+bestaudio no soporta --embed-thumbnail y yt-dlp aborta
      // con "Supported filetypes for thumbnail embedding are: ...".
      args.addAll(['-f', 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b']);
    }

    // Forzar contenedor mp4 en descargas de VIDEO: --embed-thumbnail /
    // --convert-thumbnails solo funcionan en mp3/mkv/ogg/flac/m4a/mp4/m4v/mov.
    // Un merge o stream único en webm (vp9/opus) rompe el postprocesado.
    // --merge-output-format convierte el merge; --remux-video cubre streams
    // únicos (picks explícitos de formatos webm) con remux -c copy a mp4.
    if (!extractAudio) {
      args.addAll([
        '--merge-output-format',
        'mp4',
        '--remux-video',
        'mp4',
      ]);
    }

    debugPrint('[DownloadManager] yt-dlp args: ${args.join(' ')}');

    // Últimas líneas de stderr (útil para reportar el error real)
    final stderrLines = <String>[];

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
        stderrLines.add(l);
        if (stderrLines.length > 8) stderrLines.removeAt(0);
      },
      onProgressLine: onProgressLine,
    );

    debugPrint('[DownloadManager] yt-dlp exitCode=$exitCode for task $taskId');
    return (exitCode == 0, stderrLines.join(' | '));
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
      '320k',
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

  /// Descarga el artwork cuadrado (YT Music, w1200-h1200) y lo incrusta como
  /// portada del MP3 en reemplazo de la miniatura 16:9 que yt-dlp incrustó.
  /// Silencioso: si algo falla, se conserva la portada de yt-dlp.
  Future<void> _embedSquareCoverIfAvailable(
    String filePath,
    String imageUrl,
  ) async {
    if (imageUrl.isEmpty) return;

    File? tempCover;
    File? tempOut;
    try {
      final ffmpegExe = ToolsService().ffmpegPath;
      if (!File(ffmpegExe).existsSync()) return;

      // Descargar el artwork cuadrado.
      final client = http.Client();
      try {
        final res = await client
            .get(Uri.parse(imageUrl))
            .timeout(const Duration(seconds: 12));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) return;
        // Descartar respuestas que no sean imagen (p. ej. HTML de error).
        if (res.bodyBytes.length < 1024) return;
        tempCover = File(
          '${Directory.systemTemp.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await tempCover.writeAsBytes(res.bodyBytes);
      } finally {
        client.close();
      }

      tempOut = File('$filePath.square.mp3');
      final args = [
        '-hide_banner',
        '-loglevel',
        'error',
        '-i', filePath,
        '-i', tempCover.path,
        '-map', '0:a',
        '-map', '1:0',
        '-c', 'copy',
        '-id3v2_version', '3',
        '-metadata:s:v', 'title=Album cover',
        '-metadata:s:v', 'comment=Cover (front)',
        '-y',
        tempOut.path,
      ];

      final result = await Process.run(ffmpegExe, args);
      if (result.exitCode != 0 || !tempOut.existsSync()) {
        debugPrint(
          '[DownloadManager] square cover embed failed: ${result.stderr}',
        );
        return;
      }

      // Reemplazar el original por la versión con portada cuadrada.
      final original = File(filePath);
      await original.delete();
      await tempOut.rename(filePath);
      debugPrint('[DownloadManager] square cover embedded: $imageUrl');
    } catch (e) {
      debugPrint('[DownloadManager] _embedSquareCoverIfAvailable error: $e');
    } finally {
      try {
        if (tempCover != null && tempCover.existsSync()) {
          tempCover.deleteSync();
        }
        if (tempOut != null && tempOut.existsSync()) {
          tempOut.deleteSync();
        }
      } catch (_) {}
    }
  }

  /// Invalida la caché de metadatos del reproductor para un archivo, de modo
  /// que la próxima lectura tome los tags recién incrustados por ffmpeg.
  Future<void> _invalidatePlayerMetadataCache(String filePath) async {
    try {
      await LocalMusicDatabase().invalidateMetadata(filePath);
      debugPrint(
        '[DownloadManager] player metadata cache invalidated for $filePath',
      );
    } catch (e) {
      debugPrint(
        '[DownloadManager] could not invalidate player metadata cache: $e',
      );
    }
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
