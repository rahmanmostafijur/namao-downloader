import '../models/job.dart';
import '../models/video_metadata.dart';

/// A finished file being streamed from the server.
class FileDownload {
  const FileDownload({required this.bytes, this.contentLength});

  final Stream<List<int>> bytes;

  /// From the response header; null when the server sent no length.
  final int? contentLength;
}

/// Result of the settings "Test connection" probe.
class ConnectionReport {
  const ConnectionReport({
    required this.ready,
    required this.authorized,
    this.failingChecks = const [],
  });

  /// `/health/ready` answered 200.
  final bool ready;

  /// The API key (or lack of one) is accepted by `/api/v1/*`.
  final bool authorized;

  /// Names of dependency checks the server reported as failing when not ready.
  final List<String> failingChecks;

  bool get isHealthy => ready && authorized;
}

/// The whole server surface the app uses. Thin on purpose: no extraction logic lives here.
abstract class NamaoApi {
  Future<VideoMetadata> metadata(String url);

  /// `idempotencyKey` must be new per user tap and reused only for a repeat of that tap.
  Future<Job> createDownload(String url, String quality, String idempotencyKey);

  Future<Job> getJob(String id);

  Future<Job> cancel(String id);

  /// Opens the verified file (attachment, Range-capable). Throws [ApiException] on non-2xx.
  Future<FileDownload> openFile(String id);

  Future<ConnectionReport> checkConnection();

  /// Releases connections. A no-op for implementations that hold none.
  void close() {}
}
