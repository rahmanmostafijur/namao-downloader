import '../../data/updates/engine_update_source.dart';
import '../../data/updates/engine_updater.dart';
import '../../data/updates/versions.dart';
import 'app_update_controller.dart';

/// Everything people read about updates, in one place. None of it names the technology inside.

const String engineUpdatedMessage =
    "Namao's download support has been updated.\n"
    "We've improved download compatibility and reliability.";

/// What to say about how an attempt to refresh download support ended; null when nothing needs saying.
String? engineOutcomeMessage(EngineUpdateKind kind) => switch (kind) {
  EngineUpdateKind.updated => engineUpdatedMessage,
  EngineUpdateKind.upToDate => null,
  EngineUpdateKind.busy =>
    'Downloads are in progress. Try again when they finish.',
  EngineUpdateKind.offline =>
    "Couldn't check for updates. Check your internet connection and try again.",
  EngineUpdateKind.failed =>
    "The update didn't go through, so Namao kept the version that works.",
  EngineUpdateKind.unavailable => "Updates aren't available right now.",
};

String appFailureMessage(AppUpdateFailure failure) => switch (failure) {
  AppUpdateFailure.offline =>
    "Couldn't reach the update. Check your internet connection and try again.",
  AppUpdateFailure.unreadable =>
    "Couldn't check for a new version right now. Please try again later.",
  AppUpdateFailure.downloadsActive =>
    'A download is in progress. Finish or cancel it, then update.',
  AppUpdateFailure.corrupted => "The update didn't download properly, so it wasn't installed. Please try again.",
  AppUpdateFailure.needsPermission =>
    'Allow Namao to install updates in the settings screen that just opened, '
        'then come back and tap Update again.',
  AppUpdateFailure.rejected =>
    "This update can't be installed from inside the app. You can download it "
        'and open the file to install it yourself. Your downloads and history are kept.',
  AppUpdateFailure.installerFailed =>
    "Android couldn't finish the update. You can download it and open the "
        'file to install it yourself. Your downloads and history are kept.',
};

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatDate(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

/// The installed downloader, as people read it: the date it stands for, never a version string.
String engineLabel(EngineInfo? info) {
  if (info == null) return '…';
  final date = engineVersionDate(info.version);
  if (date != null) return 'Released ${formatDate(date)}';
  return info.version == null ? 'Getting ready…' : 'Installed';
}
