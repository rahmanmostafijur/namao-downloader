import 'package:flutter/services.dart';

/// A file now stored in `Download/Namao` (the name MediaStore actually assigned).
class SavedMedia {
  const SavedMedia({
    required this.uri,
    required this.displayName,
    required this.sizeBytes,
  });

  final String uri;
  final String displayName;
  final int sizeBytes;
}

enum NativeMediaFailure { storageFull, sizeMismatch, noAppToOpen, notFound, io }

class NativeMediaException implements Exception {
  const NativeMediaException(this.failure, this.message);

  final NativeMediaFailure failure;
  final String message;

  @override
  String toString() => 'NativeMediaException($failure, $message)';
}

/// The Android-only operations behind a small MethodChannel (see `MainActivity.kt`).
abstract class NativeMedia {
  /// Copies [tempPath] into `MediaStore.Downloads` under `Download/Namao`, using
  /// `IS_PENDING` while writing. Fails with [NativeMediaFailure.sizeMismatch] unless exactly
  /// [expectedBytes] were written. MediaStore may rename on a duplicate: the result has the real name.
  Future<SavedMedia> saveToDownloads({
    required String tempPath,
    required String displayName,
    required String mimeType,
    required int expectedBytes,
  });

  /// Whether the content URI still resolves to a file.
  Future<bool> exists(String uri);

  Future<void> open(String uri, String mimeType);

  Future<void> share(String uri, String mimeType, String title);

  /// Starts the foreground service that keeps the process alive during the phone-side transfer.
  Future<void> startTransfer(String text);

  Future<void> updateTransfer(int percent, String text);

  Future<void> stopTransfer();

  /// Asks for POST_NOTIFICATIONS on API 33+. Returns whether notifications are allowed.
  Future<bool> requestNotificationPermission();

  Future<String> appVersion();
}

class MethodChannelNativeMedia implements NativeMedia {
  const MethodChannelNativeMedia();

  static const MethodChannel _channel = MethodChannel(
    'com.namao.flutter/media',
  );

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      if (result == null) {
        throw NativeMediaException(
          NativeMediaFailure.io,
          '$method returned nothing',
        );
      }
      return result;
    } on PlatformException catch (error) {
      throw NativeMediaException(
        _failureFor(error.code),
        error.message ?? error.code,
      );
    } on MissingPluginException {
      throw NativeMediaException(
        NativeMediaFailure.io,
        '$method is not available',
      );
    }
  }

  NativeMediaFailure _failureFor(String code) => switch (code) {
    'storage_full' => NativeMediaFailure.storageFull,
    'size_mismatch' => NativeMediaFailure.sizeMismatch,
    'no_app' => NativeMediaFailure.noAppToOpen,
    'not_found' => NativeMediaFailure.notFound,
    _ => NativeMediaFailure.io,
  };

  @override
  Future<SavedMedia> saveToDownloads({
    required String tempPath,
    required String displayName,
    required String mimeType,
    required int expectedBytes,
  }) async {
    final map = await _invoke<Map<Object?, Object?>>('saveToDownloads', {
      'tempPath': tempPath,
      'displayName': displayName,
      'mimeType': mimeType,
      'expectedBytes': expectedBytes,
    });
    final uri = map['uri'];
    final name = map['displayName'];
    final size = map['sizeBytes'];
    if (uri is! String || name is! String || size is! num) {
      throw const NativeMediaException(
        NativeMediaFailure.io,
        'bad save result',
      );
    }
    return SavedMedia(uri: uri, displayName: name, sizeBytes: size.toInt());
  }

  @override
  Future<bool> exists(String uri) => _invoke<bool>('exists', {'uri': uri});

  @override
  Future<void> open(String uri, String mimeType) async {
    await _invoke<bool>('open', {'uri': uri, 'mimeType': mimeType});
  }

  @override
  Future<void> share(String uri, String mimeType, String title) async {
    await _invoke<bool>('share', {
      'uri': uri,
      'mimeType': mimeType,
      'title': title,
    });
  }

  @override
  Future<void> startTransfer(String text) async {
    await _invoke<bool>('startTransfer', {'text': text});
  }

  @override
  Future<void> updateTransfer(int percent, String text) async {
    await _invoke<bool>('updateTransfer', {'percent': percent, 'text': text});
  }

  @override
  Future<void> stopTransfer() async {
    await _invoke<bool>('stopTransfer');
  }

  @override
  Future<bool> requestNotificationPermission() =>
      _invoke<bool>('requestNotificationPermission');

  @override
  Future<String> appVersion() => _invoke<String>('appVersion');
}
