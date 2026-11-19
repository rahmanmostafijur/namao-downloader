/// How a request failed. Drives the wording and whether "Retry" is offered.
enum ApiFailureKind {
  /// The server answered with an error (envelope or bare HTTP status).
  server,

  /// No usable connection: DNS, refused, reset, TLS.
  network,

  /// The server did not answer in time.
  timeout,

  /// The server answered 2xx with a body this client cannot use.
  badResponse,
}

class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.code,
    required this.message,
    this.status,
    this.retryable = false,
    this.detail,
  });

  const ApiException.network([String? detail])
    : this(
        kind: ApiFailureKind.network,
        code: 'client_network',
        message: "Couldn't reach the server.",
        retryable: true,
        detail: detail,
      );

  const ApiException.timeout()
    : this(
        kind: ApiFailureKind.timeout,
        code: 'client_timeout',
        message: 'The server took too long to answer.',
        retryable: true,
      );

  const ApiException.badResponse([String? detail])
    : this(
        kind: ApiFailureKind.badResponse,
        code: 'client_bad_response',
        message: 'The server sent a response this app could not understand.',
        retryable: true,
        detail: detail,
      );

  final ApiFailureKind kind;

  /// Server error code (see `namao/errors.py`) or a `client_*` code for local failures.
  final String code;

  /// Already user-safe when it came from the server envelope.
  final String message;
  final int? status;
  final bool retryable;
  final String? detail;

  bool get isNotFound => status == 404 || status == 410;

  /// The Namao server itself says the job is gone (error envelope). A bare 404 from a proxy or a
  /// wrong path (code `http_404`) says nothing about the job.
  bool get isJobGone => isNotFound && !code.startsWith('http_');
  bool get isUnauthorized => status == 401 || code == 'unauthorized';
  bool get isConnectivity =>
      kind == ApiFailureKind.network || kind == ApiFailureKind.timeout;

  @override
  String toString() => 'ApiException($code, status: $status, $message)';
}
