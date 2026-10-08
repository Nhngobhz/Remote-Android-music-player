/// Reads video and playlist ids out of the YouTube links people paste.
library;

final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _playlistId = RegExp(r'^[A-Za-z0-9_-]{12,}$');

/// Playlist ids typed or pasted on their own: playlists, mixes, albums and channel uploads.
final _barePlaylistId = RegExp(r'^(PL|RD|OLAK5uy_|UU|UL|PU|FL|LL)[A-Za-z0-9_-]{10,}$');

const _hosts = {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtube-nocookie.com',
  'www.youtube-nocookie.com',
  'youtu.be',
};

/// Paths whose next segment is the video id, like `youtube.com/shorts/<id>`.
const _idPaths = {'shorts', 'embed', 'live', 'v', 'e'};

/// The 11-character id of the video [link] points at, or null. A bare id counts too.
String? youtubeVideoId(String link) {
  final text = link.trim();
  if (_videoId.hasMatch(text)) return text;
  final uri = _parse(text);
  if (uri == null) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final String? id;
  if (uri.host == 'youtu.be') {
    id = segments.firstOrNull;
  } else if (segments.firstOrNull == 'watch') {
    id = uri.queryParameters['v'];
  } else if (segments.length >= 2 && _idPaths.contains(segments[0])) {
    id = segments[1];
  } else {
    id = null;
  }
  return id != null && _videoId.hasMatch(id) ? id : null;
}

/// The id of the playlist in [link], or null. A bare playlist id counts too.
String? youtubePlaylistId(String link) {
  final text = link.trim();
  if (_barePlaylistId.hasMatch(text)) return text;
  final id = _parse(text)?.queryParameters['list'];
  return id != null && _playlistId.hasMatch(id) ? id : null;
}

String youtubeVideoUrl(String videoId) => 'https://www.youtube.com/watch?v=$videoId';

String youtubePlaylistUrl(String playlistId) => 'https://www.youtube.com/playlist?list=$playlistId';

/// Only YouTube's own hosts (Uri lower-cases them).
Uri? _parse(String text) {
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  return uri != null && _hosts.contains(uri.host) ? uri : null;
}
