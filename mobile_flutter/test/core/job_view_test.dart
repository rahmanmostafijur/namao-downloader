import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/job_view.dart';
import 'package:namao_app/core/models/api_error.dart';
import 'package:namao_app/core/models/job.dart';
import 'package:namao_app/core/models/job_status.dart';

import '../support/fakes.dart';

void main() {
  group('status labels (shared terminology)', () {
    final expected = <JobStatus, String>{
      JobStatus.queued: 'Waiting in queue…',
      JobStatus.validating: 'Checking link…',
      JobStatus.fetchingMetadata: 'Reading video info…',
      JobStatus.merging: 'Merging audio and video…',
      JobStatus.verifying: 'Verifying file…',
      JobStatus.completed: 'Ready',
      JobStatus.failed: 'Failed',
      JobStatus.cancelled: 'Cancelled',
      JobStatus.interrupted: 'Interrupted',
    };
    expected.forEach((status, label) {
      test('${status.wire} -> $label', () {
        expect(describeJob(makeJob(status: status)).label, label);
      });
    });

    test('downloading shows the real percentage', () {
      final job = makeJob(
        status: JobStatus.downloading,
        progress: const JobProgress(percent: 41.6, totalBytes: 1000),
      );
      expect(describeJob(job).label, 'Downloading 42%');
    });

    test('a retried queued job says which attempt it is', () {
      final job = makeJob(status: JobStatus.queued, attempt: 1, maxAttempts: 3);
      expect(describeJob(job).label, 'Retrying (attempt 2 of 3)…');
    });
  });

  group('progress honesty', () {
    test('indeterminate for every non-downloading active stage', () {
      for (final status in [
        JobStatus.queued,
        JobStatus.validating,
        JobStatus.fetchingMetadata,
        JobStatus.merging,
        JobStatus.verifying,
      ]) {
        final view = describeJob(
          makeJob(status: status, progress: const JobProgress(percent: 80)),
        );
        expect(view.progress, isNull, reason: status.wire);
      }
    });

    test('downloading is determinate only with a real percentage', () {
      final real = describeJob(
        makeJob(
          status: JobStatus.downloading,
          progress: const JobProgress(percent: 25),
        ),
      );
      expect(real.progress, closeTo(0.25, 1e-9));

      final unknownTotal = describeJob(makeJob(status: JobStatus.downloading));
      expect(unknownTotal.progress, isNull);
      expect(unknownTotal.label, 'Downloading…');
    });

    test('a known total makes 0% a real 0%', () {
      final view = describeJob(
        makeJob(
          status: JobStatus.downloading,
          progress: const JobProgress(percent: 0, totalBytes: 5000),
        ),
      );
      expect(view.progress, 0);
      expect(view.label, 'Downloading 0%');
    });

    test('speed, eta and byte counts come only from the job', () {
      final view = describeJob(
        makeJob(
          status: JobStatus.downloading,
          progress: const JobProgress(
            percent: 50,
            downloadedBytes: 5 * 1024 * 1024,
            totalBytes: 10 * 1024 * 1024,
            speedBps: 1024 * 1024,
            etaSeconds: 5,
          ),
        ),
      );
      expect(view.speedEta, '1.0 MB/s · 5s left');
      expect(view.bytesLine, '5.0 MB / 10.0 MB');
    });

    test('no speed/eta line outside downloading', () {
      final view = describeJob(
        makeJob(
          status: JobStatus.merging,
          progress: const JobProgress(speedBps: 5, etaSeconds: 3),
        ),
      );
      expect(view.speedEta, isEmpty);
      expect(view.bytesLine, isEmpty);
    });
  });

  group('actions and tone', () {
    test('only non-terminal jobs can be cancelled', () {
      for (final status in JobStatus.values) {
        expect(
          describeJob(makeJob(status: status)).canCancel,
          !status.isTerminal,
        );
      }
    });

    test('retry rules', () {
      expect(
        describeJob(makeJob(status: JobStatus.cancelled)).canRetry,
        isTrue,
      );
      expect(
        describeJob(makeJob(status: JobStatus.interrupted)).canRetry,
        isTrue,
      );
      expect(describeJob(makeJob(status: JobStatus.failed)).canRetry, isTrue);
      expect(
        describeJob(
          makeJob(
            status: JobStatus.failed,
            error: const ApiErrorBody(
              code: 'unsupported_platform',
              message: 'nope',
              retryable: false,
            ),
          ),
        ).canRetry,
        isFalse,
      );
      expect(
        describeJob(
          makeJob(
            status: JobStatus.failed,
            error: const ApiErrorBody(
              code: 'network_transient',
              message: 'x',
              retryable: true,
            ),
          ),
        ).canRetry,
        isTrue,
      );
      expect(
        describeJob(makeJob(status: JobStatus.downloading)).canRetry,
        isFalse,
      );
      expect(
        describeJob(makeJob(status: JobStatus.completed)).canRetry,
        isFalse,
      );
    });

    test('tones', () {
      expect(
        describeJob(makeJob(status: JobStatus.completed)).tone,
        StatusTone.success,
      );
      expect(
        describeJob(makeJob(status: JobStatus.failed)).tone,
        StatusTone.danger,
      );
      expect(
        describeJob(makeJob(status: JobStatus.cancelled)).tone,
        StatusTone.neutral,
      );
      expect(
        describeJob(makeJob(status: JobStatus.downloading)).tone,
        StatusTone.active,
      );
    });

    test('terminal flag', () {
      expect(
        describeJob(makeJob(status: JobStatus.completed)).isTerminal,
        isTrue,
      );
      expect(
        describeJob(makeJob(status: JobStatus.verifying)).isTerminal,
        isFalse,
      );
    });
  });

  group('JobStatus / Job parsing', () {
    test('tryParse rejects unknown values', () {
      expect(JobStatus.tryParse('downloading'), JobStatus.downloading);
      expect(JobStatus.tryParse('paused'), isNull);
      expect(JobStatus.tryParse(null), isNull);
    });

    test('Job.fromJson reads the server record and round-trips', () {
      final json = <String, dynamic>{
        'id': 'abc',
        'status': 'downloading',
        'platform': 'youtube',
        'quality': '720',
        'title': 'T',
        'progress': {
          'percent': 12.5,
          'downloaded_bytes': 100,
          'total_bytes': 800,
          'speed_bps': 50.5,
          'eta_seconds': 14,
        },
        'attempt': 1,
        'max_attempts': 3,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:05Z',
        'expires_at': '2026-01-02T00:00:00Z',
      };
      final job = Job.fromJson(json)!;
      expect(job.progress.percent, 12.5);
      expect(job.progress.etaSeconds, 14);
      expect(job.expiresAt, DateTime.utc(2026, 1, 2));
      expect(Job.fromJson(job.toJson()), job);
    });

    test('Job.fromJson refuses unknown status or missing id', () {
      expect(Job.fromJson({'id': 'a', 'status': 'weird'}), isNull);
      expect(Job.fromJson({'status': 'queued'}), isNull);
    });

    test('a result without a size is dropped (cannot be verified)', () {
      final job = Job.fromJson({
        'id': 'a',
        'status': 'completed',
        'result': {'filename': 'x.mp4', 'download_url': '/x'},
      })!;
      expect(job.result, isNull);
    });

    test('percent is clamped to 0..100', () {
      final job = Job.fromJson({
        'id': 'a',
        'status': 'downloading',
        'progress': {'percent': 140},
      })!;
      expect(job.progress.percent, 100);
    });
  });
}
