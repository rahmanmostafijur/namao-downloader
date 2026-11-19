import 'package:flutter/material.dart';

import '../../data/history_entry.dart';
import '../../design/tokens.dart';
import '../../design/type.dart';
import 'downloads_state.dart';

String tabLabel(DownloadsTab tab) => switch (tab) {
  DownloadsTab.active => 'Active',
  DownloadsTab.completed => 'Completed',
  DownloadsTab.failed => 'Failed',
};

int tabCount(TabCounts counts, DownloadsTab tab) => switch (tab) {
  DownloadsTab.active => counts.active,
  DownloadsTab.completed => counts.completed,
  DownloadsTab.failed => counts.failed,
};

/// Three equal segments (Active / Completed / Failed) with live counts.
class TabSwitcher extends StatelessWidget {
  const TabSwitcher({
    super.key,
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  final DownloadsTab selected;
  final TabCounts counts;
  final ValueChanged<DownloadsTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(NamaoRadius.control + 3),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          for (final tab in DownloadsTab.values)
            Expanded(
              child: _Segment(
                tab: tab,
                count: tabCount(counts, tab),
                isSelected: tab == selected,
                onTap: () => onChanged(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.tab,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  final DownloadsTab tab;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = tabLabel(tab);
    final color = isSelected ? p.text : p.textDim;
    return Semantics(
      button: true,
      selected: isSelected,
      label: '$label, $count',
      excludeSemantics: true,
      onTap: onTap,
      child: AnimatedContainer(
        duration: NamaoMotion.of(context, NamaoMotion.fast),
        curve: NamaoMotion.curve,
        constraints: const BoxConstraints(
          minHeight: NamaoLayout.touchTarget - 6,
        ),
        decoration: BoxDecoration(
          color: isSelected ? p.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(NamaoRadius.control),
          border: Border.all(color: isSelected ? p.border : Colors.transparent),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(NamaoRadius.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NamaoSpace.xs,
              vertical: NamaoSpace.s,
            ),
            child: Center(
              // Same capped size for every segment, so labels stay uniform at large text sizes.
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.25,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: inter(
                          13.5,
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                          color,
                        ),
                      ),
                      const SizedBox(width: NamaoSpace.xs + 2),
                      Text(
                        '$count',
                        style: inter(
                          12.5,
                          FontWeight.w600,
                          isSelected && tab == DownloadsTab.active && count > 0
                              ? p.accent
                              : p.textDim,
                        ).tabular,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
