@Tags(['integration'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../../../../test/integration/fixture_process.dart';

const _hostVariable = 'POLTERGEIST_SSHD';
const _modernPortVariable = 'POLTERGEIST_SSHD_MODERN';
const _authmatrixPortVariable = 'POLTERGEIST_SSHD_AUTHMATRIX';
const _interactiveUsername = 'keyboard-only';
const _interactiveKinds = [
  AuthKind.keyboardInteractive,
  AuthKind.promptedPassword,
];
const _defaultPolicy = PoolPolicy();
const _operationTimeout = Duration(seconds: 15);
// A swap plus one recovery backoff cycle can approach a minute.
const _blockedTimeout = Duration(seconds: 75);
const _serviceTimeout = Duration(seconds: 50);
const _pollInterval = Duration(milliseconds: 20);
const _queueObservation = Duration(milliseconds: 200);
const _changedKeyDetail = 'has changed';

void main() {
  final environment = Platform.environment;
  final modernEnabled =
      environment[_hostVariable] != null &&
      environment[_modernPortVariable] != null;
  final authmatrixEnabled =
      environment[_hostVariable] != null &&
      environment[_authmatrixPortVariable] != null;

  group('keyboard-interactive auth against real sshd', () {
    late _Fixture fixture;

    setUpAll(() async {
      fixture = await _Fixture.load(_FixtureService.authmatrix);
    });

    test(
      'answers one challenge, then caps the pool at one transport',
      () async {
        final harness = fixture.manager(
          username: _interactiveUsername,
          method: AuthMethod.password,
          credentials: SshCredentials.password(fixture.password),
          // The keyboard-interactive suite pre-seeds the shared fixture pin
          // (08 §5): only the TOFU suite manages pin state deliberately.
          pinStore: await fixture.preSeededStore(),
          review: _decliningReview('a pre-seeded fixture must never prompt'),
        );
        final manager = harness._manager;
        final serverId = harness._server.id;

        final pane = await manager.openBrowseChannel(
          serverId,
          paneTabId: 'left',
        );
        // The auxiliary fixture users own empty homes; canonicalization is
        // the end-to-end SFTP proof over the interactive transport.
        expect(await pane.fs.canonicalize('.'), pane.homePath);
        expect(harness._authKinds, everyElement(isIn(_interactiveKinds)));
        expect(harness._challenges, hasLength(1));
        expect(harness._challenges.single.prompts, hasLength(1));

        // Leases up to the single transport's transfer budget.
        final capacity = _defaultPolicy.maxTransferChannelsPerTransport;
        final leases = <TransferChannelLease>[];
        for (var index = 0; index < capacity; index++) {
          leases.add(
            await manager
                .leaseTransferChannel(serverId)
                .timeout(_operationTimeout),
          );
        }

        // The queued fifth lease must not grow the pool: a second connect
        // would re-run authentication on an interactive-auth server (D5).
        final waiting = manager.leaseTransferChannel(serverId);
        await expectLater(
          waiting.timeout(_queueObservation),
          throwsA(isA<TimeoutException>()),
        );
        expect(harness._opens, hasLength(1));
        expect(harness._challenges, hasLength(1));

        final returnedFs = leases.first.fs;
        await leases.first.release();
        final acquired = await waiting.timeout(_operationTimeout);
        expect(acquired.fs, same(returnedFs));
        expect(await pane.fs.canonicalize('.'), pane.homePath);
        await acquired.release();
      },
    );
  }, skip: authmatrixEnabled ? false : 'Set $_hostVariable and '
        '$_authmatrixPortVariable to enable.');

  group('TOFU against real sshd', () {
    late _Fixture fixture;

    setUpAll(() async {
      fixture = await _Fixture.load(_FixtureService.modern);
    });

    test('first use prompts once, pins, and verifies silently after', () async {
      // The TOFU suite owns a private, empty store per test (08 §5).
      final store = InMemoryHostKeyStore();
      final harness = fixture.manager(pinStore: store, review: _firstUseOnly);
      final manager = harness._manager;
      final serverId = harness._server.id;

      // Two panes opening concurrently fold into one first connect: one
      // host-key prompt for the whole pool (03 §3.2 rule 1).
      final panes = await Future.wait([
        manager.openBrowseChannel(serverId, paneTabId: 'left'),
        manager.openBrowseChannel(serverId, paneTabId: 'right'),
      ]);
      for (final pane in panes) {
        expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);
      }
      expect(harness._decisions.map((decision) => decision.verdict), [
        HostKeyVerdict.firstUse,
      ]);
      final pinned = await store.all();
      expect(pinned, hasLength(1));
      expect(pinned.single.type, fixture.hostKey.type);
      expect(
        pinned.single.fingerprintSha256,
        fixture.hostKey.fingerprintSha256,
      );

      // Pool growth verifies the pinned key silently (no second prompt):
      // the fifth lease grows transport two, the cap fills both.
      final capacity =
          _defaultPolicy.maxTransports *
          _defaultPolicy.maxTransferChannelsPerTransport;
      final leases = <TransferChannelLease>[];
      for (var index = 0; index < capacity; index++) {
        leases.add(
          await manager
              .leaseTransferChannel(serverId)
              .timeout(_operationTimeout),
        );
      }
      expect(harness._opens, hasLength(2));
      expect(
        harness._opens.last.prompting,
        ConnectPrompting.disabled,
        reason: 'growth never prompts (03 §3.2 rule 3)',
      );
      expect(harness._decisions, hasLength(1));

      // A second connect on a fresh pool verifies the pin silently too.
      for (final lease in leases) {
        await lease.release();
      }
      for (final pane in panes) {
        await pane.close();
      }
      await manager.disconnectServer(serverId);
      final revisited = await manager.openBrowseChannel(
        serverId,
        paneTabId: 'left',
      );
      expect(await revisited.fs.listDirectory(revisited.homePath), isNotEmpty);
      expect(harness._decisions, hasLength(1));
      expect(await store.all(), hasLength(1));
      await revisited.close();
    });
  }, skip: modernEnabled ? false : 'Set $_hostVariable and '
        '$_modernPortVariable to enable.');

  // Declined changed keys must stay blocked; this group stops sshd-modern,
  // so it runs last and restores the original service in teardown.
  group('changed key against real sshd', () {
    late _Fixture fixture;
    Future<void> Function()? restore;

    setUpAll(() async {
      fixture = await _Fixture.load(_FixtureService.modern);
    });
    // A failed assertion after the swap must not strand later suites.
    tearDownAll(() => restore?.call());

    test('hard-blocks every operation without re-pinning', () async {
      final store = await fixture.preSeededStore();
      final harness = fixture.manager(pinStore: store, review: _firstUseOnly);
      final manager = harness._manager;
      final serverId = harness._server.id;

      final pane = await manager.openBrowseChannel(serverId, paneTabId: 'left');
      expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);

      await fixture.control(_FixtureAction.swap);
      restore = () => fixture.control(_FixtureAction.restoreModern);

      // Recovery reconnects without prompting; the changed key blocks it.
      await _until(
        () => harness._states.contains(ServerConnectionState.blocked),
        'the changed key to block the pool',
        timeout: _blockedTimeout,
      );
      expect(
        harness._details.whereType<String>(),
        anyElement(contains(_changedKeyDetail)),
      );

      // Every operation on the existing pane fails with the block reason.
      expect(() => pane.fs, throwsA(_blockedError()));

      // A fresh acquisition reviews the change and, declined, stays blocked.
      await expectLater(
        manager.openBrowseChannel(serverId, paneTabId: 'fresh'),
        throwsA(_blockedError()),
      );
      expect(
        harness._decisions.map((decision) => decision.verdict),
        contains(HostKeyVerdict.changed),
      );

      // No auto-repin: the store still holds only the original key (D18).
      final pinned = await store.all();
      expect(pinned, hasLength(1));
      expect(
        pinned.single.fingerprintSha256,
        fixture.hostKey.fingerprintSha256,
      );
    });
  }, skip: modernEnabled ? false : 'Set $_hostVariable and '
        '$_modernPortVariable to enable.');
}

Future<void> _until(
  bool Function() ready,
  String description, {
  Duration timeout = _operationTimeout,
}) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed >= timeout) {
      fail('Timed out waiting for $description.');
    }
    await Future<void>.delayed(_pollInterval);
  }
}

Matcher _blockedError() => isA<RemoteFileException>().having(
  (error) => error.message,
  'message',
  contains(_changedKeyDetail),
);

/// Approves first-use decisions only. Declining changed keys keeps this
/// suite off restored-key-review behavior, which awaits an owner decision
/// (STATUS open item 6).
Future<bool> _firstUseOnly(HostKeyDecision decision) async =>
    decision.verdict == HostKeyVerdict.firstUse;

HostKeyPrompter _decliningReview(String reason) {
  return (_) async {
    fail(reason);
  };
}

enum _FixtureAction { swap, restoreModern }

enum _FixtureService { modern, authmatrix }

/// One observed opener call: the prompting mode it ran with and, when the
/// connect landed, how it authenticated.
final class _OpenCall {
  final ConnectPrompting prompting;
  AuthKind? authKind;

  _OpenCall(this.prompting);
}

/// Owns fixture configuration and its existing safe lifecycle helper.
class _Fixture {
  final Uri _root;
  final String _host;
  final int _port;
  final String _username;
  final String _privateKey;
  final String password;
  final HostKey hostKey;

  _Fixture(
    this._root,
    this._host,
    this._port,
    this._username,
    this._privateKey,
    this.password,
    this.hostKey,
  );

  static Future<_Fixture> load(_FixtureService service) async {
    final package = await Isolate.resolvePackageUri(
      Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
    );
    if (package == null) throw StateError('Core package is unresolved.');

    final root = package.resolve('../../../');
    String requiredVariable(String name) =>
        Platform.environment[name] ??
        (throw StateError('The enabled fixture requires $name.'));
    final host = requiredVariable(_hostVariable);
    if (host != InternetAddress.loopbackIPv4.address) {
      throw StateError('The Docker fixture must use IPv4 loopback.');
    }

    final port = int.parse(
      requiredVariable(
        service == _FixtureService.modern
            ? _modernPortVariable
            : _authmatrixPortVariable,
      ),
    );
    final publicKey = (await File.fromUri(
      root.resolve('test/integration/keys/ssh_host_ed25519_key.pub'),
    ).readAsString()).trim().split(RegExp(r'\s+'));
    return _Fixture(
      root,
      host,
      port,
      requiredVariable('POLTERGEIST_SSHD_USER'),
      await File(requiredVariable('POLTERGEIST_SSHD_KEY')).readAsString(),
      requiredVariable('POLTERGEIST_SSHD_PASSWORD'),
      HostKey.fromPublicKey(
        host: host,
        port: port,
        type: publicKey[0],
        publicKeyBase64: publicKey[1],
        pinnedAt: 0,
      ),
    );
  }

  /// The committed pin shared by every non-keyswap service (08 §5).
  Future<InMemoryHostKeyStore> preSeededStore() async {
    final store = InMemoryHostKeyStore();
    await store.put(hostKey);
    return store;
  }

  _AuthHarness manager({
    String? username,
    AuthMethod method = AuthMethod.privateKey,
    SshCredentials? credentials,
    required HostKeyStore pinStore,
    required HostKeyPrompter review,
  }) {
    final server = ServerConfig(
      id: 'fixture-auth',
      label: 'fixture-auth',
      host: _host,
      port: _port,
      username: username ?? _username,
      authMethod: method,
      createdAt: 0,
      updatedAt: 0,
    );
    final harness = _AuthHarness(
      server,
      credentials ?? SshCredentials.privateKey(_privateKey),
      password,
      pinStore,
      review,
    );
    addTearDown(harness._dispose);
    return harness;
  }

  Future<void> control(_FixtureAction action) async {
    final result = await runFixtureProcess(
      'bash',
      [
        _root.resolve('test/integration/service-control.sh').toFilePath(),
        switch (action) {
          _FixtureAction.swap => 'swap',
          _FixtureAction.restoreModern => 'restore-modern',
        },
      ],
      timeout: _serviceTimeout,
      environment: {'DART_BIN': Platform.resolvedExecutable},
    );
    expect(
      result.exitCode,
      0,
      reason: 'Fixture ${action.name}: ${result.stdout}\n${result.stderr}',
    );
  }
}

/// Records prompts and opens while exercising the production opener —
/// the real connection layer, not a fake transport (07 §3.3).
class _AuthHarness {
  final ServerConfig _server;
  final SshCredentials _credentials;
  final String _challengeAnswer;
  final HostKeyStore _store;
  final HostKeyPrompter _review;
  final _decisions = <HostKeyDecision>[];
  final _challenges = <({List<String> prompts, String name})>[];
  final _opens = <_OpenCall>[];
  final _states = <ServerConnectionState>[];
  final _details = <String?>[];
  late final _manager = PooledConnectionManager(
    resolveServer: (_) async => _server,
    resolveCredentials: (_, _) async => ResolvedCredentials(
      credentials: _credentials,
      origin: CredentialOrigin.stored,
    ),
    tofu: TofuVerifier(_store),
    onHostKey: (decision) async {
      _decisions.add(decision);
      return _review(decision);
    },
    onKeyboardInteractive: (prompts, name, instruction) async {
      _challenges.add((prompts: prompts, name: name));
      return [for (final _ in prompts) _challengeAnswer];
    },
    policy: _defaultPolicy,
    openTransport: _open,
  );
  late final StreamSubscription<ServerStatus> _watch;

  _AuthHarness(
    this._server,
    this._credentials,
    this._challengeAnswer,
    this._store,
    this._review,
  ) {
    _watch = _manager.watchServer(_server.id).listen((status) {
      _states.add(status.state);
      _details.add(status.detail);
    });
  }

  List<AuthKind> get _authKinds => [
    for (final call in _opens)
      if (call.authKind != null) call.authKind!,
  ];

  Future<SshTransport> _open({
    required ServerConfig config,
    required SshCredentials credentials,
    required TofuVerifier tofu,
    required HostKeyPrompter onHostKey,
    KeyboardInteractiveResponder? onKeyboardInteractive,
    required ConnectPrompting prompting,
    Duration timeout = SshTransport.defaultOpenTimeout,
    SshConnectionLog? log,
  }) async {
    final call = _OpenCall(prompting);
    _opens.add(call);
    final transport = await openDartSshTransport(
      config: config,
      credentials: credentials,
      tofu: tofu,
      onHostKey: onHostKey,
      onKeyboardInteractive: onKeyboardInteractive,
      prompting: prompting,
      timeout: timeout,
      log: log,
    );
    call.authKind = transport.authKind;
    return transport;
  }

  Future<void> _dispose() async {
    try {
      await _manager.disconnectServer(_server.id);
    } finally {
      await _watch.cancel();
    }
  }
}
