import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/namao_api.dart';
import '../../core/error_messages.dart';
import '../../core/url_tools.dart';
import '../../data/providers.dart';
import '../../design/surfaces.dart';
import '../../design/tokens.dart';

/// Server URL + API key + "Test connection". Used by first-run setup and by Settings.
class ServerForm extends ConsumerStatefulWidget {
  const ServerForm({
    super.key,
    required this.saveLabel,
    this.onSaved,
    this.showEmulatorShortcut = false,
  });

  final String saveLabel;
  final VoidCallback? onSaved;
  final bool showEmulatorShortcut;

  @override
  ConsumerState<ServerForm> createState() => _ServerFormState();
}

enum _Outcome { ok, warning, error }

class _TestResult {
  const _TestResult(this.outcome, this.message, [this.hint]);

  final _Outcome outcome;
  final String message;
  final String? hint;
}

class _ServerFormState extends ConsumerState<ServerForm> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  bool _obscure = true;
  bool _testing = false;
  _TestResult? _result;
  String? _urlError;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _url = TextEditingController(text: settings.serverUrl ?? '');
    _key = TextEditingController(text: settings.apiKey ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  String? get _apiKey => _key.text.trim().isEmpty ? null : _key.text.trim();

  ServerUrlResult _validate() {
    final result = normalizeServerUrl(_url.text);
    setState(() => _urlError = result.error);
    return result;
  }

  Future<void> _test() async {
    final server = _validate();
    if (!server.isValid) return;
    setState(() {
      _testing = true;
      _result = null;
    });
    final api = ref.read(apiFactoryProvider)(server.url!, _apiKey);
    _TestResult result;
    try {
      result = _describe(await api.checkConnection(), server.url!);
    } on ApiException catch (error) {
      final shown = presentApiError(error, serverUrl: server.url);
      result = _TestResult(_Outcome.error, shown.message, shown.hint);
    } finally {
      api.close();
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _result = result;
      });
    }
  }

  _TestResult _describe(ConnectionReport report, String url) {
    final name = serverLabel(url);
    if (!report.authorized) {
      return const _TestResult(
        _Outcome.error,
        'The server is reachable but needs a valid API key.',
        'Enter the key the server was started with.',
      );
    }
    if (!report.ready) {
      final failing = report.failingChecks.isEmpty
          ? ''
          : ' Not ready: ${report.failingChecks.join(', ')}.';
      return _TestResult(
        _Outcome.warning,
        'Reached $name, but it reports it is not ready.$failing',
      );
    }
    return _TestResult(_Outcome.ok, 'Connected to $name. The server is ready.');
  }

  Future<void> _save() async {
    final server = _validate();
    if (!server.isValid) return;
    await ref.read(settingsProvider.notifier).saveServer(server.url!, _apiKey);
    widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final normalized = normalizeServerUrl(_url.text);
    final showCleartext =
        normalized.isValid && needsCleartextWarning(normalized.url!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {
            _urlError = null;
            _result = null;
          }),
          decoration: InputDecoration(
            labelText: 'Server address',
            hintText: 'http://192.168.1.20:8000',
            errorText: _urlError,
            errorMaxLines: 3,
          ),
        ),
        if (widget.showEmulatorShortcut && _url.text.trim().isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                _url.text = 'http://10.0.2.2:8000';
                _urlError = null;
              }),
              child: const Text(
                'Using the Android emulator? Use 10.0.2.2:8000',
              ),
            ),
          ),
        if (showCleartext) ...[
          const SizedBox(height: NamaoSpace.m),
          MessageBanner(
            tone: p.accent,
            icon: Icons.warning_amber_rounded,
            message:
                'This address uses plain http outside your private network.',
            hint: 'Anyone on the path can read your traffic and API key. Prefer https.',
          ),
        ],
        const SizedBox(height: NamaoSpace.m),
        TextField(
          controller: _key,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _result = null),
          decoration: InputDecoration(
            labelText: 'API key (optional)',
            helperText:
                'Only if the server has one. Stored encrypted on this phone.',
            helperMaxLines: 2,
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show API key' : 'Hide API key',
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: NamaoSpace.l),
        _ResultBanner(result: _result),
        if (_result != null) const SizedBox(height: NamaoSpace.m),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _testing ? null : _test,
                child: _testing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Text('Test connection'),
              ),
            ),
            const SizedBox(width: NamaoSpace.m),
            Expanded(
              child: FilledButton(
                onPressed: _testing ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(88, NamaoLayout.touchTarget),
                ),
                child: Text(widget.saveLabel),
              ),
            ),
          ],
        ),
        const SizedBox(height: NamaoSpace.s),
        Text(
          'Namao downloads on your own server; this app only talks to it.',
          style: text.bodySmall,
        ),
      ],
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.result});

  final _TestResult? result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) return const SizedBox.shrink();
    final p = context.palette;
    return switch (r.outcome) {
      _Outcome.ok => MessageBanner(
        message: r.message,
        tone: p.success,
        icon: Icons.check_circle_outline_rounded,
      ),
      _Outcome.warning => MessageBanner(
        message: r.message,
        tone: p.accent,
        icon: Icons.warning_amber_rounded,
      ),
      _Outcome.error => MessageBanner(message: r.message, hint: r.hint),
    };
  }
}
