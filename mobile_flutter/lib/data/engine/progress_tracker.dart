import 'dart:math' as math;

/// Raw counters of one stream (a video and its audio are two streams downloaded in turn).
class StreamProgress {
  const StreamProgress({
    required this.downloaded,
    required this.total,
    required this.done,
  });

  factory StreamProgress.fromMap(Map<Object?, Object?> map) => StreamProgress(
    downloaded: (map['downloaded'] as num?)?.toInt() ?? 0,
    total: (map['total'] as num?)?.toInt() ?? 0,
    done: map['done'] == true,
  );

  final int downloaded;

  /// 0 while unknown.
  final int total;
  final bool done;
}

class ProgressSnapshot {
  const ProgressSnapshot({
    required this.percent,
    required this.downloadedBytes,
    this.totalBytes,
  });

  final double percent;
  final int downloadedBytes;

  /// Null until the whole job's size is known or estimated.
  final int? totalBytes;
}

/// Turns per-stream counters into one value that only moves forward. A merged download is
/// several sequential transfers, and the raw per-file percentage would jump 0 to 100 twice.
/// Held at 99% until the file is finished: merging and conversion still have to happen.
class ProgressTracker {
  ProgressTracker({this.expectedStreams, this.estimatedTotalBytes});

  /// How many streams this download transfers (2 for video + separate audio, else 1). Null when it
  /// is not known: then only the streams seen so far count, so a one-stream download is never held
  /// at 50% waiting for a second stream that will not come.
  final int? expectedStreams;

  /// The size the format list announced, used to weigh streams that have not started yet.
  final int? estimatedTotalBytes;

  double _last = 0;

  static const double _ceiling = 99;

  ProgressSnapshot update(List<StreamProgress> streams) {
    final downloaded = streams.fold<int>(0, (sum, s) => sum + s.downloaded);
    final knownTotal = streams.fold<int>(0, (sum, s) => sum + s.total);
    final allStarted = streams.length >= (expectedStreams ?? 1);
    final allSized = allStarted && streams.every((s) => s.total > 0);
    final estimate = estimatedTotalBytes;

    final double raw;
    int? total;
    if (allSized) {
      total = knownTotal;
      raw = downloaded * 100 / knownTotal;
    } else if (estimate != null && estimate > 0) {
      total = math.max(estimate, knownTotal);
      raw = downloaded * 100 / total;
    } else {
      raw = _equalWeights(streams);
    }
    _last = math.max(_last, math.min(_ceiling, raw));
    return ProgressSnapshot(
      percent: _last,
      downloadedBytes: downloaded,
      totalBytes: total,
    );
  }

  /// Each expected stream is an equal share; a stream of unknown size counts what is known of it.
  double _equalWeights(List<StreamProgress> streams) {
    var sum = 0.0;
    for (final s in streams) {
      if (s.done) {
        sum += 1;
      } else if (s.total > 0) {
        sum += math.min(0.999, s.downloaded / s.total);
      }
    }
    return sum *
        100 /
        math.max(math.max(expectedStreams ?? 1, streams.length), 1);
  }
}
