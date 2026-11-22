import 'dart:async';

import 'package:flutter/services.dart';

enum InstallStartKind { started, needsPermission, rejected }

/// What happened when the downloaded file was handed to Android. [reason] (for `rejected`) is a
/// code such as `signature_mismatch`, `not_newer` or `incompatible`.
class InstallStart {
  const InstallStart(this.kind, {this.reason});

  final InstallStartKind kind;
  final String? reason;
}

/// How Android's installer finished, reported after [InstallStartKind.started]:
/// `success`, `aborted` (the person said no) or `failed`.
class InstallResult {
  const InstallResult(this.status, {this.message});

  final String status;
  final String? message;
}

/// The Android-only part of updating the app: a place to save the file, Android's Package
/// Installer (which always asks the person to confirm), and opening the release page by hand.
abstract class ApkInstaller {
  /// An empty folder the update may be saved into.
  Future<String> downloadDir();

  Future<InstallStart> install(String path);

  Future<void> openLink(Uri url);

  Stream<InstallResult> get results;
}

class MethodChannelApkInstaller implements ApkInstaller {
  MethodChannelApkInstaller() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const MethodChannel _channel = MethodChannel(
    'com.namao.flutter/updates',
  );

  final StreamController<InstallResult> _results =
      StreamController<InstallResult>.broadcast();

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'installResult' && call.arguments is Map) {
      final args = call.arguments as Map;
      _results.add(
        InstallResult(
          (args['status'] as String?) ?? 'failed',
          message: args['message'] as String?,
        ),
      );
    }
    return null;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _results.close();
  }

  @override
  Stream<InstallResult> get results => _results.stream;

  @override
  Future<String> downloadDir() async {
    final path = await _channel.invokeMethod<String>('downloadDir');
    if (path == null) throw PlatformException(code: 'update_error');
    return path;
  }

  @override
  Future<InstallStart> install(String path) async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>('install', {
      'path': path,
    });
    return switch (map?['status']) {
      'started' => const InstallStart(InstallStartKind.started),
      'needs_permission' => const InstallStart(
        InstallStartKind.needsPermission,
      ),
      _ => InstallStart(
        InstallStartKind.rejected,
        reason: map?['reason'] as String?,
      ),
    };
  }

  @override
  Future<void> openLink(Uri url) async {
    await _channel.invokeMethod<bool>('openLink', {'url': url.toString()});
  }
}
