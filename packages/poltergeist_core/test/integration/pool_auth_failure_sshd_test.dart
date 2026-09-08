@Tags(['integration'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// 08 §5's auth-failure legs: the pinned upstream summarizer's three cause
// branches exercised end to end through the production opener against
// sshd-authmatrix — no fakes, and no re-implementation of the summarizer.
//
//   rejected-key  publickey accepted, the offered key itself declined
//                 → "was rejected … authorized_keys"
//   password-only publickey not accepted for that user
//                 → "Switch this server to a method the host allows"
//   root          password advertised but rejected for root
//                 → "PermitRootLogin prohibit-password"

const _hostVariable = 'POLTERGEIST_SSHD';
const _authmatrixPortVariable = 'POLTERGEIST_SSHD_AUTHMATRIX';
const _rejectedKeyUsername = 'rejected-key';
const _passwordOnlyUsername = 'password-only';
const _rootUsername = 'root';
const _defaultPolicy = PoolPolicy();
const _operationTimeout = Duration(seconds: 15);

// Cause phrases pinned by the upstream contract (Séance ssh_session.dart,
// consumed via the git pin); asserting them holds the pinned rev to its
// own summarized output at a real server.
const _switchMethodPhrase = 'Switch this server to a method the host allows';
const _rejectedKeyPhrase = 'was rejected';
const _prohibitPasswordPhrase = 'prohibit-password';

void main() {
  final environment = Platform.environment;
  final authmatrixEnabled =
      environment[_hostVariable] != null &&
      environment[_authmatrixPortVariable] != null;

  group('auth failure summaries against real sshd', () {
    late _Fixture fixture;

    setUpAll(() async {
      fixture = await _Fixture.load();
    });

    test('a rejected key is named and points at authorized_keys', () async {
      final result = await _failingConnect(
        fixture,
        username: _rejectedKeyUsername,
        method: AuthMethod.privateKey,
        credentials: SshCredentials.privateKey(fixture.privateKey),
      );
      final message = result.failure.message;

      await _expectSummarized(
        result,
        prefix:
            'Authentication failed for $_rejectedKeyUsername@'
            '${fixture.host}:${fixture.port} (tried public key)',
      );
      expect(message, contains(' The server accepts: publickey.'));
      expect(message, contains(_rejectedKeyPhrase));
      expect(message, contains('Add its public half'));
      expect(message, contains('authorized_keys'));

      // The summary names the exact key this client offered: its fingerprint
      // also appears in the transcript's real "Offering key:" trace line.
      final fingerprint = RegExp(
        r'SHA256:[A-Za-z0-9+/]+={0,2}',
      ).firstMatch(message)?.group(0);
      expect(fingerprint, isNotNull, reason: 'the summary must name the key');
      expect(
        result.failure.log.lines.where(
          (line) => line.contains('Offering key: '),
        ),
        anyElement(contains(fingerprint!)),
      );

      // Branch separation: neither other cause is claimed.
      expect(message, isNot(contains(_switchMethodPhrase)));
      expect(message, isNot(contains(_prohibitPasswordPhrase)));
    });

    test('a method-not-accepted user is told to switch methods', () async {
      final result = await _failingConnect(
        fixture,
        username: _passwordOnlyUsername,
        method: AuthMethod.privateKey,
        credentials: SshCredentials.privateKey(fixture.privateKey),
      );
      final message = result.failure.message;

      await _expectSummarized(
        result,
        prefix:
            'Authentication failed for $_passwordOnlyUsername@'
            '${fixture.host}:${fixture.port} (tried public key)',
      );
      // That user's Match block leaves password as the only offered method.
      expect(message, contains(' The server accepts: password.'));
      expect(message, contains(_switchMethodPhrase));

      expect(message, isNot(contains(_rejectedKeyPhrase)));
      expect(message, isNot(contains(_prohibitPasswordPhrase)));
    });

    test('a root password rejection explains prohibit-password', () async {
      // The fixture password is root's real password: the rejection is
      // PermitRootLogin prohibit-password, not a wrong credential.
      final result = await _failingConnect(
        fixture,
        username: _rootUsername,
        method: AuthMethod.password,
        credentials: SshCredentials.password(fixture.password),
      );
      final message = result.failure.message;

      await _expectSummarized(
        result,
        prefix:
            'Authentication failed for $_rootUsername@'
            '${fixture.host}:${fixture.port} (tried password)',
      );
      expect(message, contains(_prohibitPasswordPhrase));
      expect(
        message,
        contains('Use a key, or log in as a non-root user and escalate.'),
      );

      expect(message, isNot(contains(_rejectedKeyPhrase)));
      expect(message, isNot(contains(_switchMethodPhrase)));
    });
  }, skip: authmatrixEnabled ? false : 'Set $_hostVariable and '
        '$_authmatrixPortVariable to enable.');
}

/// Drives one browse open that must fail, capturing the typed connect
/// failure plus the harness that observed it.
Future<({SshConnectException failure, _AuthHarness harness})>
_failingConnect(
  _Fixture fixture, {
  required String username,
  required AuthMethod method,
  required SshCredentials credentials,
}) async {
  final harness = await fixture.harness(
    username: username,
    method: method,
    credentials: credentials,
  );
  try {
    await harness
        ._manager
        .openBrowseChannel(harness._server.id, paneTabId: 'left')
        .timeout(_operationTimeout);
    fail('The rejected credential must not open a browse channel.');
  } on SshConnectException catch (error) {
    return (failure: error, harness: harness);
  }
}

/// The invariants every summarized auth failure shares (08 §5): an
/// actionable one-liner naming the target and the offered method, the real
/// server's accepted-methods detail mined from the transcript — never a raw
/// dartssh2 trace — delivered through one promptless production open whose
/// one-liner also fans out as the state-associated detail (03 §3.2).
Future<void> _expectSummarized(
  ({SshConnectException failure, _AuthHarness harness}) result, {
  required String prefix,
}) async {
  // The failure rethrows through awaited futures; let the status stream's
  // pending delivery settle before asserting on the recorded states.
  await pumpEventQueue();
  final message = result.failure.message;
  expect(message, startsWith('$prefix.'));
  expect(message, contains(' The server accepts: '));
  expect(message, isNot(contains('All authentication methods failed')));
  expect(message, isNot(contains('SSH_Message')));
  expect(result.failure.log.lines, isNotEmpty);

  expect(result.harness._opens, hasLength(1));
  expect(result.harness._opens.single.prompting, ConnectPrompting.enabled);
  expect(
    result.harness._decisions,
    isEmpty,
    reason: 'the pre-seeded fixture pin verifies without a host-key review',
  );
  expect(
    result.harness._challenges,
    isEmpty,
    reason: 'a rejected credential must never reach an interactive prompt',
  );

  expect(result.harness._states, containsAllInOrder([
    ServerConnectionState.connecting,
    ServerConnectionState.disconnected,
  ]));
  expect(result.harness._details.whereType<String>(), contains(message));
}

/// Loads fixture configuration from the exported environment (08 §5):
/// the authmatrix port plus the shared user key, password, and the
/// committed host-key pin pre-seeded into every non-TOFU suite.
/// The fixture username is not loaded — every case passes its own
/// authmatrix user.
class _Fixture {
  final String host;
  final int port;
  final String privateKey;
  final String password;
  final HostKey hostKey;

  _Fixture(
    this.host,
    this.port,
    this.privateKey,
    this.password,
    this.hostKey,
  );

  static Future<_Fixture> load() async {
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

    final port = int.parse(requiredVariable(_authmatrixPortVariable));
    final publicKey = (await File.fromUri(
      root.resolve('test/integration/keys/ssh_host_ed25519_key.pub'),
    ).readAsString()).trim().split(RegExp(r'\s+'));
    return _Fixture(
      host,
      port,
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

  Future<_AuthHarness> harness({
    required String username,
    required AuthMethod method,
    required SshCredentials credentials,
  }) async {
    final server = ServerConfig(
      id: 'fixture-auth-failure',
      label: 'fixture-auth-failure',
      host: host,
      port: port,
      username: username,
      authMethod: method,
      createdAt: 0,
      updatedAt: 0,
    );
    final harness = _AuthHarness(
      server,
      credentials,
      await preSeededStore(),
    );
    addTearDown(harness._dispose);
    return harness;
  }
}

/// One observed opener call: the prompting mode it ran with.
final class _OpenCall {
  final ConnectPrompting prompting;

  _OpenCall(this.prompting);
}

/// Exercises the production opener through a real pool — the connection
/// layer itself, not a fake transport (07 §3.3) — while recording prompts
/// and states for the assertions above.
class _AuthHarness {
  final ServerConfig _server;
  final SshCredentials _credentials;
  final HostKeyStore _store;
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
      // A pre-seeded fixture pin must never prompt (08 §5 pin isolation).
      // If the manager converts this throw into a connect failure, the
      // _decisions emptiness assertion in _expectSummarized still fails.
      fail('A pre-seeded fixture must never prompt: ${decision.verdict}');
    },
    onKeyboardInteractive: (prompts, name, _) async {
      _challenges.add((prompts: prompts, name: name));
      // Same fallback as the host-key guard: the emptiness assertion
      // catches a converted failure if this throw never surfaces raw.
      fail('An auth-failure case must not reach a prompt: $name');
    },
    policy: _defaultPolicy,
    openTransport: _open,
  );
  late final StreamSubscription<ServerStatus> _watch;

  _AuthHarness(this._server, this._credentials, this._store) {
    _watch = _manager.watchServer(_server.id).listen((status) {
      _states.add(status.state);
      _details.add(status.detail);
    });
  }

  Future<SshTransport> _open({
    required ServerConfig config,
    required SshCredentials credentials,
    required TofuVerifier tofu,
    required HostKeyPrompter onHostKey,
    KeyboardInteractiveResponder? onKeyboardInteractive,
    required ConnectPrompting prompting,
    Duration timeout = SshTransport.defaultOpenTimeout,
    SshConnectionLog? log,
  }) {
    _opens.add(_OpenCall(prompting));
    return openDartSshTransport(
      config: config,
      credentials: credentials,
      tofu: tofu,
      onHostKey: onHostKey,
      onKeyboardInteractive: onKeyboardInteractive,
      prompting: prompting,
      timeout: timeout,
      log: log,
    );
  }

  Future<void> _dispose() async {
    try {
      await _manager.disconnectServer(_server.id);
    } finally {
      await _watch.cancel();
    }
  }
}
