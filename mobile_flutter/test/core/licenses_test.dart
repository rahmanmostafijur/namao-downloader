import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the bundled downloader components are credited with their licenses',
    () async {
      registerEngineLicenses();

      final entries = await LicenseRegistry.licenses.toList();
      final packages = {for (final e in entries) ...e.packages};
      final text = entries
          .map((e) => e.paragraphs.map((p) => p.text).join('\n'))
          .join('\n');

      expect(
        packages,
        containsAll([
          'yt-dlp',
          'FFmpeg',
          'Python',
          'QuickJS',
          'youtubedl-android',
        ]),
      );
      expect(text, contains('GNU GENERAL PUBLIC LICENSE'));
      expect(text, contains('Version 3, 29 June 2007'));
      expect(text, contains('https://github.com/yausername/youtubedl-android'));
      expect(text, contains('The Unlicense'));
    },
  );
}
