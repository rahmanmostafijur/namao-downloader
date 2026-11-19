import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/formatting.dart';
import 'package:namao_app/core/models/video_metadata.dart';

void main() {
  group('formatBytes', () {
    test('scales units with one decimal above bytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3.5 * 1024 * 1024 * 1024), '3.5 GB');
    });

    test('returns null for missing or nonsensical values', () {
      expect(formatBytes(null), isNull);
      expect(formatBytes(-1), isNull);
      expect(formatBytes(double.nan), isNull);
      expect(formatBytes(double.infinity), isNull);
    });
  });

  group('formatSizeOption', () {
    test('marks estimates with a tilde', () {
      const estimated = FormatOption(
        id: '720',
        label: '720p',
        kind: FormatKind.video,
        sizeBytes: 2 * 1024 * 1024,
        sizeEstimated: true,
      );
      expect(formatSizeOption(estimated), '~2.0 MB');
    });

    test('exact sizes have no tilde', () {
      const exact = FormatOption(
        id: '720',
        label: '720p',
        kind: FormatKind.video,
        sizeBytes: 2 * 1024 * 1024,
      );
      expect(formatSizeOption(exact), '2.0 MB');
    });

    test('says "size unknown" when the server gave none', () {
      const unknown = FormatOption(id: 'x', label: 'x', kind: FormatKind.video);
      expect(formatSizeOption(unknown), 'size unknown');
    });
  });

  group('formatDuration', () {
    test('formats minutes and hours', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(5), '0:05');
      expect(formatDuration(65), '1:05');
      expect(formatDuration(3723), '1:02:03');
    });

    test('treats missing/negative as zero', () {
      expect(formatDuration(null), '0:00');
      expect(formatDuration(-4), '0:00');
    });
  });

  group('formatEta / formatSpeed / formatPercent', () {
    test('eta ranges', () {
      expect(formatEta(null), '');
      expect(formatEta(-1), '');
      expect(formatEta(42), '42s left');
      expect(formatEta(65), '1m 5s left');
      expect(formatEta(3725), '1h 2m left');
    });

    test('speed', () {
      expect(formatSpeed(null), isNull);
      expect(formatSpeed(2 * 1024 * 1024), '2.0 MB/s');
    });

    test('percent is clamped and rounded', () {
      expect(formatPercent(42.4), '42%');
      expect(formatPercent(99.6), '100%');
      expect(formatPercent(-5), '0%');
      expect(formatPercent(250), '100%');
    });
  });
}
