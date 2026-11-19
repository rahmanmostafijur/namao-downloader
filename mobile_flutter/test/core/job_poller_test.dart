import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/api/api_exception.dart';
import 'package:namao_app/core/job_poller.dart';
import 'package:namao_app/core/models/job.dart';
import 'package:namao_app/core/models/job_status.dart';

import '../support/fakes.dart';

const _network = ApiException(
  code: 'environment_unsupported',
  message: 'Not ready.',
  retryable: true,
);
const _notFound = notFound;

void main() {
  late FakeApi api;
  late List<Job> jobs;
  late List<(PollLoss, ApiException?)> losses;
  late List<Duration> delays;

  setUp(() {
    api = FakeApi();
    jobs = [];
    losses = [];
    delays = [];
  });

  JobPoller poller({int maxFailures = 6}) => JobPoller(
    api: api,
    jobId: 'job1',
    onJob: jobs.add,
    onLost: (reason, error) => losses.add((reason, error)),
    maxConsecutiveFailures: maxFailures,
    delay: (d) async => delays.add(d),
  );

  test('polls until the job is terminal, then stops', () async {
    api.script('job1', [
      makeJob(status: JobStatus.queued),
      makeJob(
        status: JobStatus.downloading,
        progress: const JobProgress(percent: 40),
      ),
      makeJob(status: JobStatus.completed, result: makeResult()),
    ]);
    final p = poller();
    await p.start();
    expect(jobs.map((j) => j.status), [
      JobStatus.queued,
      JobStatus.downloading,
      JobStatus.completed,
    ]);
    expect(api.calls.where((c) => c.startsWith('get')).length, 3);
    expect(p.isRunning, isFalse);
    expect(losses, isEmpty);
  });

  test('waits the normal interval between active polls', () async {
    api.script('job1', [
      makeJob(status: JobStatus.queued),
      makeJob(status: JobStatus.completed),
    ]);
    await poller().start();
    expect(delays, [const Duration(seconds: 1)]);
  });

  test('every terminal state stops polling', () async {
    for (final status in [
      JobStatus.failed,
      JobStatus.cancelled,
      JobStatus.interrupted,
    ]) {
      api.calls.clear();
      api.script('job1', [makeJob(status: status)]);
      await poller().start();
      expect(api.calls.length, 1, reason: status.wire);
    }
  });

  test(
    'transient errors back off exponentially (capped) and recover',
    () async {
      api.script('job1', [
        _network,
        _network,
        _network,
        _network,
        _network,
        makeJob(status: JobStatus.completed),
      ]);
      await poller().start();
      expect(delays, [
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
        const Duration(seconds: 15),
        const Duration(seconds: 15),
      ]);
      expect(jobs.single.status, JobStatus.completed);
      expect(losses, isEmpty);
    },
  );

  test('a success resets the failure counter', () async {
    api.script('job1', [
      _network,
      makeJob(status: JobStatus.downloading),
      _network,
      makeJob(status: JobStatus.completed),
    ]);
    await poller(maxFailures: 2).start();
    expect(losses, isEmpty);
    expect(jobs.last.status, JobStatus.completed);
  });

  test(
    'repeated failures give up as "unreachable" without inventing a job state',
    () async {
      api.script('job1', [_network]);
      await poller(maxFailures: 3).start();
      expect(jobs, isEmpty);
      expect(losses.single.$1, PollLoss.unreachable);
      expect(api.calls.length, 3);
    },
  );

  test('404 ends the watch immediately as notFound', () async {
    api.script('job1', [_notFound]);
    await poller().start();
    expect(losses.single.$1, PollLoss.notFound);
    expect(api.calls.length, 1);
    expect(delays, isEmpty);
  });

  test('stop() prevents further callbacks', () async {
    api.script('job1', [makeJob(status: JobStatus.downloading)]);
    late JobPoller p;
    p = JobPoller(
      api: api,
      jobId: 'job1',
      onJob: (job) {
        jobs.add(job);
        p.stop();
      },
      onLost: (r, e) => losses.add((r, e)),
      delay: (d) async => delays.add(d),
    );
    await p.start();
    expect(jobs.length, 1);
    expect(p.isRunning, isFalse);
  });

  test('start() while running is a no-op', () async {
    api.script('job1', [makeJob(status: JobStatus.completed)]);
    final p = poller();
    final first = p.start();
    final second = p.start();
    await Future.wait([first, second]);
    expect(api.calls.where((c) => c.startsWith('get')).length, 1);
  });
}
