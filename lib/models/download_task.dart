enum DownloadStatus { queued, running, completed, failed, cancelled }

enum TaskType { audio, video }

/// Extensión de TaskType: helpers para detección de extractor.
extension TaskTypePlatformX on TaskType {
  /// Sitios cuyos format_id son EFÍMEROS (se acuñan por extracción: IDs
  /// tipo "dash-1808..." de Instagram o IDs numéricos de TikTok). Con estos
  /// sitios el format_id cacheado del diálogo NO sirve en la descarga: la
  /// selección se hace por altura de resolución, no por ID.
  static const Set<String> _ephemeralHosts = {
    'instagram.com',
    'instagr.am',
    'cdninstagram.com',
    'tiktok.com',
    'tiktokv.com',
  };

  /// Host de la URL de origen (sin www.).
  static String _hostOf(String url) {
    try {
      return Uri.tryParse(url)?.host.toLowerCase() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// true si [url] pertenece a un sitio con format_ids efímeros.
  static bool hasEphemeralFormatIds(String url) {
    final host = _hostOf(url);
    return _ephemeralHosts.any(host.endsWith);
  }

  /// true si la URL pertenece a YouTube (watch, youtu.be, shorts, music).
  static bool isYouTubeUrl(String url) {
    final host = _hostOf(url);
    return host.endsWith('youtube.com') ||
        host.endsWith('youtu.be') ||
        host.endsWith('youtube-nocookie.com');
  }

  /// UA por sitio: YouTube mantiene el UA genérico probado; el resto de
  /// sitios (TikTok, Instagram, Twitter...) usa un UA de navegador móvil
  /// porque varios devuelven 403 al UA genérico "Mozilla/5.0".
  static String uaForSite(String url) => isYouTubeUrl(url)
      ? 'Mozilla/5.0'
      : 'Mozilla/5.0 (Linux; Android 14; SM-A156U) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.artist,
    required this.image,
    required this.sourceUrl,
    this.localPath,
    this.progress = 0.0,
    this.status = DownloadStatus.queued,
    DateTime? createdAt,
    this.startedAt,
    this.finishedAt,
    this.errorMessage,
    this.type = TaskType.audio,
    this.formatId,
    this.bypassSpotifyApi = false,
  }) : createdAt = createdAt ?? DateTime.now();

  final String artist;
  DateTime createdAt;
  String? errorMessage;
  DateTime? finishedAt;
  final String id;
  final String image;
  String? localPath;
  double progress;
  final String sourceUrl;
  DateTime? startedAt;
  DownloadStatus status;
  final String title;
  TaskType type;
  String? formatId;
  bool bypassSpotifyApi;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'image': image,
    'sourceUrl': sourceUrl,
    'localPath': localPath,
    'progress': progress,
    'status': status.index,
    'createdAt': createdAt.toIso8601String(),
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'errorMessage': errorMessage,
    'type': type.index,
    'formatId': formatId,
    'bypassSpotifyApi': bypassSpotifyApi,
  };

  static DownloadTask fromJson(Map<String, dynamic> j) => DownloadTask(
    id: j['id'] as String,
    title: j['title'] as String,
    artist: j['artist'] as String,
    image: j['image'] as String? ?? '',
    sourceUrl: j['sourceUrl'] as String,
    localPath: j['localPath'] as String?,
    progress: (j['progress'] ?? 0.0).toDouble(),
    status: DownloadStatus.values[(j['status'] ?? 0) as int],
    createdAt: DateTime.parse(j['createdAt'] as String),
    startedAt: j['startedAt'] != null
        ? DateTime.parse(j['startedAt'] as String)
        : null,
    finishedAt: j['finishedAt'] != null
        ? DateTime.parse(j['finishedAt'] as String)
        : null,
    errorMessage: j['errorMessage'] as String?,
    type: TaskType.values[(j['type'] ?? 0) as int],
    formatId: j['formatId'] as String?,
    bypassSpotifyApi: j['bypassSpotifyApi'] as bool? ?? false,
  );

  String statusString() {
    switch (status) {
      case DownloadStatus.queued:
        return 'Queued';
      case DownloadStatus.running:
        return '${(progress * 100).toStringAsFixed(1)}%';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.cancelled:
        return 'Cancelled';
    }
  }
}
