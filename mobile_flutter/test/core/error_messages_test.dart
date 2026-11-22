import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/error_messages.dart';
import 'package:namao_app/core/models/api_error.dart';

void main() {
  ApiException failure(
    String code,
    String message, {
    int status = 400,
    bool retryable = false,
  }) => ApiException(
    code: code,
    message: message,
    status: status,
    retryable: retryable,
  );

  group('presentApiError', () {
    test('uses the message it was given (it is already user-safe)', () {
      final shown = presentApiError(
        failure('video_unavailable', 'This video is unavailable.'),
      );
      expect(shown.message, 'This video is unavailable.');
      expect(shown.retryable, isFalse);
    });

    test('falls back to the code table when the message is blank', () {
      final shown = presentApiError(
        failure('network_transient', '  ', retryable: true),
      );
      expect(shown.message, contains('connection'));
      expect(shown.hint, contains('internet'));
      expect(shown.retryable, isTrue);
      expect(shown.isConnectivity, isTrue);
    });

    test('an unknown code with no message gets the generic sentence', () {
      final shown = presentApiError(failure('brand_new_code', ''));
      expect(shown.message, genericFailureMessage);
      expect(shown.isConnectivity, isFalse);
    });

    test('hints exist for actionable codes', () {
      expect(
        presentApiError(failure('file_too_large', 'x')).hint,
        contains('lower quality'),
      );
      expect(presentApiError(failure('auth_required', 'x')).hint, isNotNull);
    });

    test('no message mentions servers, keys or technical tools', () {
      for (final code in [
        'invalid_url',
        'unsupported_platform',
        'unsupported_content',
        'invalid_quality',
        'file_too_large',
        'video_unavailable',
        'auth_required',
        'geo_restricted',
        'source_rate_limited',
        'access_blocked',
        'format_unavailable',
        'engine_outdated',
        'extractor_broken',
        'js_challenge_failed',
        'environment_unsupported',
        'network_transient',
        'timeout',
        'merge_failed',
        'output_invalid',
        'storage_full',
        'metadata_failed',
        'download_failed',
        'cancelled',
        'interrupted',
        'expired',
      ]) {
        final shown = presentApiError(failure(code, ''));
        final text = '${shown.message} ${shown.hint ?? ''}'.toLowerCase();
        for (final banned in [
          'server',
          'yt-dlp',
          'ffmpeg',
          'python',
          'api key',
          'backend',
        ]) {
          expect(
            text,
            isNot(contains(banned)),
            reason: '$code mentions "$banned"',
          );
        }
      }
    });
  });

  group('presentJobError', () {
    test('uses the job error message and retryability', () {
      final shown = presentJobError(
        const ApiErrorBody(
          code: 'network_transient',
          message: 'Net hiccup.',
          retryable: true,
        ),
      );
      expect(shown.message, 'Net hiccup.');
      expect(shown.retryable, isTrue);
    });

    test('missing error is a generic retryable failure', () {
      final shown = presentJobError(null);
      expect(shown.message, genericFailureMessage);
      expect(shown.retryable, isTrue);
    });

    test('blank message falls back by code', () {
      final shown = presentJobError(
        const ApiErrorBody(code: 'expired', message: ''),
      );
      expect(shown.message, contains('no longer'));
      expect(shown.hint, contains('Retry'));
    });
  });
}
