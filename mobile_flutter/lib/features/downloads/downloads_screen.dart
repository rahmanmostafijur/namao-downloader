import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/history_entry.dart';
import '../../design/feedback.dart';
import '../../design/skeleton.dart';
import '../../design/surfaces.dart';
import '../../design/tokens.dart';
import '../shell/navigation.dart';
import 'download_tile.dart';
import 'downloads_state.dart';
import 'tab_switcher.dart';

final downloadsTabProvider =
    NotifierProvider<DownloadsTabController, DownloadsTab>(
      DownloadsTabController.new,
    );

class DownloadsTabController extends Notifier<DownloadsTab> {
  @override
  DownloadsTab build() => DownloadsTab.active;

  void select(DownloadsTab tab) => state = tab;
}

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(downloadsTabProvider);
    final counts = ref.watch(tabCountsProvider);
    final isLoaded = ref.watch(downloadsProvider.select((s) => s.isLoaded));
    return SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: NamaoLayout.contentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Header(),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NamaoSpace.l,
                  0,
                  NamaoSpace.l,
                  NamaoSpace.m,
                ),
                child: TabSwitcher(
                  selected: tab,
                  counts: counts,
                  onChanged: ref.read(downloadsTabProvider.notifier).select,
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: NamaoMotion.of(context, NamaoMotion.fast),
                  child: isLoaded
                      ? _TabList(key: ValueKey(tab), tab: tab)
                      : const _LoadingList(key: ValueKey('loading')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasFinished = ref.watch(
      tabCountsProvider.select((c) => c.completed + c.failed > 0),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NamaoSpace.l,
        NamaoSpace.m,
        NamaoSpace.xs,
        NamaoSpace.s,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: NamaoLayout.touchTarget),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  'Downloads',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ),
            if (hasFinished)
              TextButton(
                onPressed: () => _clearFinished(context, ref),
                child: const Text('Clear finished'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearFinished(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Clear finished downloads?',
      body:
          'This empties the Completed and Failed lists. Running downloads keep going, '
          'and videos already saved stay in Downloads/Namao on your phone.',
      confirmLabel: 'Clear',
    );
    if (confirmed) ref.read(downloadsProvider.notifier).clearFinished();
  }
}

class _TabList extends ConsumerWidget {
  const _TabList({super.key, required this.tab});

  final DownloadsTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(tabIdsProvider(tab)).ids;
    if (ids.isEmpty) return _emptyState(context, ref, tab);
    return RefreshIndicator(
      onRefresh: () async =>
          ref.read(downloadsProvider.notifier).onAppResumed(),
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
          NamaoSpace.l,
          NamaoSpace.xs,
          NamaoSpace.l,
          NamaoSpace.xxl + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: ids.length,
        separatorBuilder: (_, _) => const SizedBox(height: NamaoSpace.m),
        itemBuilder: (context, index) =>
            _DismissibleTile(key: ValueKey(ids[index]), jobId: ids[index]),
      ),
    );
  }

  Widget _emptyState(BuildContext context, WidgetRef ref, DownloadsTab tab) {
    return switch (tab) {
      DownloadsTab.active => EmptyState(
        icon: Icons.download_for_offline_outlined,
        title: 'Nothing downloading',
        body: 'Paste a link on Home, pick a quality, and your download shows up here.',
        action: OutlinedButton(
          onPressed: () =>
              ref.read(tabIndexProvider.notifier).select(AppTab.home),
          child: const Text('Go to Home'),
        ),
      ),
      DownloadsTab.completed => const EmptyState(
        icon: Icons.task_alt_rounded,
        title: 'No saved videos yet',
        body: 'Finished downloads land here once they are saved to Downloads/Namao.',
      ),
      DownloadsTab.failed => const EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'No problems',
        body: 'Failed, cancelled and interrupted downloads show up here with a Retry.',
      ),
    };
  }
}

/// Swipe to remove a finished entry. Active rows can't be swiped away: they have to be cancelled.
class _DismissibleTile extends ConsumerWidget {
  const _DismissibleTile({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(entryProvider(jobId));
    final canDismiss = entry != null && !entry.isActive;
    final tile = DownloadTile(jobId: jobId);
    if (!canDismiss) return tile;
    final p = context.palette;
    return Dismissible(
      key: ValueKey('dismiss-$jobId'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => confirmAndRemove(context, ref, entry),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: NamaoSpace.xl),
        decoration: BoxDecoration(
          color: p.danger.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(NamaoRadius.card),
        ),
        child: Icon(Icons.delete_outline_rounded, color: p.danger),
      ),
      child: tile,
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(NamaoSpace.l),
      children: const [
        _SkeletonRow(),
        SizedBox(height: NamaoSpace.m),
        _SkeletonRow(),
      ],
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const NamaoCard(
      child: Row(
        children: [
          SkeletonBox(width: 96, height: 54),
          SizedBox(width: NamaoSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 14),
                SizedBox(height: NamaoSpace.s),
                SkeletonBox(width: 120, height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
