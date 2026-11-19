import 'dart:math' as math;

import 'api/api_exception.dart';
import 'api/namao_api.dart';
import 'models/job.dart';

/// Why polling stopped without a terminal job.
enum PollLoss {
  /// 404/410: the server no longer has the job (expired or server reset).
  notFound,

  /// 401: the API key is missing or wrong.
  unauthorized,

  /// Repeated network/server errors. The job itself may still be running on the server.
  unreachable,
}

typedef DelayFn = Future<void> Function(Duration duration);

/// Polls `GET /downloads/{id}` until the job is terminal.
///
/// Polling (not SSE) because it survives flaky mobile networks and is always correct.
/// Transient errors back off exponentially (capped); 404/401 end the watch immediately.
class JobPoller {
  JobPoller({
    required this.api,
    required this.jobId,
    required this.onJob,
    required this.onLost,
    this.interval = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 15),
    this.maxConsecutiveFailures = 6,
    DelayFn? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final NamaoApi api;
  final String jobId;
  final void Function(Job job) onJob;
  final void Function(PollLoss reason, ApiException? error) onLost;
  final Duration interval;
  final Duration maxBackoff;
  final int maxConsecutiveFailures;
  final DelayFn _delay;

  bool _stopped = true;
  int _generation = 0;

  bool get isRunning => !_stopped;

  /// Starts the loop; a second call while running is a no-op.
  Future<void> start() {
    if (!_stopped) return Future<void>.value();
    _stopped = false;
    final generation = ++_generation;
    // Whatever ends the loop (even an exception in a callback) leaves the poller restartable.
    return _run(generation).whenComplete(() => _finish(generation));
  }

  void stop() {
    _stopped = true;
    _generation++;
  }

  bool _isCurrent(int generation) => !_stopped && generation == _generation;

  Future<void> _run(int generation) async {
    var failures = 0;
    while (_isCurrent(generation)) {
      try {
        final job = await api.getJob(jobId);
        if (!_isCurrent(generation)) return;
        failures = 0;
        onJob(job);
        if (job.status.isTerminal) return _finish(generation);
        await _delay(interval);
      } on ApiException catch (error) {
        if (!_isCurrent(generation)) return;
        final loss = _classify(error, ++failures);
        if (loss != null) {
          _finish(generation);
          onLost(loss, error);
          return;
        }
        await _delay(_backoff(failures));
      }
    }
  }

  void _finish(int generation) {
    if (generation == _generation) _stopped = true;
  }

  PollLoss? _classify(ApiException error, int failures) {
    if (error.isJobGone) return PollLoss.notFound;
    if (error.isUnauthorized) return PollLoss.unauthorized;
    if (failures >= maxConsecutiveFailures) return PollLoss.unreachable;
    return null;
  }

  Duration _backoff(int failures) {
    final factor = math.pow(2, failures).toInt();
    final next = interval * factor;
    return next > maxBackoff ? maxBackoff : next;
  }
}
