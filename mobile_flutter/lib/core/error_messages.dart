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

  /// True when the problem is the phone's internet connection rather than the video.
  final bool isConnectivity;
}

const String genericFailureMessage = 'Something went wrong. Please try again.';

/// Wording per failure code. The codes are shared with the web client and the Python server
/// (`namao/errors.py`); these are the on-phone phrasings, with no technical terms.
const Map<String, String> _messages = {
  'invalid_url': "That doesn't look like a valid video link.",
  'unsupported_platform': unsupportedLinkMessage,
  'unsupported_content':
      'Only single, non-live videos are supported (no playlists or live streams).',
  'invalid_quality': "That quality option isn't valid.",
  'file_too_large': 'This file is too large to download.',
  'video_unavailable':
      'This video is unavailable. It may be private, deleted, or removed.',
  'auth_required':
      "This video requires signing in. Namao can't download it without authorized access.",
  'geo_restricted': "This video isn't available in your region.",
  'source_rate_limited':
      'The site is limiting requests right now. Try again later.',
  'access_blocked': 'The site refused the request from this connection.',
  'format_unavailable':
      "The selected quality isn't available. Pick another option.",
  'engine_outdated': 'Namao needs a quick refresh for this site.',
  'extractor_broken':
      "The site changed and this video couldn't be read. Try again later.",
  'js_challenge_failed': "The site's check couldn't be completed. Try again.",
  'environment_unsupported': "Namao couldn't get ready on this phone.",
  'network_transient':
      'Your internet connection was interrupted.',
  'timeout': 'This took too long and was stopped.',
  'merge_failed':
      "The video was downloaded but couldn't be finished. Please try again.",
  'output_invalid': "The downloaded file couldn't be used. Please try again.",
  'storage_full': 'Not enough free space on this phone. Free some up and retry.',
  'metadata_failed': "Couldn't read this video's information.",
  'download_failed': genericFailureMessage,
  'cancelled': 'The download was cancelled.',
  'interrupted': 'The download was interrupted. Tap Retry to start it again.',
  'expired':
      'This download is no longer on this phone. Retry downloads it again.',
};

/// Short, actionable follow-ups.
const Map<String, String> _hints = {
  'network_transient': 'Check your internet connection, then try again.',
  'source_rate_limited': 'Wait a few minutes, then try again.',
  'file_too_large': 'Pick a lower quality.',
  'format_unavailable': 'Pick another quality and try again.',
  'expired': 'Use Retry to download it again from the source.',
  'auth_required': 'Namao is for public videos only; it does not bypass logins.',
  'access_blocked': 'Try again later, or on a different network.',
  'engine_outdated': 'Connect to the internet and try again.',
  'environment_unsupported': 'Close Namao and open it again.',
  'storage_full': 'Delete something you no longer need, then retry.',
};

/// The user-safe sentence for a failure [code].
String messageForCode(String code) => _messages[code] ?? genericFailureMessage;

ErrorPresentation presentApiError(ApiException error) {
  final message = error.message.trim().isNotEmpty
      ? error.message.trim()
      : messageForCode(error.code);
  return ErrorPresentation(
    message: message,
    hint: _hints[error.code],
    retryable: error.retryable,
    isConnectivity: error.code == 'network_transient',
  );
}

/// For a job that ended `failed` / `cancelled` / `interrupted`.
ErrorPresentation presentJobError(ApiErrorBody? error) {
  if (error == null) {
    return const ErrorPresentation(
      message: genericFailureMessage,
      retryable: true,
    );
  }
  final message = error.message.trim().isNotEmpty
      ? error.message.trim()
      : messageForCode(error.code);
  return ErrorPresentation(
    message: message,
    hint: _hints[error.code],
    retryable: error.retryable,
    isConnectivity: error.code == 'network_transient',
  );
}
