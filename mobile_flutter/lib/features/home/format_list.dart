import 'package:flutter/material.dart';

import '../../core/formatting.dart';
import '../../core/models/video_metadata.dart';
import '../../design/surfaces.dart';
import '../../design/tokens.dart';
import '../../design/type.dart';

/// Qualities exactly as the server listed them, grouped Video / Audio.
class FormatList extends StatelessWidget {
  const FormatList({
    super.key,
    required this.metadata,
    required this.selectedId,
    required this.onSelected,
  });

  final VideoMetadata metadata;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final video = metadata.videoFormats;
    final audio = metadata.audioFormats;
    if (video.isEmpty && audio.isEmpty) {
      return const MessageBanner(
        message: 'The server found no downloadable formats for this video.',
        icon: Icons.info_outline_rounded,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!metadata.ffmpeg)
          const Padding(
            padding: EdgeInsets.only(bottom: NamaoSpace.m),
            child: MessageBanner(
              message: 'This server has no FFmpeg, so formats that need merging will fail.',
              icon: Icons.warning_amber_rounded,
            ),
          ),
        if (video.isNotEmpty)
          _Group(
            title: 'Video',
            formats: video,
            selectedId: selectedId,
            onSelected: onSelected,
          ),
        if (audio.isNotEmpty)
          _Group(
            title: 'Audio',
            formats: audio,
            selectedId: selectedId,
            onSelected: onSelected,
          ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.formats,
    required this.selectedId,
    required this.onSelected,
  });

  final String title;
  final List<FormatOption> formats;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NamaoSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(title),
          for (final format in formats) ...[
            FormatRow(
              format: format,
              isSelected: format.id == selectedId,
              onTap: () => onSelected(format.id),
            ),
            const SizedBox(height: NamaoSpace.s),
          ],
        ],
      ),
    );
  }
}

class FormatRow extends StatelessWidget {
  const FormatRow({
    super.key,
    required this.format,
    required this.isSelected,
    required this.onTap,
  });

  final FormatOption format;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final size = formatSizeOption(format);
    return Semantics(
      button: true,
      selected: isSelected,
      inMutuallyExclusiveGroup: true,
      label:
          '${format.label}${format.note.isEmpty ? '' : ', ${format.note}'}, $size',
      excludeSemantics: true,
      onTap: onTap,
      child: AnimatedContainer(
        duration: NamaoMotion.of(context, NamaoMotion.fast),
        curve: NamaoMotion.curve,
        decoration: BoxDecoration(
          color: isSelected ? p.accent.withValues(alpha: 0.10) : p.surface,
          borderRadius: BorderRadius.circular(NamaoRadius.card),
          border: Border.all(
            color: isSelected ? p.accent : p.border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(NamaoRadius.card),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: NamaoLayout.touchTarget + 8,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NamaoSpace.l,
                vertical: NamaoSpace.m,
              ),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: isSelected ? p.accent : p.textDim,
                  ),
                  const SizedBox(width: NamaoSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(format.label, style: text.titleSmall),
                        if (format.note.isNotEmpty)
                          Text(
                            format.note,
                            style: text.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: NamaoSpace.m),
                  Text(
                    size,
                    style: inter(
                      13,
                      FontWeight.w500,
                      format.sizeBytes == null ? p.textDim : p.text,
                    ).tabular,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
