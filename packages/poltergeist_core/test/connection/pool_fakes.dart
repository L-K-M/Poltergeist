import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:seance_core/seance_core.dart';

/// In-memory TOFU pin store (tests never touch real persistence).
class FakeHostKeyStore implements HostKeyStore {
  final Map<String, HostKey> pins = {};

  @override
  Future<HostKey?> get(String host, int port) async => pins['$host:$port'];

  @override
  Future<void> put(HostKey key) async => pins['${key.host}:${key.port}'] = key;

  @override
  Future<List<HostKey>> all() async => List.of(pins.values);
}

/// Minimal filesystem stand-in: the pool only ever calls `canonicalize('.')`
/// on it (home resolution at open). Any other call fails loudly.
class StubRemoteFileSystem implements RemoteFileSystem {
  final String home;

  final Completer<void>? canonicalizeGate;

  StubRemoteFileSystem(this.home, {this.canonicalizeGate});

  @override
  Future<String> canonicalize(String path) async {
    // The pool only ever resolves the home — anything else means production
    // code drifted, and the stub must fail loudly, not invent a path.
    if (path != '.') {
      throw StateError(
        'StubRemoteFileSystem only supports canonicalize("."), got "$path".',
      );
    }
    await canonicalizeGate?.future;
    return home;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(
        'StubRemoteFileSystem only implements canonicalize("."), got '
        '${invocation.memberName}.',
      );
}

class FakeChannel implements SftpChannel {
  @override
  final RemoteFileSystem fs;

  bool closed = false;

  FakeChannel(this.fs);

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// A fake transport whose channels are plain records — pool and lease logic
/// without sockets (08 §3.2). Closed transports keep their channel list so
/// post-teardown assertions can inspect what was open.
class FakeTransport implements SshTransport {
  @override
  final AuthKind authKind;

  /// When set, [openChannel] throws once this many channels exist — the
  /// server-side MaxSessions refusal, for fallback-path tests.
  final int? openLimit;

  final List<FakeChannel> channels = [];
  bool closed = false;
  Completer<void>? openGate;
  Completer<void>? canonicalizeGate;

  FakeTransport({required this.authKind, this.openLimit});

  @override
  bool get isClosed => closed;

  @override
  Future<SftpChannel> openChannel({Duration timeout = SshTransport.defaultOpenTimeout}) async {
    if (closed) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'open SFTP',
        message: 'The SSH transport is disconnected.',
      );
    }
    if (openLimit != null &&
        channels.where((c) => !c.closed).length >= openLimit!) {
      // Aligned with the production funnel: a channel-open refusal is not
      // a RemoteFileException, so the transport maps it to `unsupported`.
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'open SFTP',
        message: 'Channel open refused (fake MaxSessions limit).',
      );
    }

    final channel = FakeChannel(StubRemoteFileSystem(
      '/home/test',
      canonicalizeGate: canonicalizeGate,
    ));
    channels.add(channel);
    await openGate?.future;
    return channel;
  }

  @override
  Future<void> close() async {
    closed = true;
    for (final channel in List<FakeChannel>.of(channels)) {
      await channel.close();
    }
  }
}

/// One recorded opener call — everything the growth rules reason about.
/// [transport] is null when the attempt failed (challenge or rejection):
/// the call itself still counts.
class RecordedOpenCall {
  final ServerConfig config;
  final SshCredentials credentials;
  final HostKeyPrompter onHostKey;
  final KeyboardInteractiveResponder? onKeyboardInteractive;
  final ConnectPrompting prompting;
  FakeTransport? transport;

  RecordedOpenCall({
    required this.config,
    required this.credentials,
    required this.onHostKey,
    required this.onKeyboardInteractive,
    required this.prompting,
    this.transport,
  });
}

/// Fake opener mirroring `openAuthenticatedClient`'s TOFU behavior: verify
/// through the verifier, prompt when untrusted, pin on approval. Growth
/// behavior is scripted per test.
class FakeTransportOpener {
  final AuthKind authKind;

  /// A prompting-disabled connect behaves as if the server demanded
  /// interaction: auth fails without a prompt (rule 3's growth case).
  final bool growthRequiresChallenge;

  /// Fingerprint presented per call (last value repeats) — index 1 differing
  /// from index 0 is how a key change is staged.
  final List<String> presentedFingerprints;

  /// Handed to every created transport: refuse opens past this many
  /// channels (a fake MaxSessions ceiling).
  final int? transportOpenLimit;

  /// When set, every prompting-disabled (growth) connect parks on this
  /// completer before returning — for teardown-race tests.
  Completer<void>? growthGate;

  final List<RecordedOpenCall> calls = [];

  FakeTransportOpener({
    this.authKind = AuthKind.key,
    this.growthRequiresChallenge = false,
    this.presentedFingerprints = const ['SHA256:presented'],
    this.transportOpenLimit,
  });

  SshTransportOpener get opener => ({
        required config,
        required credentials,
        required tofu,
        required onHostKey,
        onKeyboardInteractive,
        required prompting,
        timeout = const Duration(seconds: 15),
        log,
      }) async {
        final index = calls.length;
        final call = RecordedOpenCall(
          config: config,
          credentials: credentials,
          onHostKey: onHostKey,
          onKeyboardInteractive: onKeyboardInteractive,
          prompting: prompting,
        );
        calls.add(call);

        // An empty script is a test bug; fail with a clear message instead
        // of a mid-connect RangeError.
        if (presentedFingerprints.isEmpty) {
          throw StateError('presentedFingerprints must not be empty');
        }
        final fingerprint = presentedFingerprints[index
            < presentedFingerprints.length
            ? index
            : presentedFingerprints.length - 1];

        final presented = HostKey(
          host: config.host,
          port: config.port,
          type: 'ssh-ed25519',
          fingerprintSha256: fingerprint,
          pinnedAt: 0,
        );

        final decision = await tofu.check(presented);
        if (!decision.isTrusted) {
          final approved = await onHostKey(decision);
          if (!approved) {
            throw SshConnectException(
              'Host key not accepted for ${config.host}:${config.port}.',
              StateError('host key rejected'),
              log ?? SshConnectionLog(),
            );
          }
          await tofu.pin(presented);
        }

        if (prompting == ConnectPrompting.disabled) {
          if (growthGate != null) await growthGate!.future;
          if (growthRequiresChallenge) {
            throw const AuthChallengeRequiredError(
              'The server requires interactive authentication.',
            );
          }
        }

        final transport = FakeTransport(
          // Growth (prompting-disabled) connects re-authenticate
          // non-interactively, so they report a non-interactive kind even
          // when `authKind` scripts an interactive server.
          authKind: prompting == ConnectPrompting.disabled
              ? AuthKind.key
              : authKind,
          openLimit: transportOpenLimit,
        );
        call.transport = transport;
        return transport;
      };

  List<FakeTransport> get transports =>
      [for (final call in calls) if (call.transport != null) call.transport!];
}

/// Wires a [PooledConnectionManager] over the fakes with a static
/// serverId → connection table and a user host-key prompter the test
/// controls.
class PoolHarness {
  final FakeHostKeyStore store = FakeHostKeyStore();
  late final FakeTransportOpener opener;
  late final PooledConnectionManager manager;

  final Map<String, ResolvedServerConnection> servers = {};
  int resolveCalls = 0;

  /// When set, every resolve parks on this completer — for tests that race
  /// a disconnect against an in-flight first connect.
  Completer<void>? resolveGate;

  /// Set per test; defaults to approving every host key.
  Future<bool> Function(HostKeyDecision decision) onHostKey =
      (_) async => true;

  PoolHarness({
    FakeTransportOpener? opener,
    PoolPolicy policy = const PoolPolicy(),
  }) {
    this.opener = opener ?? FakeTransportOpener();
    manager = PooledConnectionManager(
      resolveServer: _resolve,
      tofu: TofuVerifier(store),
      onHostKey: (decision) => onHostKey(decision),
      // A trivial responder: interactive-auth servers still complete their
      // first connect, which is what the pool reasons about.
      onKeyboardInteractive:
          (prompts, name, instruction) async => List.filled(prompts.length, ''),
      policy: policy,
      openTransport: this.opener.opener,
    );
  }

  Future<ResolvedServerConnection> _resolve(String serverId) async {
    if (resolveGate != null) await resolveGate!.future;
    resolveCalls++;

    final resolved = servers[serverId];
    if (resolved == null) {
      throw StateError('unknown serverId $serverId');
    }
    return resolved;
  }

  void addServer(
    String serverId, {
    String host = 'example.com',
    int port = 22,
    String username = 'test',
    String? jumpHostId,
  }) {
    servers[serverId] = ResolvedServerConnection(
      config: ServerConfig(
        id: serverId,
        label: serverId,
        host: host,
        port: port,
        username: username,
        authMethod: AuthMethod.privateKey,
        jumpHostId: jumpHostId,
        createdAt: 0,
        updatedAt: 0,
      ),
      credentials: const SshCredentials.privateKey('TEST KEY'),
    );
  }

  List<FakeChannel> get channels => [
        for (final transport in opener.transports) ...transport.channels,
      ];

  /// Channels not yet closed — for "currently open" assertions that must
  /// not count channels a teardown already closed.
  Iterable<FakeChannel> get openChannels =>
      channels.where((channel) => !channel.closed);
}
