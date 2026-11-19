import 'package:flutter/material.dart';

import '../../core/formatting.dart';
import '../../core/models/video_metadata.dart';
import '../../core/url_tools.dart';
import '../../design/skeleton.dart';
import '../../design/surfaces.dart';
import '../../design/thumbnail.dart';
import '../../design/tokens.dart';
import '../../design/type.dart';

/// Thumbnail, title, "uploader · duration" and the platform chip for the looked-up video.
class PreviewCard extends StatelessWidget {
  const PreviewCard({super.key, required this.metadata});

  final VideoMetadata metadata;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final platform =
        SourcePlatform.fromName(metadata.platform)?.label ?? metadata.platform;
    final byline = [
      if (metadata.uploader.isNotEmpty) metadata.uploader,
      if (metadata.durationSeconds > 0)
        formatDuration(metadata.durationSeconds),
    ].join(' · ');
    return NamaoCard(
      padding: const EdgeInsets.all(NamaoSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VideoThumbnail(url: metadata.thumbnail, width: 112),
          const SizedBox(width: NamaoSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metadata.title.isEmpty ? 'Untitled video' : metadata.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                if (byline.isNotEmpty) ...[
                  const SizedBox(height: NamaoSpace.xs),
                  Text(
                    byline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.tabular,
                  ),
                ],
                if (platform.isNotEmpty) ...[
                  const SizedBox(height: NamaoSpace.s),
                  Pill(platform),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder shaped like [PreviewCard] + the format list while the server reads the video.
class PreviewSkeleton extends StatelessWidget {
  const PreviewSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Reading video info',
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NamaoCard(
            padding: EdgeInsets.all(NamaoSpace.m),
            child: Row(
              children: [
                SkeletonBox(width: 112, height: 63),
                SizedBox(width: NamaoSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(height: 14),
                      SizedBox(height: NamaoSpace.s),
                      SkeletonBox(width: 90, height: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: NamaoSpace.l),
          for (var i = 0; i < 3; i++) ...[
            const SkeletonBox(height: 56, radius: NamaoRadius.card),
            const SizedBox(height: NamaoSpace.s),
          ],
        ],
      ),
    );
  }
}
