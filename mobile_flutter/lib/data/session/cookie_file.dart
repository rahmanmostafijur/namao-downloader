/// Why a chosen file cannot be used as an Instagram session.
enum CookieProblem {
  empty,
  tooLarge,
  notCookieFile,
  noInstagram,
  noSession,
  expired,
}

class CookieFileException implements Exception {
  const CookieFileException(this.problem);

  final CookieProblem problem;

  /// What the person is told. Never includes any of the file's contents.
  String get message => switch (problem) {
    CookieProblem.empty => 'That file is empty.',
    CookieProblem.tooLarge => 'That file is too large to be a cookies.txt.',
    CookieProblem.notCookieFile =>
      "That doesn't look like a cookies.txt file (Netscape format).",
    CookieProblem.noInstagram => 'That file has no Instagram cookies.',
    CookieProblem.noSession => 'That file has no Instagram login cookie. Export it while you are logged in to Instagram.',
    CookieProblem.expired => 'The Instagram session in that file has already expired. Export a fresh one.',
  };

  @override
  String toString() => 'CookieFileException(${problem.name})';
}

/// A cookies.txt reduced to what Namao may keep: Instagram's own cookies only.
class InstagramCookies {
  const InstagramCookies({
    required this.text,
    required this.cookieCount,
    this.expiresAt,
  });

  /// Netscape-format text, with the header yt-dlp requires. Holds secrets: never log it.
  final String text;
  final int cookieCount;

  /// When the login cookie stops working; null when the file does not say (a session cookie).
  final DateTime? expiresAt;
}

const int maxCookieFileChars = 1000000;
const String _netscapeHeader = '# Netscape HTTP Cookie File';
const String _httpOnlyPrefix = '#HttpOnly_';
const String _loginCookie = 'sessionid';

bool _isInstagramDomain(String domain) {
  final host = domain.startsWith('.') ? domain.substring(1) : domain;
  return host == 'instagram.com' || host.endsWith('.instagram.com');
}

/// Checks a user-supplied cookies.txt and keeps only its Instagram lines, so a browser export that
/// holds every site's cookies never leaves anything else behind in Namao. Throws
/// [CookieFileException] with the specific reason when the file cannot work. Nothing about the
/// file's contents is ever put in an error.
InstagramCookies parseInstagramCookies(String raw, {DateTime? now}) {
  if (raw.length > maxCookieFileChars) {
    throw const CookieFileException(CookieProblem.tooLarge);
  }
  final clock = now ?? DateTime.now();
  final lines = raw.replaceFirst('﻿', '').split(RegExp(r'\r?\n'));
  if (lines.every((l) => l.trim().isEmpty)) {
    throw const CookieFileException(CookieProblem.empty);
  }

  var wellFormed = 0;
  final kept = <String>[];
  DateTime? loginExpiry;
  var hasLogin = false;
  var loginExpired = false;

  for (final line in lines) {
    final isHttpOnly = line.startsWith(_httpOnlyPrefix);
    if (line.trim().isEmpty || (line.startsWith('#') && !isHttpOnly)) continue;
    final fields = line.split('\t');
    if (fields.length != 7) continue;
    final epoch = int.tryParse(fields[4]);
    if (epoch == null || fields[5].isEmpty) continue;
    wellFormed++;
    final domain =
        (isHttpOnly ? fields[0].substring(_httpOnlyPrefix.length) : fields[0])
            .toLowerCase();
    if (!_isInstagramDomain(domain)) continue;
    kept.add(line);
    if (fields[5] == _loginCookie && fields[6].isNotEmpty) {
      hasLogin = true;
      if (epoch > 0) {
        final expiry = DateTime.fromMillisecondsSinceEpoch(
          epoch * 1000,
          isUtc: true,
        );
        loginExpiry = expiry;
        if (!expiry.isAfter(clock.toUtc())) loginExpired = true;
      }
    }
  }

  if (wellFormed == 0) {
    throw const CookieFileException(CookieProblem.notCookieFile);
  }
  if (kept.isEmpty) throw const CookieFileException(CookieProblem.noInstagram);
  if (!hasLogin) throw const CookieFileException(CookieProblem.noSession);
  if (loginExpired) throw const CookieFileException(CookieProblem.expired);

  return InstagramCookies(
    text: '$_netscapeHeader\n${kept.join('\n')}\n',
    cookieCount: kept.length,
    expiresAt: loginExpiry,
  );
}
