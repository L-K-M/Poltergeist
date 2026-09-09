import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/registered_command.dart';
import '../../services/sftp_demo_controller.dart';
import '../connection_status_panel.dart';

/// The registered id of the debug entry command (02 §8.1's connect.*
/// group; D21).
const kSftpDemoCommandId = 'connect.demoListing';

const _defaultSshPort = 22;

/// The debug-only demo entry command: spawns the engine, opens the
/// listing view, and owns the whole session's teardown.
///
/// [spawnEngine] is injectable for tests; production spawns the real
/// engine isolate. Throwaway: M3 replaces this surface.
RegisteredCommand buildSftpDemoCommand({
  required SftpDemoEngineFactory spawnEngine,
  required bool Function() enabled,
}) {
  return RegisteredCommand(
    id: kSftpDemoCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.sftpDemoCommandLabel,
    enabled: enabled,
    run: (context) => _runSftpDemoSession(context, spawnEngine),
  );
}

Future<void> _runSftpDemoSession(
  BuildContext context,
  SftpDemoEngineFactory spawnEngine,
) async {
  final SftpDemoEngine engine;
  try {
    engine = await spawnEngine();
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).sftpDemoEngineFailed),
      ),
    );
    return;
  }
  if (!context.mounted) {
    await engine.shutdown();
    return;
  }

  final navigatorKey = GlobalKey<NavigatorState>();
  final controller = SftpDemoController(
    engine: engine,
    navigatorKey: navigatorKey,
  );
  try {
    // Inside the try so a failing start() (synchronous throws only — the
    // method is sync) still reaches the dispose in the finally: the
    // spawned engine must not be stranded.
    controller.start();
    await Navigator.of(
      context,
      rootNavigator: true, // matches the close button's root pop
    ).push(MaterialPageRoute<void>(builder: (_) => SftpDemoView(controller)));
  } finally {
    // Popping the route ends the session: prompts close, the browse
    // channel closes, and the spawned engine shuts down.
    controller.dispose();
  }
}

/// The debug-only demo page: a connect form over the engine seam, the
/// live status/transcript panel, and the home listing. Owns a nested
/// navigator so prompt dialogs live and die inside this route (02 §10).
class SftpDemoView extends StatelessWidget {
  const SftpDemoView(this.controller, {super.key});

  final SftpDemoController controller;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: controller.navigatorKey,
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => _SftpDemoPage(controller),
      ),
    );
  }
}

class _SftpDemoPage extends StatefulWidget {
  const _SftpDemoPage(this.controller);

  final SftpDemoController controller;

  @override
  State<_SftpDemoPage> createState() => _SftpDemoPageState();
}

class _SftpDemoPageState extends State<_SftpDemoPage> {
  final _formKey = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '$_defaultSshPort');
  final _username = TextEditingController();
  AuthMethod _authMethod = AuthMethod.agent;

  SftpDemoController get _controller => widget.controller;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = _controller;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final serverId = controller.serverId;
        return Scaffold(
          appBar: AppBar(
            // The nested navigator's home route cannot pop itself; the
            // close action pops the demo route on the app's root navigator.
            leading: IconButton(
              key: const ValueKey('sftp-demo-close'),
              tooltip: l10n.sftpDemoClose,
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            ),
            title: Text(l10n.sftpDemoTitle),
            actions: [
              if (serverId != null)
                TextButton.icon(
                  onPressed: controller.isConnecting
                      ? null
                      : controller.disconnect,
                  icon: const Icon(Icons.link_off, size: 18),
                  label: Text(l10n.sftpDemoDisconnect),
                ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.sftpDemoDebugNote,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  _DemoForm(
                    formKey: _formKey,
                    host: _host,
                    port: _port,
                    username: _username,
                    authMethod: _authMethod,
                    connecting: controller.isConnecting,
                    onAuthMethodChanged: (method) =>
                        setState(() => _authMethod = method),
                    onConnect: _submit,
                  ),
                  if (serverId != null) ...[
                    const SizedBox(height: 16),
                    ConnectionStatusPanel(
                      serverId: serverId,
                      states: controller.states,
                      log: controller.connectLog,
                      onRetry: controller.retry,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _Listing(controller),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _submit() {
    if (_controller.isConnecting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    unawaited(
      _controller.connect(
        SftpDemoConnectFacts(
          host: _host.text.trim(),
          port: int.parse(_port.text.trim()),
          username: _username.text.trim(),
          authMethod: _authMethod,
        ),
      ),
    );
  }
}

class _DemoForm extends StatelessWidget {
  const _DemoForm({
    required this.formKey,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.connecting,
    required this.onAuthMethodChanged,
    required this.onConnect,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController username;
  final AuthMethod authMethod;
  final bool connecting;
  final ValueChanged<AuthMethod> onAuthMethodChanged;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: const ValueKey('sftp-demo-host'),
            controller: host,
            decoration: InputDecoration(labelText: l10n.sftpDemoHostLabel),
            validator: (value) => (value == null || value.trim().isEmpty)
                ? l10n.sftpDemoHostRequired
                : null,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: const ValueKey('sftp-demo-port'),
                  controller: port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.sftpDemoPortLabel,
                  ),
                  validator: (value) => _validatePort(context, value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: const ValueKey('sftp-demo-username'),
                  controller: username,
                  decoration: InputDecoration(
                    labelText: l10n.sftpDemoUsernameLabel,
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? l10n.sftpDemoUsernameRequired
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<AuthMethod>(
            key: const ValueKey('sftp-demo-auth'),
            // initialValue is initial-only; the field is unkeyed because
            // _authMethod only ever changes through its own onChanged.
            initialValue: authMethod,
            items: [
              DropdownMenuItem(
                value: AuthMethod.agent,
                child: Text(l10n.sftpDemoAuthAgent),
              ),
              DropdownMenuItem(
                value: AuthMethod.password,
                child: Text(l10n.sftpDemoAuthPassword),
              ),
            ],
            onChanged: connecting
                ? null
                : (method) {
                    if (method != null) onAuthMethodChanged(method);
                  },
            decoration: InputDecoration(
              labelText: l10n.sftpDemoAuthMethodLabel,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('sftp-demo-connect'),
            onPressed: connecting ? null : onConnect,
            icon: const Icon(Icons.link, size: 18),
            label: Text(l10n.sftpDemoConnect),
          ),
        ],
      ),
    );
  }

  String? _validatePort(BuildContext context, String? value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return AppLocalizations.of(context).sftpDemoPortInvalid;
    }
    return null;
  }
}

/// The home listing plus the failure one-liner; the status panel owns
/// the connect/block rendering and the transcript.
class _Listing extends StatelessWidget {
  const _Listing(this.controller);

  final SftpDemoController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (controller.isConnecting) return const SizedBox.shrink();

    final failure = controller.failureDetail;
    if (failure != null) {
      return Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(failure)),
        ],
      );
    }
    if (controller.isListing) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(l10n.sftpDemoListingLoading),
        ],
      );
    }
    if (controller.serverId == null) return const SizedBox.shrink();

    final entries = controller.entries;
    if (entries.isEmpty) {
      return Text(
        l10n.sftpDemoListingEmpty,
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.sftpDemoListingCount(entries.length),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        for (final entry in entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              entry.isDirectory
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined,
            ),
            title: Text(entry.name),
          ),
      ],
    );
  }
}
