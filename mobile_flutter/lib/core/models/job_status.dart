/// Server job states, in the exact wire spelling used by `/api/v1/downloads`.
enum JobStatus {
  queued('queued'),
  validating('validating'),
  fetchingMetadata('fetching_metadata'),
  downloading('downloading'),
  merging('merging'),
  verifying('verifying'),
  completed('completed'),
  failed('failed'),
  cancelled('cancelled'),
  interrupted('interrupted');

  const JobStatus(this.wire);

  /// The value sent by the server.
  final String wire;

  /// True once the server will never change this job again.
  bool get isTerminal => switch (this) {
    JobStatus.completed ||
    JobStatus.failed ||
    JobStatus.cancelled ||
    JobStatus.interrupted => true,
    _ => false,
  };

  /// Stages with no meaningful percentage: the UI shows an indeterminate bar.
  bool get isIndeterminate => switch (this) {
    JobStatus.queued ||
    JobStatus.validating ||
    JobStatus.fetchingMetadata ||
    JobStatus.merging ||
    JobStatus.verifying => true,
    _ => false,
  };

  /// Returns null for a value this client does not know (never guessed).
  static JobStatus? tryParse(Object? value) {
    for (final status in JobStatus.values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}
