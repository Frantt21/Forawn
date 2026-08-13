import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Servicio que descarga automáticamente ffmpeg y yt-dlp en la carpeta tools/
/// si no existen. Se ejecuta al inicio de la app.
class ToolsService {
  static final ToolsService _instance = ToolsService._internal();
  factory ToolsService() => _instance;
  ToolsService._internal();

  bool _initialized = false;
  bool _installing = false;

  // URLs de descarga
  static const _ytdlpUrl =
      'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe';
  static const _ffmpegZipUrl =
      'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip';

  /// Directorio base donde están (o se colocarán) los tools
  String? _baseDir;

  String get toolsDir => _baseDir != null ? p.join(_baseDir!, 'tools') : '';

  bool get isReady =>
      _initialized &&
      File(p.join(toolsDir, 'yt-dlp.exe')).existsSync() &&
      File(p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe')).existsSync();

  bool get isInstalling => _installing;

  /// Inicializa el servicio: busca la carpeta tools y descarga si falta algo
  Future<void> initialize() async {
    if (_initialized) return;

    _baseDir = _findBaseDir();
    if (_baseDir == null) {
      debugPrint('[ToolsService] No se encontró carpeta base para tools/');
      return;
    }

    _initialized = true;
    debugPrint('[ToolsService] Base dir: $_baseDir');

    // Verificar y descargar si falta
    final missing = _checkMissing();
    if (missing.isNotEmpty) {
      debugPrint('[ToolsService] Faltan: $missing — iniciando descarga...');
      await _downloadAll(missing);
    } else {
      debugPrint('[ToolsService] Todos los tools están presentes');
    }
  }

  /// Lista de tools que faltan
  List<String> _checkMissing() {
    final missing = <String>[];
    if (!File(p.join(toolsDir, 'yt-dlp.exe')).existsSync()) {
      missing.add('yt-dlp');
    }
    if (!File(p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe')).existsSync()) {
      missing.add('ffmpeg');
    }
    return missing;
  }

  /// Descarga todos los tools que faltan
  Future<void> _downloadAll(List<String> missing) async {
    if (_installing) return;
    _installing = true;

    try {
      // Crear directorio tools si no existe
      final toolsDirectory = Directory(toolsDir);
      if (!toolsDirectory.existsSync()) {
        toolsDirectory.createSync(recursive: true);
      }

      for (final tool in missing) {
        try {
          if (tool == 'yt-dlp') {
            await _downloadYtdlp();
          } else if (tool == 'ffmpeg') {
            await _downloadFfmpeg();
          }
        } catch (e) {
          debugPrint('[ToolsService] Error descargando $tool: $e');
        }
      }
    } finally {
      _installing = false;
    }
  }

  /// Descarga yt-dlp.exe directamente
  Future<void> _downloadYtdlp() async {
    final dest = File(p.join(toolsDir, 'yt-dlp.exe'));
    debugPrint('[ToolsService] Descargando yt-dlp.exe...');

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(_ytdlpUrl));
      final response = await request.close().timeout(
        const Duration(seconds: 120),
        onTimeout: () => throw TimeoutException('Timeout descargando yt-dlp'),
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode} descargando yt-dlp');
      }

      final sink = dest.openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();

      debugPrint(
        '[ToolsService] yt-dlp.exe descargado: ${dest.lengthSync()} bytes',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Descarga y extrae ffmpeg del zip de BtbN builds
  Future<void> _downloadFfmpeg() async {
    debugPrint('[ToolsService] Descargando ffmpeg (zip)...');

    // Descargar zip a archivo temporal
    final tempZip = File(p.join(Directory.systemTemp.path, 'ffmpeg_build.zip'));
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(_ffmpegZipUrl));
      final response = await request.close().timeout(
        const Duration(seconds: 180),
        onTimeout: () => throw TimeoutException('Timeout descargando ffmpeg'),
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode} descargando ffmpeg');
      }

      final sink = tempZip.openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();
      debugPrint(
        '[ToolsService] ffmpeg zip descargado: ${tempZip.lengthSync()} bytes',
      );
    } finally {
      client.close(force: true);
    }

    // Extraer ffmpeg.exe del zip usando PowerShell
    final ffmpegDir = p.join(toolsDir, 'ffmpeg');
    final ffmpegBin = p.join(ffmpegDir, 'bin');
    Directory(ffmpegBin).createSync(recursive: true);

    debugPrint('[ToolsService] Extrayendo ffmpeg.exe...');
    final result = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-Command',
        'Expand-Archive -Path "${tempZip.path}" -DestinationPath "${p.join(ffmpegDir, '_tmp')}" -Force',
      ],
    );

    if (result.exitCode != 0) {
      debugPrint('[ToolsService] PowerShell extract error: ${result.stderr}');
      // Fallback: usar tar si está disponible (Git Bash lo incluye)
      final tarResult = await Process.run(
        'tar',
        ['-xf', tempZip.path, '-C', ffmpegDir],
      );
      if (tarResult.exitCode != 0) {
        debugPrint('[ToolsService] tar extract error: ${tarResult.stderr}');
        return;
      }
    }

    // Buscar ffmpeg.exe en los archivos extraídos y moverlo a bin/
    try {
      final tmpDir = Directory(p.join(ffmpegDir, '_tmp'));
      if (tmpDir.existsSync()) {
        // Buscar ffmpeg.exe recursivamente
        await for (final entity in tmpDir.list(recursive: true)) {
          if (entity is File && p.basename(entity.path) == 'ffmpeg.exe') {
            final dest = File(p.join(ffmpegBin, 'ffmpeg.exe'));
            if (dest.existsSync()) dest.deleteSync();
            await entity.copy(dest.path);
            debugPrint('[ToolsService] ffmpeg.exe copiado a ${dest.path}');
            break;
          }
        }
        // Limpiar directorio temporal
        tmpDir.deleteSync(recursive: true);
      }
    } catch (e) {
      debugPrint('[ToolsService] Error moviendo ffmpeg.exe: $e');
    }

    // Limpiar zip temporal
    try {
      if (tempZip.existsSync()) tempZip.deleteSync();
    } catch (_) {}
  }

  /// Busca la carpeta base del ejecutable
  String? _findBaseDir() {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      // En release/debug: usar directorio del ejecutable
      if (Directory(p.join(exeDir, 'tools')).existsSync()) return exeDir;
      // Crear tools/ si no existe (primera ejecución)
      Directory(p.join(exeDir, 'tools')).createSync(recursive: true);
      return exeDir;
    } catch (_) {}

    // Fallback: directorio de trabajo
    final currentDir = Directory.current.path;
    if (Directory(p.join(currentDir, 'tools')).existsSync()) return currentDir;

    // Fallback: build directory (para desarrollo)
    final candidates = <String>[
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Debug'),
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Release'),
    ];
    for (final base in candidates) {
      if (Directory(p.join(base, 'tools')).existsSync()) return base;
    }
    return null;
  }
}
