import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/engine/error_classifier.dart';

void main() {
  EngineFailure classify(
    String text, {
    bool metadata = false,
    bool stale = false,
  }) => classifyEngineError(text, metadataPhase: metadata, engineStale: stale);

  group('known failures', () {
    const cases = <String, String>{
      'ERROR: [youtube] x: Video unavailable': 'video_unavailable',
      'ERROR: [youtube] x: This video is private': 'auth_required',
      'ERROR: [youtube] x: Sign in to confirm your age': 'auth_required',
      "ERROR: [youtube] x: Sign in to confirm you're not a bot":
          'access_blocked',
      'ERROR: unable to download video data: HTTP Error 429: Too Many Requests':
          'source_rate_limited',
      'ERROR: [youtube] x: The uploader has not made this video available in your country':
          'geo_restricted',
      'ERROR: [youtube] x: Requested format is not available':
          'format_unavailable',
      'ERROR: Unsupported URL: https://example.com/x': 'unsupported_platform',
      'ERROR: [youtube] x: This live event will begin in 2 hours':
          'unsupported_content',
      'ERROR: [Errno 28] No space left on device': 'storage_full',
      'ERROR: Postprocessing: ffmpeg exited with code 1': 'merge_failed',
      'ERROR: unable to download video data: <urlopen error [Errno -2] Name or service not known>':
          'network_transient',
      'ERROR: [youtube] x: Unable to extract initial data': 'extractor_broken',
    };

    cases.forEach((text, code) {
      test('$code <- $text', () {
        expect(classify(text).code, code);
      });
    });
  });

  test(
    'only ERROR lines decide, so a warning cannot cause a wrong verdict',
    () {
      const output = '''
WARNING: [youtube] x: Sign in to confirm your age (a warning, not the failure)
ERROR: [youtube] x: Video unavailable
''';
      expect(classify(output).code, 'video_unavailable');
    },
  );

  test('text without ERROR lines is still read as a whole', () {
    expect(classify('Video unavailable').code, 'video_unavailable');
  });

  group('retry advice', () {
    test('connection and rate-limit problems can be retried', () {
      expect(classify('HTTP Error 429').retryable, isTrue);
      expect(classify('timed out').retryable, isTrue);
      expect(classify('No space left on device').retryable, isTrue);
    });

    test('a private or removed video cannot', () {
      expect(classify('Video unavailable').retryable, isFalse);
      expect(classify('This video is private').retryable, isFalse);
      expect(classify('Unsupported URL').retryable, isFalse);
    });
  });

  group('an out-of-date engine', () {
    test('a broken extractor is reported as outdated when yt-dlp is old', () {
      expect(
        classify('Unable to extract initial data', stale: true).code,
        'engine_outdated',
      );
      expect(
        classify('Unable to extract initial data').code,
        'extractor_broken',
      );
    });

    test(
      'an ambiguous 403 is outdated when yt-dlp is old, a block otherwise',
      () {
        expect(
          classify('HTTP Error 403: Forbidden', stale: true).code,
          'engine_outdated',
        );
        expect(classify('HTTP Error 403: Forbidden').code, 'access_blocked');
      },
    );

    test(
      'outdated is something a retry (after the engine refreshes) can fix',
      () {
        expect(classify('Unable to extract', stale: true).retryable, isTrue);
      },
    );
  });

  // The wording below is what the real yt-dlp printed for these cases (2026.10.x).
  group('Facebook and Instagram, from real extractor output', () {
    const facebookWall =
        'ERROR: [facebook] 100000000000001: Cannot parse data; please report this issue on '
        ' https://github.com/yt-dlp/yt-dlp/issues?q= , filling out the appropriate issue template.';
    const igEmpty =
        'ERROR: [Instagram] ZZZZZZZZZZZ: Instagram sent an empty media response. Check if this '
        'post is accessible in your browser without being logged-in. If it is not, then use '
        '--cookies-from-browser or --cookies for the authentication.';
    const igStory =
        'ERROR: [instagram:story] 3570: You need to log in to access this content. Use '
        '--cookies-from-browser or --cookies for the authentication.';
    const igRate =
        'ERROR: [Instagram] Cx: The webpage request was redirected to the login page. You have '
        'exceeded the rate-limit for accessing posts anonymously. Use --cookies-from-browser or '
        '--cookies for the authentication.';
    const noExtractor =
        'ERROR: No suitable extractor found for URL https://example.org/x';

    test("Facebook's login-wall 'Cannot parse data' is unavailable, not unsupported", () {
      expect(classify(facebookWall, metadata: true).code, 'video_unavailable');
    });

    test(
      'Instagram stories ask for a session; an existing one is called expired',
      () {
        expect(
          classifyEngineError(
            igStory,
            metadataPhase: true,
            isInstagram: true,
          ).code,
          'instagram_login_required',
        );
        expect(
          classifyEngineError(
            igStory,
            metadataPhase: true,
            isInstagram: true,
            hasSession: true,
          ).code,
          'instagram_session_expired',
        );
      },
    );

    test('the ambiguous empty response never claims a login is the cause', () {
      for (final session in [false, true]) {
        final failure = classifyEngineError(
          igEmpty,
          metadataPhase: true,
          isInstagram: true,
          hasSession: session,
        );
        expect(failure.code, 'instagram_unreachable');
      }
      expect(
        classify(igEmpty, metadata: true).code,
        isNot('unsupported_platform'),
      );
    });

    test('anonymous rate limiting on Instagram is a temporary restriction', () {
      final failure = classifyEngineError(
        igRate,
        metadataPhase: true,
        isInstagram: true,
      );
      expect(failure.code, 'source_rate_limited');
      expect(failure.retryable, isTrue);
    });

    test('only a link no extractor accepts is called unsupported', () {
      expect(
        classify(noExtractor, metadata: true).code,
        'unsupported_platform',
      );
      expect(classify(facebookWall).code, isNot('unsupported_platform'));
      expect(
        classify('ERROR: something odd happened').code,
        isNot('unsupported_platform'),
      );
    });
  });

  group('anything unrecognised', () {
    test('falls back by phase without guessing a cause', () {
      expect(classify('something odd', metadata: true).code, 'metadata_failed');
      expect(classify('something odd').code, 'download_failed');
      expect(classify('').code, 'download_failed');
    });

    test('is worth retrying once', () {
      expect(classify('something odd').retryable, isTrue);
    });
  });
}
