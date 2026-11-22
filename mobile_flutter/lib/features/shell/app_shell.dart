import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../downloads/downloads_screen.dart';
import '../downloads/downloads_state.dart';
import '../home/home_screen.dart';
import '../settings/settings_screen.dart';
import '../updates/update_widgets.dart';
import 'navigation.dart';

const List<({AppTab tab, String label, IconData icon, IconData selectedIcon})>
_destinations = [
  (
    tab: AppTab.home,
    label: 'Home',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
  ),
  (
    tab: AppTab.downloads,
    label: 'Downloads',
    icon: Icons.download_outlined,
    selectedIcon: Icons.download_rounded,
  ),
  (
    tab: AppTab.settings,
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
  ),
];

/// NavigationRail on wide screens (>= 600dp), NavigationBar below. Pages stay alive in an
/// IndexedStack so the Home field and scroll positions survive tab changes.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(tabIndexProvider);
    final select = ref.read(tabIndexProvider.notifier).select;
    final pages = IndexedStack(
      index: tab.index,
      children: const [HomeScreen(), DownloadsScreen(), SettingsScreen()],
    );
    return UpdateEvents(
      child: PopScope(
        canPop: tab == AppTab.home,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) select(AppTab.home);
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= NamaoLayout.railBreakpoint;
            return Scaffold(
              resizeToAvoidBottomInset: true,
              body: wide
                  ? Row(
                      children: [
                        _Rail(selected: tab, onSelected: select),
                        VerticalDivider(
                          width: 1,
                          color: context.palette.border,
                        ),
                        Expanded(child: pages),
                      ],
                    )
                  : pages,
              bottomNavigationBar: wide
                  ? null
                  : _Bar(selected: tab, onSelected: select),
            );
          },
        ),
      ),
    );
  }
}

Widget _icon(WidgetRef ref, AppTab tab, IconData icon) {
  if (tab != AppTab.downloads) return Icon(icon);
  final active = ref.watch(tabCountsProvider.select((c) => c.active));
  return Badge(
    isLabelVisible: active > 0,
    label: Text('$active'),
    child: Icon(icon),
  );
}

class _Bar extends ConsumerWidget {
  const _Bar({required this.selected, required this.onSelected});

  final AppTab selected;
  final ValueChanged<AppTab> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.palette.border)),
      ),
      child: NavigationBar(
        selectedIndex: selected.index,
        onDestinationSelected: (i) => onSelected(AppTab.values[i]),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: _icon(ref, d.tab, d.icon),
              selectedIcon: _icon(ref, d.tab, d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

class _Rail extends ConsumerWidget {
  const _Rail({required this.selected, required this.onSelected});

  final AppTab selected;
  final ValueChanged<AppTab> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NavigationRail(
      selectedIndex: selected.index,
      onDestinationSelected: (i) => onSelected(AppTab.values[i]),
      labelType: NavigationRailLabelType.all,
      destinations: [
        for (final d in _destinations)
          NavigationRailDestination(
            icon: _icon(ref, d.tab, d.icon),
            selectedIcon: _icon(ref, d.tab, d.selectedIcon),
            label: Text(d.label),
          ),
      ],
    );
  }
}
