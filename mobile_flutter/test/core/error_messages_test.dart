import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/error_messages.dart';
import 'package:namao_app/core/models/api_error.dart';

void main() {
  ApiException server(
    String code,
    String message, {
    int status = 400,
    bool retryable = false,
  }) => ApiException(
    kind: ApiFailureKind.server,
    code: code,
    message: message,
    status: status,
    retryable: retryable,
  );

  group('presentApiError', () {
    test('uses the server message verbatim (it is already user-safe)', () {
      final shown = presentApiError(
        server('video_unavailable', 'This video is unavailable.'),
      );
      expect(shown.message, 'This video is unavailable.');
      expect(shown.retryable, isFalse);
    });

    test('falls back to the code table when the message is blank', () {
      final shown = presentApiError(
        server('queue_full', '  ', status: 503, retryable: true),
      );
      expect(shown.message, contains('busy'));
      expect(shown.hint, isNotNull);
      expect(shown.retryable, isTrue);
    });

    test('401 points at the API key in Settings', () {
      final shown = presentApiError(
        server('unauthorized', 'Missing or invalid credentials.', status: 401),
      );
      expect(shown.message, contains('API key'));
      expect(shown.hint, contains('Settings'));
    });

    test('network and timeout errors name the configured server', () {
      final network = presentApiError(
        const ApiException.network(),
        serverUrl: 'http://10.0.2.2:8000',
      );
      expect(network.message, contains('10.0.2.2:8000'));
      expect(network.isConnectivity, isTrue);
      expect(network.retryable, isTrue);

      final timeout = presentApiError(
        const ApiException.timeout(),
        serverUrl: 'http://nas.local:8000',
      );
      expect(timeout.message, contains('nas.local:8000'));
    });

    test('network error without a configured server says "the server"', () {
      expect(
        presentApiError(const ApiException.network()).message,
        contains('the server'),
      );
    });

    test('bad response suggests checking the address', () {
      final shown = presentApiError(const ApiException.badResponse());
      expect(shown.hint, contains('Namao'));
    });

    test('unknown code with no message still says something', () {
      final shown = presentApiError(server('brand_new_code', ''));
      expect(shown.message, isNotEmpty);
    });

    test('hints exist for actionable codes', () {
      expect(
        presentApiError(server('file_too_large', 'x')).hint,
        contains('lower quality'),
      );
      expect(presentApiError(server('auth_required', 'x')).hint, isNotNull);
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
      expect(shown.message, 'The download failed.');
      expect(shown.retryable, isTrue);
    });

    test('blank message falls back by code', () {
      final shown = presentJobError(
        const ApiErrorBody(code: 'expired', message: ''),
      );
      expect(shown.message, contains('expired'));
      expect(shown.hint, contains('Retry'));
    });
  });
}
