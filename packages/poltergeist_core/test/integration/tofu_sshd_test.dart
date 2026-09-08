@TestOn('linux')
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
const _portVariable = 'POLTERGEIST_SSHD_MODERN';
const _primaryId = 'primary';
const _siblingId = 'sibling';
const _serverIds = [_primaryId, _siblingId];
const _operationTimeout = Duration(seconds: 15);
const _serviceTimeout = Duration(seconds: 50);
// Swap, restoration, recovery, and explicit SSH reviews have separate bounds.
const _swapTestTimeout = Timeout(Duration(minutes: 4));
const _policy = PoolPolicy(
  maxTransports: 2,
  maxTransferChannelsPerTransport: 1,
  maxChannelsPerTransport: 3,
);

void main() {
  final environment = Platform.environment;
  final enabled =
      environment[_hostVariable] != null && environment[_portVariable] != null;

  group('TOFU against real sshd', () {
    late _Fixture fixture;
    Future<void> Function()? restore;
    setUpAll(() async => fixture = await _Fixture._load());
    // Restore even when a swap or assertion fails; run.sh owns final cleanup.
    tearDownAll(() => restore?.call());

    test(
      'first use pins once; reconnect and pool growth verify silently',
      () async {
        final harness = fixture._pool();
        final entered = Completer<void>();
        final approval = Completer<bool>();
        addTearDown(() {
          if (!approval.isCompleted) approval.complete(false);
        });
        harness._onHostKey = (_) {
          if (!entered.isCompleted) entered.complete();
          return approval.future;
        };

        // Two bookmarks at one endpoint share even a pending trust decision.
        final opening = Future.wait([
          harness._manager.openBrowseChannel(_primaryId, paneTabId: 'left'),
          harness._manager.openBrowseChannel(_siblingId, paneTabId: 'right'),
        ]);
        final opened = expectLater(opening, completes);
        await entered.future.timeout(_operationTimeout);
        expect(await harness._store.all(), isEmpty);
        approval.complete(true);
        await opened;
        final panes = await opening;
        expect(harness._decisions, hasLength(1));
        final decision = harness._decisions.single;
        expect(decision.verdict, HostKeyVerdict.firstUse);
        expect(decision.pinned, isNull);
        expect(decision.presented.host, fixture._host);
        expect(decision.presented.port, fixture._port);
        expect(
          decision.presented.fingerprintSha256,
          fixture._originalFingerprint,
        );
        await harness._expectPin(fixture._originalFingerprint);
        expect(harness._attempts, [ConnectPrompting.enabled]);
        expect(panes.first.fs, isNot(same(panes.last.fs)));

        // The first transport holds two panes and one lease; this forces growth.
        await harness._manager.leaseTransferChannel(_primaryId);
        final grown = await harness._manager
            .leaseTransferChannel(_siblingId)
            .timeout(_operationTimeout);
        expect(harness._attempts, [
          ConnectPrompting.enabled,
          ConnectPrompting.disabled,
        ]);
        expect(harness._transports, hasLength(_policy.maxTransports));
        expect(await grown.fs.canonicalize('.'), panes.first.homePath);
        for (final pane in panes) {
          expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);
        }

        await harness._disconnect();
        final reopened = await harness._manager.openBrowseChannel(
          _primaryId,
          paneTabId: 'fresh-session',
        );
        expect(await reopened.fs.listDirectory(reopened.homePath), isNotEmpty);
        expect(harness._attempts, [
          ConnectPrompting.enabled,
          ConnectPrompting.disabled,
          ConnectPrompting.enabled,
        ]);
        expect(harness._decisions, hasLength(1));
        await harness._expectPin(fixture._originalFingerprint);
      },
    );

    test('declining first use stores no pin and retry asks again', () async {
      final harness = fixture._pool();
      harness._onHostKey = (_) async => false;
      await expectLater(
        harness._manager.openBrowseChannel(_primaryId, paneTabId: 'declined'),
        throwsA(isA<SshConnectException>()),
      );
      expect(harness._decisions, hasLength(1));
      expect(harness._decisions.single.verdict, HostKeyVerdict.firstUse);
      expect(await harness._store.all(), isEmpty);
      expect(await harness._manager.connectedServerIds(), isEmpty);
      expect(harness._transports, isEmpty);

      harness._onHostKey = (_) async => true;
      final pane = await harness._manager.openBrowseChannel(
        _primaryId,
        paneTabId: 'approved',
      );
      expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);
      expect(harness._decisions, hasLength(2));
      expect(
        harness._decisions.map((decision) => decision.verdict),
        everyElement(HostKeyVerdict.firstUse),
      );
      await harness._expectPin(fixture._originalFingerprint);
    });

    test('a swapped key blocks both bookmarks until explicit review', () async {
      // LIFO teardown closes the pool before restoring its original endpoint.
      addTearDown(() async {
        final restoring = restore;
        if (restoring == null) return;

        await restoring();
        restore = null;
      });
      final harness = fixture._pool();
      final panes = await Future.wait([
        harness._manager.openBrowseChannel(_primaryId, paneTabId: 'left'),
        harness._manager.openBrowseChannel(_siblingId, paneTabId: 'right'),
      ]);
      final lease = await harness._manager.leaseTransferChannel(_primaryId);
      await harness._expectPin(fixture._originalFingerprint);
      expect(harness._decisions, hasLength(1));

      restore = () => fixture._control(_ServiceAction.restoreModern);
      await fixture._control(_ServiceAction.swap);
      for (final id in _serverIds) {
        final status = await harness._manager
            .watchServer(id)
            .firstWhere(
              (status) => status.state == ServerConnectionState.blocked,
            )
            .timeout(_policy.reconnectBackoffCap + _operationTimeout);
        expect(status.detail, contains('has changed'));
        expect(status.detail, contains(fixture._originalFingerprint));
        expect(status.detail, contains(fixture._swappedFingerprint));
      }

      // Recovery detects the changed key without asking or replacing the pin.
      expect(harness._decisions, hasLength(1));
      expect(harness._attempts.last, ConnectPrompting.disabled);
      expect(harness._transports, hasLength(1));
      expect(harness._transports.single.isClosed, isTrue);
      expect(await harness._manager.connectedServerIds(), isEmpty);
      await harness._expectPin(fixture._originalFingerprint);
      for (final pane in panes) {
        expect(
          () => pane.fs.listDirectory(pane.homePath),
          throwsA(_changedKey),
        );
      }
      expect(() => lease.fs.canonicalize('.'), throwsA(_changedKey));
      final attemptsBeforeWorkers = harness._attempts.length;
      for (final id in _serverIds) {
        await expectLater(
          harness._manager.leaseTransferChannel(id),
          throwsA(_changedKey),
        );
      }
      expect(harness._attempts, hasLength(attemptsBeforeWorkers));
      expect(harness._decisions, hasLength(1));

      harness._onHostKey = (_) async => false;
      await expectLater(
        harness._manager.openBrowseChannel(_primaryId, paneTabId: 'decline'),
        throwsA(_changedKey),
      );
      expect(harness._decisions, hasLength(2));
      final changed = harness._decisions.last;
      expect(changed.verdict, HostKeyVerdict.changed);
      expect(changed.presented.host, fixture._host);
      expect(changed.presented.port, fixture._port);
      expect(changed.presented.fingerprintSha256, fixture._swappedFingerprint);
      expect(changed.pinned!.fingerprintSha256, fixture._originalFingerprint);
      await harness._expectPin(fixture._originalFingerprint);

      harness._onHostKey = (_) async => true;
      final reviewed = await harness._manager.openBrowseChannel(
        _primaryId,
        paneTabId: 'accept',
      );
      expect(await reviewed.fs.listDirectory(reviewed.homePath), isNotEmpty);
      expect(harness._decisions, hasLength(3));
      expect(harness._decisions.last.verdict, HostKeyVerdict.changed);
      await harness._expectPin(fixture._swappedFingerprint);
      final sibling = await harness._manager.openBrowseChannel(
        _siblingId,
        paneTabId: 'reviewed-sibling',
      );
      expect(await sibling.fs.listDirectory(sibling.homePath), isNotEmpty);
      expect(harness._decisions, hasLength(3));
    }, timeout: _swapTestTimeout);

    test('subsequent tests see the original fixture host key', () async {
      final harness = fixture._pool();
      final pane = await harness._manager.openBrowseChannel(
        _primaryId,
        paneTabId: 'after-swap',
      );
      expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);
      expect(harness._decisions.single.verdict, HostKeyVerdict.firstUse);
      await harness._expectPin(fixture._originalFingerprint);
    });
  }, skip: enabled ? false : 'Set $_hostVariable and $_portVariable to enable.');
}

final _changedKey = isA<RemoteFileException>()
    .having((error) => error.kind, 'kind', RemoteFileErrorKind.other)
    .having((error) => error.message, 'message', contains('has changed'));

enum _ServiceAction {
  swap('swap'),
  restoreModern('restore-modern');

  final String _argument;
  const _ServiceAction(this._argument);
}

/// Keeps fixture files and Docker lifecycle outside the pool assertions.
class _Fixture {
  final Uri _root;
  final String _host;
  final int _port;
  final String _username;
  final String _privateKey;
  final String _originalFingerprint;
  final String _swappedFingerprint;

  _Fixture(
    this._root,
    this._host,
    this._port,
    this._username,
    this._privateKey,
    this._originalFingerprint,
    this._swappedFingerprint,
  );

  static Future<_Fixture> _load() async {
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

    final port = int.parse(requiredVariable(_portVariable));
    Future<String> fingerprint(String file) async {
      final key = (await File.fromUri(
        root.resolve('test/integration/keys/$file.pub'),
      ).readAsString()).trim().split(RegExp(r'\s+'));
      return HostKey.fromPublicKey(
        host: host,
        port: port,
        type: key[0],
        publicKeyBase64: key[1],
        pinnedAt: 0,
      ).fingerprintSha256;
    }

    return _Fixture(
      root,
      host,
      port,
      requiredVariable('POLTERGEIST_SSHD_USER'),
      await File(requiredVariable('POLTERGEIST_SSHD_KEY')).readAsString(),
      await fingerprint('ssh_host_ed25519_key'),
      await fingerprint('ssh_host_ed25519_key_swap'),
    );
  }

  _PoolHarness _pool() {
    final harness = _PoolHarness(this);
    addTearDown(harness._dispose);
    return harness;
  }

  Future<void> _control(_ServiceAction action) async {
    final result = await runFixtureProcess(
      'bash',
      [
        _root.resolve('test/integration/service-control.sh').toFilePath(),
        action._argument,
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

/// Each test owns its pins; only real SSH handshakes may change them.
class _PoolHarness {
  final _Fixture _fixture;
  final _store = InMemoryHostKeyStore();
  final _decisions = <HostKeyDecision>[];
  final _attempts = <ConnectPrompting>[];
  final _transports = <SshTransport>[];
  final _unexpectedPrompts = <String>[];
  HostKeyPrompter _onHostKey = (_) async => true;
  late final _manager = PooledConnectionManager(
    resolveServer: (id) async => ServerConfig(
      id: id,
      label: id,
      host: _fixture._host,
      port: _fixture._port,
      username: _fixture._username,
      authMethod: AuthMethod.privateKey,
      createdAt: 0,
      updatedAt: 0,
    ),
    resolveCredentials: (_, _) async => ResolvedCredentials(
      credentials: SshCredentials.privateKey(_fixture._privateKey),
      origin: CredentialOrigin.stored,
    ),
    tofu: TofuVerifier(_store),
    onHostKey: (decision) async {
      _decisions.add(decision);
      return _onHostKey(decision);
    },
    onKeyboardInteractive: (_, _, _) async {
      _unexpectedPrompts.add('keyboard interactive');
      fail('Key-auth fixture must not prompt for credentials.');
    },
    policy: _policy,
    openTransport: _open,
  );

  _PoolHarness(this._fixture);

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
    _attempts.add(prompting);
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
    _transports.add(transport);
    return transport;
  }

  Future<void> _expectPin(String fingerprint) async {
    final pins = await _store.all();
    expect(pins, hasLength(1));
    expect(pins.single.host, _fixture._host);
    expect(pins.single.port, _fixture._port);
    expect(pins.single.fingerprintSha256, fingerprint);
  }

  Future<void> _disconnect() async {
    for (final id in _serverIds) {
      await _manager.disconnectServer(id);
    }
  }

  Future<void> _dispose() async {
    try {
      await _disconnect();
    } finally {
      // SSH can catch callback failures; record them independently of its result.
      expect(_unexpectedPrompts, isEmpty, reason: 'Unexpected fixture prompts');
    }
  }
}
