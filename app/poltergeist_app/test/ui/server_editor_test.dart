// The server editor against its [ServerEditorDelegate] seam — the port of
// Séance's server_editor_test.dart @ 035b0d8 minus its AppServices boot (the
// delegate is the seam the real services sit behind here), plus direct
// coverage of the pure save-planning helpers the port exposes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/server_editor.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

const _nowMs = 1780000000000;

ServerConfig _server(
  String id, {
  String label = 'web',
  String? secretRef,
  AuthMethod authMethod = AuthMethod.agent,
  bool excludeFromSync = false,
  int updatedAt = _nowMs,
}) => ServerConfig(
  id: id,
  label: label,
  host: '$id.example.com',
  port: 22,
  username: 'deploy',
  authMethod: authMethod,
  secretRef: secretRef,
  excludeFromSync: excludeFromSync,
  createdAt: _nowMs,
  updatedAt: updatedAt,
);

/// The application layer the editor writes through, reduced to a field
/// recorder: what lands in `saved` is what the app would persist.
final class _FakeDelegate extends ServerEditorDelegate {
  List<ServerConfig> serverList = const [];
  bool configured = false;
  (ServerConfig, Secret?)? saved;
  Secret? storedSecret;
  ConnectionTestResult? testResult;
  int testCalls = 0;
  TransferConcurrency defaultLimit = const TransferConcurrency.automatic();
  final Map<String, TransferConcurrency> limits = {};
  final List<(String, TransferConcurrency?)> limitWrites = [];
  Object? limitWriteFailure;

  @override
  List<ServerConfig> get servers => serverList;

  @override
  bool get syncConfigured => configured;

  @override
  Color get themeSeed => const Color(0xFF335577);

  @override
  Future<String?> pickIdentityFile() async => null;

  @override
  Future<Secret?> readSecret(String secretId) async => storedSecret;

  @override
  Future<void> save(ServerConfig config, {Secret? secret}) async {
    saved = (config, secret);
    serverList = [...serverList, config];
  }

  @override
  TransferConcurrency get defaultTransferConcurrency => defaultLimit;

  @override
  TransferConcurrency? transferConcurrencyFor(String serverId) =>
      limits[serverId];

  @override
  Future<void> saveTransferConcurrency(
    String serverId,
    TransferConcurrency? value,
  ) async {
    limitWrites.add((serverId, value));
    if (limitWriteFailure case final failure?) throw failure;
    if (value == null) {
      limits.remove(serverId);
    } else {
      limits[serverId] = value;
    }
  }

  @override
  Future<ConnectionTestResult> testConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    SshConnectionLog? log,
  }) async {
    testCalls++;
    log?.add('trial handshake');
    return testResult ??
        const ConnectionTestResult(
          ok: true,
          summary: 'Connected.',
          log: 'trial handshake\n',
        );
  }
}

void main() {
  late _FakeDelegate delegate;

  setUp(() => delegate = _FakeDelegate());

  Future<void> openEditor(
    WidgetTester tester, {
    ServerConfig? existing,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showServerEditor(context, delegate, existing),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text(existing == null ? 'Add server' : 'Edit server'),
      findsOneWidget,
    );
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  /// The dialog's own scrollable, as opposed to one of its text fields'.
  Future<void> scrollTo(WidgetTester tester, Finder target) =>
      tester.scrollUntilVisible(
        target,
        100,
        scrollable: find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  /// Type the three required fields, leaving the focus in the last of them.
  Future<void> fillRequired(WidgetTester tester) async {
    await tester.enterText(field('Label'), 'box');
    await tester.enterText(field('Host'), 'box.example.com');
    await tester.enterText(field('Username'), 'deploy');
    await tester.pump();
  }

  group('save', () {
    testWidgets('a new server lands through the delegate with a fresh id', (
      tester,
    ) async {
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final (config, secret) = delegate.saved!;
      expect(config.id, isNotEmpty);
      expect(config.label, 'box');
      expect(config.host, 'box.example.com');
      expect(config.username, 'deploy');
      expect(config.port, 22);
      expect(secret, isNull);
      expect(config.secretRef, isNull);
      // The dialog closed on success.
      expect(find.text('Add server'), findsNothing);
    });

    testWidgets('a typed password saves the credential and points the config '
        'at it', (tester) async {
      await openEditor(tester);
      await fillRequired(tester);
      // Auth method: password, then type it.
      await tester.tap(find.byType(DropdownButtonFormField<AuthMethod>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Password').last);
      await tester.pumpAndSettle();
      await tester.enterText(field('Password'), 'hunter2');

      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final (config, secret) = delegate.saved!;
      expect(secret?.kind, SecretKind.password);
      expect(secret?.value, 'hunter2');
      expect(config.secretRef, secret?.id);
      expect(config.authMethod, AuthMethod.password);
    });

    testWidgets('an edit with the credential left blank keeps the stored '
        'entry and its reference', (tester) async {
      final existing = _server(
        'web',
        authMethod: AuthMethod.password,
        secretRef: 'sec-1',
      );
      delegate.serverList = [existing];
      await openEditor(tester, existing: existing);

      // Change only the group, then save.
      await scrollTo(tester, field('Group'));
      await tester.enterText(field('Group'), 'Prod');
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final (config, secret) = delegate.saved!;
      expect(config.id, 'web');
      expect(config.group, 'Prod');
      // Blank means "keep what is stored" — no write, same reference.
      expect(secret, isNull);
      expect(config.secretRef, 'sec-1');
    });

    testWidgets('an edit stamps updatedAt past the freshest pulled copy', (
      tester,
    ) async {
      final existing = _server('web', updatedAt: 100);
      // A round landed a newer record than the editor opened with; the
      // stamp has to outrank it, or this edit silently loses LWW. Dated
      // ahead of the wall clock, so only consulting that freshest copy —
      // not "now" — can pass below.
      final pulled = DateTime.now().millisecondsSinceEpoch + 60000;
      delegate.serverList = [_server('web', updatedAt: pulled)];
      await openEditor(tester, existing: existing);
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final (config, _) = delegate.saved!;
      expect(config.updatedAt, greaterThan(pulled));
    });
  });

  // D37: the server's own cap on simultaneous transfers, stored on the
  // device beside the config rather than in it.
  group('simultaneous transfers', () {
    Finder menu() => find.byKey(const ValueKey('serverEditor.transferLimit'));

    Future<void> choose(WidgetTester tester, String entry) async {
      await scrollTo(tester, menu());
      await tester.tap(menu());
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry).last);
      await tester.pumpAndSettle();
    }

    Future<void> save(WidgetTester tester) async {
      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('names the default in force and stores a changed choice', (
      tester,
    ) async {
      delegate.defaultLimit = const TransferConcurrency.fixed(2);
      final existing = _server('web');
      delegate.serverList = [existing];
      await openEditor(tester, existing: existing);
      await scrollTo(tester, menu());
      expect(
        find.descendant(of: menu(), matching: find.text('Default (2)')),
        findsOneWidget,
      );

      await choose(tester, '1');
      await save(tester);
      expect(delegate.limitWrites, [
        ('web', const TransferConcurrency.fixed(1)),
      ]);
      expect(find.text('Edit server'), findsNothing);
    });

    testWidgets('an untouched choice is not written', (tester) async {
      final existing = _server('web');
      delegate.serverList = [existing];
      delegate.limits['web'] = const TransferConcurrency.automatic();
      await openEditor(tester, existing: existing);
      await scrollTo(tester, menu());
      expect(
        find.descendant(of: menu(), matching: find.text('Automatic')),
        findsOneWidget,
      );

      await save(tester);
      expect(delegate.saved, isNotNull);
      expect(delegate.limitWrites, isEmpty);
    });

    testWidgets('going back to the default clears the server\'s own cap', (
      tester,
    ) async {
      final existing = _server('web');
      delegate.serverList = [existing];
      delegate.limits['web'] = const TransferConcurrency.fixed(3);
      await openEditor(tester, existing: existing);

      await choose(tester, 'Default (Automatic)');
      await save(tester);
      expect(delegate.limitWrites, [('web', null)]);
      expect(delegate.limits, isEmpty);
    });

    testWidgets('a new server\'s cap is stored under the id it saves as', (
      tester,
    ) async {
      await openEditor(tester);
      await fillRequired(tester);
      await choose(tester, 'Automatic');
      await save(tester);

      final (config, _) = delegate.saved!;
      expect(delegate.limitWrites, [
        (config.id, const TransferConcurrency.automatic()),
      ]);
    });

    testWidgets('a cap that cannot be stored keeps the editor open to retry', (
      tester,
    ) async {
      final existing = _server('web');
      delegate.serverList = [existing];
      delegate.limitWriteFailure = StateError('settings are read-only');
      await openEditor(tester, existing: existing);

      await choose(tester, '2');
      await save(tester);
      // The server itself saved; only the cap failed, and the editor says
      // so and stays up with the choice still in it.
      expect(delegate.saved, isNotNull);
      expect(find.text('Edit server'), findsOneWidget);
      expect(
        find.textContaining('its transfer limit wasn\'t'),
        findsOneWidget,
      );

      delegate.limitWriteFailure = null;
      await save(tester);
      expect(delegate.limits['web'], const TransferConcurrency.fixed(2));
      expect(find.text('Edit server'), findsNothing);
      // Let the failure toast's dismissal timer run out.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('Return', () {
    testWidgets('in a one-line field saves the server', (tester) async {
      await openEditor(tester);
      await fillRequired(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(delegate.saved?.$1.label, 'box');
      expect(find.text('Add server'), findsNothing);
    });

    testWidgets('in the login script is a newline, not a save', (
      tester,
    ) async {
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(delegate.saved, isNull);
      expect(find.text('Add server'), findsOneWidget);
    });

    testWidgets('with a modifier saves from the login script too', (
      tester,
    ) async {
      await openEditor(tester);
      await fillRequired(tester);
      final script = field('Login script (optional)');
      await scrollTo(tester, script);
      await tester.enterText(script, 'cd ~/work');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(delegate.saved?.$1.loginScript, 'cd ~/work');
      expect(find.text('Add server'), findsNothing);
    });

    testWidgets('does nothing while the form does not validate', (
      tester,
    ) async {
      await openEditor(tester);
      await tester.enterText(field('Label'), 'box');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(delegate.saved, isNull);
      expect(find.text('Required'), findsWidgets);
    });
  });

  group('exclude from sync', () {
    testWidgets('turning it on for a synced server asks first', (
      tester,
    ) async {
      delegate.configured = true;
      delegate.serverList = [_server('web')];
      await openEditor(tester, existing: _server('web'));
      await scrollTo(tester, find.text('Exclude from sync'));
      await tester.tap(find.text('Exclude from sync'));
      await tester.pumpAndSettle();

      // The confirmation is its own dialog — dismiss and the switch
      // stays off. Scoped to the AlertDialog: the editor itself has a
      // Cancel too.
      expect(find.text('Exclude from sync?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Exclude from sync?'), findsNothing);
    });

    testWidgets('confirming retracts: the switch lands on', (tester) async {
      delegate.configured = true;
      delegate.serverList = [_server('web')];
      await openEditor(tester, existing: _server('web'));
      await scrollTo(tester, find.text('Exclude from sync'));
      await tester.tap(find.text('Exclude from sync'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Exclude'));
      await tester.pumpAndSettle();

      await scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(delegate.saved?.$1.excludeFromSync, isTrue);
    });
  });

  group('test connection', () {
    testWidgets('drives the delegate with the form config and reports', (
      tester,
    ) async {
      delegate.testResult = const ConnectionTestResult(
        ok: true,
        summary: 'Connected and authenticated.',
        log: 'transcript',
      );
      await openEditor(tester);
      await fillRequired(tester);
      await scrollTo(tester, find.text('Test connection'));
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(delegate.testCalls, 1);
      expect(find.textContaining('Connected and authenticated'), findsWidgets);
    });
  });

  group('plannedCredential', () {
    const storedPem = Secret(
      id: 'sec-1',
      kind: SecretKind.privateKey,
      value: 'STORED-PEM',
      keyPassphrase: 'old-phrase',
    );

    test('password auth writes a password only when typed', () {
      expect(
        plannedCredential(
          auth: AuthMethod.password,
          referenceKeyFile: false,
          password: '',
          keyPem: '',
          keyPassphrase: '',
          secretId: 's',
        ),
        isNull,
      );
      final secret = plannedCredential(
        auth: AuthMethod.password,
        referenceKeyFile: false,
        password: 'hunter2',
        keyPem: '',
        keyPassphrase: '',
        secretId: 's',
      )!;
      expect(secret.kind, SecretKind.password);
      expect(secret.value, 'hunter2');
    });

    test('agent auth never writes a credential', () {
      expect(
        plannedCredential(
          auth: AuthMethod.agent,
          referenceKeyFile: false,
          password: 'stray',
          keyPem: 'stray',
          keyPassphrase: 'stray',
          secretId: 's',
        ),
        isNull,
      );
    });

    test('a typed PEM writes the key, blank passphrase dropping the old one',
        () {
      final secret = plannedCredential(
        auth: AuthMethod.privateKey,
        referenceKeyFile: false,
        password: '',
        keyPem: 'PEM-BYTES',
        keyPassphrase: '',
        secretId: 's',
        stored: storedPem,
      )!;
      expect(secret.kind, SecretKind.privateKey);
      expect(secret.value, 'PEM-BYTES');
      // A re-pasted key brings its own passphrase — the stored one must not
      // silently apply to new material.
      expect(secret.keyPassphrase, isNull);
    });

    test('a referenced key writes only its passphrase, carrying the PEM', () {
      // Blank passphrase in reference mode plans nothing — the stored entry
      // is the credential already.
      expect(
        plannedCredential(
          auth: AuthMethod.privateKey,
          referenceKeyFile: true,
          password: '',
          keyPem: '',
          keyPassphrase: '',
          secretId: 's',
          stored: storedPem,
        ),
        isNull,
      );
      final secret = plannedCredential(
        auth: AuthMethod.privateKey,
        referenceKeyFile: true,
        password: '',
        keyPem: '',
        keyPassphrase: 'file-phrase',
        secretId: 's',
        stored: storedPem,
      )!;
      // The file's passphrase, not the stored PEM's, and the stored key
      // material carried so the entry stays a key.
      expect(secret.keyPassphrase, 'file-phrase');
      expect(secret.value, 'STORED-PEM');
    });

    test('a referenced key over a password-kind entry stores an empty PEM',
        () {
      final secret = plannedCredential(
        auth: AuthMethod.privateKey,
        referenceKeyFile: true,
        password: '',
        keyPem: '',
        keyPassphrase: 'file-phrase',
        secretId: 's',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'hunter2',
        ),
      )!;
      // The entry under this id belongs to whatever auth last wrote it — a
      // password must not be carried into a private-key slot.
      expect(secret.kind, SecretKind.privateKey);
      expect(secret.value, '');
    });

    test('reads the stored entry only on the carry-over branch', () {
      // The guard is where "fetch the vault entry first" is decided: wherever
      // it says no read happens, the plan must be identical with and without
      // one in hand.
      bool reads(AuthMethod auth, bool ref, String pass) =>
          plannedCredentialReadsStored(
            auth: auth,
            referenceKeyFile: ref,
            keyPassphrase: pass,
          );
      expect(reads(AuthMethod.privateKey, true, 'x'), isTrue);
      expect(reads(AuthMethod.privateKey, true, ''), isFalse);
      expect(reads(AuthMethod.privateKey, false, 'x'), isFalse);
      expect(reads(AuthMethod.password, true, 'x'), isFalse);
      expect(reads(AuthMethod.agent, true, 'x'), isFalse);
    });
  });

  group('excludingNeedsConfirmation', () {
    test('only an already-synced server confirms', () {
      expect(
        excludingNeedsConfirmation(existing: _server('web'), syncConfigured: true),
        isTrue,
      );
      // A server being added has never been anywhere.
      expect(
        excludingNeedsConfirmation(existing: null, syncConfigured: true),
        isFalse,
      );
      // Already excluded: retracted once already.
      expect(
        excludingNeedsConfirmation(
          existing: _server('web', excludeFromSync: true),
          syncConfigured: true,
        ),
        isFalse,
      );
      // No account linked: no other device could lose anything.
      expect(
        excludingNeedsConfirmation(
          existing: _server('web'),
          syncConfigured: false,
        ),
        isFalse,
      );
    });
  });

  group('nextUpdatedAt', () {
    test('advances past both the clock and the record', () {
      expect(nextUpdatedAt(100, now: 200), 200);
      // A fast peer's record this device pulled: the stamp has to beat it.
      expect(nextUpdatedAt(2000000000, now: 200), (2000000000) + 1);
      expect(nextUpdatedAt(null, now: 200), 200);
    });
  });
}
