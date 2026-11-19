import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatting.dart';
import '../../core/models/video_metadata.dart';
import '../../design/tokens.dart';
import '../../design/type.dart';
import '../shell/navigation.dart';
import 'home_controller.dart';

/// Sticky bottom bar (in thumb reach): the primary action once a quality is chosen, or the
/// inline confirmation after a download was added.
class HomeBottomBar extends ConsumerWidget {
  const HomeBottomBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addedJobId = ref.watch(homeProvider.select((s) => s.addedJobId));
    final format = ref.watch(homeProvider.select((s) => s.selectedFormat));
    final isStarting = ref.watch(homeProvider.select((s) => s.isStarting));
    final startError = ref.watch(homeProvider.select((s) => s.startError));
    final Widget child;
    if (addedJobId != null) {
      child = const _Confirmation(key: ValueKey('added'));
    } else if (format != null) {
      child = _DownloadBar(
        key: const ValueKey('download'),
        format: format,
        isStarting: isStarting,
        errorMessage: startError == null
            ? null
            : [startError.message, ?startError.hint].join(' '),
      );
    } else {
      child = const SizedBox.shrink(key: ValueKey('empty'));
    }
    return AnimatedSwitcher(
      duration: NamaoMotion.of(context, NamaoMotion.normal),
      switchInCurve: NamaoMotion.curve,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: child,
    );
  }
}

class _BarShell extends StatelessWidget {
  const _BarShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        NamaoSpace.l,
        NamaoSpace.m,
        NamaoSpace.l,
        NamaoSpace.m,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: NamaoLayout.contentMaxWidth,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _DownloadBar extends ConsumerWidget {
  const _DownloadBar({
    super.key,
    required this.format,
    required this.isStarting,
    this.errorMessage,
  });

  final FormatOption format;
  final bool isStarting;
  final String? errorMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    return _BarShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: NamaoSpace.s),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  errorMessage!,
                  style: inter(13, FontWeight.w500, p.danger),
                ),
              ),
            ),
          FilledButton(
            onPressed: isStarting
                ? null
                : () => ref.read(homeProvider.notifier).startDownload(),
            child: isStarting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.download_rounded, size: 20),
                      const SizedBox(width: NamaoSpace.s),
                      Flexible(
                        child: Text(
                          'Download ${format.label}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: NamaoSpace.s),
                      Text(
                        formatSizeOption(format),
                        style: inter(
                          13,
                          FontWeight.w500,
                          p.onAccent.withValues(alpha: 0.8),
                        ).tabular,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Confirmation extends ConsumerWidget {
  const _Confirmation({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    return _BarShell(
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: p.success),
            const SizedBox(width: NamaoSpace.m),
            Expanded(
              child: Text(
                'Added to Downloads',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            FilledButton.tonal(
              onPressed: () {
                ref.read(homeProvider.notifier).dismissConfirmation();
                ref.read(tabIndexProvider.notifier).select(AppTab.downloads);
              },
              style: FilledButton.styleFrom(
                minimumSize: const Size(88, NamaoLayout.touchTarget),
              ),
              child: const Text('View'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close_rounded),
              onPressed: () =>
                  ref.read(homeProvider.notifier).dismissConfirmation(),
            ),
          ],
        ),
      ),
    );
  }
}
