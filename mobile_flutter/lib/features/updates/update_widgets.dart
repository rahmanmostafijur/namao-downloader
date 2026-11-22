import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/updates/distribution.dart';
import '../../data/updates/engine_updater.dart';
import '../../design/feedback.dart';
import '../../design/surfaces.dart';
import '../../design/tokens.dart';
import 'app_update_controller.dart';
import 'engine_update_controller.dart';
import 'update_messages.dart';

/// Settings > Updates: the app's version, the downloader's, the automatic-update switch, a manual
/// check, and the date of the last successful refresh. Absent from builds that do not self-update.
class UpdateSection extends ConsumerWidget {
  const UpdateSection({super.key, required this.appVersion});

  /// "1.1.0 (3)", or null while it is still being read.
  final String? appVersion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kUpdatesEnabled) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Updates'),
        _UpdateCard(appVersion: appVersion),
        const SizedBox(height: NamaoSpace.xl),
      ],
    );
  }
}

class _UpdateCard extends ConsumerStatefulWidget {
  const _UpdateCard({required this.appVersion});

  final String? appVersion;

  @override
  ConsumerState<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends ConsumerState<_UpdateCard> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(engineUpdateProvider.notifier).refresh());
  }

  void _checkNow() {
    ref.read(engineUpdateProvider.notifier).checkNow();
    ref.read(appUpdateProvider.notifier).checkNow();
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineUpdateProvider);
    final app = ref.watch(appUpdateProvider);
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final busy = engine.isBusy || app.isBusy;
    final lastUpdate = engine.info?.lastUpdate;
    final lines = _statusLines(engine, app);

    return NamaoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: 'Namao', value: widget.appVersion ?? '…'),
          const SizedBox(height: NamaoSpace.s),
          _InfoRow(label: 'Download support', value: engineLabel(engine.info)),
          const SizedBox(height: NamaoSpace.s),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: engine.info?.autoUpdate ?? true,
            onChanged: engine.info == null
                ? null
                : ref.read(engineUpdateProvider.notifier).setAutoUpdate,
            title: Text(
              'Update download support automatically',
              style: text.titleSmall,
            ),
            subtitle: Text(
              'Keeps downloads working when sites change.',
              style: text.bodySmall,
            ),
          ),
          if (engine.isBusy) ...[
            const SizedBox(height: NamaoSpace.s),
            LinearProgressIndicator(value: engine.progress),
            const SizedBox(height: NamaoSpace.s),
            Text(
              engine.phase == EngineUpdatePhase.updating
                  ? 'Updating download support…'
                  : 'Checking for updates…',
              style: text.bodySmall,
            ),
          ] else if (app.phase == AppUpdatePhase.checking) ...[
            const SizedBox(height: NamaoSpace.s),
            Text('Checking for updates…', style: text.bodySmall),
          ],
          for (final line in lines) ...[
            const SizedBox(height: NamaoSpace.s),
            Semantics(
              liveRegion: true,
              child: Text(line, style: text.bodyMedium),
            ),
          ],
          const SizedBox(height: NamaoSpace.m),
          Wrap(
            spacing: NamaoSpace.s,
            runSpacing: NamaoSpace.s,
            children: [
              OutlinedButton(
                onPressed: busy ? null : _checkNow,
                child: const Text('Check for updates'),
              ),
              if (app.release != null && !app.isBusy)
                FilledButton(
                  onPressed: () => showAppUpdateDialog(context, ref),
                  child: Text('Update Namao to ${app.release!.versionName}'),
                ),
            ],
          ),
          if (lastUpdate != null) ...[
            const SizedBox(height: NamaoSpace.m),
            Text(
              'Download support last updated ${formatDate(lastUpdate)}.',
              style: text.bodySmall?.copyWith(color: p.textDim),
            ),
          ],
        ],
      ),
    );
  }

  List<String> _statusLines(EngineUpdateState engine, AppUpdateState app) {
    final lines = <String>[];
    final engineOutcome = engine.outcome;
    final engineLine = engineOutcome == null
        ? null
        : engineOutcomeMessage(engineOutcome.kind);
    if (engineLine != null) lines.add(engineLine);
    if (app.failure != null) {
      lines.add(appFailureMessage(app.failure!));
    } else if (app.release != null && !app.isBusy) {
      lines.add('Namao ${app.release!.versionName} is ready to install.');
    }
    final checkedEverything =
        !engine.isBusy &&
        !app.isBusy &&
        engineOutcome?.kind == EngineUpdateKind.upToDate &&
        app.upToDate;
    if (checkedEverything) lines.add('Everything is up to date.');
    return lines;
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(child: Text(label, style: text.titleSmall)),
        Text(value, style: text.bodyMedium),
      ],
    );
  }
}

// ---------------------------------------------------------------------------- the prompt

/// The update prompt: what is new, then progress, then the hand-off to Android's installer.
/// One dialog follows the whole flow; it never opens twice at once.
Future<void> showAppUpdateDialog(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(appUpdateProvider.notifier);
  if (controller.promptOpen) return;
  controller.promptOpen = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AppUpdateDialog(),
    );
  } finally {
    controller.promptOpen = false;
  }
}

class _AppUpdateDialog extends ConsumerWidget {
  const _AppUpdateDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);
    final controller = ref.read(appUpdateProvider.notifier);
    final text = Theme.of(context).textTheme;
    void close() => Navigator.of(context).pop();

    Widget dialog({
      required String title,
      required Widget body,
      required List<Widget> actions,
    }) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: body),
      actions: actions,
    );

    switch (state.phase) {
      case AppUpdatePhase.downloading:
        return dialog(
          title: 'Downloading the update',
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: state.progress),
              const SizedBox(height: NamaoSpace.s),
              Text(
                state.progress == null
                    ? 'Please wait…'
                    : '${(state.progress! * 100).round()}%',
                style: text.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: controller.cancelDownload,
              child: const Text('Cancel'),
            ),
          ],
        );
      case AppUpdatePhase.awaitingInstaller:
        return dialog(
          title: 'Almost there',
          body: const Text(
            'Confirm the installation on the next screen. Your downloads and '
            'history stay as they are.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.acknowledgeInstaller();
                close();
              },
              child: const Text('Close'),
            ),
          ],
        );
      case AppUpdatePhase.checking:
        return dialog(
          title: 'Checking for updates',
          body: const LinearProgressIndicator(),
          actions: const [],
        );
      case AppUpdatePhase.idle:
        break;
    }

    final failure = state.failure;
    if (failure != null) {
      return dialog(
        title: "Couldn't update",
        body: Text(appFailureMessage(failure)),
        actions: [
          TextButton(onPressed: close, child: const Text('Close')),
          if (state.offersManualInstall)
            FilledButton(
              onPressed: controller.openReleasePage,
              child: const Text('Open download page'),
            )
          else if (state.release != null &&
              failure != AppUpdateFailure.downloadsActive)
            FilledButton(
              onPressed: controller.install,
              child: const Text('Try again'),
            ),
        ],
      );
    }

    final release = state.release;
    if (release == null) {
      return dialog(
        title: 'Namao is up to date',
        body: const Text('You have the latest version.'),
        actions: [TextButton(onPressed: close, child: const Text('Close'))],
      );
    }
    return dialog(
      title: 'Namao ${release.versionName} is available',
      body: Text(
        release.notes.isEmpty ? 'Improvements and fixes.' : release.notes,
      ),
      actions: [
        TextButton(
          onPressed: () {
            controller.remindLater();
            close();
          },
          child: const Text('Remind me later'),
        ),
        FilledButton(
          onPressed: controller.install,
          child: const Text('Update'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------------ launch events

/// Starts the two automatic checks once the first screen is up, tells the person when download
/// support was refreshed, and opens the prompt when an app update is found. Wraps the app shell.
class UpdateEvents extends ConsumerStatefulWidget {
  const UpdateEvents({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateEvents> createState() => _UpdateEventsState();
}

class _UpdateEventsState extends ConsumerState<UpdateEvents> {
  @override
  void initState() {
    super.initState();
    if (kUpdatesEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
    }
  }

  Future<void> _startup() async {
    await ref.read(engineUpdateProvider.notifier).autoCheck();
    if (!mounted) return;
    await ref.read(appUpdateProvider.notifier).autoCheck();
  }

  void _promptForUpdate() {
    ref.read(appUpdateProvider.notifier).markAnnounced();
    showAppUpdateDialog(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(engineUpdateProvider.select((s) => s.updatedCount), (
      previous,
      next,
    ) {
      if (next > (previous ?? 0)) showNamaoSnack(context, engineUpdatedMessage);
    });
    ref.listen<bool>(appUpdateProvider.select((s) => s.announce), (_, next) {
      if (next) _promptForUpdate();
    });
    return widget.child;
  }
}
