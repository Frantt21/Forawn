// DTO para resultados de búsqueda de lyrics
class LyricsSearchResult {
  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final double duration;
  final bool synced;
  final String plainLyrics;
  final String syncedLyrics;

  LyricsSearchResult({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.duration,
    required this.synced,
    required this.plainLyrics,
    required this.syncedLyrics,
  });

  factory LyricsSearchResult.fromJson(Map<String, dynamic> json) {
    return LyricsSearchResult(
      id: json['id'] as int? ?? 0,
      trackName: json['trackName'] as String? ?? 'Unknown',
      artistName: json['artistName'] as String? ?? 'Unknown',
      albumName: json['albumName'] as String? ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      synced:
          json['syncedLyrics'] != null &&
          (json['syncedLyrics'] as String).isNotEmpty,
      plainLyrics: json['plainLyrics'] as String? ?? '',
      syncedLyrics: json['syncedLyrics'] as String? ?? '',
    );
  }
}
