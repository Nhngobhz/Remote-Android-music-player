enum TrackSource { upload, youtube }

class Track {
  final String id;
  String title;
  final String? artist;

  /// Path relative to the library root, so the library survives app-directory moves.
  final String fileName;

  /// A video-only file the web page shows in step with the audio, for karaoke.
  String? videoFileName;

  /// Subtitle (usually lyrics) WebVTT files by language code, relative to the library root.
  final Map<String, String> subtitleFileNames;
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
    this.videoFileName,
    Map<String, String>? subtitleFileNames,
    this.durationMs,
    this.sourceUrl,
  }) : subtitleFileNames = subtitleFileNames ?? {};

  bool get hasVideo => videoFileName != null;

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        fileName: json['fileName'] as String,
        videoFileName: json['videoFileName'] as String?,
        subtitleFileNames: json['subtitleFileNames'] == null
            ? null
            : Map<String, String>.from(json['subtitleFileNames'] as Map),
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
        'videoFileName': videoFileName,
        'subtitleFileNames': subtitleFileNames,
        'folderId': folderId,
        'durationMs': durationMs,
        'source': source.name,
        'sourceUrl': sourceUrl,
        'addedAt': addedAt.toIso8601String(),
      };
}
