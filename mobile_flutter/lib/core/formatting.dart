import 'models/video_metadata.dart';

const List<String> _units = ['B', 'KB', 'MB', 'GB', 'TB'];

/// "12.3 MB". Null for a missing or nonsensical value (never shows a made-up size).
String? formatBytes(num? value) {
  if (value == null || !value.isFinite || value < 0) return null;
  var size = value.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < _units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  final text = unit == 0 ? size.round().toString() : size.toStringAsFixed(1);
  return '$text ${_units[unit]}';
}

/// Size shown beside a format: "~48.2 MB" when the server estimated it, "size unknown" when absent.
String formatSizeOption(FormatOption option) {
  final bytes = formatBytes(option.sizeBytes);
  if (bytes == null) return 'size unknown';
  return option.sizeEstimated ? '~$bytes' : bytes;
}

String? formatSpeed(num? bytesPerSecond) {
  final text = formatBytes(bytesPerSecond);
  return text == null ? null : '$text/s';
}

/// "1:05" or "1:02:03".
String formatDuration(num? seconds) {
  final total = (seconds == null || !seconds.isFinite || seconds < 0)
      ? 0
      : seconds.round();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final secs = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(secs)}'
      : '$minutes:${two(secs)}';
}

/// "42s left", "3m 5s left", "1h 2m left". Empty when unknown.
String formatEta(int? seconds) {
  if (seconds == null || seconds < 0) return '';
  if (seconds >= 3600) {
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m left';
  }
  if (seconds >= 60) return '${seconds ~/ 60}m ${seconds % 60}s left';
  return '${seconds}s left';
}

String formatPercent(double percent) => '${percent.clamp(0, 100).round()}%';
