@Tags(['integration'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:seance_core/seance_core.dart' show TcpBannerProber;
import 'package:test/test.dart';

const _hostVariable = 'POLTERGEIST_SSHD';
const _portVariable = 'POLTERGEIST_SSHD_MODERN';
const _serverId = 'fixture';
const _defaultPolicy = PoolPolicy();
const _operationTimeout = Duration(seconds: 15);
const _serviceTimeout = Duration(seconds: 50);
const _pollInterval = Duration(milliseconds: 20);
const _queueObservation = Duration(milliseconds: 200);
const _keepAliveInterval = Duration(milliseconds: 200);
const _minimumFirstBackoff = Duration(milliseconds: 700);
const _minimumSecondBackoff = Duration(milliseconds: 1400);
// VM timer resolution can shave a millisecond off a requested delay.
const _timerTolerance = Duration(milliseconds: 10);

void main() {
  final environment = Platform.environment;
  final enabled =
      environment[_hostVariable] != null && environment[_portVariable] != null;

  group('pool against real sshd', () {
    late _Fixture fixture;

    Future<void> Function()? restore;
    setUpAll(() async {
      fixture = await _Fixture._load();
      restore = () => fixture._control(_ServiceAction.start);
    });
    // A failed assertion after stop must not strand later integration suites.
    tearDownAll(() => restore?.call());

    for (final method in [AuthMethod.privateKey, AuthMethod.password]) {
      test(
        '${method.name} grows to the transport cap and queues excess demand',
        () async {
          final harness = await fixture._pool(method: method);
          final manager = harness._manager;
          final panes = await Future.wait([
            manager.openBrowseChannel(_serverId, paneTabId: 'left'),
            manager.openBrowseChannel(_serverId, paneTabId: 'right'),
          ]);
          expect(harness._transports, hasLength(1));
          expect(panes.first.fs, isNot(same(panes.last.fs)));

          final capacity =
              _defaultPolicy.maxTransports *
              _defaultPolicy.maxTransferChannelsPerTransport;
          final leases = <TransferChannelLease>[];
          for (var index = 0; index < capacity; index++) {
            leases.add(
              await manager
                  .leaseTransferChannel(_serverId)
                  .timeout(_operationTimeout),
            );
          }

          expect(harness._transports, hasLength(_defaultPolicy.maxTransports));
          expect(harness._resolutions, 1);
          expect(harness._prompting, [
            ConnectPrompting.enabled,
            ConnectPrompting.disabled,
          ]);
          expect(
            harness._credentialsSeen,
            everyElement(same(harness._credentials)),
          );
          expect(
            harness._transports.map((transport) => transport.authKind),
            everyElement(
              method == AuthMethod.privateKey
                  ? AuthKind.key
                  : AuthKind.storedPassword,
            ),
          );

          for (final transport in harness._transports) {
            expect(
              transport._channels.length,
              lessThanOrEqualTo(_defaultPolicy.maxChannelsPerTransport),
            );
            expect(
              leases.where(
                (lease) => transport._channels.any(
                  (channel) => identical(channel.fs, lease.fs),
                ),
              ),
              hasLength(_defaultPolicy.maxTransferChannelsPerTransport),
            );
          }

          // Real SFTP still serves both panes while every transfer slot is held.
          for (final pane in panes) {
            expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);
          }

        final waiting = manager.leaseTransferChannel(_serverId);
        await expectLater(
          waiting.timeout(_queueObservation),
          throwsA(isA<TimeoutException>()),
          );
          final returnedFs = leases.first.fs;
          await leases.first.release();
          final acquired = await waiting.timeout(_operationTimeout);
        expect(acquired.fs, same(returnedFs));
          expect(harness._transports, hasLength(_defaultPolicy.maxTransports));
          await acquired.release();
        },
      );
    }

    test(
      'pool keepalive completes real ping round trips on both transports',
      () async {
        // A one-channel budget grows transport two without starting a transfer.
        final harness = await fixture._pool(
          policy: const PoolPolicy(
            maxTransferChannelsPerTransport: 1,
            maxChannelsPerTransport: 1,
            keepAliveInterval: _keepAliveInterval,
          ),
        );
        final pane = await harness._manager.openBrowseChannel(
          _serverId,
          paneTabId: 'left',
        );
        final lease = await harness._manager.leaseTransferChannel(_serverId);
        expect(harness._transports, hasLength(2));

        await _until(
          () => harness._transports.every((transport) => transport._pings >= 2),
          'two server replies per idle transport',
        );
        expect(
          harness._transports.any((transport) => transport.isClosed),
          isFalse,
        );
        expect(
          harness._states,
          isNot(contains(ServerConnectionState.reconnecting)),
        );
        expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);
        expect(await lease.fs.canonicalize('.'), pane.homePath);
      },
    );

    test(
      'stop/start probes with backoff and rebinds the existing browse handle',
      () async {
        final harness = await fixture._pool();
        final pane = await harness._manager.openBrowseChannel(
          _serverId,
          paneTabId: 'left',
        );
        final lease = await harness._manager.leaseTransferChannel(_serverId);
        final previousFs = pane.fs;
        final home = pane.homePath;
        final transport = harness._transports.single;

        await fixture._control(_ServiceAction.stop);
        await _until(
          () => harness._prober._probes.length >= 2,
          'two completed probes while sshd is stopped',
        );
        expect(harness._states, contains(ServerConnectionState.reconnecting));
        expect(
          harness._transports,
          hasLength(1),
          reason: 'offline probes must not attempt SSH authentication',
        );
        expect(
          harness._prober._probes.map((probe) => probe.status),
          everyElement(isNot(ProbeStatus.online)),
        );

        final probes = harness._prober._probes;
        expect(
          probes.first.started - transport._closedAt!,
          greaterThanOrEqualTo(_minimumFirstBackoff - _timerTolerance),
        );
        expect(
          probes[1].started - probes.first.finished,
          greaterThanOrEqualTo(_minimumSecondBackoff - _timerTolerance),
        );
        expect(
          () => lease.fs,
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.disconnected,
            ),
          ),
        );

        await fixture._control(_ServiceAction.start);
        await _until(
          () => harness._states.last == ServerConnectionState.connected,
          'connected state after sshd restart',
          // Slow Docker startup may advance recovery to its maximum backoff.
          timeout: _defaultPolicy.reconnectBackoffCap + _operationTimeout,
        );
        expect(harness._transports, hasLength(2));
        expect(transport.isClosed, isTrue);
        expect(pane.fs, isNot(same(previousFs)));
        expect(pane.homePath, home);
        expect(pane.homePath, await pane.fs.canonicalize('.'));
        expect(await pane.fs.listDirectory(pane.homePath), isNotEmpty);
        expect(
          harness._states,
          containsAllInOrder([
            ServerConnectionState.connecting,
            ServerConnectionState.connected,
            ServerConnectionState.reconnecting,
            ServerConnectionState.connected,
          ]),
        );
        expect(harness._prober._probes.last.status, ProbeStatus.online);
        expect(
          harness._resolutions,
          1,
          reason: 'recovery first reuses the live session credentials',
        );
        expect(harness._prompting, [
          ConnectPrompting.enabled,
          ConnectPrompting.disabled,
        ]);
        expect(
          () => lease.fs,
          throwsA(isA<RemoteFileException>()),
          reason: 'recovery replaces panes, never a worker lease',
        );
        await lease.release();
      },
    );
  }, skip: enabled ? false : 'Set $_hostVariable and $_portVariable to enable.');
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

enum _ServiceAction { start, stop }

/// Owns fixture configuration and its existing safe lifecycle helper.
class _Fixture {
  final Uri _root;
  final String _host;
  final int _port;
  final String _username;
  final String _privateKey;
  final String _password;
  final HostKey _hostKey;

  _Fixture(
    this._root,
    this._host,
    this._port,
    this._username,
    this._privateKey,
    this._password,
    this._hostKey,
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

  Future<_PoolHarness> _pool({
    AuthMethod method = AuthMethod.privateKey,
    PoolPolicy policy = _defaultPolicy,
  }) async {
    final store = InMemoryHostKeyStore();
    await store.put(_hostKey);
    final credentials = method == AuthMethod.privateKey
        ? SshCredentials.privateKey(_privateKey)
        : SshCredentials.password(_password);
    final server = ServerConfig(
      id: _serverId,
      label: _serverId,
      host: _host,
      port: _port,
      username: _username,
      authMethod: method,
      createdAt: 0,
      updatedAt: 0,
    );
    final harness = _PoolHarness(
      server,
      credentials,
      TofuVerifier(store),
      policy,
    );
    addTearDown(harness._dispose);
    return harness;
  }

  Future<void> _control(_ServiceAction action) async {
    final result = await Process.run(
      'bash',
      [
        _root.resolve('test/integration/service-control.sh').toFilePath(),
        action.name,
        'sshd-modern',
      ],
      environment: {'DART_BIN': Platform.resolvedExecutable},
    ).timeout(_serviceTimeout);
    expect(
      result.exitCode,
      0,
      reason: 'Fixture ${action.name}: ${result.stdout}\n${result.stderr}',
    );
  }
}

/// Observe the production transport seam; return the real VFS unchanged (D3).
class _PoolHarness {
  final ServerConfig _server;
  final SshCredentials _credentials;
  final TofuVerifier _tofu;
  final PoolPolicy _policy;
  final _clock = Stopwatch()..start();
  final _transports = <_ObservedTransport>[];
  final _credentialsSeen = <SshCredentials>[];
  final _prompting = <ConnectPrompting>[];
  final _states = <ServerConnectionState>[];
  int _resolutions = 0;
  late final _prober = _ObservedProber(_clock);
  late final _manager = PooledConnectionManager(
    resolveServer: (_) async => _server,
    resolveCredentials: (_, _) async {
      _resolutions++;
      return ResolvedCredentials(
        credentials: _credentials,
        origin: CredentialOrigin.stored,
      );
    },
    tofu: _tofu,
    onHostKey: (_) async => fail('A pre-seeded fixture must never prompt.'),
    onKeyboardInteractive: (_, _, _) async =>
        fail('Stored credentials must not prompt.'),
    policy: _policy,
    prober: _prober,
    openTransport: _open,
  );
  late final StreamSubscription<ServerConnectionState> _watch;

  _PoolHarness(this._server, this._credentials, this._tofu, this._policy) {
    _watch = _manager.watchServer(_serverId).listen(_states.add);
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
  }) async {
    _credentialsSeen.add(credentials);
    _prompting.add(prompting);
    final transport = _ObservedTransport(
      await openDartSshTransport(
        config: config,
        credentials: credentials,
        tofu: tofu,
        onHostKey: onHostKey,
        onKeyboardInteractive: onKeyboardInteractive,
        prompting: prompting,
        timeout: timeout,
        log: log,
      ),
      _clock,
    );
    _transports.add(transport);
    return transport;
  }

  Future<void> _dispose() async {
    try {
      await _manager.disconnectServer(_serverId);
    } finally {
      await _watch.cancel();
    }
  }
}

class _ObservedTransport implements SshTransport {
  final SshTransport _delegate;
  final Stopwatch _clock;
  final _channels = <SftpChannel>[];
  int _pings = 0;
  Duration? _closedAt;
  late final _done = _delegate.done.whenComplete(
    () => _closedAt = _clock.elapsed,
  );

  _ObservedTransport(this._delegate, this._clock);

  @override
  AuthKind get authKind => _delegate.authKind;
  @override
  bool get isClosed => _delegate.isClosed;
  @override
  bool get hasActiveOperations => _delegate.hasActiveOperations;
  @override
  Future<void> get done => _done;

  @override
  Future<SftpChannel> openChannel({
    Duration timeout = SshTransport.defaultOpenTimeout,
  }) async {
    final channel = await _delegate.openChannel(timeout: timeout);
    _channels.add(channel);
    return channel;
  }

  @override
  Future<void> ping() async {
    await _delegate.ping();
    _pings++;
  }

  @override
  Future<void> close() => _delegate.close();
}

typedef _Probe = ({Duration started, Duration finished, ProbeStatus status});

class _ObservedProber implements Prober {
  final Stopwatch _clock;
  final _probes = <_Probe>[];
  static const _delegate = TcpBannerProber();
  static const _timeout = Duration(seconds: 5);

  _ObservedProber(this._clock);

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = _timeout,
  }) async {
    final started = _clock.elapsed;
    final status = await _delegate.probe(host, port, timeout: timeout);
    _probes.add((started: started, finished: _clock.elapsed, status: status));
    return status;
  }
}
