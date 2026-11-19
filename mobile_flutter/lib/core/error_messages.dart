import 'api/api_exception.dart';
import 'models/api_error.dart';
import 'url_tools.dart';

/// What the UI shows for a failure: a user-safe message, an optional next step, and
/// whether offering "Retry" makes sense.
class ErrorPresentation {
  const ErrorPresentation({
    required this.message,
    required this.retryable,
    this.hint,
    this.isConnectivity = false,
  });

  final String message;
  final String? hint;
  final bool retryable;

  /// True when the problem is reaching the server rather than something the server said.
  final bool isConnectivity;
}

/// Fallback wording per server code (`namao/errors.py`), used only when the envelope carried
/// no message. The server's own `message` is always preferred: it is already user-safe.
const Map<String, String> _fallbackMessages = {
  'invalid_url': "That doesn't look like a valid video link.",
  'unsupported_platform': unsupportedLinkMessage,
  'unsupported_content': 'Only single, non-live videos are supported (no playlists or live streams).',
  'invalid_quality': "That quality option isn't valid.",
  'file_too_large': 'The file is larger than this server allows.',
  'duration_too_long': 'The video is longer than this server allows.',
  'queue_full': 'The server is busy. Please try again in a few minutes.',
  'too_many_requests':
      'Too many requests. Please slow down and try again shortly.',
  'video_unavailable':
      'This video is unavailable. It may be private, deleted, or removed.',
  'auth_required': "This video requires signing in. Namao can't download it without authorized access.",
  'geo_restricted': "This video isn't available in the server's region.",
  'source_rate_limited':
      'The source site is rate-limiting this server. Try again later.',
  'access_blocked':
      "The source site refused the request from this server's network.",
  'format_unavailable':
      "The selected quality isn't available. Pick another option.",
  'engine_outdated': 'The download engine is out of date for this site.',
  'extractor_broken': "The site changed and the video couldn't be read.",
  'js_runtime_missing':
      "A required JavaScript runtime isn't installed on the server.",
  'js_challenge_failed':
      "The server couldn't solve the site's JavaScript challenge.",
  'ffmpeg_missing': "FFmpeg isn't installed on the server.",
  'environment_unsupported': "The server environment can't run this download.",
  'network_transient': 'A temporary network problem interrupted the download.',
  'timeout': 'The download took too long and was stopped.',
  'merge_failed':
      'The video was downloaded but combining audio and video failed.',
  'output_invalid':
      'The downloaded file failed verification and was discarded.',
  'storage_full': 'The server is out of storage space.',
  'metadata_failed': "Couldn't read this video's information.",
  'download_failed': 'The download failed.',
  'cancelled': 'The download was cancelled.',
  'interrupted': 'The download was interrupted. Start it again.',
  'not_found': 'Not found.',
  'expired':
      'This download has expired and its file was deleted. Start it again.',
  'invalid_request': 'The request was malformed.',
  'conflict': "That action isn't possible in the job's current state.",
  'unauthorized': 'The server needs a valid API key.',
  'internal_error': 'Something went wrong on the server.',
};

/// Short, actionable follow-ups that only the client can phrase (it knows about Settings).
const Map<String, String> _hints = {
  'unauthorized': 'Check the API key in Settings.',
  'queue_full': 'Wait a few minutes, then try again.',
  'too_many_requests': 'Wait a moment, then try again.',
  'file_too_large': 'Pick a lower quality.',
  'format_unavailable': 'Pick another quality and try again.',
  'duration_too_long': 'Pick a shorter video.',
  'expired': 'Use Retry to download it again from the source.',
  'auth_required':
      'Namao is for public videos only; it does not bypass logins.',
  'access_blocked': 'Retrying or updating the server may not help.',
};

ErrorPresentation presentApiError(ApiException error, {String? serverUrl}) {
  final server = serverUrl == null ? 'the server' : serverLabel(serverUrl);
  switch (error.kind) {
    case ApiFailureKind.network:
      return ErrorPresentation(
        message: "Can't reach $server.",
        hint: 'Check that it is running and that this phone can see it.',
        retryable: true,
        isConnectivity: true,
      );
    case ApiFailureKind.timeout:
      return ErrorPresentation(
        message: '$server took too long to answer.',
        hint: 'It may be busy. Try again.',
        retryable: true,
        isConnectivity: true,
      );
    case ApiFailureKind.badResponse:
      return ErrorPresentation(
        message: "$server sent a reply this app couldn't read.",
        hint: 'Is this address a Namao server?',
        retryable: true,
      );
    case ApiFailureKind.server:
      return _presentServerError(error);
  }
}

ErrorPresentation _presentServerError(ApiException error) {
  final code = error.code;
  final isUnauthorized = error.isUnauthorized;
  final message = isUnauthorized
      ? _fallbackMessages['unauthorized']!
      : (error.message.trim().isNotEmpty
            ? error.message.trim()
            : (_fallbackMessages[code] ?? 'Request failed.'));
  return ErrorPresentation(
    message: message,
    hint: _hints[isUnauthorized ? 'unauthorized' : code],
    retryable: error.retryable,
  );
}

/// For a job that ended `failed` / `cancelled` / `interrupted` on the server.
ErrorPresentation presentJobError(ApiErrorBody? error) {
  if (error == null) {
    return const ErrorPresentation(
      message: 'The download failed.',
      retryable: true,
    );
  }
  final message = error.message.trim().isNotEmpty
      ? error.message.trim()
      : (_fallbackMessages[error.code] ?? 'The download failed.');
  return ErrorPresentation(
    message: message,
    hint: _hints[error.code],
    retryable: error.retryable,
  );
}
