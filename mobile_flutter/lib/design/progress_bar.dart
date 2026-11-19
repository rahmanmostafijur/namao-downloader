import 'package:flutter/material.dart';

import 'tokens.dart';

/// A thin pill progress bar. [value] null means indeterminate (queued, merging, verifying).
class NamaoProgressBar extends StatelessWidget {
  const NamaoProgressBar({
    super.key,
    this.value,
    this.color,
    this.semanticLabel,
  });

  /// 0..1, or null for an indeterminate bar.
  final double? value;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(NamaoRadius.pill),
      child: value == null
          ? (reduceMotion
                // A static partial bar: motion-free but still clearly "no percentage".
                ? FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: 0.35,
                    child: ColoredBox(
                      color: color ?? p.accent,
                      child: const SizedBox(height: 5),
                    ),
                  )
                : LinearProgressIndicator(
                    minHeight: 5,
                    color: color ?? p.accent,
                    backgroundColor: p.border,
                  ))
          : TweenAnimationBuilder<double>(
              tween: Tween<double>(end: value!.clamp(0, 1).toDouble()),
              duration: NamaoMotion.of(context),
              curve: NamaoMotion.curve,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 5,
                color: color ?? p.accent,
                backgroundColor: p.border,
              ),
            ),
    );
    return Semantics(
      label: semanticLabel,
      value: value == null ? null : '${(value! * 100).round()} percent',
      child: ExcludeSemantics(
        child: Container(
          height: 5,
          decoration: BoxDecoration(
            color: reduceMotion && value == null ? p.border : null,
            borderRadius: BorderRadius.circular(NamaoRadius.pill),
          ),
          child: bar,
        ),
      ),
    );
  }
}
