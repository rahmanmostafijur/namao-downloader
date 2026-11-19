import 'package:flutter/material.dart';

import 'tokens.dart';
import 'type.dart';

/// A hairline-bordered surface: the app's one card style.
class NamaoCard extends StatelessWidget {
  const NamaoCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(NamaoSpace.l),
    this.raised = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool raised;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final radius = BorderRadius.circular(NamaoRadius.card);
    return Material(
      color: raised ? p.surfaceRaised : p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : InkWell(
              onTap: onTap,
              child: Padding(padding: padding, child: child),
            ),
    );
  }
}

/// A small rounded label: platform, quality, status.
class Pill extends StatelessWidget {
  const Pill(
    this.label, {
    super.key,
    this.color,
    this.icon,
    this.filled = false,
  });

  final String label;
  final Color? color;
  final IconData? icon;

  /// Tinted background (for state) instead of a plain outline.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tone = color ?? p.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NamaoSpace.s + 2,
        vertical: NamaoSpace.xs,
      ),
      decoration: BoxDecoration(
        color: filled ? tone.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(NamaoRadius.pill),
        border: Border.all(color: filled ? Colors.transparent : p.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: tone),
            const SizedBox(width: NamaoSpace.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: inter(12, FontWeight.w600, tone).tabular,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: NamaoSpace.s),
        child: Text(
          text.toUpperCase(),
          style: inter(
            11.5,
            FontWeight.w600,
            context.palette.textDim,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

/// A message with an optional next step and an optional Retry.
class MessageBanner extends StatelessWidget {
  const MessageBanner({
    super.key,
    required this.message,
    this.hint,
    this.onRetry,
    this.tone,
    this.icon = Icons.error_outline_rounded,
    this.actionLabel = 'Retry',
  });

  final String message;
  final String? hint;
  final VoidCallback? onRetry;
  final Color? tone;
  final IconData icon;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = tone ?? p.danger;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(NamaoSpace.l),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(NamaoRadius.card),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: NamaoSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: Theme.of(context).textTheme.bodyMedium),
                  if (hint != null) ...[
                    const SizedBox(height: NamaoSpace.xs),
                    Text(hint!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                  if (onRetry != null) ...[
                    const SizedBox(height: NamaoSpace.xs),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: onRetry,
                        child: Text(actionLabel),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(NamaoSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: p.textDim),
              const SizedBox(height: NamaoSpace.l),
              Text(title, style: text.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: NamaoSpace.s),
              Text(body, style: text.bodySmall, textAlign: TextAlign.center),
              if (action != null) ...[
                const SizedBox(height: NamaoSpace.l),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
