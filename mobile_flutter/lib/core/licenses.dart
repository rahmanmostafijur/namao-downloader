import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds the notices for the downloader components bundled in the app (they are native code, so
/// Flutter's own license collection does not know about them) to the Open-source licenses page.
void registerEngineLicenses() {
  LicenseRegistry.addLicense(() async* {
    final notices = await rootBundle.loadString('assets/licenses/engine_notices.txt');
    final gpl = await rootBundle.loadString('assets/licenses/GPL-3.0.txt');
    yield LicenseEntryWithLineBreaks(
      ['yt-dlp', 'FFmpeg', 'Python', 'QuickJS', 'youtubedl-android'],
      notices,
    );
    yield LicenseEntryWithLineBreaks(['youtubedl-android'], gpl);
  });
}
