import 'dart:io';

import '../models/job.dart';
import '../models/video_metadata.dart';

/// Everything the app asks of the downloader. The Android app implements it on the phone
/// (`LocalNamaoApi`); screens and controllers only ever see this interface.
abstract class NamaoApi {
  /// Gets the engine ready (unpacks it on first launch). Safe to call again; throws
  /// [ApiException] if the phone cannot run it.
  Future<void> prepare();

  Future<VideoMetadata> metadata(String url);

  /// `idempotencyKey` must be new per user tap and reused only for a repeat of that tap.
  Future<Job> createDownload(String url, String quality, String idempotencyKey);

  Future<Job> getJob(String id);

  Future<Job> cancel(String id);

  /// The finished file, ready to be moved into Downloads. Throws [ApiException] with a
  /// job-gone code when it no longer exists.
  Future<File> finishedFile(String id);

  /// Deletes the job's working files (once the result is saved).
  Future<void> release(String id);

  /// Deletes the working files of every job not in [keep]: leftovers of crashes and removals.
  Future<void> cleanup(Set<String> keep);
}
