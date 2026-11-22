import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:namao_app/core/models/video_metadata.dart';
import 'package:namao_app/data/engine/format_builder.dart';

String lines(Map<String, Object?> info, List<Map<String, Object?>> formats) =>
    '${jsonEncode(info)}\n${jsonEncode(formats)}\n';

Map<String, Object?> video(
  int height, {
  double tbr = 1000,
  double? fps = 30,
  String vcodec = 'avc1',
  String acodec = 'none',
  int? filesize,
}) => {
  'format_id': 'v$height-$tbr',
  'height': height,
  'fps': fps,
  'vcodec': vcodec,
  'acodec': acodec,
  'tbr': tbr,
  'filesize': filesize,
};

Map<String, Object?> audio({double abr = 128, int? filesize}) => {
  'format_id': 'a$abr',
  'vcodec': 'none',
  'acodec': 'mp4a',
  'abr': abr,
  'filesize': filesize,
};

RawInfo parse(List<Map<String, Object?>> formats, {int duration = 100}) {
  final info = RawInfo.parse(
    lines({'title': 'T', 'uploader': 'U', 'duration': duration}, formats),
  );
  expect(info, isNotNull);
  return info!;
}

void main() {
  group('buildFormatOptions', () {
    test(
      'lists only offered heights, highest first, marking only the top one',
      () {
        final options = buildFormatOptions(
          parse([video(720), video(1080), video(1080, tbr: 500), audio()]),
        );
        expect(options.map((o) => o.id), ['1080', '720', 'audio']);
        expect(options[0].note, 'Highest available');
        expect(options[1].note, '');
        expect(options[0].kind, FormatKind.video);
        expect(options[0].height, 1080);
      },
    );

    test('never invents a quality the source did not list', () {
      final options = buildFormatOptions(parse([video(480), audio()]));
      expect(options.map((o) => o.id), ['480', 'audio']);
    });

    test(
      'per height, prefers the higher frame rate, then the higher bitrate',
      () {
        final options = buildFormatOptions(
          parse([
            video(1080, tbr: 5000, fps: 30, filesize: 111),
            video(1080, tbr: 3000, fps: 60, filesize: 222),
            video(1080, tbr: 4000, fps: 60, filesize: 333),
          ]),
        );
        expect(options.first.label, '1080p60');
        expect(
          options.first.sizeBytes,
          333,
          reason: '60fps with the higher bitrate',
        );
      },
    );

    test('frame rate is only shown above 30', () {
      expect(
        buildFormatOptions(parse([video(720, fps: 30)])).first.label,
        '720p',
      );
      expect(
        buildFormatOptions(parse([video(720, fps: 24)])).first.label,
        '720p',
      );
      expect(
        buildFormatOptions(parse([video(720, fps: 60)])).first.label,
        '720p60',
      );
    });

    test('a stream without audio needs a merge; one with audio does not', () {
      final merged = buildFormatOptions(parse([video(720), audio()])).first;
      final muxed = buildFormatOptions(parse([video(720, acodec: 'mp4a')]))
          .first;
      expect(merged.needsMerge, isTrue);
      expect(muxed.needsMerge, isFalse);
    });

    test('a reported size is exact; merge adds the best audio stream', () {
      final options = buildFormatOptions(
        parse([
          video(1080, filesize: 1000),
          audio(abr: 128, filesize: 200),
          audio(abr: 64, filesize: 50),
        ]),
      );
      expect(options.first.sizeBytes, 1200);
      expect(options.first.sizeEstimated, isFalse);
      expect(
        options.last.sizeBytes,
        200,
        reason: 'audio-only uses the best audio',
      );
    });

    test(
      'without a reported size the size is estimated from bitrate and duration',
      () {
        final options = buildFormatOptions(
          parse([video(720, tbr: 800)], duration: 10),
        );
        expect(options.first.sizeBytes, 800 * 125 * 10);
        expect(options.first.sizeEstimated, isTrue);
      },
    );

    test('an unknown size stays unknown rather than 0', () {
      final options = buildFormatOptions(
        parse([video(720, tbr: 0)], duration: 0),
      );
      expect(options.first.sizeBytes, isNull);
    });

    test('formats with neither video nor audio (storyboards) are ignored', () {
      final options = buildFormatOptions(
        parse([
          {
            'format_id': 'sb0',
            'height': 180,
            'vcodec': 'none',
            'acodec': 'none',
          },
          video(360),
        ]),
      );
      expect(options.map((o) => o.id), ['360', 'audio']);
    });

    test('video without heights becomes one "Best available" option', () {
      final options = buildFormatOptions(
        parse([
          {'format_id': 'x', 'vcodec': 'avc1', 'acodec': 'mp4a', 'tbr': 500},
        ]),
      );
      expect(options.map((o) => o.id), ['best', 'audio']);
      expect(options.first.label, 'Best available');
    });

    test('an audio-only source offers only audio', () {
      final options = buildFormatOptions(parse([audio()]));
      expect(options.map((o) => o.id), ['audio']);
      expect(options.single.note, 'MP3');
    });

    test('nothing downloadable gives no options', () {
      expect(buildFormatOptions(parse([])), isEmpty);
    });
  });

  group('RawInfo.parse', () {
    test('reads the facts and the format list from the two lines', () {
      final info = RawInfo.parse(
        lines(
          {
            'title': 'Big Buck Bunny',
            'channel': 'Blender',
            'duration': 635.4,
            'thumbnail': 'https://i.ytimg.com/vi/x/max.jpg',
            'is_live': false,
            'live_status': 'not_live',
          },
          [video(720)],
        ),
      )!;
      expect(info.title, 'Big Buck Bunny');
      expect(
        info.uploader,
        'Blender',
        reason: 'channel when there is no uploader',
      );
      expect(info.durationSeconds, 635);
      expect(info.thumbnail, 'https://i.ytimg.com/vi/x/max.jpg');
      expect(info.isLive, isFalse);
      expect(info.formats, hasLength(1));
    });

    test('live and upcoming streams are flagged', () {
      for (final status in ['is_live', 'is_upcoming']) {
        final info = RawInfo.parse(
          lines({'title': 'x', 'live_status': status}, [video(720)]),
        )!;
        expect(info.isLive, isTrue, reason: status);
      }
      expect(
        RawInfo.parse(lines({'title': 'x', 'is_live': true}, []))!.isLive,
        isTrue,
      );
    });

    test('only plain https thumbnails are accepted', () {
      for (final bad in [
        'http://x/y.jpg',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'https://a b/c',
      ]) {
        final info = RawInfo.parse(
          lines({'title': 'x', 'thumbnail': bad}, []),
        )!;
        expect(info.thumbnail, isNull, reason: bad);
      }
    });

    test('a missing title becomes "Untitled"', () {
      expect(RawInfo.parse(lines({}, []))!.title, 'Untitled');
    });

    test('output that is not the two expected JSON lines is rejected', () {
      expect(RawInfo.parse(''), isNull);
      expect(RawInfo.parse('{"title":"x"}'), isNull, reason: 'one line only');
      expect(RawInfo.parse('not json\nalso not json'), isNull);
      expect(
        RawInfo.parse('[]\n[]'),
        isNull,
        reason: 'the first line must be an object',
      );
      expect(
        RawInfo.parse('{}\n{}'),
        isNull,
        reason: 'the second line must be a list',
      );
    });

    test('blank lines around the output are tolerated', () {
      expect(RawInfo.parse('\n${lines({'title': 'x'}, [])}\n'), isNotNull);
    });
  });
}
