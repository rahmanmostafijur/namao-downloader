import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/session/cookie_file.dart';
import '../../data/session/instagram_session_store.dart';
import '../../design/feedback.dart';
import '../../design/surfaces.dart';
import '../../design/tokens.dart';

/// The stored Instagram session, or null. A failure to read it counts as "none".
final instagramSessionProvider =
    AsyncNotifierProvider<InstagramSessionController, SessionInfo?>(
      InstagramSessionController.new,
    );

class InstagramSessionController extends AsyncNotifier<SessionInfo?> {
  InstagramSessionStore get _store => ref.read(instagramSessionStoreProvider);

  @override
  Future<SessionInfo?> build() => _read();

  Future<SessionInfo?> _read() async {
    try {
      return await _store.info();
    } on Object {
      return null;
    }
  }

  /// Lets the person pick their own cookies.txt, checks it and stores it. Returns a sentence for
  /// the person when it could not be used, or null when it worked (or they cancelled).
  Future<String?> importFromFile() async {
    try {
      final text = await _store.pickFile();
      if (text == null) return null;
      final cookies = parseInstagramCookies(
        text,
        now: ref.read(clockProvider)(),
      );
      await _store.save(cookies);
      state = AsyncData(await _read());
      return null;
    } on CookieFileException catch (error) {
      return error.message;
    } on SessionStoreException {
      return "Couldn't read or store that file. Please try again.";
    }
  }

  /// Returns a sentence when the session could not be removed, otherwise null.
  Future<String?> remove() async {
    try {
      await _store.remove();
    } on SessionStoreException {
      return "Couldn't remove the session. Please try again.";
    } finally {
      state = AsyncData(await _read());
    }
    return null;
  }
}

/// Settings > Instagram session: optional, the user's own cookies.txt, kept encrypted on the phone.
class InstagramSessionCard extends ConsumerWidget {
  const InstagramSessionCard({super.key});

  static const String explanation =
      'Most public Instagram posts and reels download without logging in. If you are allowed '
      'to see something that needs a login, you can import your own cookies.txt, exported '
      'from your browser while you are logged in. It stays on this phone, encrypted, and is '
      'used only for Instagram links. Namao never asks for your Instagram password.';

  static const String expiryNote =
      'Sessions expire, and Instagram can end one at any time. When Instagram stops '
      'accepting it, import a fresh file.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final session = ref.watch(instagramSessionProvider).value;
    final now = ref.watch(clockProvider)();
    return NamaoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Instagram session (optional)', style: text.titleSmall),
          const SizedBox(height: NamaoSpace.xs),
          Text(_status(session, now), style: text.bodyMedium),
          const SizedBox(height: NamaoSpace.m),
          Text(explanation, style: text.bodySmall),
          const SizedBox(height: NamaoSpace.s),
          Text(expiryNote, style: text.bodySmall),
          const SizedBox(height: NamaoSpace.m),
          Wrap(
            spacing: NamaoSpace.s,
            runSpacing: NamaoSpace.s,
            children: [
              OutlinedButton(
                onPressed: () => _import(context, ref),
                child: Text(
                  session == null
                      ? 'Import cookies.txt'
                      : 'Replace cookies.txt',
                ),
              ),
              if (session != null)
                OutlinedButton(
                  onPressed: () => _remove(context, ref),
                  child: const Text('Remove session'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _status(SessionInfo? session, DateTime now) {
    if (session == null) return 'No session imported.';
    final expiry = session.expiresAt;
    if (expiry == null) return 'Session imported.';
    final date = '${expiry.year}-${_two(expiry.month)}-${_two(expiry.day)}';
    return session.isExpired(now)
        ? 'Session expired on $date. Import a fresh file.'
        : 'Session imported. Expires $date.';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final problem = await ref
        .read(instagramSessionProvider.notifier)
        .importFromFile();
    if (!context.mounted) return;
    showNamaoSnack(
      context,
      problem ?? 'Instagram session saved on this phone.',
      isError: problem != null,
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove Instagram session?',
      body:
          'The imported cookies are deleted from this phone. Instagram links that need a '
          'login will stop working until you import a file again.',
      confirmLabel: 'Remove session',
    );
    if (!confirmed || !context.mounted) return;
    final problem = await ref.read(instagramSessionProvider.notifier).remove();
    if (!context.mounted) return;
    showNamaoSnack(
      context,
      problem ?? 'Instagram session removed.',
      isError: problem != null,
    );
  }
}
