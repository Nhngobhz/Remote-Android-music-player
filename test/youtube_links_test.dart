import 'package:flutter_test/flutter_test.dart';
import 'package:music_contoller/services/youtube_links.dart';

void main() {
  test('finds the video id in the usual link shapes', () {
    const id = 'kJQP7kiw5Fk';
    for (final link in [
      'https://www.youtube.com/watch?v=$id',
      'https://www.youtube.com/watch?v=$id&list=PLx1234567890&index=3',
      'http://m.youtube.com/watch?feature=share&v=$id',
      'https://music.youtube.com/watch?v=$id&si=abc',
      'https://youtu.be/$id?si=abc',
      'youtu.be/$id',
      'www.youtube.com/watch?v=$id',
      'https://WWW.YouTube.com/watch?v=$id',
      'https://www.youtube.com/shorts/$id',
      'https://www.youtube.com/embed/$id',
      'https://www.youtube-nocookie.com/embed/$id?start=10',
      'https://www.youtube.com/live/$id',
      '  $id  ',
    ]) {
      expect(youtubeVideoId(link), id, reason: link);
    }
  });

  test('rejects links that are not a YouTube video', () {
    for (final link in [
      'https://example.com/watch?v=kJQP7kiw5Fk',
      'https://www.youtube.com/watch?v=short',
      'https://www.youtube.com/playlist?list=PLx1234567890',
      'https://www.youtube.com/@channel',
      'not a link',
      '',
    ]) {
      expect(youtubeVideoId(link), isNull, reason: link);
    }
  });

  test('finds playlist ids, including bare ones', () {
    expect(youtubePlaylistId('https://www.youtube.com/playlist?list=PLabcdefghijk123'), 'PLabcdefghijk123');
    expect(youtubePlaylistId('https://music.youtube.com/playlist?list=OLAK5uy_abcdefghij'),
        'OLAK5uy_abcdefghij');
    expect(youtubePlaylistId('PLabcdefghijk123'), 'PLabcdefghijk123');
    expect(youtubePlaylistId('https://example.com/playlist?list=PLabcdefghijk123'), isNull);
    expect(youtubePlaylistId('https://www.youtube.com/playlist?list=x'), isNull);
  });
}
