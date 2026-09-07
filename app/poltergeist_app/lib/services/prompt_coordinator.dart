import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../ui/prompts/credential_dialog.dart';
import '../ui/prompts/host_key_dialog.dart';
import '../ui/prompts/keyboard_interactive_dialog.dart';
import 'identity_file_reader.dart';

/// One prompt flowing through the coordinator: the engine event plus the
/// `dismissed` flag every post-await path rechecks (09 §3.1) — the engine
/// withdrawing a prompt pops its dialog without an answer, so a result
/// racing a dismissal is never applied.
class _PendingPrompt {
  final EnginePromptEvent event;

  /// Identifies this prompt's dialog route without touching unrelated routes.
  final dialogKey = GlobalKey();

  /// Set when the engine withdrew the prompt before an answer was applied.
  bool dismissed = false;

  bool closeScheduled = false;

  _PendingPrompt(this.event);
}

/// Renders engine prompts as dialogs and answers them (03 §5, 07 §3.3):
/// host-key first-use/changed review, keyboard-interactive challenges, and
/// the connect-time credential prompt — vault-first, dialog only when the
/// vault has no usable secret.
///
/// Dialogs never stack (02 §10): prompts render one at a time from a FIFO
/// queue. The engine serializes a pool's first connect, so queueing is rare
/// (two servers prompting at once); the full modal-queue service with quit
/// supersession lands with the dialog slice that needs it.
class PromptCoordinator {
  final PromptBridge engine;
  final SecretVault? vault;

  /// Reads "reference, don't store" identity files, auditing every attempt
  /// (D18). Null only where no reader is wired yet; a private-key prompt
  /// then fails with a readable read error instead of touching the disk.
  final IdentityFileReader? identityReader;

  final GlobalKey<NavigatorState> navigatorKey;

  /// Notices (vault-save failures) ride the root scaffold messenger.
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  final _queue = <_PendingPrompt>[];
  _PendingPrompt? _showing;
  StreamSubscription<EnginePromptEvent>? _prompts;
  StreamSubscription<PromptDismissedEvent>? _dismissals;
  bool _disposed = false;

  PromptCoordinator({
    required this.engine,
    required this.navigatorKey,
    this.vault,
    this.identityReader,
    this.scaffoldMessengerKey,
  });

  /// Starts consuming the engine's prompt streams. Idempotent.
  void start() {
    if (_prompts != null) return;
    _prompts = engine.prompts.listen(_onPrompt);
    _dismissals = engine.promptDismissals.listen(_onDismissal);
  }

  /// Closes every open dialog without answering; the engine treats an
  /// un-answered prompt as implicitly cancelled at its own teardown.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_prompts?.cancel());
    unawaited(_dismissals?.cancel());
    _closeShowingDialog();
    _queue.clear();
    _showing = null;
  }

  void _onPrompt(EnginePromptEvent event) {
    if (_disposed) return;
    _queue.add(_PendingPrompt(event));
    _drain();
  }

  void _onDismissal(PromptDismissedEvent event) {
    // The dialog owning this promptId closes without answering (03 §5).
    // A queued — not yet shown — prompt is simply dropped.
    for (final pending in _queue) {
      if (pending.event.promptId == event.promptId) pending.dismissed = true;
    }
    final showing = _showing;
    if (showing?.event.promptId == event.promptId) {
      showing!.dismissed = true;
      _closeShowingDialog();
    }
  }

  void _closeShowingDialog() {
    final showing = _showing;
    if (showing == null) return;

    _closeDialog(showing);
  }

  void _closeDialog(_PendingPrompt pending) {
    final dialogContext = pending.dialogKey.currentContext;
    if (dialogContext == null) {
      if (pending.closeScheduled) return;
      pending.closeScheduled = true;

      // showDialog pushes before its widget builds. Retry after that first
      // frame so a same-turn engine dismissal cannot leave the route open.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        pending.closeScheduled = false;
        if (pending.dialogKey.currentContext != null) _closeDialog(pending);
      });
      return;
    }
    if (!dialogContext.mounted) return;

    final route = ModalRoute.of(dialogContext);
    if (route == null || !route.isActive) return;

    // Remove this prompt's route even if another page now covers it. A
    // navigator-wide pop could dismiss that unrelated page instead.
    final navigator = Navigator.of(dialogContext);
    if (route.isCurrent) {
      navigator.pop();
      return;
    }
    navigator.removeRoute(route);
  }

  void _drain() {
    if (_disposed || _showing != null) return;

    while (_queue.isNotEmpty && _showing == null) {
      final pending = _queue.removeAt(0);
      if (pending.dismissed) continue;

      // An auto-answered prompt never sets _showing: keep draining so the
      // next queued prompt renders without waiting for another trigger.
      if (_answerWithoutDialog(pending)) continue;
      _showing = pending;
      switch (pending.event.kind) {
        case EnginePromptKind.hostKeyFirstUse:
        case EnginePromptKind.hostKeyChanged:
          unawaited(_showGuarded(pending, () => _showHostKey(pending)));
        case EnginePromptKind.keyboardInteractive:
          unawaited(_showGuarded(pending, () => _showKeyboard(pending)));
        case EnginePromptKind.credentialNeeded:
          unawaited(_showGuarded(pending, () => _showCredential(pending)));
        case EnginePromptKind.conflict:
          // No producer exists until the transfer queue (M4) lands.
          _finishShowing();
      }
      return;
    }
  }

  Future<void> _showGuarded(
    _PendingPrompt pending,
    Future<void> Function() show,
  ) async {
    try {
      await show();
    } on Object {
      // A broken dialog must fail safely, then release the queue.
      if (identical(_showing, pending) && !_wasDismissed(pending)) {
        final reply = switch (pending.event.kind) {
          EnginePromptKind.hostKeyFirstUse || EnginePromptKind.hostKeyChanged =>
            const HostKeyPromptReply(accepted: false),
          EnginePromptKind.keyboardInteractive =>
            const KeyboardInteractivePromptReply(answers: []),
          EnginePromptKind.credentialNeeded => _cancelledCredentialReply,
          EnginePromptKind.conflict => null,
        };
        if (reply != null) {
          try {
            _reply(pending, reply);
          } on Object {
            // The queue still must progress if its bridge is already gone.
          }
        }
      }
      if (identical(_showing, pending)) _finishShowing();
    }
  }

  /// Credentials that never need a dialog: agent auth holds no secret to
  /// ask for. Returns true when [pending] was answered.
  bool _answerWithoutDialog(_PendingPrompt pending) {
    final data = pending.event.data;
    if (pending.event.kind != EnginePromptKind.credentialNeeded) return false;
    if (data is! CredentialPromptData) return false;
    if (data.authMethod != AuthMethod.agent) return false;

    _reply(
      pending,
      const CredentialPromptReply(origin: CredentialOrigin.stored),
    );
    return true;
  }

  BuildContext? get _context {
    final context = navigatorKey.currentContext;
    return (context != null && context.mounted) ? context : null;
  }

  Future<void> _showHostKey(_PendingPrompt pending) async {
    final context = _context;
    final data = pending.event.data as HostKeyPromptData;
    if (context == null) {
      // No surface to ask on: decline rather than block the engine.
      _reply(pending, const HostKeyPromptReply(accepted: false));
      _finishShowing();
      return;
    }

    // A dialog popped by an engine dismissal completes with the show
    // helper's cancellation value; the `dismissed` recheck keeps it from
    // being applied as the user's answer (09 §3.1).
    final accepted = await showHostKeyDialog(
      context,
      data,
      dialogKey: pending.dialogKey,
    );
    if (!_wasDismissed(pending)) {
      _reply(pending, HostKeyPromptReply(accepted: accepted));
    }
    _finishShowing();
  }

  Future<void> _showKeyboard(_PendingPrompt pending) async {
    final context = _context;
    final data = pending.event.data as KeyboardInteractivePromptData;
    if (context == null) {
      // Empty answers cannot authenticate: the connect fails its auth step.
      _reply(pending, const KeyboardInteractivePromptReply(answers: []));
      _finishShowing();
      return;
    }

    final answers = await showKeyboardInteractiveDialog(
      context,
      data,
      dialogKey: pending.dialogKey,
    );
    if (!_wasDismissed(pending)) {
      _reply(pending, KeyboardInteractivePromptReply(answers: answers));
    }
    _finishShowing();
  }

  Future<void> _showCredential(_PendingPrompt pending) async {
    final data = pending.event.data as CredentialPromptData;

    // Vault first (03 §3.2): a stored, kind-matching secret answers without
    // a dialog, and its stored provenance lets the pool grow.
    var vaultUnavailable = false;
    if (data.authMethod != AuthMethod.agent &&
        data.secretRef != null &&
        vault != null) {
      try {
        final secret = await vault!.getSecret(data.secretRef!);
        if (secret != null &&
            secret.value.isNotEmpty &&
            _secretMatches(secret, data.authMethod)) {
          if (!_wasDismissed(pending)) {
            _reply(pending, _storedReply(secret));
          }
          _finishShowing();
          return;
        }
      } on Object {
        // The dialog's banner renders the ported keystore failure through
        // ARB (D20), never the raw exception message.
        vaultUnavailable = true;
      }
    }

    if (_wasDismissed(pending)) {
      _finishShowing();
      return;
    }

    // Inline the mounted check so the context use is lint-clean across
    // the vault-read await above (09 §3.1: re-fetch after every await).
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      _reply(pending, _cancelledCredentialReply);
      _finishShowing();
      return;
    }

    final result = await showCredentialDialog(
      context,
      data,
      readKeyFile: (path) => _readIdentityFile(data, path),
      vaultUnavailable: vaultUnavailable,
      dialogKey: pending.dialogKey,
    );
    if (_wasDismissed(pending)) {
      _finishShowing();
      return;
    }
    if (result == null) {
      // The user cancelled (button or Esc): fail the resolution without an
      // answer — the abandoned open fails disconnected (03 §3.2).
      _reply(pending, _cancelledCredentialReply);
      _finishShowing();
      return;
    }

    if (result.saveToVault && data.secretRef != null && vault != null) {
      await _saveToVault(data, result);
    }
    if (!_wasDismissed(pending)) {
      _reply(
        pending,
        CredentialPromptReply(
          password: result.password,
          privateKeyPem: result.privateKeyPem,
          keyPassphrase: result.keyPassphrase,
          origin: CredentialOrigin.prompted,
        ),
      );
    }
    _finishShowing();
  }

  static const _cancelledCredentialReply = CredentialPromptReply(
    cancelled: true,
    origin: CredentialOrigin.prompted,
  );

  Future<String> _readIdentityFile(
    CredentialPromptData data,
    String path,
  ) async {
    final reader = identityReader;
    if (reader == null) {
      throw IdentityFileReadException(
        path,
        FileSystemException('No identity-file reader is wired', path),
      );
    }
    return reader.read(
      serverId: data.secretRef ?? data.host,
      serverLabel: '${data.username}@${data.host}',
      identityFilePath: path,
    );
  }

  Future<void> _saveToVault(
    CredentialPromptData data,
    CredentialDialogResult result,
  ) async {
    // Nothing typed means nothing worth storing — an empty secret would
    // auto-answer future prompts with empty credentials (kind matches).
    final value = result.password ?? result.privateKeyPem;
    if (value == null || value.isEmpty) return;

    try {
      await vault!.putSecret(
        Secret(
          id: data.secretRef!,
          kind: data.authMethod == AuthMethod.privateKey
              ? SecretKind.privateKey
              : SecretKind.password,
          value: value,
          keyPassphrase: result.keyPassphrase,
        ),
      );
    } on Object {
      // Saving is an offer, not a requirement: the connect proceeds with
      // the entered secret; only the save failed, and that failure is
      // transient feedback (02 §10).
      _showNotice();
    }
  }

  void _showNotice() {
    final messenger = scaffoldMessengerKey?.currentState;
    final context = navigatorKey.currentContext;
    if (messenger == null || context == null || !context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).vaultSaveFailed)),
    );
  }

  static bool _secretMatches(Secret secret, AuthMethod method) =>
      (secret.kind == SecretKind.privateKey &&
          method == AuthMethod.privateKey) ||
      (secret.kind == SecretKind.password && method == AuthMethod.password);

  static CredentialPromptReply _storedReply(Secret secret) =>
      CredentialPromptReply(
        password: secret.kind == SecretKind.password ? secret.value : null,
        privateKeyPem: secret.kind == SecretKind.privateKey
            ? secret.value
            : null,
        keyPassphrase: secret.keyPassphrase,
        origin: CredentialOrigin.stored,
      );

  bool _wasDismissed(_PendingPrompt pending) => _disposed || pending.dismissed;

  void _reply(_PendingPrompt pending, PromptReply reply) {
    engine.replyPrompt(pending.event.promptId, pending.event.kind, reply);
  }

  void _finishShowing() {
    _showing = null;
    _drain();
  }
}
