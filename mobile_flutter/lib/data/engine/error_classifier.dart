/// What went wrong, as a stable code (the same vocabulary as the web client and server) plus
/// whether trying again could help. People never see the tool's own text.
class EngineFailure {
  const EngineFailure(this.code, {required this.retryable});

  final String code;
  final bool retryable;
}

/// First matching rule wins, so specific rules come first. Anything not positively recognised
/// falls through to a generic failure rather than being blamed on a cause we cannot prove.
const List<(String, List<String>)> _rules = [
  (
    'storage_full',
    ['no space left on device', 'disk full', 'not enough space', 'errno 28'],
  ),
  ('file_too_large', ['larger than max-filesize', 'file is larger than']),
  (
    'js_challenge_failed',
    [
      'challenge solving failed',
      'n challenge',
      'nsig extraction failed',
      'signature extraction failed',
      'unable to solve',
      'only images are available',
      'js challenge',
    ],
  ),
  (
    'merge_failed',
    [
      'error merging',
      'merger',
      'postprocessing:',
      'postprocessing error',
      'ffmpeg exited with code',
      'conversion failed',
      'error opening output',
    ],
  ),
  (
    'unsupported_content',
    ['is live', 'live event will begin', 'premieres in', 'this live event'],
  ),
  (
    'unsupported_platform',
    ['unsupported url', 'no suitable extractor', 'extractor is not allowed'],
  ),
  ('invalid_url', ['is not a valid url', 'invalid url']),
  (
    'access_blocked',
    [
      'not a bot',
      'ip is likely being blocked',
      'your ip address is blocked',
      'http error 407',
    ],
  ),
  (
    'source_rate_limited',
    [
      'http error 429',
      'too many requests',
      'rate-limited',
      'rate limited',
      'rate limit',
      'rate-limit for accessing', // Instagram: "exceeded the rate-limit for accessing posts anonymously"
      'try again later',
    ],
  ),
  (
    'geo_restricted',
    [
      'not available in your country',
      'blocked it in your country',
      'geo restrict',
      'geo-restrict',
      'not available in your location',
      'unavailable in your country',
      'uploader has not made this video available',
    ],
  ),
  (
    'auth_required',
    [
      'sign in to confirm your age',
      'age-restricted',
      'age restricted',
      'inappropriate for some users',
      'login required',
      'log in',
      'sign in',
      'members-only',
      'members only',
      'join this channel',
      'private video',
      'this video is private',
      'requires authentication',
      'use --cookies',
      'cookies are needed',
      'authentication required',
    ],
  ),
  (
    'video_unavailable',
    [
      'video unavailable',
      'has been removed',
      'this video is no longer available',
      'account associated with this video has been terminated',
      'does not exist',
      "this video isn't available",
      "content isn't available",
      'content is not available',
      'removed by the uploader',
      'no longer available',
      'copyright',
      'http error 404',
      'http error 410',
      'post is unavailable',
      "page isn't available",
      // Facebook's current answer to a private, removed or login-walled video: the page holds no
      // video data and yt-dlp's extractor (unchanged in the latest stable) says only this.
      'cannot parse data',
    ],
  ),
  (
    'format_unavailable',
    [
      'requested format is not available',
      'no video formats found',
      'no formats found',
      'no video could be found',
    ],
  ),
  (
    'network_transient',
    [
      'timed out',
      'timeout',
      'connection reset',
      'connection aborted',
      'temporary failure',
      'name or service not known',
      'getaddrinfo failed',
      'network is unreachable',
      'econnreset',
      'failed to establish a new connection',
      'remote end closed connection',
      'incompleteread',
      'incomplete read',
      'http error 500',
      'http error 502',
      'http error 503',
      'http error 504',
      'transporterror',
      'ssl:',
      'unexpected eof',
      'connection refused',
      'read error',
      'chunkedencodingerror',
      'unable to download',
    ],
  ),
  (
    'extractor_broken',
    [
      'unable to extract',
      'please report this issue',
      'make sure you are using the latest version',
      'unable to download json metadata',
      'player response',
      'unable to parse',
      'failed to parse',
    ],
  ),
];

const Set<String> _retryable = {
  'network_transient',
  'source_rate_limited',
  'timeout',
  'access_blocked',
  'storage_full',
  'engine_outdated',
  'js_challenge_failed',
};

/// yt-dlp prints `ERROR:` lines for what stopped it; warnings around them would only add noise
/// to the match (a warning that mentions "sign in" is not an auth failure).
String _errorText(String raw) {
  final errors = raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('ERROR:'));
  final joined = errors.join('\n');
  return (joined.isEmpty ? raw : joined).toLowerCase();
}

/// Maps the tool's error output to a stable code. [engineStale] is true when the bundled yt-dlp
/// is old: an ambiguous 403 or a broken extractor is then reported as an out-of-date engine
/// instead of guessing at the network.
EngineFailure classifyEngineError(
  String raw, {
  required bool metadataPhase,
  bool engineStale = false,
  bool isInstagram = false,
  bool hasSession = false,
}) {
  final text = _errorText(raw);
  // Instagram answers a deleted, private or rate-limited post with this same sentence, so it
  // proves no single cause: say that, instead of claiming a login is the problem.
  if (isInstagram && text.contains('empty media response')) {
    return const EngineFailure('instagram_unreachable', retryable: false);
  }
  for (final (code, markers) in _rules) {
    if (markers.any(text.contains)) {
      final upgraded =
          engineStale &&
              (code == 'extractor_broken' || code == 'js_challenge_failed')
          ? 'engine_outdated'
          : code;
      final result = isInstagram && upgraded == 'auth_required'
          ? (hasSession
                ? 'instagram_session_expired'
                : 'instagram_login_required')
          : upgraded;
      return EngineFailure(result, retryable: _retryable.contains(result));
    }
  }
  if (text.contains('http error 403') || text.contains('403: forbidden')) {
    final code = engineStale ? 'engine_outdated' : 'access_blocked';
    return EngineFailure(code, retryable: true);
  }
  return EngineFailure(
    metadataPhase ? 'metadata_failed' : 'download_failed',
    retryable: true,
  );
}
