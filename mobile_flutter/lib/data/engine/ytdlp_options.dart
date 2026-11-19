import '../../core/url_tools.dart';

/// Single-video extractors only (same list as the Python server): playlists, channels and the
/// generic "fetch any URL" extractor are never reachable. Regexes over yt-dlp extractor keys.
const List<String> _allowedExtractors = [
  r'^Youtube$', r'^YoutubeYtBe$', r'^YoutubeClip$',
  r'^Facebook$', r'^FacebookReel$', r'^FacebookRedirectURL$', r'^FacebookPluginsVideo$',
  r'^TikTok$', r'^TikTokVM$',
  r'^Instagram$', r'^InstagramIOS$',
  r'^Twitter$',
];

/// Preference order used for every download, the same as the server: resolution, frame rate,
/// then the codecs every phone plays.
const String _formatSort = 'res,fps,vcodec:h264,acodec:aac';

/// Options shared by reading a link and downloading it.
List<String> _commonOptions({required bool allowAnyLink}) => [
  '--no-playlist',
  '--playlist-items', '1',
  '--no-warnings',
  '--socket-timeout', '30',
  '--retries', '3',
  '--fragment-retries', '3',
  '--extractor-retries', '2',
  '--concurrent-fragments', '4',
  if (!allowAnyLink) ...['--use-extractors', _allowedExtractors.join(',')],
];

/// The two lines the app reads from a link: the video's facts, then its format list.
/// Printing only the needed fields keeps a YouTube answer at a few KB instead of megabytes.
const String _infoTemplate =
    '%(.{id,title,uploader,channel,duration,thumbnail,is_live,live_status})j';
const String _formatsTemplate =
    '%(formats.:.{format_id,height,width,fps,vcodec,acodec,ext,tbr,abr,filesize,filesize_approx})j';

List<String> metadataOptions({bool allowAnyLink = kAllowAnyLink}) => [
  ..._commonOptions(allowAnyLink: allowAnyLink),
  '--skip-download',
  '-O', _infoTemplate,
  '-O', _formatsTemplate,
];

/// What a user chose, as the app's `quality` string: `best`, `audio` or an exact height.
enum QualityKind { best, audio, height }

class Quality {
  const Quality._(this.kind, this.height);

  final QualityKind kind;
  final int? height;

  static const int minHeight = 100;
  static const int maxHeight = 8640;

  /// Null for anything else: a malformed value is rejected, never guessed at.
  static Quality? tryParse(String value) {
    if (value == 'best') return const Quality._(QualityKind.best, null);
    if (value == 'audio') return const Quality._(QualityKind.audio, null);
    if (!RegExp(r'^[0-9]{3,4}$').hasMatch(value)) return null;
    final height = int.parse(value);
    if (height < minHeight || height > maxHeight) return null;
    return Quality._(QualityKind.height, height);
  }
}

/// Options for downloading [quality]. Heights are exact: the selected height or a failure,
/// never a quiet downgrade. Where files go and how progress is reported belong to the native
/// runner, which also reads that output.
List<String> downloadOptions(Quality quality, {bool allowAnyLink = kAllowAnyLink}) => [
  ..._commonOptions(allowAnyLink: allowAnyLink),
  '-S', _formatSort,
  ...switch (quality.kind) {
    QualityKind.audio => [
      '-f', 'bestaudio/best',
      '--extract-audio',
      '--audio-format', 'mp3',
      '--audio-quality', '192',
    ],
    QualityKind.best => ['-f', 'bv*+ba/b', '--merge-output-format', 'mp4/mkv'],
    QualityKind.height => [
      '-f', 'bv*[height=${quality.height}]+ba/b[height=${quality.height}]',
      '--merge-output-format', 'mp4/mkv',
    ],
  },
];
