import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 16:9 video thumbnail. Decoded at display size (`memCacheWidth`), with a quiet placeholder.
class VideoThumbnail extends StatelessWidget {
  const VideoThumbnail({
    super.key,
    this.url,
    this.width = 96,
    this.isAudio = false,
  });

  final String? url;
  final double width;
  final bool isAudio;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final height = width * 9 / 16;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = ColoredBox(
      color: p.surfaceRaised,
      child: Center(
        child: Icon(
          isAudio ? Icons.audiotrack_rounded : Icons.movie_outlined,
          size: width * 0.28,
          color: p.textDim,
        ),
      ),
    );
    final image = url == null || url!.isEmpty
        ? placeholder
        : CachedNetworkImage(
            imageUrl: url!,
            fit: BoxFit.cover,
            memCacheWidth: (width * dpr).round(),
            fadeInDuration: NamaoMotion.of(context, NamaoMotion.fast),
            placeholder: (context, _) => placeholder,
            errorWidget: (context, _, _) => placeholder,
          );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NamaoRadius.control),
        child: SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(NamaoRadius.control),
              border: Border.all(color: p.border),
            ),
            child: image,
          ),
        ),
      ),
    );
  }
}
