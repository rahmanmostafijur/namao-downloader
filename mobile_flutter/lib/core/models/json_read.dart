/// Tolerant readers for server JSON. A wrong type reads as absent, never as a guess.
int? readInt(Object? value) => value is num ? value.round() : null;

double? readDouble(Object? value) => value is num ? value.toDouble() : null;

String? readString(Object? value) => value is String ? value : null;

DateTime? readDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

Map<String, dynamic>? readMap(Object? value) =>
    value is Map<String, dynamic> ? value : null;
