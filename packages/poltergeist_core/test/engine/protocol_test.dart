import 'dart:async';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

const _expectedProtocolVersion = 6;
const _probeStatuses = {
  'reachable': ProbeStatus.online,
  'refused': ProbeStatus.offline,
  'uncertain': ProbeStatus.unknown,
};

const _sample = TransferProgressEvent(
  taskId: 'task',
  itemId: 'item',
  transferred: 7,
  total: 10,
  taskTransferredBytes: 1007,
  taskTotalBytes: 1010,
);
const _unknownTotals = TransferProgressEvent(
  taskId: 'other',
  itemId: 'item',
  transferred: 2,
  total: null,
  taskTransferredBytes: 12,
  taskTotalBytes: null,
);

final _config = ServerConfig(
  id: 'srv-1',
  label: 'Test Server',
  host: 'example.com',
  port: 2222,
  username: 'user',
  authMethod: AuthMethod.privateKey,
  secretRef: 'secret-7',
  identityFilePath: '/home/user/.ssh/id_ed25519',
  createdAt: 1700000000,
  updatedAt: 1700000001,
);

const _entry = RemoteFileEntry(
  path: '/tmp/a.txt',
  name: 'a.txt',
  type: RemoteFileType.file,
  size: 42,
);

const _pin = HostKey(
  host: 'example.com',
  port: 2222,
  type: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:pinned',
  pinnedAt: 12,
);

/// A declined changed-key record and the endpoint it blocks — the incident
/// bridge's payloads (03 §5).
const _incident = IncidentRecord(
  serverId: 'srv-1',
  host: 'example.com',
  port: 2222,
  username: 'user',
  presentedFingerprintSha256: 'SHA256:presented',
  pinnedFingerprintSha256: 'SHA256:pinned',
);
const _endpoint = PoolKey(host: 'example.com', port: 2222, username: 'user');

/// A second record at a different endpoint: one element cannot distinguish
/// "the list crossed" from "the first element crossed and the rest dropped".
const _otherIncident = IncidentRecord(
  serverId: 'srv-2',
  host: 'other.example.com',
  port: 22,
  username: 'ops',
  presentedFingerprintSha256: 'SHA256:other-presented',
  pinnedFingerprintSha256: 'SHA256:other-pinned',
);

void main() {
  test('batch snapshots its input and exposes an immutable item list', () {
    final source = [_sample];
    final batch = TransferProgressBatchEvent(source);
    source.add(_unknownTotals);

    expect(batch.items, [_sample]);
    expect(() => batch.items.add(_unknownTotals), throwsUnsupportedError);
    expect(() => batch.items[0] = _unknownTotals, throwsUnsupportedError);
  });

  test('probe targets snapshot their input and remain immutable', () {
    final source = [_config];
    final request = SetProbeTargetsRequest(requestId: 1, targets: source);
    source.clear();

    expect(request.targets, [_config]);
    expect(() => request.targets.clear(), throwsUnsupportedError);
    expect(() => request.targets[0] = _config, throwsUnsupportedError);
  });

  test('probe statuses snapshot their input and remain immutable', () {
    final source = Map<String, ProbeStatus>.of(_probeStatuses);
    final event = ProbeStatusesEvent(statuses: source);
    source.clear();

    expect(event.statuses, _probeStatuses);
    expect(() => event.statuses.clear(), throwsUnsupportedError);
    expect(
      () => event.statuses['uncertain'] = ProbeStatus.offline,
      throwsUnsupportedError,
    );
  });

  test(
    'every protocol message round-trips through a spawned isolate',
    () async {
      final messages = ReceivePort();
      final incoming = StreamIterator<dynamic>(messages);
      final isolate = await Isolate.spawn(_echo, messages.sendPort);
      addTearDown(() async {
        isolate.kill(priority: Isolate.immediate);
        messages.close();
        await incoming.cancel();
      });

      expect(await incoming.moveNext(), isTrue);
      final engine = incoming.current as SendPort;

      // ── Events (08 §3.2: every EngineEvent crosses intact). ─────────────
      await _roundTrip(incoming, engine, _sample);
      await _roundTrip(incoming, engine, _unknownTotals);
      await _roundTrip(
        incoming,
        engine,
        TransferProgressBatchEvent([_sample, _unknownTotals]),
      );
      await _roundTrip(
        incoming,
        engine,
        ProbeStatusesEvent(statuses: _probeStatuses),
      );
      await _roundTrip(incoming, engine, ProbeStatusesEvent(statuses: {}));

      await _roundTrip(
        incoming,
        engine,
        ResponseEvent(requestId: 9, result: DirectoryListed(entries: [_entry])),
      );
      await _roundTrip(
        incoming,
        engine,
        ResponseEvent(
          requestId: 10,
          result: const EngineError(
            kind: RemoteFileErrorKind.permissionDenied,
            operation: 'list directory',
            path: '/tmp',
            message: 'denied',
          ),
        ),
      );

      await _roundTrip(
        incoming,
        engine,
        const ServerStateEvent(
          serverId: 'srv-1',
          state: ServerConnectionState.reconnecting,
          detail: 'summary line',
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const ServerStateEvent(
          serverId: 'srv-1',
          state: ServerConnectionState.connected,
        ),
      );

      // A pane failure identifies its binding; a pool failure affects every
      // pane at this server. Both remain plain data across the isolate.
      for (final paneTabId in [null, 'tab-1']) {
        await _roundTrip(
          incoming,
          engine,
          RecoveryFailedEvent(
            serverId: 'srv-1',
            paneTabId: paneTabId,
            error: const EngineError(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'canonicalize',
              path: '.',
              message: 'Home inaccessible.',
            ),
          ),
        );
      }

      await _roundTrip(
        incoming,
        engine,
        const EnginePromptEvent(
          promptId: 'p1',
          kind: EnginePromptKind.hostKeyChanged,
          data: HostKeyPromptData(
            host: 'example.com',
            port: 2222,
            keyType: 'ssh-ed25519',
            fingerprintSha256: 'SHA256:presented',
            pinnedFingerprintSha256: 'SHA256:pinned',
          ),
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const EnginePromptEvent(
          promptId: 'p2',
          kind: EnginePromptKind.keyboardInteractive,
          data: KeyboardInteractivePromptData(
            name: 'name',
            instruction: 'instruction',
            prompts: ['Token:', 'Pass:'],
          ),
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        EnginePromptEvent(
          promptId: 'p3',
          kind: EnginePromptKind.credentialNeeded,
          data: CredentialPromptData(
            host: _config.host,
            port: _config.port,
            username: _config.username,
            authMethod: _config.authMethod,
            secretRef: _config.secretRef,
            identityFilePath: _config.identityFilePath,
          ),
        ),
      );

      await _roundTrip(
        incoming,
        engine,
        const PromptDismissedEvent(
          promptId: 'p3',
          kind: EnginePromptKind.credentialNeeded,
        ),
      );

      await _roundTrip(incoming, engine, const HostKeyPinnedEvent(key: _pin));

      // The incident bridge: a stored record, an endpoint-scoped delete (a
      // lifted block), and a whole-bookmark delete (the 3a cascade).
      await _roundTrip(
        incoming,
        engine,
        const IncidentRecordStoredEvent(record: _incident),
      );
      await _roundTrip(
        incoming,
        engine,
        const IncidentRecordRemovedEvent(
          serverId: 'srv-1',
          endpoint: _endpoint,
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const IncidentRecordRemovedEvent(serverId: 'srv-1'),
      );

      // ── Requests (every EngineRequest crosses intact). ──────────────────
      await _roundTrip(
        incoming,
        engine,
        OpenBrowseChannelRequest(
          requestId: 1,
          serverId: 'srv-1',
          paneTabId: 'tab-1',
          config: _config,
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const CloseBrowseChannelRequest(requestId: 2, channelId: 5),
      );
      await _roundTrip(
        incoming,
        engine,
        const ListDirectoryRequest(requestId: 3, channelId: 5, path: '/tmp'),
      );
      await _roundTrip(
        incoming,
        engine,
        const WatchServerRequest(requestId: 4, serverId: 'srv-1'),
      );
      await _roundTrip(
        incoming,
        engine,
        const UnwatchServerRequest(requestId: 5, serverId: 'srv-1'),
      );
      await _roundTrip(
        incoming,
        engine,
        const ConnectedServerIdsRequest(requestId: 6),
      );
      await _roundTrip(
        incoming,
        engine,
        SetProbeTargetsRequest(requestId: 16, targets: [_config]),
      );
      await _roundTrip(
        incoming,
        engine,
        SetProbeTargetsRequest(requestId: 17, targets: []),
      );
      for (final activity in ProbeActivity.values) {
        await _roundTrip(
          incoming,
          engine,
          SetProbeActivityRequest(requestId: 18, activity: activity),
        );
      }
      await _roundTrip(
        incoming,
        engine,
        const DisconnectServerRequest(requestId: 7, serverId: 'srv-1'),
      );
      await _roundTrip(
        incoming,
        engine,
        const RemoveBookmarkRequest(requestId: 19, serverId: 'srv-1'),
      );
      await _roundTrip(
        incoming,
        engine,
        const PromptReplyRequest(
          requestId: 8,
          promptId: 'p1',
          kind: EnginePromptKind.hostKeyChanged,
          reply: HostKeyPromptReply(accepted: true),
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const PromptReplyRequest(
          requestId: 9,
          promptId: 'p2',
          kind: EnginePromptKind.keyboardInteractive,
          reply: KeyboardInteractivePromptReply(answers: ['012345']),
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const PromptReplyRequest(
          requestId: 10,
          promptId: 'p3',
          kind: EnginePromptKind.credentialNeeded,
          reply: CredentialPromptReply(
            password: 'hunter2',
            origin: CredentialOrigin.prompted,
          ),
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const PromptReplyRequest(
          requestId: 11,
          promptId: 'p3',
          kind: EnginePromptKind.credentialNeeded,
          reply: CredentialPromptReply(
            cancelled: true,
            origin: CredentialOrigin.stored,
          ),
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        const PromptReplyRequest(
          requestId: 16,
          promptId: 'p3',
          kind: EnginePromptKind.credentialNeeded,
          reply: CredentialPromptReply(
            // A neutral marker, not a real PEM header: the fixture-key
            // scope guard keeps private-key-looking material confined to
            // test/integration/keys, and this fixture only needs a
            // non-null secret string to prove key replies cross intact.
            privateKeyPem: 'TEST-PEM-KEY-BLOCK',
            keyPassphrase: 'open sesame',
            origin: CredentialOrigin.prompted,
          ),
        ),
      );
      await _roundTrip(incoming, engine, const ShutdownRequest(requestId: 12));

      // ── Remaining results and the spawn config. ─────────────────────────
      await _roundTrip(
        incoming,
        engine,
        const ResponseEvent(
          requestId: 13,
          result: BrowseChannelOpened(channelId: 5, homePath: '/home/user'),
        ),
      );
      await _roundTrip(
        incoming,
        engine,
        ResponseEvent(requestId: 14, result: ServerIdsListed(ids: ['a', 'b'])),
      );
      await _roundTrip(
        incoming,
        engine,
        const ResponseEvent(requestId: 15, result: EngineAck()),
      );
      await _roundTrip(
        incoming,
        engine,
        const EngineConfig(
          policy: PoolPolicy(maxTransports: 3),
          hostKeyPins: [_pin],
          incidents: [_incident, _otherIncident],
        ),
      );
    },
  );
}

/// Sends [message], awaits the echo, and asserts it reconstructed intact
/// (field equality — these types are plain data without operator==).
Future<void> _roundTrip(
  StreamIterator<dynamic> incoming,
  SendPort engine,
  Object message,
) async {
  engine.send(message);
  expect(await incoming.moveNext(), isTrue);
  final returned = incoming.current;

  switch ((message, returned)) {
    case (final TransferProgressEvent sent, final TransferProgressEvent got):
      _expectProgress(got, sent);
    case (
      final TransferProgressBatchEvent sent,
      final TransferProgressBatchEvent got,
    ):
      expect(got.items, hasLength(sent.items.length));
      for (var index = 0; index < sent.items.length; index++) {
        _expectProgress(got.items[index], sent.items[index]);
      }
    case (final ResponseEvent sent, final ResponseEvent got):
      expect(got.requestId, sent.requestId);
      _expectResult(got.result, sent.result);
    case (final ServerStateEvent sent, final ServerStateEvent got):
      expect(got.serverId, sent.serverId);
      expect(got.state, sent.state);
      expect(got.detail, sent.detail);
    case (final ProbeStatusesEvent sent, final ProbeStatusesEvent got):
      expect(got.statuses, sent.statuses);
      expect(() => got.statuses.clear(), throwsUnsupportedError);
    case (final RecoveryFailedEvent sent, final RecoveryFailedEvent got):
      expect(got.serverId, sent.serverId);
      expect(got.paneTabId, sent.paneTabId);
      _expectResult(got.error, sent.error);
    case (final EnginePromptEvent sent, final EnginePromptEvent got):
      expect(got.promptId, sent.promptId);
      expect(got.kind, sent.kind);
      _expectPromptData(got.data, sent.data);
    case (final PromptDismissedEvent sent, final PromptDismissedEvent got):
      expect(got.promptId, sent.promptId);
      expect(got.kind, sent.kind);
    case (final HostKeyPinnedEvent sent, final HostKeyPinnedEvent got):
      expect(got.key.host, sent.key.host);
      expect(got.key.port, sent.key.port);
      expect(got.key.type, sent.key.type);
      expect(got.key.fingerprintSha256, sent.key.fingerprintSha256);
      expect(got.key.pinnedAt, sent.key.pinnedAt);
    case (
      final IncidentRecordStoredEvent sent,
      final IncidentRecordStoredEvent got,
    ):
      expect(got.record, sent.record);
      expect(got.record.poolKey, sent.record.poolKey);
    case (
      final IncidentRecordRemovedEvent sent,
      final IncidentRecordRemovedEvent got,
    ):
      expect(got.serverId, sent.serverId);
      expect(got.endpoint, sent.endpoint);
    case (
      final OpenBrowseChannelRequest sent,
      final OpenBrowseChannelRequest got,
    ):
      expect(got.requestId, sent.requestId);
      expect(got.serverId, sent.serverId);
      expect(got.paneTabId, sent.paneTabId);
      expect(got.config.host, sent.config.host);
      expect(got.config.id, sent.config.id);
      expect(got.config.port, sent.config.port);
      expect(got.config.username, sent.config.username);
      expect(got.config.authMethod, sent.config.authMethod);
      expect(got.config.secretRef, sent.config.secretRef);
      expect(got.config.identityFilePath, sent.config.identityFilePath);
    case (
      final CloseBrowseChannelRequest sent,
      final CloseBrowseChannelRequest got,
    ):
      expect(got.requestId, sent.requestId);
      expect(got.channelId, sent.channelId);
    case (final ListDirectoryRequest sent, final ListDirectoryRequest got):
      expect(got.requestId, sent.requestId);
      expect(got.channelId, sent.channelId);
      expect(got.path, sent.path);
    case (final WatchServerRequest sent, final WatchServerRequest got):
      expect(got.requestId, sent.requestId);
      expect(got.serverId, sent.serverId);
    case (final UnwatchServerRequest sent, final UnwatchServerRequest got):
      expect(got.requestId, sent.requestId);
      expect(got.serverId, sent.serverId);
    case (
      final DisconnectServerRequest sent,
      final DisconnectServerRequest got,
    ):
      expect(got.requestId, sent.requestId);
      expect(got.serverId, sent.serverId);
    case (
      final RemoveBookmarkRequest sent,
      final RemoveBookmarkRequest got,
    ):
      expect(got.requestId, sent.requestId);
      expect(got.serverId, sent.serverId);
    case (
      final ConnectedServerIdsRequest sent,
      final ConnectedServerIdsRequest got,
    ):
      expect(got.requestId, sent.requestId);
    case (final SetProbeTargetsRequest sent, final SetProbeTargetsRequest got):
      expect(got.requestId, sent.requestId);
      expect(
        got.targets.map((target) => target.toJson()).toList(),
        sent.targets.map((target) => target.toJson()).toList(),
      );
      expect(() => got.targets.clear(), throwsUnsupportedError);
    case (
      final SetProbeActivityRequest sent,
      final SetProbeActivityRequest got,
    ):
      expect(got.requestId, sent.requestId);
      expect(got.activity, sent.activity);
    case (final ShutdownRequest sent, final ShutdownRequest got):
      expect(got.requestId, sent.requestId);
    case (final PromptReplyRequest sent, final PromptReplyRequest got):
      expect(got.requestId, sent.requestId);
      expect(got.promptId, sent.promptId);
      expect(got.kind, sent.kind);
      _expectReply(got.reply, sent.reply);
    case (final EngineConfig sent, final EngineConfig got):
      expect(got.policy.maxTransports, sent.policy.maxTransports);
      expect(got.hostKeyPins, hasLength(sent.hostKeyPins.length));
      expect(got.hostKeyPins.single.host, sent.hostKeyPins.single.host);
      expect(got.hostKeyPins.single.port, sent.hostKeyPins.single.port);
      expect(got.hostKeyPins.single.type, sent.hostKeyPins.single.type);
      expect(
        got.hostKeyPins.single.fingerprintSha256,
        sent.hostKeyPins.single.fingerprintSha256,
      );
      expect(got.hostKeyPins.single.pinnedAt, sent.hostKeyPins.single.pinnedAt);
      expect(got.incidents, hasLength(sent.incidents.length));
      expect(got.incidents, sent.incidents);
    default:
      fail(
        'Message type changed across the port: '
        'sent ${message.runtimeType}, got $returned',
      );
  }

  final event = returned;
  if (event is EngineEvent) {
    expect(event.protocolVersion, _expectedProtocolVersion);
    expect(event.protocolVersion, engineProtocolVersion);
  }
}

void _expectResult(EngineResult actual, EngineResult expected) {
  switch ((expected, actual)) {
    case (final DirectoryListed sent, final DirectoryListed got):
      expect(got.entries, hasLength(sent.entries.length));
      expect(got.entries.single.path, sent.entries.single.path);
      expect(got.entries.single.name, sent.entries.single.name);
      expect(got.entries.single.type, sent.entries.single.type);
      expect(got.entries.single.size, sent.entries.single.size);
    case (final EngineError sent, final EngineError got):
      expect(got.kind, sent.kind);
      expect(got.operation, sent.operation);
      expect(got.path, sent.path);
      expect(got.message, sent.message);
    case (final BrowseChannelOpened sent, final BrowseChannelOpened got):
      expect(got.channelId, sent.channelId);
      expect(got.homePath, sent.homePath);
    case (final ServerIdsListed sent, final ServerIdsListed got):
      expect(got.ids, sent.ids);
    case (final EngineAck _, final EngineAck _):
      return;
    default:
      fail('Result type changed across the port: $actual');
  }
}

void _expectPromptData(EnginePromptData actual, EnginePromptData expected) {
  switch ((expected, actual)) {
    case (final HostKeyPromptData sent, final HostKeyPromptData got):
      expect(got.host, sent.host);
      expect(got.port, sent.port);
      expect(got.keyType, sent.keyType);
      expect(got.fingerprintSha256, sent.fingerprintSha256);
      expect(got.pinnedFingerprintSha256, sent.pinnedFingerprintSha256);
    case (
      final KeyboardInteractivePromptData sent,
      final KeyboardInteractivePromptData got,
    ):
      expect(got.name, sent.name);
      expect(got.instruction, sent.instruction);
      expect(got.prompts, sent.prompts);
    case (final CredentialPromptData sent, final CredentialPromptData got):
      expect(got.host, sent.host);
      expect(got.port, sent.port);
      expect(got.username, sent.username);
      expect(got.authMethod, sent.authMethod);
      expect(got.secretRef, sent.secretRef);
      expect(got.identityFilePath, sent.identityFilePath);
    default:
      fail('Prompt data type changed across the port: $actual');
  }
}

void _expectReply(PromptReply actual, PromptReply expected) {
  switch ((expected, actual)) {
    case (final HostKeyPromptReply sent, final HostKeyPromptReply got):
      expect(got.accepted, sent.accepted);
    case (
      final KeyboardInteractivePromptReply sent,
      final KeyboardInteractivePromptReply got,
    ):
      expect(got.answers, sent.answers);
    case (final CredentialPromptReply sent, final CredentialPromptReply got):
      expect(got.cancelled, sent.cancelled);
      expect(got.password, sent.password);
      expect(got.privateKeyPem, sent.privateKeyPem);
      expect(got.keyPassphrase, sent.keyPassphrase);
      expect(got.origin, sent.origin);
    default:
      fail('Reply type changed across the port: $actual');
  }
}

void _expectProgress(
  TransferProgressEvent actual,
  TransferProgressEvent expected,
) {
  expect(actual.taskId, expected.taskId);
  expect(actual.itemId, expected.itemId);
  expect(actual.transferred, expected.transferred);
  expect(actual.total, expected.total);
  expect(actual.taskTransferredBytes, expected.taskTransferredBytes);
  expect(actual.taskTotalBytes, expected.taskTotalBytes);
}

void _echo(SendPort parent) {
  final requests = ReceivePort();
  parent.send(requests.sendPort);
  requests.listen(parent.send);
}
