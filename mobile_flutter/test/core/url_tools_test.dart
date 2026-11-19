import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/url_tools.dart';

void main() {
  group('detectPlatform', () {
    test('matches the web client hosts', () {
      const cases = {
        'https://www.youtube.com/watch?v=abc': SourcePlatform.youtube,
        'https://youtu.be/abc': SourcePlatform.youtube,
        'https://m.youtube.com/watch?v=abc': SourcePlatform.youtube,
        'https://www.youtube-nocookie.com/embed/x': SourcePlatform.youtube,
        'https://www.facebook.com/watch?v=1': SourcePlatform.facebook,
        'https://fb.watch/abc': SourcePlatform.facebook,
        'https://www.tiktok.com/@u/video/1': SourcePlatform.tiktok,
        'https://x.com/u/status/1': SourcePlatform.twitter,
        'https://twitter.com/u/status/1': SourcePlatform.twitter,
        'https://www.instagram.com/reel/abc': SourcePlatform.instagram,
      };
      cases.forEach((url, platform) {
        expect(detectPlatform(url), platform, reason: url);
      });
    });

    test('accepts a link pasted without a scheme', () {
      expect(detectPlatform('youtube.com/watch?v=abc'), SourcePlatform.youtube);
    });

    test('does not match look-alike hosts', () {
      expect(detectPlatform('https://notyoutube.com/x'), isNull);
      expect(detectPlatform('https://youtube.com.evil.example/x'), isNull);
      expect(detectPlatform('https://example.com'), isNull);
      expect(detectPlatform(''), isNull);
    });

    test('fromName maps the server platform string', () {
      expect(SourcePlatform.fromName('YouTube'), SourcePlatform.youtube);
      expect(SourcePlatform.fromName('vimeo'), isNull);
    });
  });

  group('checkVideoUrl', () {
    test('empty input is neither valid nor an error', () {
      const check = VideoUrlCheck();
      final result = checkVideoUrl('   ');
      expect(result.isValid, check.isValid);
      expect(result.error, isNull);
    });

    test('valid link gets a scheme and a platform', () {
      final result = checkVideoUrl(' youtu.be/abc ');
      expect(result.isValid, isTrue);
      expect(result.url, 'https://youtu.be/abc');
      expect(result.platform, SourcePlatform.youtube);
    });

    test('unsupported site explains which sites work', () {
      final result = checkVideoUrl('https://vimeo.com/123');
      expect(result.isValid, isFalse);
      expect(result.error, unsupportedLinkMessage);
    });

    test('garbage and multi-word text are incomplete links', () {
      expect(checkVideoUrl('hello world').error, incompleteLinkMessage);
      expect(checkVideoUrl('notaurl').error, incompleteLinkMessage);
      expect(checkVideoUrl('ftp://youtube.com/x').error, incompleteLinkMessage);
    });
  });

  test('verification-only flag skips the platform hint but nothing else', () {
    final local = checkVideoUrl(
      'http://localhost:10444/manifest.mpd',
      allowAnyHost: true,
    );
    expect(local.isValid, isTrue);
    expect(local.platform, isNull);
    expect(
      checkVideoUrl('http://localhost:10444/x').isValid,
      isFalse,
      reason: 'off by default',
    );
    expect(checkVideoUrl('two words', allowAnyHost: true).isValid, isFalse);
    expect(kAllowAnyLink, isFalse, reason: 'normal builds never enable it');
  });
}
