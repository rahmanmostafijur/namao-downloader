import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/engine/ytdlp_options.dart';

void main() {
  group('Quality.tryParse', () {
    test('accepts best, audio and exact heights', () {
      expect(Quality.tryParse('best')!.kind, QualityKind.best);
      expect(Quality.tryParse('audio')!.kind, QualityKind.audio);
      final height = Quality.tryParse('1080')!;
      expect(height.kind, QualityKind.height);
      expect(height.height, 1080);
    });

    test('rejects anything else instead of guessing', () {
      for (final bad in ['', '99', '12345', '10x', 'BEST', '720p', '-720', '9999', '1080; rm']) {
        expect(Quality.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('metadataOptions', () {
    test('reads one video, never a playlist, and prints two compact JSON lines', () {
      final options = metadataOptions(allowAnyLink: false);
      expect(options, containsAllInOrder(['--no-playlist', '--playlist-items', '1']));
      expect(options, contains('--skip-download'));
      expect(options.where((o) => o == '-O').length, 2);
      expect(options.join(' '), contains('formats.:.{format_id,height'));
    });

    test('is restricted to the supported sites', () {
      final options = metadataOptions(allowAnyLink: false);
      final value = options[options.indexOf('--use-extractors') + 1];
      expect(value, contains(r'^Youtube$'));
      expect(value, contains(r'^TikTok$'));
      expect(value, isNot(contains('Generic')));
    });

    test('verification builds may skip the site restriction', () {
      expect(metadataOptions(allowAnyLink: true), isNot(contains('--use-extractors')));
    });
  });

  group('downloadOptions', () {
    String joined(String quality, {bool any = false}) =>
        downloadOptions(Quality.tryParse(quality)!, allowAnyLink: any).join(' ');

    test('an exact height selects that height or fails, with no silent downgrade', () {
      final text = joined('720');
      expect(text, contains('-f bv*[height=720]+ba/b[height=720]'));
      expect(text, contains('--merge-output-format mp4/mkv'));
      expect(text, isNot(contains('/best')), reason: 'no lower-quality fallback');
    });

    test('best takes the highest available quality', () {
      expect(joined('best'), contains('-f bv*+ba/b'));
    });

    test('audio only extracts MP3', () {
      final text = joined('audio');
      expect(text, contains('-f bestaudio/best'));
      expect(text, contains('--extract-audio'));
      expect(text, contains('--audio-format mp3'));
      expect(text, isNot(contains('--merge-output-format')));
    });

    test('every download prefers the codecs phones play, then resolution', () {
      expect(joined('1080'), contains('-S res,fps,vcodec:h264,acodec:aac'));
    });

    test('every download is one non-playlist video with retries and timeouts', () {
      final text = joined('1080');
      expect(text, contains('--no-playlist --playlist-items 1'));
      expect(text, contains('--socket-timeout 30'));
      expect(text, contains('--retries 3'));
    });

    test('the site restriction applies to downloads too', () {
      expect(joined('720'), contains('--use-extractors'));
      expect(joined('720', any: true), isNot(contains('--use-extractors')));
    });
  });
}
