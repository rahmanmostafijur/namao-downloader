import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/api/api_exception.dart';
import '../core/api/namao_api.dart';
import 'native_media.dart';

/// Why a phone-side save failed. All of these leave the server file untouched, so a retry is
/// valid until the server's copy expires.
enum TransferFailure {
  /// The bytes received did not equal the size the server announced.
  sizeMismatch,
  storageFull,
  network,
  unauthorized,
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

/// Lets the owner stop an in-flight transfer between chunks.
class TransferToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// A stalled connection is abandoned after this long without a single byte.
const Duration transferStallTimeout = Duration(seconds: 45);

/// How many bytes are written between explicit flushes.
const int _flushEvery = 1024 * 1024;

const String _incompleteMessage =
    "The file didn't transfer completely. Please try again.";

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

/// Streams a finished file from the server to a temp file, proves it is complete, then hands it
/// to MediaStore. A short or partial file is never reported as success, and the temp file is
/// removed on every path.
class FileSaver {
  FileSaver({
    required this.api,
    required this.media,
    required this.tempDirectory,
    this.stallTimeout = transferStallTimeout,
  });

  final NamaoApi api;
  final NativeMedia media;
  final Directory Function() tempDirectory;
  final Duration stallTimeout;

  File _tempFile(String jobId) {
    final id = jobId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final name = id.isEmpty
        ? 'job'
        : (id.length > 40 ? id.substring(0, 40) : id);
    return File(
      '${tempDirectory().path}${Platform.pathSeparator}namao_$name.part',
    );
  }

  /// Removes leftovers from transfers an earlier process never finished.
  Future<void> cleanStaleTempFiles() async {
    final dir = tempDirectory();
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (entity is File &&
            name.startsWith('namao_') &&
            name.endsWith('.part')) {
          await _deleteQuietly(entity);
        }
      }
    } on FileSystemException {
      // The folder vanished or is unreadable: nothing to clean, and never worth failing startup.
    }
  }

  Future<SavedMedia> save({
    required String jobId,
    required String filename,
    required int expectedBytes,
    void Function(int received)? onProgress,
    TransferToken? token,
  }) async {
    final temp = _tempFile(jobId);
    try {
      await _deleteQuietly(temp);
      final received = await _download(
        jobId,
        temp,
        expectedBytes,
        onProgress,
        token,
      );
      if (received != expectedBytes || await temp.length() != expectedBytes) {
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
      return await _store(temp, filename, expectedBytes);
    } finally {
      await _deleteQuietly(temp);
    }
  }

  Future<int> _download(
    String jobId,
    File temp,
    int expectedBytes,
    void Function(int received)? onProgress,
    TransferToken? token,
  ) async {
    final FileDownload download;
    try {
      download = await api.openFile(jobId);
    } on ApiException catch (error) {
      throw _fromApi(error);
    }
    final announced = download.contentLength;
    if (announced != null && announced != expectedBytes) {
      throw const TransferException(
        TransferFailure.sizeMismatch,
        _incompleteMessage,
      );
    }
    final sink = temp.openWrite();
    var received = 0;
    var flushed = 0;
    try {
      await for (final chunk in download.bytes.timeout(
        stallTimeout,
        onTimeout: (events) {
          events
            ..addError(TimeoutException('stalled'))
            ..close();
        },
      )) {
        if (token?.isCancelled ?? false) {
          throw const TransferException(
            TransferFailure.cancelled,
            'Save cancelled.',
          );
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
        if (received - flushed >= _flushEvery) {
          // Back-pressure: a full disk surfaces here, not after the whole file was downloaded.
          await sink.flush();
          flushed = received;
        }
      }
      await sink.flush();
      await sink.close();
    } on TransferException {
      await _closeQuietly(sink);
      rethrow;
    } on Object catch (error) {
      await _closeQuietly(sink);
      throw _fromStreamError(error);
    }
    return received;
  }

  Future<SavedMedia> _store(
    File temp,
    String filename,
    int expectedBytes,
  ) async {
    try {
      return await media.saveToDownloads(
        tempPath: temp.path,
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
        _ => TransferException(
          TransferFailure.io,
          "Couldn't save to Downloads/Namao. ${error.message}",
        ),
      };
    }
  }

  TransferException _fromApi(ApiException error) {
    if (error.isJobGone) {
      return const TransferException(
        TransferFailure.expired,
        'This download expired on the server. Start it again.',
      );
    }
    if (error.isUnauthorized) {
      return const TransferException(
        TransferFailure.unauthorized,
        'The server rejected the API key. Check Settings.',
      );
    }
    return TransferException(
      error.isConnectivity ? TransferFailure.network : TransferFailure.io,
      error.isConnectivity
          ? "Lost the connection to the server."
          : error.message,
    );
  }

  TransferException _fromStreamError(Object error) {
    if (error is FileSystemException) {
      final noSpace = error.osError?.errorCode == 28; // ENOSPC
      return noSpace
          ? const TransferException(
              TransferFailure.storageFull,
              'Not enough free space on this phone. Free some up and retry.',
            )
          : TransferException(
              TransferFailure.io,
              "Couldn't write the file: ${error.message}",
            );
    }
    if (error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException ||
        error is HandshakeException) {
      return const TransferException(
        TransferFailure.network,
        'The connection to the server dropped during the transfer.',
      );
    }
    return TransferException(TransferFailure.io, 'Transfer failed: $error');
  }

  Future<void> _closeQuietly(IOSink sink) async {
    try {
      await sink.close();
    } on Object {
      // The sink already failed (disk full, closed); the temp file is deleted afterwards.
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort: a leftover .part file is also removed by cleanStaleTempFiles on next launch.
    }
  }
}
