import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppTab { home, downloads, settings }

final tabIndexProvider = NotifierProvider<TabIndexController, AppTab>(
  TabIndexController.new,
);

/// Which top-level destination is showing. App-level so "View" on Home can jump to Downloads.
class TabIndexController extends Notifier<AppTab> {
  @override
  AppTab build() => AppTab.home;

  void select(AppTab tab) => state = tab;
}
