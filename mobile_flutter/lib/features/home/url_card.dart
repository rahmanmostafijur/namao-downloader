import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/url_tools.dart';
import '../../design/surfaces.dart';
import '../../design/tokens.dart';
import '../../design/type.dart';
import 'home_controller.dart';

/// The URL field, Paste / Clear, the live platform chip and the validation message.
class UrlCard extends ConsumerStatefulWidget {
  const UrlCard({super.key});

  @override
  ConsumerState<UrlCard> createState() => _UrlCardState();
}

class _UrlCardState extends ConsumerState<UrlCard> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(homeProvider).input,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _controller.text = text;
    ref.read(homeProvider.notifier).setInput(text);
  }

  void _clear() {
    _controller.clear();
    ref.read(homeProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final input = ref.watch(homeProvider.select((s) => s.input));
    final check = checkVideoUrl(input);
    final isLoading = ref.watch(
      homeProvider.select((s) => s.phase == HomePhase.loading),
    );
    // Keep the field in step when state is reset elsewhere.
    ref.listen<String>(homeProvider.select((s) => s.input), (_, next) {
      if (_controller.text == next) return;
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          enabled: !isLoading,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          enableSuggestions: false,
          maxLines: 1,
          style: Theme.of(context).textTheme.bodyLarge,
          onChanged: ref.read(homeProvider.notifier).setInput,
          onSubmitted: (_) => ref.read(homeProvider.notifier).fetchFormats(),
          decoration: InputDecoration(
            hintText: 'Paste a video link',
            errorText: check.error,
            errorMaxLines: 2,
            prefixIcon: Icon(Icons.link_rounded, color: p.textDim),
            suffixIcon: input.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: _clear,
                  ),
          ),
        ),
        const SizedBox(height: NamaoSpace.m),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: isLoading ? null : _paste,
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: const Text('Paste'),
            ),
            const SizedBox(width: NamaoSpace.m),
            Expanded(child: _PlatformChip(platform: check.platform)),
          ],
        ),
      ],
    );
  }
}

class _PlatformChip extends StatelessWidget {
  const _PlatformChip({this.platform});

  final SourcePlatform? platform;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedSwitcher(
      duration: NamaoMotion.of(context, NamaoMotion.fast),
      child: platform == null
          ? const SizedBox(
              key: ValueKey('none'),
              height: NamaoLayout.touchTarget,
            )
          : Align(
              key: ValueKey(platform),
              alignment: Alignment.centerLeft,
              child: Semantics(
                label: 'Detected ${platform!.label}',
                excludeSemantics: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NamaoSpace.m,
                    vertical: NamaoSpace.s,
                  ),
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(NamaoRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_rounded, size: 16, color: p.accent),
                      const SizedBox(width: NamaoSpace.xs),
                      Flexible(
                        child: Text(
                          platform!.label,
                          overflow: TextOverflow.ellipsis,
                          style: inter(13, FontWeight.w600, p.accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// Shown while nothing has been looked up: what is supported and the honest limits.
class SupportedSites extends StatelessWidget {
  const SupportedSites({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Works with'),
        Wrap(
          spacing: NamaoSpace.s,
          runSpacing: NamaoSpace.s,
          children: [for (final p in SourcePlatform.values) Pill(p.label)],
        ),
        const SizedBox(height: NamaoSpace.m),
        Text(
          'Single public videos only: no playlists, live streams or private content. '
          'Use it for videos you are allowed to download.',
          style: text.bodySmall,
        ),
      ],
    );
  }
}
