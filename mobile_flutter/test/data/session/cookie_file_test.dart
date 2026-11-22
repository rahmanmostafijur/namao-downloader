import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/session/cookie_file.dart';

/// Synthetic cookies only: the values are obviously fake and belong to no account.
String line(
  String domain,
  String name,
  String value, {
  int expiry = 2000000000, // 2033
  bool httpOnly = false,
}) =>
    '${httpOnly ? '#HttpOnly_' : ''}$domain\tTRUE\t/\tTRUE\t$expiry\t$name\t$value';

final DateTime now = DateTime.utc(2026, 11, 23);

CookieProblem problemOf(String text) {
  try {
    parseInstagramCookies(text, now: now);
  } on CookieFileException catch (e) {
    return e.problem;
  }
  fail('expected the file to be refused');
}

void main() {
  test('a valid export is accepted and reduced to Instagram cookies only', () {
    final file = [
      '# Netscape HTTP Cookie File',
      line('.google.com', 'SID', 'FAKE-google'),
      line('.facebook.com', 'c_user', 'FAKE-facebook'),
      line('.instagram.com', 'csrftoken', 'FAKE-csrf'),
      line('.instagram.com', 'sessionid', 'FAKE-session', httpOnly: true),
      line('www.instagram.com', 'ig_did', 'FAKE-did'),
      '',
    ].join('\n');
    final result = parseInstagramCookies(file, now: now);
    expect(result.cookieCount, 3);
    expect(result.text, startsWith('# Netscape HTTP Cookie File\n'));
    expect(result.text, contains('FAKE-session'));
    expect(result.text, isNot(contains('FAKE-google')));
    expect(result.text, isNot(contains('FAKE-facebook')));
    expect(
      result.expiresAt,
      DateTime.fromMillisecondsSinceEpoch(2000000000 * 1000, isUtc: true),
    );
  });

  test('a file without the header, with Windows line endings and a BOM, still works', () {
    final file =
        '﻿${line('.instagram.com', 'sessionid', 'FAKE')}\r\n'
        '${line('.instagram.com', 'csrftoken', 'FAKE')}\r\n';
    final result = parseInstagramCookies(file, now: now);
    expect(result.cookieCount, 2);
    expect(result.text, startsWith('# Netscape HTTP Cookie File\n'));
    expect(result.text, isNot(contains('\r')));
  });

  test('a session cookie with no expiry date is accepted', () {
    final result = parseInstagramCookies(
      line('.instagram.com', 'sessionid', 'FAKE', expiry: 0),
      now: now,
    );
    expect(result.expiresAt, isNull);
  });

  test('an expired login cookie is refused with its own reason', () {
    expect(
      problemOf(
        line('.instagram.com', 'sessionid', 'FAKE', expiry: 1600000000),
      ),
      CookieProblem.expired,
    );
  });

  test('files that are not cookies.txt are refused', () {
    expect(problemOf(''), CookieProblem.empty);
    expect(problemOf('   \n\n'), CookieProblem.empty);
    expect(problemOf('hello world'), CookieProblem.notCookieFile);
    expect(problemOf('{"cookies": []}'), CookieProblem.notCookieFile);
    expect(problemOf('a\tb\tc'), CookieProblem.notCookieFile);
    expect(
      problemOf('.instagram.com TRUE / TRUE 2000000000 sessionid FAKE'),
      CookieProblem.notCookieFile,
      reason: 'space-separated fields are not Netscape format',
    );
    expect(
      problemOf('.instagram.com\tTRUE\t/\tTRUE\tsoon\tsessionid\tFAKE'),
      CookieProblem.notCookieFile,
      reason: 'the expiry must be a number',
    );
  });

  test('a valid cookie file from other sites only is refused', () {
    expect(
      problemOf(line('.google.com', 'SID', 'FAKE')),
      CookieProblem.noInstagram,
    );
  });

  test('Instagram cookies without a login cookie are refused', () {
    expect(
      problemOf(line('.instagram.com', 'csrftoken', 'FAKE')),
      CookieProblem.noSession,
    );
    expect(
      problemOf(line('.instagram.com', 'sessionid', '')),
      CookieProblem.noSession,
      reason: 'an empty login cookie is logged out',
    );
  });

  test('look-alike domains are not Instagram', () {
    expect(
      problemOf(line('.instagram.com.evil.example', 'sessionid', 'FAKE')),
      CookieProblem.noInstagram,
    );
    expect(
      problemOf(line('.notinstagram.com', 'sessionid', 'FAKE')),
      CookieProblem.noInstagram,
    );
  });

  test('an oversized file is refused before it is parsed', () {
    expect(problemOf('x' * (maxCookieFileChars + 1)), CookieProblem.tooLarge);
  });

  test('error messages never contain the file contents', () {
    const secret = 'SUPER-SECRET-VALUE';
    for (final text in [
      line('.google.com', 'SID', secret),
      line('.instagram.com', 'csrftoken', secret),
      '$secret is not a cookie file',
      line('.instagram.com', 'sessionid', secret, expiry: 1600000000),
    ]) {
      try {
        parseInstagramCookies(text, now: now);
        fail('expected a refusal');
      } on CookieFileException catch (e) {
        expect(e.message, isNot(contains(secret)));
        expect(e.toString(), isNot(contains(secret)));
      }
    }
  });
}
