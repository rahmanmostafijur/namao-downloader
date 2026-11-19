import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/surfaces.dart';
import '../../design/tokens.dart';
import '../../design/wordmark.dart';
import 'download_bar.dart';
import 'format_list.dart';
import 'home_controller.dart';
import 'preview_card.dart';
import 'url_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const Column(
      children: [
        Expanded(child: _HomeBody()),
        HomeBottomBar(),
      ],
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(homeProvider.select((s) => s.phase));
    return SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: NamaoLayout.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              NamaoSpace.l,
              NamaoSpace.m,
              NamaoSpace.l,
              NamaoSpace.xxl,
            ),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              const _Header(),
              const SizedBox(height: NamaoSpace.xl),
              const UrlCard(),
              const SizedBox(height: NamaoSpace.m),
              const _GetFormatsButton(),
              const SizedBox(height: NamaoSpace.xl),
              AnimatedSwitcher(
                duration: NamaoMotion.of(context, NamaoMotion.normal),
                switchInCurve: NamaoMotion.curve,
                child: KeyedSubtree(
                  key: ValueKey(phase),
                  child: _Content(phase: phase),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => const Row(children: [Wordmark(size: 28)]);
}

class _GetFormatsButton extends ConsumerWidget {
  const _GetFormatsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canFetch = ref.watch(homeProvider.select((s) => s.check.isValid));
    final isLoading = ref.watch(
      homeProvider.select((s) => s.phase == HomePhase.loading),
    );
    return FilledButton(
      onPressed: canFetch && !isLoading
          ? () => ref.read(homeProvider.notifier).fetchFormats()
          : null,
      child: isLoading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : const Text('Get formats'),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.phase});

  final HomePhase phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (phase) {
      case HomePhase.idle:
        return const SupportedSites();
      case HomePhase.loading:
        return const PreviewSkeleton();
      case HomePhase.error:
        final error = ref.watch(homeProvider.select((s) => s.error));
        return MessageBanner(
          message: error?.message ?? 'Something went wrong.',
          hint: error?.hint,
          onRetry: error?.retryable ?? true
              ? () => ref.read(homeProvider.notifier).fetchFormats()
              : null,
        );
      case HomePhase.loaded:
        final metadata = ref.watch(homeProvider.select((s) => s.metadata));
        final selected = ref.watch(
          homeProvider.select((s) => s.selectedFormatId),
        );
        if (metadata == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PreviewCard(metadata: metadata),
            const SizedBox(height: NamaoSpace.xl),
            FormatList(
              metadata: metadata,
              selectedId: selected,
              onSelected: ref.read(homeProvider.notifier).selectFormat,
            ),
          ],
        );
    }
  }
}
