import 'dart:io';

import '../core/api/api_exception.dart';
import '../core/api/namao_api.dart';
import 'native_media.dart';

/// Why moving a finished file into Downloads failed. The finished file is kept on every one of
/// these except `cancelled` by the owner, so "Retry save" is valid until it is saved.
enum TransferFailure {
  /// The file on disk is not the size the download reported: it is incomplete.
  sizeMismatch,
  storageFull,

  /// The finished file is gone (the system cleared it, or the app data was wiped).
  expired,
  cancelled,
  io,
}

class TransferException implements Exception {
  const TransferException(this.failure, this.message);

  final TransferFailure failure;

  /// User-safe.
  final String message;

  @override
  String toString() => 'TransferException($failure, $message)';
}

/// Lets the owner stop a save that has not started writing yet.
class TransferToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

const String _incompleteMessage =
    "The file didn't finish downloading. Please try again.";

const Map<String, String> _mimeByExtension = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'opus': 'audio/ogg',
  'ogg': 'audio/ogg',
  'wav': 'audio/wav',
};

String mimeFor(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  final extension = filename.substring(dot + 1).toLowerCase();
  return _mimeByExtension[extension] ?? 'application/octet-stream';
}

/// A file name that is safe on every Android filesystem: no separators, controls or reserved characters.
String safeDisplayName(String filename) {
  final cleaned = filename
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'^\.+'), '');
  if (cleaned.isEmpty) return 'video';
  return cleaned.length > 120
      ? cleaned.substring(cleaned.length - 120)
      : cleaned;
}

/// Moves a finished download into `Download/Namao` through MediaStore. The file's size is proved
/// first, so a short or partial file is never reported as saved; once it is stored, the working
/// copy is deleted. On any failure the working copy stays, so the save can be retried.
class FileSaver {
  FileSaver({required this.api, required this.media});

  final NamaoApi api;
  final NativeMedia media;

  Future<SavedMedia> save({
    required String jobId,
    required String filename,
    required int expectedBytes,
    TransferToken? token,
  }) async {
    final File file;
    try {
      file = await api.finishedFile(jobId);
    } on ApiException catch (error) {
      throw error.isJobGone
          ? const TransferException(
              TransferFailure.expired,
              'This download is no longer on this phone. Download it again.',
            )
          : TransferException(TransferFailure.io, error.message);
    }
    if (await file.length() != expectedBytes) {
      throw const TransferException(
        TransferFailure.sizeMismatch,
        _incompleteMessage,
      );
    }
    if (token?.isCancelled ?? false) {
      throw const TransferException(
        TransferFailure.cancelled,
        'Save cancelled.',
      );
    }
    final saved = await _store(file, filename, expectedBytes);
    await api.release(jobId);
    return saved;
  }

  Future<SavedMedia> _store(
    File file,
    String filename,
    int expectedBytes,
  ) async {
    try {
      return await media.saveToDownloads(
        tempPath: file.path,
        displayName: safeDisplayName(filename),
        mimeType: mimeFor(filename),
        expectedBytes: expectedBytes,
      );
    } on NativeMediaException catch (error) {
      throw switch (error.failure) {
        NativeMediaFailure.storageFull => const TransferException(
          TransferFailure.storageFull,
          'Not enough free space on this phone. Free some up and retry.',
        ),
        NativeMediaFailure.sizeMismatch => const TransferException(
          TransferFailure.sizeMismatch,
          _incompleteMessage,
        ),
        _ => const TransferException(
          TransferFailure.io,
          "Couldn't save to Downloads/Namao. Please try again.",
        ),
      };
    }
  }
}
