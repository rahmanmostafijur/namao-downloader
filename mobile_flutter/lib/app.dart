import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/providers.dart';
import 'design/theme.dart';
import 'design/tokens.dart';
import 'features/downloads/downloads_state.dart';
import 'features/setup/setup_screen.dart';
import 'features/shell/app_shell.dart';

class NamaoApp extends ConsumerWidget {
  const NamaoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final configured = ref.watch(
      settingsProvider.select((s) => s.isConfigured),
    );
    return MaterialApp(
      title: 'Namao',
      debugShowCheckedModeBanner: false,
      theme: buildNamaoTheme(Brightness.light),
      darkTheme: buildNamaoTheme(Brightness.dark),
      themeMode: mode,
      themeAnimationDuration: NamaoMotion.fast,
      builder: (context, child) =>
          _SystemChrome(child: _Lifecycle(child: child!)),
      home: configured ? const AppShell() : const SetupScreen(),
    );
  }
}

/// Edge-to-edge with transparent bars whose icons follow the active theme.
class _SystemChrome extends StatelessWidget {
  const _SystemChrome({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = context.palette;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarDividerColor: p.border,
      ),
      child: child,
    );
  }
}

/// Re-checks running downloads when the app returns to the foreground, and stops polling when
/// it leaves (the OS would freeze the timer anyway).
class _Lifecycle extends ConsumerStatefulWidget {
  const _Lifecycle({required this.child});

  final Widget child;

  @override
  ConsumerState<_Lifecycle> createState() => _LifecycleState();
}

class _LifecycleState extends ConsumerState<_Lifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(downloadsProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        controller.onAppResumed();
      case AppLifecycleState.paused:
        controller.onAppPaused();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Instantiate the controller at startup so history is restored and tracking starts.
    ref.watch(downloadsProvider.select((s) => s.isLoaded));
    return widget.child;
  }
}
