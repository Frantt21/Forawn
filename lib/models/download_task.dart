enum DownloadStatus { queued, running, completed, failed, cancelled }

enum TaskType { audio, video }

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
