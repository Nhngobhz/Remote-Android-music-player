enum TrackSource { upload, youtube }

class Track {
  final String id;
  String title;
  final String? artist;

  /// Path relative to the library root, so the library survives app-directory moves.
  final String fileName;
  String folderId;
  final int? durationMs;
  final TrackSource source;
  final String? sourceUrl;
  final DateTime addedAt;

  Track({
    required this.id,
    required this.title,
    required this.fileName,
    required this.folderId,
    required this.source,
    required this.addedAt,
    this.artist,
    this.durationMs,
    this.sourceUrl,
  });

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        fileName: json['fileName'] as String,
        folderId: json['folderId'] as String,
        durationMs: json['durationMs'] as int?,
        source: TrackSource.values.byName(json['source'] as String),
        sourceUrl: json['sourceUrl'] as String?,
        addedAt: DateTime.parse(json['addedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'fileName': fileName,
        'folderId': folderId,
        'durationMs': durationMs,
        'source': source.name,
        'sourceUrl': sourceUrl,
        'addedAt': addedAt.toIso8601String(),
      };
}
