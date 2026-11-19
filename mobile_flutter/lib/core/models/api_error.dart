/// The `{"error": {...}}` envelope used by every failing response and failed job.
class ApiErrorBody {
  const ApiErrorBody({
    required this.code,
    required this.message,
    this.retryable = false,
    this.detail,
  });

  factory ApiErrorBody.fromJson(Map<String, dynamic> json) => ApiErrorBody(
    code: json['code'] is String ? json['code'] as String : 'unknown',
    message: json['message'] is String ? json['message'] as String : '',
    retryable: json['retryable'] == true,
    detail: json['detail'] is String ? json['detail'] as String : null,
  );

  final String code;
  final String message;
  final bool retryable;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    'retryable': retryable,
    if (detail != null) 'detail': detail,
  };

  @override
  bool operator ==(Object other) =>
      other is ApiErrorBody &&
      other.code == code &&
      other.message == message &&
      other.retryable == retryable &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(code, message, retryable, detail);
}
