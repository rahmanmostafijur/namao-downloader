import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../design/feedback.dart';
import '../../design/surfaces.dart';
import '../../design/tokens.dart';
import '../downloads/downloads_state.dart';
import '../updates/update_widgets.dart';
import 'instagram_session_card.dart';

/// Shown in About. Kept as one constant so the wording is reviewed in one place.
const String aboutLimits =
    'Namao is for personal use with videos you are allowed to download. It does not '
    'bypass logins, paywalls or DRM, and it can only fetch what the source site serves '
    'publicly. Sites change often; if a download starts failing, connect to the internet '
    'and reopen Namao so it can refresh itself.';

final appVersionProvider = FutureProvider<String>((ref) async {
  try {
    return await ref.watch(nativeMediaProvider).appVersion();
  } on Object {
    return 'unknown';
  }
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: NamaoLayout.contentMaxWidth,
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              NamaoSpace.l,
              NamaoSpace.m,
              NamaoSpace.l,
              NamaoSpace.xxl + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Settings',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: NamaoSpace.xl),
              const SectionLabel('Appearance'),
              const _ThemePicker(),
              const SizedBox(height: NamaoSpace.xl),
              const SectionLabel('Storage'),
              const _StorageCard(),
              const SizedBox(height: NamaoSpace.xl),
              const SectionLabel('History'),
              const _HistoryCard(),
              const SizedBox(height: NamaoSpace.xl),
              const SectionLabel('Instagram'),
              const InstagramSessionCard(),
              const SizedBox(height: NamaoSpace.xl),
              UpdateSection(appVersion: ref.watch(appVersionProvider).value),
              const SectionLabel('About'),
              const _AboutCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemePicker extends ConsumerWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ThemeMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: ThemeMode.system,
            label: Text('System'),
            icon: Icon(Icons.brightness_auto_rounded),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            label: Text('Light'),
            icon: Icon(Icons.light_mode_outlined),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            label: Text('Dark'),
            icon: Icon(Icons.dark_mode_outlined),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (selection) =>
            ref.read(settingsProvider.notifier).setThemeMode(selection.first),
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return NamaoCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.folder_outlined, color: p.textDim),
          const SizedBox(width: NamaoSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Saved to Downloads/Namao', style: text.titleSmall),
                const SizedBox(height: NamaoSpace.xs),
                Text(
                  'Finished videos go to your phone’s Downloads folder, so they show up in your '
                  'Files and gallery apps. Removing an entry from history never deletes the file.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  const _HistoryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final finished = ref.watch(
      tabCountsProvider.select((c) => c.completed + c.failed),
    );
    final text = Theme.of(context).textTheme;
    return NamaoCard(
      child: Row(
        children: [
          Expanded(
            child: Text(
              finished == 0
                  ? 'No finished downloads in history.'
                  : '$finished finished in history.',
              style: text.bodyMedium,
            ),
          ),
          OutlinedButton(
            onPressed: finished == 0 ? null : () => _clear(context, ref),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Clear history?',
      body:
          'Finished downloads are removed from this list. Running downloads keep going, '
          'and videos already saved stay in Downloads/Namao on your phone.',
      confirmLabel: 'Clear history',
    );
    if (!confirmed) return;
    ref.read(downloadsProvider.notifier).clearFinished();
    if (context.mounted) showNamaoSnack(context, 'History cleared');
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).value;
    final text = Theme.of(context).textTheme;
    return NamaoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Namao (নামাও)', style: text.titleSmall),
          const SizedBox(height: NamaoSpace.xs),
          Text(
            version == null ? 'Version …' : 'Version $version',
            style: text.bodySmall,
          ),
          const SizedBox(height: NamaoSpace.m),
          Text(
            'Paste a video link, pick a quality, and Namao saves it straight to your phone. '
            'No account and no setup needed.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: NamaoSpace.m),
          Text(aboutLimits, style: text.bodySmall),
          const SizedBox(height: NamaoSpace.m),
          OutlinedButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Namao',
              applicationVersion: version,
            ),
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    );
  }
}
