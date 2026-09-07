import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/identity_audit_log.dart';
import 'package:poltergeist_app/services/identity_file_reader.dart';
import 'package:poltergeist_app/services/prompt_coordinator.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

class FakePromptBridge implements PromptBridge {
  final promptsController = StreamController<EnginePromptEvent>.broadcast();
  final dismissalsController =
      StreamController<PromptDismissedEvent>.broadcast();
  final replies = <(String, EnginePromptKind, PromptReply)>[];

  @override
  Stream<EnginePromptEvent> get prompts => promptsController.stream;

  @override
  Stream<PromptDismissedEvent> get promptDismissals =>
      dismissalsController.stream;

  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) {
    replies.add((promptId, kind, reply));
  }

  void emit(EnginePromptEvent event) => promptsController.add(event);

  void dismiss(String promptId, EnginePromptKind kind) =>
      dismissalsController.add(
        PromptDismissedEvent(promptId: promptId, kind: kind),
      );
}

class ScriptedVault extends SecretVault {
  Secret? secret;
  Object? readFailure;
  Object? writeFailure;
  final List<Secret> puts = [];

  ScriptedVault() : super(InMemoryVaultStore(), const []);

  @override
  Future<Secret?> getSecret(String id) async {
    final failure = readFailure;
    if (failure != null) throw failure;
    final secret = this.secret;
    return secret != null && secret.id == id ? secret : null;
  }

  @override
  Future<void> putSecret(Secret secret) async {
    final failure = writeFailure;
    if (failure != null) throw failure;
    puts.add(secret);
    this.secret = secret;
  }
}

class ScriptedIdentityReader extends IdentityFileReader {
  Object? failure;
  final List<String> reads = [];

  ScriptedIdentityReader() : super(IdentityAuditLog(File('unused')));

  @override
  Future<String> read({
    required String serverId,
    required String serverLabel,
    required String identityFilePath,
  }) async {
    reads.add(identityFilePath);
    final error = failure;
    if (error != null) throw error;
    return 'OPENSSH PRIVATE KEY';
  }
}

EnginePromptEvent _event(
  String promptId,
  EnginePromptKind kind,
  EnginePromptData data,
) => EnginePromptEvent(promptId: promptId, kind: kind, data: data);

const _credential = CredentialPromptData(
  host: 'example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.password,
);

void main() {
  late FakePromptBridge bridge;
  late ScriptedVault vault;
  late ScriptedIdentityReader reader;
  late GlobalKey<NavigatorState> navigatorKey;
  late GlobalKey<ScaffoldMessengerState> messengerKey;
  late PromptCoordinator coordinator;

  setUp(() {
    bridge = FakePromptBridge();
    vault = ScriptedVault();
    reader = ScriptedIdentityReader();
    navigatorKey = GlobalKey<NavigatorState>();
    messengerKey = GlobalKey<ScaffoldMessengerState>();
    coordinator = PromptCoordinator(
      engine: bridge,
      vault: vault,
      identityReader: reader,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
    );
  });

  tearDown(() {
    coordinator.dispose();
  });

  testWidgets('host-key first use renders and trusts', (tester) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p1',
        EnginePromptKind.hostKeyFirstUse,
        const HostKeyPromptData(
          host: 'example.com',
          port: 2222,
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:presented',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unknown host key'), findsOneWidget);
    await tester.tap(find.text('Trust and connect'));
    await tester.pumpAndSettle();

    expect(bridge.replies, hasLength(1));
    expect(bridge.replies.single.$1, 'p1');
    expect(bridge.replies.single.$2, EnginePromptKind.hostKeyFirstUse);
    expect(bridge.replies.single.$3, isA<HostKeyPromptReply>());
    expect(
      (bridge.replies.single.$3 as HostKeyPromptReply).accepted,
      isTrue,
    );
  });

  testWidgets('declining a changed key answers accepted:false', (tester) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p1',
        EnginePromptKind.hostKeyChanged,
        const HostKeyPromptData(
          host: 'example.com',
          port: 2222,
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:changed',
          pinnedFingerprintSha256: 'SHA256:original',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      (bridge.replies.single.$3 as HostKeyPromptReply).accepted,
      isFalse,
    );
  });

  testWidgets('keyboard-interactive answers travel back', (tester) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p2',
        EnginePromptKind.keyboardInteractive,
        const KeyboardInteractivePromptData(
          name: 'Duo',
          instruction: '',
          prompts: ['Passcode'],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Passcode'), '42');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    final reply = bridge.replies.single.$3 as KeyboardInteractivePromptReply;
    expect(reply.answers, ['42']);
  });

  testWidgets('agent auth answers immediately without any dialog', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p3',
        EnginePromptKind.credentialNeeded,
        const CredentialPromptData(
          host: 'example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final reply = bridge.replies.single.$3 as CredentialPromptReply;
    expect(reply.origin, CredentialOrigin.stored);
    expect(reply.password, isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a stored, matching secret answers as stored, no dialog', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();
    vault.secret = const Secret(
      id: 'secret-7',
      kind: SecretKind.password,
      value: 'stored-pw',
    );

    bridge.emit(
      _event(
        'p4',
        EnginePromptKind.credentialNeeded,
        _credential.copyWithSecretRef('secret-7'),
      ),
    );
    await tester.pumpAndSettle();

    final reply = bridge.replies.single.$3 as CredentialPromptReply;
    expect(reply.origin, CredentialOrigin.stored);
    expect(reply.password, 'stored-pw');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a vault miss prompts; the typed answer replies as prompted', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p5',
        EnginePromptKind.credentialNeeded,
        _credential.copyWithSecretRef('secret-7'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    final reply = bridge.replies.single.$3 as CredentialPromptReply;
    expect(reply.origin, CredentialOrigin.prompted);
    expect(reply.password, 'pw');
    expect(vault.puts, isEmpty, reason: 'saving requires opting in');
  });

  testWidgets('opting into save stores the typed secret under the ref', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p6',
        EnginePromptKind.credentialNeeded,
        _credential.copyWithSecretRef('secret-7'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(vault.puts.single.id, 'secret-7');
    expect(vault.puts.single.value, 'pw');
    final reply = bridge.replies.single.$3 as CredentialPromptReply;
    expect(reply.password, 'pw');
  });

  testWidgets('a locked vault surfaces its banner and still accepts typing', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();
    vault.readFailure = StateError('keyring locked');

    bridge.emit(
      _event(
        'p7',
        EnginePromptKind.credentialNeeded,
        _credential.copyWithSecretRef('secret-7'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('the OS keyring is locked or missing'),
        findsOneWidget);
    expect(find.textContaining('keyring locked'), findsNothing,
        reason: 'the raw port exception never renders (D20)');

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(
      (bridge.replies.single.$3 as CredentialPromptReply).password,
      'pw',
    );
  });

  testWidgets('a private-key prompt reads the identity file through the '
      'audited reader', (tester) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p8',
        EnginePromptKind.credentialNeeded,
        const CredentialPromptData(
          host: 'example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.privateKey,
          identityFilePath: '~/.ssh/id_ed25519',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Passphrase'),
      'phrase',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(reader.reads, ['~/.ssh/id_ed25519']);
    final reply = bridge.replies.single.$3 as CredentialPromptReply;
    expect(reply.privateKeyPem, 'OPENSSH PRIVATE KEY');
    expect(reply.keyPassphrase, 'phrase');
  });

  testWidgets('an engine dismissal closes the open dialog without replying', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event('p9', EnginePromptKind.hostKeyFirstUse,
          const HostKeyPromptData(
        host: 'example.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:presented',
      )),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    bridge.dismiss('p9', EnginePromptKind.hostKeyFirstUse);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.replies, isEmpty);
  });

  testWidgets('a dismissal racing the vault read suppresses the dialog', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p10',
        EnginePromptKind.credentialNeeded,
        _credential.copyWithSecretRef('secret-7'),
      ),
    );
    // The dismissal lands while the vault read is still pending.
    await tester.pump();
    bridge.dismiss('p10', EnginePromptKind.credentialNeeded);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.replies, isEmpty);
  });

  testWidgets('two prompts render one at a time, in FIFO order', (tester) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'a',
        EnginePromptKind.hostKeyFirstUse,
        const HostKeyPromptData(
          host: 'a.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:a',
        ),
      ),
    );
    bridge.emit(
      _event(
        'b',
        EnginePromptKind.keyboardInteractive,
        const KeyboardInteractivePromptData(
          name: 'Duo',
          instruction: '',
          prompts: ['Passcode'],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Only the first dialog is up; the second waits its turn.
    expect(find.text('Unknown host key'), findsOneWidget);
    expect(find.text('Duo'), findsNothing);

    await tester.tap(find.text('Trust and connect'));
    await tester.pumpAndSettle();

    expect(find.text('Duo'), findsOneWidget);
    expect(bridge.replies, hasLength(1));
    expect(bridge.replies.single.$1, 'a');
  });

  testWidgets('a queued prompt the engine dismissed never renders', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'a',
        EnginePromptKind.hostKeyFirstUse,
        const HostKeyPromptData(
          host: 'a.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:a',
        ),
      ),
    );
    bridge.emit(
      _event(
        'b',
        EnginePromptKind.keyboardInteractive,
        const KeyboardInteractivePromptData(
          name: 'Duo',
          instruction: '',
          prompts: ['Passcode'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    bridge.dismiss('b', EnginePromptKind.keyboardInteractive);

    await tester.tap(find.text('Trust and connect'));
    await tester.pumpAndSettle();

    // The queue skipped the dismissed prompt; nothing else shows.
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.replies.map((r) => r.$1), ['a']);
  });

  testWidgets('cancelling the credential prompt answers cancelled', (
    tester,
  ) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();

    bridge.emit(
      _event(
        'p11',
        EnginePromptKind.credentialNeeded,
        _credential.copyWithSecretRef('secret-7'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final reply = bridge.replies.single.$3 as CredentialPromptReply;
    expect(reply.cancelled, isTrue);
  });

  testWidgets('a failing vault save shows a transient notice, connect '
      'proceeds', (tester) async {
    await _pumpHost(tester, navigatorKey, messengerKey);
    coordinator.start();
    vault.writeFailure = StateError('disk full');

    bridge.emit(
      _event(
        'p12',
        EnginePromptKind.credentialNeeded,
        _credential.copyWithSecretRef('secret-7'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save the secret to the vault'),
        findsOneWidget);
    expect(
      (bridge.replies.single.$3 as CredentialPromptReply).password,
      'pw',
    );
  });
}

Future<void> _pumpHost(
  WidgetTester tester,
  GlobalKey<NavigatorState> navigatorKey,
  GlobalKey<ScaffoldMessengerState> messengerKey,
) async {
  await tester.pumpWidget(
    PoltergeistApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
    ),
  );
  await tester.pump();
}

extension on CredentialPromptData {
  CredentialPromptData copyWithSecretRef(String ref) =>
      CredentialPromptData(
        host: host,
        port: port,
        username: username,
        authMethod: authMethod,
        secretRef: ref,
        identityFilePath: identityFilePath,
      );
}
