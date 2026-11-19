import 'dart:convert';

import '../../core/models/json_read.dart';
import '../../core/models/video_metadata.dart';

/// One stream the source offers, as yt-dlp reports it.
class RawFormat {
  const RawFormat({
    this.height,
    this.fps,
    this.vcodec,
    this.acodec,
    this.tbr,
    this.abr,
    this.sizeBytes,
  });

  factory RawFormat.fromJson(Map<String, dynamic> json) {
    final size = readInt(json['filesize']) ?? readInt(json['filesize_approx']);
    return RawFormat(
      height: readInt(json['height']),
      fps: readDouble(json['fps']),
      vcodec: readString(json['vcodec']),
      acodec: readString(json['acodec']),
      tbr: readDouble(json['tbr']),
      abr: readDouble(json['abr']),
      sizeBytes: (size == null || size <= 0) ? null : size,
    );
  }

  final int? height;
  final double? fps;
  final String? vcodec;
  final String? acodec;
  final double? tbr;
  final double? abr;
  final int? sizeBytes;

  bool get hasVideo => vcodec != null && vcodec != 'none';
  bool get hasAudio => acodec != null && acodec != 'none';
}

/// The facts and format list yt-dlp printed for a link (see `metadataOptions`).
class RawInfo {
  const RawInfo({
    required this.title,
    required this.uploader,
    required this.durationSeconds,
    required this.thumbnail,
    required this.isLive,
    required this.formats,
  });

  /// Parses the two JSON lines yt-dlp printed. Null when the output is not what was asked for.
  static RawInfo? parse(String output) {
    final lines = LineSplitter.split(output)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    try {
      final info = jsonDecode(lines[0]);
      final formats = jsonDecode(lines[1]);
      if (info is! Map<String, dynamic> || formats is! List) return null;
      final status = readString(info['live_status']);
      return RawInfo(
        title: readString(info['title']) ?? 'Untitled',
        uploader: readString(info['uploader']) ?? readString(info['channel']) ?? '',
        durationSeconds: readInt(info['duration']) ?? 0,
        thumbnail: _safeThumbnail(readString(info['thumbnail'])),
        isLive:
            info['is_live'] == true ||
            status == 'is_live' ||
            status == 'is_upcoming',
        formats: [
          for (final f in formats)
            if (f is Map<String, dynamic>) RawFormat.fromJson(f),
        ],
      );
    } on FormatException {
      return null;
    }
  }

  final String title;
  final String uploader;
  final int durationSeconds;
  final String? thumbnail;
  final bool isLive;
  final List<RawFormat> formats;
}

/// Thumbnails are shown on screen: accept only plain https links of sane length.
String? _safeThumbnail(String? value) {
  if (value == null || value.length > 2048) return null;
  return RegExp(r'^https://\S+$', caseSensitive: false).hasMatch(value)
      ? value
      : null;
}

RawFormat _bestByRate(List<RawFormat> candidates) {
  var best = candidates.first;
  for (final f in candidates.skip(1)) {
    final fps = f.fps ?? 0;
    final bestFps = best.fps ?? 0;
    if (fps > bestFps || (fps == bestFps && (f.tbr ?? 0) > (best.tbr ?? 0))) {
      best = f;
    }
  }
  return best;
}

/// (size in bytes, is it an estimate): the reported size, else bitrate x duration, else unknown.
(int?, bool) _sizeOf(RawFormat format, int duration) {
  if (format.sizeBytes != null) return (format.sizeBytes, false);
  final rate = format.tbr ?? format.abr;
  if (rate != null && rate > 0 && duration > 0) {
    return ((rate * 125 * duration).toInt(), true); // kbit/s -> bytes/s
  }
  return (null, false);
}

/// Only the qualities the source really offers, each an exact height, plus audio-only. The same
/// rules as the web client and server, so every client lists the same choices for a link.
List<FormatOption> buildFormatOptions(RawInfo info) {
  final video = info.formats.where((f) => f.hasVideo).toList();
  final audioOnly = info.formats.where((f) => f.hasAudio && !f.hasVideo).toList();

  RawFormat? bestAudio;
  for (final f in audioOnly) {
    if (bestAudio == null || (f.abr ?? f.tbr ?? 0) > (bestAudio.abr ?? bestAudio.tbr ?? 0)) {
      bestAudio = f;
    }
  }
  final (audioSize, audioEstimated) = bestAudio == null
      ? (null, false)
      : _sizeOf(bestAudio, info.durationSeconds);

  final byHeight = <int, List<RawFormat>>{};
  for (final f in video) {
    final h = f.height;
    if (h != null && h > 0) byHeight.putIfAbsent(h, () => []).add(f);
  }

  final options = <FormatOption>[];
  final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
  for (final height in heights) {
    final best = _bestByRate(byHeight[height]!);
    final needsMerge = !best.hasAudio;
    var (size, estimated) = _sizeOf(best, info.durationSeconds);
    if (size != null && needsMerge && audioSize != null) {
      size += audioSize;
      estimated = estimated || audioEstimated;
    }
    final fps = best.fps;
    final fpsSuffix = (fps != null && fps > 30) ? '${fps.round()}' : '';
    options.add(
      FormatOption(
        id: '$height',
        label: '${height}p$fpsSuffix',
        kind: FormatKind.video,
        height: height,
        note: options.isEmpty ? 'Highest available' : '',
        sizeBytes: size,
        sizeEstimated: estimated,
        needsMerge: needsMerge,
      ),
    );
  }

  if (options.isEmpty && video.isNotEmpty) {
    // Video exists but the source reports no heights (some short-form platforms).
    final best = _bestByRate(video);
    final (size, estimated) = _sizeOf(best, info.durationSeconds);
    options.add(
      FormatOption(
        id: 'best',
        label: 'Best available',
        kind: FormatKind.video,
        sizeBytes: size,
        sizeEstimated: estimated,
        needsMerge: !best.hasAudio,
      ),
    );
  }

  if (audioOnly.isNotEmpty || video.isNotEmpty) {
    options.add(
      FormatOption(
        id: 'audio',
        label: 'Audio only',
        kind: FormatKind.audio,
        note: 'MP3',
        sizeBytes: audioSize,
        sizeEstimated: audioEstimated,
      ),
    );
  }
  return options;
}
