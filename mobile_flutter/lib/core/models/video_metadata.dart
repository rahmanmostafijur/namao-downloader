import 'json_read.dart';

enum FormatKind { video, audio }

class FormatOption {
  const FormatOption({
    required this.id,
    required this.label,
    required this.kind,
    this.height,
    this.note = '',
    this.sizeBytes,
    this.sizeEstimated = false,
    this.needsMerge = false,
  });

  /// Null when the entry is malformed (missing id/label, unknown kind): never shown.
  static FormatOption? fromJson(Map<String, dynamic> json) {
    final id = readString(json['id']);
    final label = readString(json['label']);
    final kind = switch (json['kind']) {
      'video' => FormatKind.video,
      'audio' => FormatKind.audio,
      _ => null,
    };
    if (id == null || label == null || kind == null) return null;
    return FormatOption(
      id: id,
      label: label,
      kind: kind,
      height: readInt(json['height']),
      note: readString(json['note']) ?? '',
      sizeBytes: readInt(json['size_bytes']),
      sizeEstimated: json['size_estimated'] == true,
      needsMerge: json['needs_merge'] == true,
    );
  }

  /// The value sent as `quality` when creating a job: `best`, `audio` or a height.
  final String id;
  final String label;
  final FormatKind kind;
  final int? height;
  final String note;
  final int? sizeBytes;
  final bool sizeEstimated;
  final bool needsMerge;
}

class VideoMetadata {
  const VideoMetadata({
    required this.platform,
    required this.title,
    required this.formats,
    this.uploader = '',
    this.durationSeconds = 0,
    this.thumbnail,
    this.ffmpeg = true,
  });

  factory VideoMetadata.fromJson(Map<String, dynamic> json) {
    final raw = json['formats'];
    final formats = <FormatOption>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        final format = FormatOption.fromJson(item);
        if (format != null) formats.add(format);
      }
    }
    return VideoMetadata(
      platform: readString(json['platform']) ?? '',
      title: readString(json['title']) ?? '',
      uploader: readString(json['uploader']) ?? '',
      durationSeconds: readInt(json['duration_seconds']) ?? 0,
      thumbnail: readString(json['thumbnail']),
      formats: List.unmodifiable(formats),
      ffmpeg: json['ffmpeg'] != false,
    );
  }

  final String platform;
  final String title;
  final String uploader;
  final int durationSeconds;
  final String? thumbnail;
  final List<FormatOption> formats;
  final bool ffmpeg;

  List<FormatOption> get videoFormats =>
      formats.where((f) => f.kind == FormatKind.video).toList(growable: false);

  List<FormatOption> get audioFormats =>
      formats.where((f) => f.kind == FormatKind.audio).toList(growable: false);
}
