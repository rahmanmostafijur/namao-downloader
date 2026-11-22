import 'package:flutter/services.dart';

import 'cookie_file.dart';

/// What is known about the stored session. The cookies themselves never leave the native side.
class SessionInfo {
  const SessionInfo({this.savedAt, this.expiresAt});

  final DateTime? savedAt;

  /// When the login cookie stops working; null when it was a session cookie with no end date.
  final DateTime? expiresAt;

  bool isExpired(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);
}

/// Picking, keeping and removing the user's own Instagram cookies.txt.
abstract class InstagramSessionStore {
  /// Null when no session is stored.
  Future<SessionInfo?> info();

  /// Opens Android's file picker and returns the chosen file's text; null when cancelled.
  /// Throws [CookieFileException] for a file that is too large to be a cookies.txt.
  Future<String?> pickFile();

  /// Keeps [cookies] encrypted on this phone, replacing any earlier session.
  Future<void> save(InstagramCookies cookies);

  /// Deletes the session and its encryption key.
  Future<void> remove();
}

/// The storage failed for a reason that is not about the file (no picker app, keystore trouble).
class SessionStoreException implements Exception {
  const SessionStoreException(this.code);

  final String code;

  @override
  String toString() => 'SessionStoreException($code)';
}

class MethodChannelInstagramSessionStore implements InstagramSessionStore {
  const MethodChannelInstagramSessionStore();

  static const MethodChannel _channel = MethodChannel(
    'com.namao.flutter/session',
  );

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      if (error.code == 'too_large') {
        throw const CookieFileException(CookieProblem.tooLarge);
      }
      throw SessionStoreException(
        error.code,
      ); // never the message: it could echo content
    } on MissingPluginException {
      throw const SessionStoreException('unavailable');
    }
  }

  DateTime? _fromEpoch(Object? seconds) => seconds is num && seconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000)
      : null;

  @override
  Future<SessionInfo?> info() async {
    final map = await _invoke<Map<Object?, Object?>>('info');
    if (map == null) return null;
    return SessionInfo(
      savedAt: _fromEpoch(map['savedAt']),
      expiresAt: _fromEpoch(map['expiresAt']),
    );
  }

  @override
  Future<String?> pickFile() => _invoke<String>('pick');

  @override
  Future<void> save(InstagramCookies cookies) async {
    await _invoke<bool>('save', {
      'text': cookies.text,
      'expiresAt': cookies.expiresAt == null
          ? null
          : cookies.expiresAt!.millisecondsSinceEpoch ~/ 1000,
    });
  }

  @override
  Future<void> remove() async {
    await _invoke<bool>('remove');
  }
}
