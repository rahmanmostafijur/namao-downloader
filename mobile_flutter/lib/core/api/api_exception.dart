/// A download operation that failed, with a stable [code] (see `error_messages.dart`) and a
/// user-safe [message]. The tool's own technical text is never carried here.
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.retryable = false,
    this.status,
  });

  final String code;

  /// Already user-safe.
  final String message;
  final bool retryable;

  /// HTTP-style status: 400 for a refused request, 404 for a missing job, 409 for a conflict.
  final int? status;

  bool get isNotFound => status == 404 || status == 410;

  /// The job (or its file) no longer exists.
  bool get isJobGone => isNotFound;

  @override
  String toString() => 'ApiException($code, status: $status)';
}
