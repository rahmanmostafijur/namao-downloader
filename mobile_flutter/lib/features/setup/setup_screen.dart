import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/wordmark.dart';
import '../settings/server_form.dart';

/// First run: connect to a server. Leaves automatically once a server is saved (the app root
/// watches the settings).
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: NamaoLayout.contentMaxWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(NamaoSpace.xl),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                const SizedBox(height: NamaoSpace.l),
                const Wordmark(size: 34),
                const SizedBox(height: NamaoSpace.xl),
                Semantics(
                  header: true,
                  child: Text(
                    'Connect to your server',
                    style: text.headlineSmall,
                  ),
                ),
                const SizedBox(height: NamaoSpace.s),
                Text(
                  'Namao runs on a server you control. Enter its address to get started. '
                  'Test it first to make sure this phone can reach it.',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: NamaoSpace.xl),
                const ServerForm(
                  saveLabel: 'Continue',
                  showEmulatorShortcut: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
