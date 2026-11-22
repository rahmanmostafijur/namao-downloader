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

    test('every Facebook link form is recognised', () {
      const urls = [
        'https://www.facebook.com/watch/?v=740370353488040',
        'https://facebook.com/watch?v=1',
        'https://m.facebook.com/watch/?v=1',
        'https://web.facebook.com/watch/?v=1',
        'https://mbasic.facebook.com/story.php?story_fbid=1&id=2',
        'https://www.facebook.com/somepage/videos/123456789/',
        'https://www.facebook.com/reel/123456789',
        'https://www.facebook.com/reels/123456789',
        'https://www.facebook.com/share/v/1AbCdEfGhI/',
        'https://www.facebook.com/share/r/1AbCdEfGhI/',
        'https://fb.watch/abcDEF12_x/',
        'http://www.facebook.com/watch/?v=1',
        'FACEBOOK.COM/watch/?v=1',
      ];
      for (final url in urls) {
        final result = checkVideoUrl(url);
        expect(result.isValid, isTrue, reason: url);
        expect(result.platform, SourcePlatform.facebook, reason: url);
      }
    });

    test('every Instagram link form is recognised', () {
      const urls = [
        'https://www.instagram.com/reel/CxAbCdEfGhI/',
        'https://www.instagram.com/reels/CxAbCdEfGhI/',
        'https://www.instagram.com/p/CxAbCdEfGhI/',
        'https://www.instagram.com/tv/CxAbCdEfGhI/',
        'https://www.instagram.com/stories/someone/1234567890/',
        'https://www.instagram.com/share/reel/BAbCdEfGh/',
        'https://m.instagram.com/p/CxAbCdEfGhI/',
        'https://instagram.com/p/CxAbCdEfGhI/',
        'https://instagr.am/p/CxAbCdEfGhI/',
      ];
      for (final url in urls) {
        final result = checkVideoUrl(url);
        expect(result.isValid, isTrue, reason: url);
        expect(result.platform, SourcePlatform.instagram, reason: url);
      }
    });

    test('look-alike and disguised hosts are not accepted', () {
      const urls = [
        'https://facebook.com.example.org/watch/?v=1',
        'https://www.facebook.com.evil.example/reel/1',
        'https://notfacebook.com/watch/?v=1',
        'https://fb.watch.example.org/abc',
        'https://example.org/?u=https://www.facebook.com/watch/?v=1',
        'https://instagram.com.example.org/p/x/',
        'https://www.facebook.com@evil.example/watch/?v=1',
        'https://user:pw@www.facebook.com/watch/?v=1',
        'https://www.facebook.com:8443/watch/?v=1',
      ];
      for (final url in urls) {
        expect(checkVideoUrl(url).isValid, isFalse, reason: url);
      }
      expect(
        checkVideoUrl('https://facebook.com.example.org/watch/?v=1').error,
        unsupportedLinkMessage,
      );
    });

    test('trailing punctuation and wrappers are dropped, queries are kept', () {
      expect(
        checkVideoUrl('(https://www.facebook.com/watch/?v=1&t=30).').url,
        'https://www.facebook.com/watch/?v=1&t=30',
      );
      expect(
        checkVideoUrl('"https://fb.watch/abc/",').url,
        'https://fb.watch/abc/',
      );
      expect(
        checkVideoUrl('https://www.instagram.com/reel/Cx/?igsh=abc123!').url,
        'https://www.instagram.com/reel/Cx/?igsh=abc123',
      );
    });

    test('links are rewritten only where the downloader needs it', () {
      expect(
        checkVideoUrl('https://www.facebook.com/reels/123456789?s=x').url,
        'https://www.facebook.com/reel/123456789?s=x',
      );
      expect(
        checkVideoUrl('https://instagr.am/p/CxAbCdEfGhI/?igsh=1').url,
        'https://www.instagram.com/p/CxAbCdEfGhI/?igsh=1',
      );
      expect(
        checkVideoUrl('https://m.facebook.com/watch/?v=1').url,
        'https://m.facebook.com/watch/?v=1',
        reason: 'mobile hosts are left alone: the downloader handles them',
      );
    });

    test(
      'redirect-style links are flagged for resolving, canonical ones are not',
      () {
        bool flagged(String u) => needsRedirectResolution(Uri.parse(u));
        expect(flagged('https://fb.watch/abc/'), isTrue);
        expect(flagged('https://www.facebook.com/share/v/1Ab/'), isTrue);
        expect(flagged('https://m.facebook.com/share/r/1Ab/'), isTrue);
        expect(flagged('https://www.instagram.com/share/reel/Bx/'), isTrue);
        expect(flagged('https://www.facebook.com/watch/?v=1'), isFalse);
        expect(flagged('https://www.facebook.com/reel/1'), isFalse);
        expect(flagged('https://www.instagram.com/reel/Cx/'), isFalse);
        expect(flagged('https://youtu.be/abc'), isFalse);
        expect(flagged('https://example.org/share/v/1'), isFalse);
      },
    );

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
