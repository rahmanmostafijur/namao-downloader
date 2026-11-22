import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/data/updates/apk_downloader.dart';
import 'package:namao_app/data/updates/app_release.dart';
import 'package:namao_app/data/updates/engine_update_source.dart';
import 'package:namao_app/data/updates/engine_updater.dart';
import 'package:namao_app/data/updates/https_get.dart';
import 'package:namao_app/data/updates/update_store.dart';
import 'package:namao_app/data/updates/versions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/update_fakes.dart';

const String _old = '2026.10.05';
const String _new = '2026.11.10';

EngineInfo _info({
  String? version = _old,
  bool auto = true,
  DateTime? checked,
  DateTime? attempted,
  bool updating = false,
}) => EngineInfo(
  version: version,
  autoUpdate: auto,
  lastCheck: checked,
  lastAttempt: attempted,
  updating: updating,
);

void main() {
  group('versions', () {
    test(
      'a newer downloader version wins; same, older and unreadable never do',
      () {
        expect(isNewerEngineVersion(_new, _old), isTrue);
        expect(isNewerEngineVersion(_old, _old), isFalse);
        expect(isNewerEngineVersion(_old, _new), isFalse);
        expect(isNewerEngineVersion('2026.11.10.1', _new), isTrue);
        expect(isNewerEngineVersion('garbage', _old), isFalse);
      },
    );

    test('an installed downloader that cannot be read is replaced', () {
      expect(isNewerEngineVersion(_new, null), isTrue);
      expect(isNewerEngineVersion(_new, 'garbage'), isTrue);
    });

    test('a downloader version stands for its release date', () {
      expect(engineVersionDate(_new), DateTime(2026, 11, 10));
      expect(engineVersionDate('nope'), isNull);
    });

    test('app versions compare numerically, not as text', () {
      expect(isNewerAppVersion('v1.10.0', '1.9.9'), isTrue);
      expect(isNewerAppVersion('v1.1.0', '1.1.0'), isFalse);
      expect(isNewerAppVersion('v1.0.9', '1.1.0'), isFalse);
      expect(isNewerAppVersion('nightly', '1.1.0'), isFalse);
      expect(appVersionName('v1.2.3+4'), '1.2.3');
      expect(appVersionName('latest'), isNull);
    });

    test('the installed app version is read from "name (code)"', () {
      expect(parseInstalledApp('1.1.0 (3)'), (name: '1.1.0', code: 3));
      expect(parseInstalledApp('unknown'), isNull);
      expect(parseInstalledApp(null), isNull);
    });
  });

  group('EngineUpdater.update', () {
    test('detects the installed version, then finds nothing newer', () async {
      final source = FakeEngineUpdateSource(
        info: _info(version: _new),
        latest: _new,
      );

      final outcome = await EngineUpdater(source).update();

      expect(source.calls.first, 'info');
      expect(outcome.kind, EngineUpdateKind.upToDate);
      expect(outcome.version, _new);
    });

    test('already up to date installs nothing and records the check', () async {
      final source = FakeEngineUpdateSource(
        info: _info(version: _new),
        latest: _new,
      );

      await EngineUpdater(source).update();

      expect(source.calls, ['info', 'latest', 'checked']);
    });

    test(
      'an installed version newer than upstream is never replaced',
      () async {
        final source = FakeEngineUpdateSource(
          info: _info(version: _new),
          latest: _old,
        );

        final outcome = await EngineUpdater(source).update();

        expect(outcome.kind, EngineUpdateKind.upToDate);
        expect(source.calls.any((c) => c.startsWith('install')), isFalse);
      },
    );

    test('a newer stable version is installed and reported', () async {
      final source = FakeEngineUpdateSource(info: _info(), latest: _new);

      final outcome = await EngineUpdater(source).update();

      expect(source.calls, ['info', 'latest', 'install $_new']);
      expect(outcome.kind, EngineUpdateKind.updated);
      expect(outcome.version, _new);
      expect(outcome.previousVersion, _old);
      expect(source.current.version, _new);
    });

    test('no network: reported as offline, nothing installed', () async {
      final source = FakeEngineUpdateSource(info: _info(), latest: _new)
        ..latestError = const EngineUpdateException('network', 'unreachable');

      final outcome = await EngineUpdater(source).update();

      expect(outcome.kind, EngineUpdateKind.offline);
      expect(source.calls.any((c) => c.startsWith('install')), isFalse);
    });

    test(
      'a download that drops mid-way is offline, and the working version stays',
      () async {
        final source = FakeEngineUpdateSource(info: _info(), latest: _new)
          ..installError = const EngineUpdateException('network', 'reset');

        final outcome = await EngineUpdater(source).update();

        expect(outcome.kind, EngineUpdateKind.offline);
        expect(source.current.version, _old);
      },
    );

    test(
      'an update that fails verification leaves the previous version in place',
      () async {
        final source = FakeEngineUpdateSource(info: _info(), latest: _new)
          ..installError = const EngineUpdateException(
            'verify_failed',
            'bad checksum',
          );

        final outcome = await EngineUpdater(source).update();

        expect(outcome.kind, EngineUpdateKind.failed);
        expect(source.current.version, _old);
      },
    );

    test('the engine being in use is reported as busy', () async {
      final source = FakeEngineUpdateSource(info: _info(), latest: _new)
        ..installError = const EngineUpdateException('busy', 'in use');

      expect(
        (await EngineUpdater(source).update()).kind,
        EngineUpdateKind.busy,
      );
    });

    test('an update that is already running is not started twice', () async {
      final source = FakeEngineUpdateSource(info: _info(updating: true));

      final outcome = await EngineUpdater(source).update();

      expect(outcome.kind, EngineUpdateKind.busy);
      expect(source.calls, ['info']);
    });

    test('a platform without the engine reports unavailable', () async {
      final source = FakeEngineUpdateSource(info: _info())
        ..latestError = const EngineUpdateException('unavailable', 'no engine');

      expect(
        (await EngineUpdater(source).update()).kind,
        EngineUpdateKind.unavailable,
      );
    });
  });

  group('EngineUpdater.isAutoCheckDue', () {
    final now = DateTime(2026, 11, 22, 12);

    test('never checked: due', () {
      expect(EngineUpdater.isAutoCheckDue(_info(), now), isTrue);
    });

    test('checked within a day: not due; after a day: due', () {
      expect(
        EngineUpdater.isAutoCheckDue(
          _info(checked: now.subtract(const Duration(hours: 23))),
          now,
        ),
        isFalse,
      );
      expect(
        EngineUpdater.isAutoCheckDue(
          _info(checked: now.subtract(const Duration(hours: 25))),
          now,
        ),
        isTrue,
      );
    });

    test('switched off: never due', () {
      expect(EngineUpdater.isAutoCheckDue(_info(auto: false), now), isFalse);
    });

    test(
      'a failed attempt is retried after a few hours, not on every launch',
      () {
        expect(
          EngineUpdater.isAutoCheckDue(
            _info(attempted: now.subtract(const Duration(hours: 1))),
            now,
          ),
          isFalse,
        );
        expect(
          EngineUpdater.isAutoCheckDue(
            _info(attempted: now.subtract(const Duration(hours: 4))),
            now,
          ),
          isTrue,
        );
      },
    );
  });

  group('GithubReleaseSource', () {
    const apkUrl =
        'https://github.com/o/r/releases/download/v1.2.0/namao-android.apk';
    const sumUrl = '$apkUrl.sha256';
    final sha = 'ab' * 32;

    String json({
      String tag = 'v1.2.0',
      bool draft = false,
      bool prerelease = false,
      String body = '- Faster downloads',
      List<Map<String, Object?>>? assets,
    }) => jsonEncode({
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'body': body,
      'html_url': 'https://github.com/o/r/releases/tag/$tag',
      'assets':
          assets ??
          [
            {
              'name': 'namao-android.apk',
              'browser_download_url': apkUrl,
              'size': 123,
            },
            {
              'name': 'namao-android.apk.sha256',
              'browser_download_url': sumUrl,
            },
          ],
    });

    GithubReleaseSource sourceFor(
      String latest, [
      Map<String, String> extra = const {},
    ]) => GithubReleaseSource(
      fetch: (uri) async {
        if (uri == GithubReleaseSource.latestUri) return latest;
        final answer = extra[uri.toString()];
        if (answer == null) {
          throw AppUpdateException('network', 'no route to $uri');
        }
        return answer;
      },
    );

    test(
      'reads the version, notes, size, download link and published checksum',
      () async {
        final release = await sourceFor(json(), {
          sumUrl: '${sha.toUpperCase()}  namao-android.apk\n',
        }).latest();

        expect(release!.versionName, '1.2.0');
        expect(release.notes, '• Faster downloads');
        expect(release.sizeBytes, 123);
        expect(release.apkUrl.toString(), apkUrl);
        expect(release.sha256, sha);
      },
    );

    test(
      'uses the digest GitHub records when no checksum file is published',
      () async {
        final release = await sourceFor(
          json(
            assets: [
              {
                'name': 'namao-android.apk',
                'browser_download_url': apkUrl,
                'digest': 'sha256:$sha',
              },
            ],
          ),
        ).latest();

        expect(release!.sha256, sha);
      },
    );

    test(
      'a release with no checksum at all is still offered, unverified by hash',
      () async {
        final release = await sourceFor(
          json(
            assets: [
              {'name': 'namao-android.apk', 'browser_download_url': apkUrl},
            ],
          ),
        ).latest();

        expect(release!.sha256, isNull);
      },
    );

    test('a checksum file that cannot be read stops the update instead of skipping the check', () {
      expect(
        sourceFor(json()).latest(), // the checksum URL has no route
        throwsA(isA<AppUpdateException>()),
      );
      expect(
        sourceFor(json(), {sumUrl: 'not a checksum'}).latest(),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('drafts, pre-releases and non-version tags are not updates', () async {
      expect(await sourceFor(json(draft: true)).latest(), isNull);
      expect(await sourceFor(json(prerelease: true)).latest(), isNull);
      expect(await sourceFor(json(tag: 'nightly')).latest(), isNull);
    });

    test('a release without the APK, or with one on another host, is not an update', () async {
      expect(await sourceFor(json(assets: [])).latest(), isNull);
      expect(
        await sourceFor(
          json(
            assets: [
              {
                'name': 'namao-android.apk',
                'browser_download_url':
                    'https://evil.example/namao-android.apk',
              },
            ],
          ),
        ).latest(),
        isNull,
      );
      expect(
        await sourceFor(
          json(
            assets: [
              {
                'name': 'namao-android.apk',
                'browser_download_url':
                    'http://github.com/o/r/namao-android.apk',
              },
            ],
          ),
        ).latest(),
        isNull,
      );
    });

    test(
      'an answer that is not release information is reported as unreadable',
      () {
        expect(
          sourceFor('<html>rate limited</html>').latest(),
          throwsA(
            isA<AppUpdateException>().having(
              (e) => e.code,
              'code',
              'unreadable',
            ),
          ),
        );
      },
    );

    test('release notes keep what is new, and drop headings, the download table and tech names', () {
      const body = '''
## Namao for Android 1.2.0

- **Faster** starts, see [details](https://example.com)
- The downloader (yt-dlp) is refreshed from the official site
- Better `error` messages

## Download and verify

| | |
| File | namao-android.apk |
''';

      expect(
        summarizeNotes(body),
        '• Faster starts, see details\n• Better error messages',
      );
      expect(summarizeNotes('- yt-dlp only'), '');
      expect(
        summarizeNotes('- ${'word ' * 200}', maxChars: 40).endsWith('…'),
        isTrue,
      );
    });
  });

  group('ApkDownloader', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('namao_apk_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    final bytes = List<int>.generate(20, (i) => i);
    final goodSha = crypto.sha256.convert(bytes).toString();

    test(
      'returns the file once its size and SHA-256 match, and reports progress',
      () async {
        final progress = <double?>[];

        final file = await ApkDownloader(FakeApkByteSource(bytes)).download(
          makeRelease(sha256: goodSha, sizeBytes: bytes.length),
          dir,
          onProgress: progress.add,
        );

        expect(await file.readAsBytes(), bytes);
        expect(file.path.endsWith('.apk'), isTrue);
        expect(
          dir.listSync().length,
          1,
          reason: 'no partial file is left behind',
        );
        expect(progress.last, 1.0);
      },
    );

    test(
      'a download with the wrong checksum is deleted and never returned',
      () async {
        await expectLater(
          ApkDownloader(FakeApkByteSource(bytes))
              .download(makeRelease(sha256: 'cd' * 32), dir),
          throwsA(isA<ApkVerificationException>()),
        );
        expect(dir.listSync(), isEmpty);
      },
    );

    test('the checksum comparison ignores letter case', () async {
      final file = File('${dir.path}/x')..writeAsBytesSync(bytes);

      expect(await fileMatchesSha256(file, goodSha.toUpperCase()), isTrue);
      expect(await fileMatchesSha256(file, 'cd' * 32), isFalse);
    });

    test('a truncated download is rejected even without a checksum', () async {
      await expectLater(
        ApkDownloader(FakeApkByteSource(bytes))
            .download(makeRelease(sizeBytes: bytes.length + 5), dir),
        throwsA(isA<ApkVerificationException>()),
      );
      expect(dir.listSync(), isEmpty);
    });

    test(
      'a release that publishes no checksum is accepted on size alone',
      () async {
        final file = await ApkDownloader(FakeApkByteSource(bytes))
            .download(makeRelease(sizeBytes: bytes.length), dir);

        expect(file.existsSync(), isTrue);
      },
    );

    test(
      'cancelling stops the download and removes the partial file',
      () async {
        var chunks = 0;

        await expectLater(
          ApkDownloader(FakeApkByteSource(bytes)).download(
            makeRelease(),
            dir,
            onProgress: (_) => chunks++,
            isCancelled: () => chunks >= 1,
          ),
          throwsA(isA<ApkDownloadCancelled>()),
        );
        expect(dir.listSync(), isEmpty);
      },
    );

    test('a connection failure leaves nothing behind', () async {
      final source = FakeApkByteSource(bytes)
        ..error = const AppUpdateException('network', 'unreachable');

      await expectLater(
        ApkDownloader(source).download(makeRelease(), dir),
        throwsA(isA<AppUpdateException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  });

  group('trusted update addresses', () {
    test('only HTTPS to GitHub hosts', () {
      expect(isTrustedUpdateUri(Uri.parse('https://github.com/a/b')), isTrue);
      expect(
        isTrustedUpdateUri(
          Uri.parse('https://objects.githubusercontent.com/x'),
        ),
        isTrue,
      );
      expect(isTrustedUpdateUri(Uri.parse('http://github.com/a')), isFalse);
      expect(
        isTrustedUpdateUri(Uri.parse('https://evilgithub.com/a')),
        isFalse,
      );
      expect(
        isTrustedUpdateUri(Uri.parse('https://github.com.evil.io/a')),
        isFalse,
      );
    });
  });

  group('UpdateStore', () {
    late UpdateStore store;
    final now = DateTime(2026, 11, 22);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = UpdateStore(await SharedPreferences.getInstance());
    });

    test('a dismissed version stays quiet until its reminder date', () async {
      await store.snooze('1.2.0', now.add(const Duration(days: 7)));

      expect(
        store.isSnoozed('1.2.0', now.add(const Duration(days: 6))),
        isTrue,
      );
      expect(
        store.isSnoozed('1.2.0', now.add(const Duration(days: 8))),
        isFalse,
      );
    });

    test('a newer version is never silenced by an older dismissal', () async {
      await store.snooze('1.2.0', now.add(const Duration(days: 7)));

      expect(store.isSnoozed('1.3.0', now), isFalse);
    });

    test('remembers when the last check happened', () async {
      expect(store.lastAppCheck, isNull);

      await store.recordAppCheck(now);

      expect(store.lastAppCheck, now);
    });
  });
}
