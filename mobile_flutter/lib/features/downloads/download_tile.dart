import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/job_view.dart';
import '../../data/history_entry.dart';
import '../../design/feedback.dart';
import '../../design/progress_bar.dart';
import '../../design/surfaces.dart';
import '../../design/thumbnail.dart';
import '../../design/tokens.dart';
import '../../design/type.dart';
import 'action_errors.dart';
import 'downloads_controller.dart';
import 'downloads_state.dart';
import 'entry_view.dart';

/// One row. Watches only its own entry, so a poll tick rebuilds just the rows that changed.
class DownloadTile extends ConsumerWidget {
  const DownloadTile({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(entryProvider(jobId));
    if (entry == null) return const SizedBox.shrink();
    final lost = ref.watch(lostProvider(jobId));
    return _TileBody(entry: entry, view: describeEntry(entry, lost: lost));
  }
}

class _TileBody extends ConsumerWidget {
  const _TileBody({required this.entry, required this.view});

  final HistoryEntry entry;
  final EntryView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final toneColor = _toneColor(p, view.tone);
    return Semantics(
      container: true,
      label: '${entry.title}. ${entry.qualityLabel}. ${view.label}.',
      child: NamaoCard(
        padding: const EdgeInsets.all(NamaoSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VideoThumbnail(
                  url: entry.thumbnail,
                  isAudio: entry.qualityId == 'audio',
                ),
                const SizedBox(width: NamaoSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title.isEmpty ? 'Untitled video' : entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      const SizedBox(height: NamaoSpace.xs),
                      Wrap(
                        spacing: NamaoSpace.s,
                        runSpacing: NamaoSpace.xs,
                        children: [
                          Pill(entry.qualityLabel),
                          if (entry.platform.isNotEmpty)
                            Pill(_platformName(entry.platform)),
                        ],
                      ),
                    ],
                  ),
                ),
                if (view.canRemove) _MenuButton(entry: entry, view: view),
              ],
            ),
            const SizedBox(height: NamaoSpace.m),
            Text(
              view.label,
              style: inter(13.5, FontWeight.w600, toneColor).tabular,
              semanticsLabel: 'Status: ${view.label}',
            ),
            if (view.showProgress) ...[
              const SizedBox(height: NamaoSpace.s),
              NamaoProgressBar(
                value: view.progress,
                color: toneColor,
                semanticLabel: 'Progress',
              ),
            ],
            if (_infoLine.isNotEmpty) ...[
              const SizedBox(height: NamaoSpace.s),
              Text(_infoLine, style: text.bodySmall?.tabular),
            ],
            if (view.message != null) ...[
              const SizedBox(height: NamaoSpace.xs),
              Text(
                view.message!,
                style: text.bodySmall?.copyWith(
                  color: view.messageIsError ? p.danger : p.textDim,
                ),
              ),
            ],
            if (view.hint != null) Text(view.hint!, style: text.bodySmall),
            _Actions(entry: entry, view: view),
          ],
        ),
      ),
    );
  }

  String get _infoLine => [
    view.detail,
    view.bytesLine,
    view.sizeLine,
  ].where((s) => s.isNotEmpty).join(' · ');

  Color _toneColor(NamaoPalette p, StatusTone tone) => switch (tone) {
    StatusTone.success => p.success,
    StatusTone.danger => p.danger,
    StatusTone.active => p.accent,
    StatusTone.neutral => p.textDim,
  };

  String _platformName(String platform) =>
      platform.isEmpty ? '' : platform[0].toUpperCase() + platform.substring(1);
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.entry, required this.view});

  final HistoryEntry entry;
  final EntryView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(downloadsProvider.notifier);
    final buttons = <Widget>[
      if (view.canCancel)
        TextButton(
          onPressed: () =>
              _guard(context, () => controller.cancel(entry.jobId)),
          child: const Text('Cancel'),
        ),
      if (view.canRefresh)
        TextButton(
          onPressed: () => controller.refresh(entry.jobId),
          child: const Text('Refresh'),
        ),
      if (view.canRetry)
        FilledButton.tonal(
          onPressed: () => _guard(context, () => controller.retry(entry.jobId)),
          style: FilledButton.styleFrom(
            minimumSize: const Size(88, NamaoLayout.touchTarget),
          ),
          child: const Text('Retry'),
        ),
      if (view.canRetrySave)
        FilledButton.tonal(
          onPressed: () => controller.saveToDevice(entry.jobId),
          style: FilledButton.styleFrom(
            minimumSize: const Size(88, NamaoLayout.touchTarget),
          ),
          child: const Text('Retry save'),
        ),
      if (view.isSaved) ...[
        FilledButton.tonal(
          onPressed: () =>
              _fileAction(context, controller.openSaved(entry.jobId)),
          style: FilledButton.styleFrom(
            minimumSize: const Size(88, NamaoLayout.touchTarget),
          ),
          child: const Text('Open'),
        ),
        TextButton(
          onPressed: () =>
              _fileAction(context, controller.shareSaved(entry.jobId)),
          child: const Text('Share'),
        ),
      ],
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: NamaoSpace.s),
      child: Wrap(
        spacing: NamaoSpace.s,
        runSpacing: NamaoSpace.xs,
        children: buttons,
      ),
    );
  }

  Future<void> _guard(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Exception catch (error) {
      if (context.mounted) {
        showNamaoSnack(context, describeActionError(error), isError: true);
      }
    }
  }

  Future<void> _fileAction(
    BuildContext context,
    Future<FileActionResult> pending,
  ) async {
    final result = await pending;
    if (!context.mounted) return;
    final message = switch (result) {
      FileActionResult.ok => null,
      FileActionResult.fileMissing =>
        'That file is no longer in Downloads/Namao. Use Retry to download it again.',
      FileActionResult.noAppFound =>
        'No app on this phone can open that file. Try Share.',
      FileActionResult.failed => "Couldn't complete that action.",
    };
    if (message != null) showNamaoSnack(context, message, isError: true);
  }
}

class _MenuButton extends ConsumerWidget {
  const _MenuButton({required this.entry, required this.view});

  final HistoryEntry entry;
  final EntryView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (_) => confirmAndRemove(context, ref, entry),
      itemBuilder: (context) => const [
        PopupMenuItem<String>(
          value: 'remove',
          child: Text('Remove from history'),
        ),
      ],
    );
  }
}

/// Removes the history record. A saved file stays on the phone: the dialog says so.
Future<bool> confirmAndRemove(
  BuildContext context,
  WidgetRef ref,
  HistoryEntry entry,
) async {
  if (entry.isSaved) {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove from history?',
      body: 'This only removes the entry from this list. The video stays in Downloads/Namao on your phone.',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return false;
  }
  ref.read(downloadsProvider.notifier).remove(entry.jobId);
  return true;
}
