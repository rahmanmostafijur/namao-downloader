import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'app_release.dart';
import 'https_get.dart';

/// The bytes of a file being downloaded.
class ApkByteStream {
  const ApkByteStream(this.bytes, this.length);

  final Stream<List<int>> bytes;
  final int? length;
}

abstract class ApkByteSource {
  Future<ApkByteStream> open(Uri url);
}

/// The real source: HTTPS to GitHub only, every redirect re-checked (see [openHttps]).
class HttpApkByteSource implements ApkByteSource {
  const HttpApkByteSource();

  @override
  Future<ApkByteStream> open(Uri url) async {
    final body = await openHttps(url);
    return ApkByteStream(body.bytes, body.length);
  }
}

/// The downloaded file is not the one the release published (wrong size or checksum).
class ApkVerificationException implements Exception {
  const ApkVerificationException(this.message);

  final String message;

  @override
  String toString() => 'ApkVerificationException($message)';
}

class ApkDownloadCancelled implements Exception {
  const ApkDownloadCancelled();
}

/// Whether [file]'s SHA-256 equals [expectedHex] (case does not matter).
Future<bool> fileMatchesSha256(File file, String expectedHex) async {
  final digest = await crypto.sha256.bind(file.openRead()).first;
  return digest.toString() == expectedHex.trim().toLowerCase();
}

/// Downloads a release's APK into [dir] and only returns it once it is verified: a partial or
/// mismatching file is deleted, never handed to the installer.
class ApkDownloader {
  const ApkDownloader(this._source);

  final ApkByteSource _source;

  Future<File> download(
    AppRelease release,
    Directory dir, {
    void Function(double? fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final partial = File('${dir.path}/namao-${release.versionName}.apk.part');
    final target = File('${dir.path}/namao-${release.versionName}.apk');
    var received = 0;
    try {
      final stream = await _source.open(release.apkUrl);
      final total = stream.length ?? release.sizeBytes;
      final sink = partial.openWrite();
      try {
        await for (final chunk in stream.bytes) {
          if (isCancelled?.call() ?? false) throw const ApkDownloadCancelled();
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(
            total == null || total <= 0
                ? null
                : (received / total).clamp(0.0, 1.0),
          );
        }
      } finally {
        await sink.close();
      }
      final expectedSize = release.sizeBytes;
      if (expectedSize != null && received != expectedSize) {
        throw ApkVerificationException(
          'got $received bytes, expected $expectedSize',
        );
      }
      final expectedHash = release.sha256;
      if (expectedHash != null &&
          !await fileMatchesSha256(partial, expectedHash)) {
        throw const ApkVerificationException('checksum does not match');
      }
      return await partial.rename(target.path);
    } on SocketException catch (error) {
      await _discard(partial);
      throw AppUpdateException('network', error.message);
    } on TimeoutException {
      await _discard(partial);
      throw const AppUpdateException('network', 'timed out');
    } on HttpException catch (error) {
      await _discard(partial);
      throw AppUpdateException('network', error.message);
    } on Object {
      await _discard(partial);
      rethrow;
    }
  }

  Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The cache folder is emptied before the next download anyway.
    }
  }
}
