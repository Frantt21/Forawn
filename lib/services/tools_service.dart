import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Servicio que descarga automáticamente ffmpeg y yt-dlp en la carpeta tools/
/// si no existen. Se ejecuta al inicio de la app.
///
/// Los binarios son específicos por plataforma:
///  - Windows: yt-dlp.exe + ffmpeg.exe (build win64)
///  - Linux:   yt-dlp (build estático linux64/aarch64) + ffmpeg (tar.xz)
///  - macOS:   yt-dlp_macos + ffmpeg (zip macos64 / macos64-arm64)
class ToolsService {
  static final ToolsService _instance = ToolsService._internal();
  factory ToolsService() => _instance;
  ToolsService._internal();

  bool _initialized = false;
  bool _installing = false;

  // ---------------------------------------------------------------------------
  // Detección de plataforma
  // ---------------------------------------------------------------------------
  static bool get _isWindows => Platform.isWindows;
  static bool get _isMacOS => Platform.isMacOS;

  /// Detecta arquitectura ARM64 (Apple Silicon / Linux arm64).
  static bool get _isArm64 {
    try {
      final version = Platform.version.toLowerCase();
      if (version.contains('arm64') || version.contains('aarch64')) {
        return true;
      }
      final arch = (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '')
          .toLowerCase();
      if (arch == 'arm64') return true;
    } catch (_) {}
    try {
      final res = Process.runSync('uname', ['-m']);
      if (res.exitCode == 0) {
        final m = (res.stdout as String).trim().toLowerCase();
        if (m == 'arm64' || m == 'aarch64') return true;
      }
    } catch (_) {}
    return false;
  }

  // ---------------------------------------------------------------------------
  // Nombres de binarios locales
  // ---------------------------------------------------------------------------
  String get _ytDlpBinaryName => _isWindows ? 'yt-dlp.exe' : 'yt-dlp';
  String get _ffmpegBinaryName => _isWindows ? 'ffmpeg.exe' : 'ffmpeg';

  // ---------------------------------------------------------------------------
  // URLs de descarga por plataforma
  // ---------------------------------------------------------------------------
  static String get _ytDlpDownloadUrl {
    if (Platform.isWindows) {
      return 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe';
    }
    if (Platform.isMacOS) {
      return 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos';
    }
    // Linux: build estático (no requiere python3 en el sistema)
    return _isArm64
        ? 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux_aarch64'
        : 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux';
  }

  static String get _ffmpegDownloadUrl {
    if (Platform.isWindows) {
      return 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip';
    }
    if (Platform.isMacOS) {
      // Los builds de macOS se llaman macos64 (Intel) y macos64-arm64 (Apple Silicon)
      final arch = _isArm64 ? 'arm64' : '64';
      return 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-macos$arch-gpl.zip';
    }
    // Linux
    final arch = _isArm64 ? 'linuxarm64' : 'linux64';
    return 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-$arch-gpl.tar.xz';
  }

  // ---------------------------------------------------------------------------
  // Rutas públicas de los binarios (usadas por el resto de la app)
  // ---------------------------------------------------------------------------
  /// Directorio base donde están (o se colocarán) los tools
  String? _baseDir;

  String get toolsDir => _baseDir != null ? p.join(_baseDir!, 'tools') : '';

  /// Ruta completa al binario de yt-dlp (según plataforma).
  String get ytDlpPath => p.join(toolsDir, _ytDlpBinaryName);

  /// Ruta completa al binario de ffmpeg (según plataforma).
  String get ffmpegPath =>
      p.join(toolsDir, 'ffmpeg', 'bin', _ffmpegBinaryName);

  /// Directorio donde vive el binario de ffmpeg.
  String get ffmpegBinDir => p.join(toolsDir, 'ffmpeg', 'bin');

  bool get hasYtDlp => File(ytDlpPath).existsSync();
  bool get hasFfmpeg => File(ffmpegPath).existsSync();
  bool get isReady => _initialized && hasYtDlp && hasFfmpeg;

  bool get isInstalling => _installing;

  // ---------------------------------------------------------------------------
  // Inicialización
  // ---------------------------------------------------------------------------
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

  /// Lista de tools que faltan (o que están corruptos/incompletos)
  List<String> _checkMissing() {
    final missing = <String>[];
    if (!_binaryUsable(ytDlpPath, isYtDlp: true)) {
      missing.add('yt-dlp');
    }
    if (!_binaryUsable(ffmpegPath)) {
      missing.add('ffmpeg');
    }
    return missing;
  }

  /// Valida que un binario exista, esté completo (no truncado) y realmente
  /// se ejecute.
  ///
  /// Los tamaños mínimos descartan descargas interrumpidas (un archivo
  /// parcial "existe" pero no funciona), y la ejecución de --version/-version
  /// detecta binarios o extracciones corruptas.
  bool _binaryUsable(String path, {bool isYtDlp = false}) {
    try {
      final f = File(path);
      if (!f.existsSync()) return false;
      final minSize = isYtDlp ? 8 * 1024 * 1024 : 20 * 1024 * 1024;
      if (f.lengthSync() < minSize) return false;

      // Verificar que el binario realmente ejecuta (version check rápido)
      final args = isYtDlp ? ['--version'] : ['-version'];
      final res = Process.runSync(path, args);
      if (res.exitCode != 0) return false;
      final out =
          '${res.stdout}${res.stderr}'.trim();
      return out.isNotEmpty;
    } catch (_) {
      return false;
    }
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
        // Reintentar una vez por si la descarga se interrumpe
        for (var attempt = 1; attempt <= 2; attempt++) {
          try {
            if (tool == 'yt-dlp') {
              await _downloadYtdlp();
              if (!_binaryUsable(ytDlpPath, isYtDlp: true)) {
                throw Exception('yt-dlp no ejecuta (corrupto)');
              }
            } else if (tool == 'ffmpeg') {
              await _downloadFfmpeg();
              if (!_binaryUsable(ffmpegPath)) {
                throw Exception('ffmpeg no ejecuta (corrupto)');
              }
            }
            break;
          } catch (e) {
            debugPrint(
              '[ToolsService] Error descargando $tool (intento $attempt/2): $e',
            );
            // Limpiar archivo corrupto para que el próximo intento parta de cero
            try {
              final target = tool == 'yt-dlp'
                  ? File(ytDlpPath)
                  : File(ffmpegPath);
              if (target.existsSync()) target.deleteSync();
            } catch (_) {}
            if (attempt == 2) {
              debugPrint('[ToolsService] $tool no pudo descargarse');
            }
          }
        }
      }
    } finally {
      _installing = false;
    }
  }

  /// Marca un binario como ejecutable en plataformas POSIX.
  Future<void> _makeExecutable(String path) async {
    if (_isWindows) return;
    try {
      await Process.run('chmod', ['+x', path]);
      debugPrint('[ToolsService] chmod +x aplicado a $path');
    } catch (e) {
      debugPrint('[ToolsService] No se pudo hacer ejecutable $path: $e');
    }
  }

  /// Descarga el binario de yt-dlp correspondiente a la plataforma
  Future<void> _downloadYtdlp() async {
    final dest = File(ytDlpPath);
    debugPrint('[ToolsService] Descargando ${_ytDlpBinaryName} desde $_ytDlpDownloadUrl...');

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(_ytDlpDownloadUrl));
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

      await _makeExecutable(dest.path);

      debugPrint(
        '[ToolsService] ${_ytDlpBinaryName} descargado: ${dest.lengthSync()} bytes',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Descarga y extrae ffmpeg del build correspondiente a la plataforma
  Future<void> _downloadFfmpeg() async {
    debugPrint('[ToolsService] Descargando ffmpeg ($_ffmpegDownloadUrl)...');

    final isZip = _isWindows || _isMacOS;
    final tempArchive = File(
      p.join(
        Directory.systemTemp.path,
        isZip ? 'ffmpeg_build.zip' : 'ffmpeg_build.tar.xz',
      ),
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(_ffmpegDownloadUrl));
      final response = await request.close().timeout(
        const Duration(seconds: 180),
        onTimeout: () => throw TimeoutException('Timeout descargando ffmpeg'),
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode} descargando ffmpeg');
      }

      final sink = tempArchive.openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();
      debugPrint(
        '[ToolsService] ffmpeg archive descargado: ${tempArchive.lengthSync()} bytes',
      );
    } finally {
      client.close(force: true);
    }

    // Extraer el archivo
    final ffmpegDir = p.join(toolsDir, 'ffmpeg');
    final tmpExtractDir = p.join(ffmpegDir, '_tmp');
    Directory(tmpExtractDir).createSync(recursive: true);

    debugPrint('[ToolsService] Extrayendo ffmpeg...');
    final extracted = await _extractArchive(tempArchive.path, tmpExtractDir);
    if (!extracted) {
      debugPrint('[ToolsService] No se pudo extraer el archivo de ffmpeg');
      return;
    }

    // Buscar el binario en los archivos extraídos y copiarlo a bin/
    final ffmpegBin = p.join(ffmpegDir, 'bin');
    Directory(ffmpegBin).createSync(recursive: true);

    try {
      final tmpDir = Directory(tmpExtractDir);
      if (tmpDir.existsSync()) {
        await for (final entity in tmpDir.list(recursive: true)) {
          if (entity is File &&
              (p.basename(entity.path) == 'ffmpeg.exe' ||
                  p.basename(entity.path) == 'ffmpeg')) {
            final dest = File(p.join(ffmpegBin, _ffmpegBinaryName));
            if (dest.existsSync()) dest.deleteSync();
            await entity.copy(dest.path);
            await _makeExecutable(dest.path);
            debugPrint(
              '[ToolsService] $_ffmpegBinaryName copiado a ${dest.path}',
            );
            break;
          }
        }
        // Limpiar directorio temporal
        tmpDir.deleteSync(recursive: true);
      }
    } catch (e) {
      debugPrint('[ToolsService] Error moviendo $_ffmpegBinaryName: $e');
    }

    // Limpiar archivo temporal
    try {
      if (tempArchive.existsSync()) tempArchive.deleteSync();
    } catch (_) {}
  }

  /// Extrae un zip o tar.xz dependiendo de la plataforma.
  Future<bool> _extractArchive(String archivePath, String destDir) async {
    if (_isWindows) {
      // Windows: PowerShell Expand-Archive con fallback a tar (bsdtar)
      final psResult = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Expand-Archive -Path "${archivePath}" -DestinationPath "${destDir}" -Force',
        ],
      );
      if (psResult.exitCode == 0) return true;
      debugPrint('[ToolsService] PowerShell extract error: ${psResult.stderr}');
      final tarResult = await Process.run('tar', ['-xf', archivePath, '-C', destDir]);
      return tarResult.exitCode == 0;
    }

    if (_isMacOS) {
      // macOS: ditto -x -k (preserva permisos), fallback a unzip y tar
      final dittoResult = await Process.run(
        'ditto',
        ['-x', '-k', archivePath, destDir],
      );
      if (dittoResult.exitCode == 0) return true;
      debugPrint('[ToolsService] ditto extract error: ${dittoResult.stderr}');

      final unzipResult = await Process.run(
        'unzip',
        ['-o', archivePath, '-d', destDir],
      );
      if (unzipResult.exitCode == 0) return true;
      debugPrint('[ToolsService] unzip extract error: ${unzipResult.stderr}');
    }

    // Linux (tar.xz) y fallback general: tar (bsdtar extrae zip y tar.xz)
    final tarResult = await Process.run('tar', ['-xf', archivePath, '-C', destDir]);
    if (tarResult.exitCode != 0) {
      debugPrint('[ToolsService] tar extract error: ${tarResult.stderr}');
      return false;
    }
    return true;
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

    // Fallback: directorios de build (para desarrollo)
    final candidates = <String>[
      // Windows
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Debug'),
      p.join(currentDir, 'build', 'windows', 'x64', 'runner', 'Release'),
      // Linux
      p.join(currentDir, 'build', 'linux', 'x64', 'debug', 'bundle'),
      p.join(currentDir, 'build', 'linux', 'x64', 'release', 'bundle'),
      // macOS
      p.join(currentDir, 'build', 'macos', 'Build', 'Products', 'Debug'),
      p.join(currentDir, 'build', 'macos', 'Build', 'Products', 'Release'),
    ];
    for (final base in candidates) {
      if (Directory(p.join(base, 'tools')).existsSync()) return base;
    }
    return null;
  }
}
