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
