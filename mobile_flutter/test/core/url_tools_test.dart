import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/url_tools.dart';

void main() {
  group('normalizeServerUrl', () {
    test('requires an explicit http or https scheme', () {
      expect(normalizeServerUrl('192.168.1.20:8000').isValid, isFalse);
      expect(normalizeServerUrl('ftp://example.com').isValid, isFalse);
      expect(normalizeServerUrl('192.168.1.20:8000').error, contains('http'));
    });

    test('strips trailing slashes and whitespace', () {
      expect(
        normalizeServerUrl('  http://10.0.2.2:8000/  ').url,
        'http://10.0.2.2:8000',
      );
      expect(
        normalizeServerUrl('https://namao.example.com///').url,
        'https://namao.example.com',
      );
    });

    test('keeps a reverse-proxy path prefix', () {
      expect(
        normalizeServerUrl('https://host.example/namao/').url,
        'https://host.example/namao',
      );
    });

    test('rejects empty, credentials, query and fragment', () {
      expect(normalizeServerUrl('').error, isNotNull);
      expect(
        normalizeServerUrl('http://user:pw@host').error,
        contains('API key'),
      );
      expect(normalizeServerUrl('http://host/?key=1').isValid, isFalse);
      expect(normalizeServerUrl('http://host/#x').isValid, isFalse);
      expect(normalizeServerUrl('http://').isValid, isFalse);
    });

    test('keeps IPv6 hosts bracketed', () {
      expect(normalizeServerUrl('http://[::1]:8000/').url, 'http://[::1]:8000');
    });
  });

  group('isPrivateHost / needsCleartextWarning', () {
    test('private and local addresses are fine over http', () {
      for (final host in [
        'localhost',
        '127.0.0.1',
        '10.0.2.2',
        '192.168.1.20',
        '172.16.5.4',
        '172.31.255.255',
        '169.254.1.1',
        'nas.local',
        'myserver',
        '::1',
        'fd00::1',
      ]) {
        expect(isPrivateHost(host), isTrue, reason: host);
      }
    });

    test('public addresses are not private', () {
      for (final host in ['example.com', '8.8.8.8', '172.32.0.1', '11.0.0.1']) {
        expect(isPrivateHost(host), isFalse, reason: host);
      }
    });

    test('warns only for plain http to a public host', () {
      expect(needsCleartextWarning('http://example.com'), isTrue);
      expect(needsCleartextWarning('http://203.0.113.9:8000'), isTrue);
      expect(needsCleartextWarning('https://example.com'), isFalse);
      expect(needsCleartextWarning('http://192.168.1.2:8000'), isFalse);
      expect(needsCleartextWarning('not a url'), isFalse);
    });
  });

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

  test('serverLabel names host and port', () {
    expect(serverLabel('http://10.0.2.2:8000'), '10.0.2.2:8000');
    expect(serverLabel('https://namao.example.com'), 'namao.example.com');
  });
}
