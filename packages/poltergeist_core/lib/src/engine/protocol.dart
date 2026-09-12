import 'package:seance_core/seance_core.dart';

import '../connection/connection_manager.dart'
    show CredentialOrigin, ServerConnectionState;
import '../connection/incident_store.dart' show IncidentRecord;
import '../connection/pool_key.dart' show PoolKey;
import '../connection/pool_policy.dart' show PoolPolicy;

/// Increment when the cross-isolate message contract changes.
///
/// v2 adds the connection/prompt surface (03 §5). v3 adds
/// [RecoveryFailedEvent] for terminal background failures. v4 adds live
/// transcript batches ([ConnectionLogEvent]) and starts populating the
/// previously reserved [ServerStateEvent.detail]. v5 adds probe targets,
/// activity control, and tri-state reachability snapshots. v6 adds
/// [RemoveBookmarkRequest] and the incident-store bridge
/// ([IncidentStoreEvent]). v7 adds the local browse-channel open request
/// ([OpenLocalBrowseChannelRequest]) — the engine-side seam for local
/// panes (03 §5's ownership table).
const engineProtocolVersion = 7;

// ── Engine → UI events ──────────────────────────────────────────────────

/// Plain-data events keep sockets and callbacks on the engine isolate.
sealed class EngineEvent {
  final int protocolVersion;

  const EngineEvent() : protocolVersion = engineProtocolVersion;
}

/// Item counters and task rollups travel together; the UI cannot derive totals
/// from the subset of items retained by progress coalescing.
final class TransferProgressEvent extends EngineEvent {
  final String taskId;
  final String itemId;
  final int transferred;
  final int? total;
  final int taskTransferredBytes;
  final int? taskTotalBytes;

  const TransferProgressEvent({
    required this.taskId,
    required this.itemId,
    required this.transferred,
    required this.total,
    required this.taskTransferredBytes,
    required this.taskTotalBytes,
  });
}

/// One flush window across all tasks, so task count cannot multiply port traffic.
final class TransferProgressBatchEvent extends EngineEvent {
  /// Oldest update first; replace task rollups in order, never sum them.
  final List<TransferProgressEvent> items;

  TransferProgressBatchEvent(Iterable<TransferProgressEvent> items)
    : items = List.unmodifiable(items);
}

/// The reply to one [EngineRequest], correlated by `requestId`.
final class ResponseEvent extends EngineEvent {
  final int requestId;
  final EngineResult result;

  const ResponseEvent({required this.requestId, required this.result});
}

/// One `watchServer` emission for one serverId (03 §3.2).
final class ServerStateEvent extends EngineEvent {
  final String serverId;
  final ServerConnectionState state;

  /// The state-associated failure one-liner (03 §3.2): a summarized connect
  /// failure, terminal background-recovery error, or host-key block reason.
  /// [RecoveryFailedEvent] also delivers scoped terminal failures without a
  /// watch. Null for healthy and cancelled states.
  final String? detail;

  const ServerStateEvent({
    required this.serverId,
    required this.state,
    this.detail,
  });
}

/// Complete reachability snapshot for the currently eligible probe targets.
/// Live connection state remains authoritative for the Connections section.
final class ProbeStatusesEvent extends EngineEvent {
  final Map<String, ProbeStatus> statuses;

  ProbeStatusesEvent({required Map<String, ProbeStatus> statuses})
    : statuses = Map.unmodifiable(statuses);
}

/// A terminal background recovery failure for local diagnostics (D19).
/// Independent of state watches and request replies; causes stay engine-side.
final class RecoveryFailedEvent extends EngineEvent {
  final String serverId;

  /// A failed browse binding; null when recovery stopped for the whole pool.
  final String? paneTabId;
  final EngineError error;

  const RecoveryFailedEvent({
    required this.serverId,
    this.paneTabId,
    required this.error,
  });
}

/// Live transcript lines for one server's connect attempts (03 §3.3,
/// crossing per 03 §5): dartssh2 debug/trace plus the connect steps, the
/// material the UI renders during connect and keeps visible on failure.
final class ConnectionLogEvent extends EngineEvent {
  final String serverId;

  /// Oldest first, in attempt append order. Per server at most
  /// `connectionLogMaxLines` lines are pending at once (drop-oldest,
  /// mirroring the source log's own bound) and batches flush at most
  /// `connectionLogFlushesPerSecond` times per second.
  final List<String> lines;

  ConnectionLogEvent({required this.serverId, required List<String> lines})
    : lines = List.unmodifiable(lines);
}

/// The engine asks the UI a question; exactly one [PromptReplyRequest] per
/// `promptId` answers it (03 §5). The seance_core prompt callbacks cannot
/// cross isolates, so the engine emits one of these and awaits the reply.
final class EnginePromptEvent extends EngineEvent {
  final String promptId;
  final EnginePromptKind kind;
  final EnginePromptData data;

  const EnginePromptEvent({
    required this.promptId,
    required this.kind,
    required this.data,
  });
}

/// The engine withdrew an open prompt: the dialog owning [promptId] must
/// close without answering. This is the isolate boundary's half of
/// `CredentialResolutionScope` dismissal (03 §3.2) — one mechanism, both
/// sides — plus engine shutdown's implicit cancel for still-open prompts.
final class PromptDismissedEvent extends EngineEvent {
  final String promptId;
  final EnginePromptKind kind;

  const PromptDismissedEvent({required this.promptId, required this.kind});
}

/// The engine pinned (or re-pinned) a host key. Pin storage lives on the UI
/// side (app-layer file store), so the engine — which owns the TOFU verifier
/// — surfaces every pin write for the UI to persist.
final class HostKeyPinnedEvent extends EngineEvent {
  final HostKey key;

  const HostKeyPinnedEvent({required this.key});
}

/// A trust-incident store mutation crossing the port (03 §5, owner decision
/// 2a). The engine owns the live incident logic; the app owns the persisted
/// store. The engine mirrors every put/remove here so a restart seeds it from
/// exactly the records the app persisted — one writer, one store owner,
/// exactly like [HostKeyPinnedEvent].
///
/// These events and the [EngineConfig.incidents] seed cross an isolate port:
/// [IncidentRecord] and [PoolKey] must stay deeply sendable and immutable,
/// and a receiver must treat them as snapshots — object identity does not
/// survive the port.
sealed class IncidentStoreEvent extends EngineEvent {
  const IncidentStoreEvent();
}

/// The engine stored (or updated) an incident record: a declined changed-key
/// block was installed or re-written for [IncidentRecordStoredEvent.record]'s
/// `serverId`.
final class IncidentRecordStoredEvent extends IncidentStoreEvent {
  final IncidentRecord record;

  const IncidentRecordStoredEvent({required this.record});
}

/// The engine deleted incident records: [endpoint] scopes the delete to one
/// endpoint (a lifted block), null deletes every record for [serverId] (the
/// bookmark-removal cascade, owner decision 3a).
final class IncidentRecordRemovedEvent extends IncidentStoreEvent {
  final String serverId;
  final PoolKey? endpoint;

  const IncidentRecordRemovedEvent({required this.serverId, this.endpoint});
}

// ── Prompt model ────────────────────────────────────────────────────────

/// The prompts the engine can raise (03 §5).
enum EnginePromptKind {
  hostKeyFirstUse,
  hostKeyChanged,
  keyboardInteractive,
  credentialNeeded,

  /// Transfer conflicts (02 §5.2). No producer exists until the transfer
  /// queue (M4) lands; its prompt payload and reply subtype land with it.
  conflict,
}

/// Kind-specific prompt payload (03 §5: "fingerprint, prompt texts, …").
sealed class EnginePromptData {
  const EnginePromptData();
}

/// A host key awaiting approval — first use or a detected change.
final class HostKeyPromptData extends EnginePromptData {
  final String host;
  final int port;

  /// Key algorithm, e.g. `ssh-ed25519`.
  final String keyType;

  /// `SHA256:...` fingerprint of the presented key.
  final String fingerprintSha256;

  /// The previously pinned fingerprint when a change was detected.
  final String? pinnedFingerprintSha256;

  const HostKeyPromptData({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprintSha256,
    this.pinnedFingerprintSha256,
  });
}

/// A keyboard-interactive challenge (2FA/TOTP); one answer per prompt.
final class KeyboardInteractivePromptData extends EnginePromptData {
  final String name;
  final String instruction;
  final List<String> prompts;

  const KeyboardInteractivePromptData({
    required this.name,
    required this.instruction,
    required this.prompts,
  });
}

/// The engine needs credentials for a first connect. The UI-side handler
/// checks the vault first and answers from it (origin `stored`) or renders
/// a dialog and answers with what the user typed (origin `prompted`) —
/// provenance caps pool growth per 03 §3.2 rule 2.
final class CredentialPromptData extends EnginePromptData {
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;

  /// Vault entry the UI-side handler should read, when the config has one.
  final String? secretRef;

  /// Referenced on-disk key, when the config authenticates by identity file.
  final String? identityFilePath;

  const CredentialPromptData({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.secretRef,
    this.identityFilePath,
  });
}

/// One plain-data subtype per [EnginePromptKind] (03 §5). A UI-side dialog
/// dismissal sends the cancel form for the prompt's kind: `accepted: false`,
/// empty `answers`, or `cancelled: true`.
sealed class PromptReply {
  const PromptReply();
}

final class HostKeyPromptReply extends PromptReply {
  final bool accepted;

  const HostKeyPromptReply({required this.accepted});
}

final class KeyboardInteractivePromptReply extends PromptReply {
  /// Empty answers cannot authenticate; the connect fails its auth step.
  final List<String> answers;

  const KeyboardInteractivePromptReply({required this.answers});
}

final class CredentialPromptReply extends PromptReply {
  /// The dialog was dismissed: fail the resolution without an answer.
  final bool cancelled;

  /// Which secret field is set picks the [SshCredentials] constructor:
  /// `privateKeyPem` → key auth, `password` → password auth, neither → agent.
  final String? privateKeyPem;
  final String? keyPassphrase;
  final String? password;

  /// Whether the answer came from the vault or a user prompt — growth
  /// rule 2's interactive-cap signal (03 §3.2). Required: a dialog-sourced
  /// reply that forgets it would silently claim vault provenance and cap
  /// pool growth; a compile error is cheaper than that bug.
  final CredentialOrigin origin;

  const CredentialPromptReply({
    this.cancelled = false,
    this.privateKeyPem,
    this.keyPassphrase,
    this.password,
    required this.origin,
  });
}

// ── UI → engine requests ────────────────────────────────────────────────

/// One call on the [EngineClient] facade. Most requests are answered by
/// exactly one [ResponseEvent]; the protocol's fire-and-forget exceptions —
/// watch/unwatch (answered by the [ServerStateEvent] stream they create)
/// and prompt replies (applied-or-ignored by contract, 03 §5) — allocate a
/// requestId only for uniform addressing and never expect a response.
sealed class EngineRequest {
  final int requestId;

  const EngineRequest({required this.requestId});
}

/// Opens (or rejoins) the pane-tab's browse channel (03 §3.2). Carries the
/// [ServerConfig] — the engine holds no bookmark store; the UI owns bookmarks
/// and supplies the config with every connection-bearing request.
final class OpenBrowseChannelRequest extends EngineRequest {
  final String serverId;
  final String paneTabId;
  final ServerConfig config;

  const OpenBrowseChannelRequest({
    required super.requestId,
    required this.serverId,
    required this.paneTabId,
    required this.config,
  });
}

/// Opens a local browse channel backed by a `LocalFileSystem` the engine
/// owns (03 §5's ownership table; D8 keeps dart:io off the UI isolate). No
/// [ServerConfig], no pool, no server-state surface — a local pane is not a
/// connection. [rootPath] is the channel's initial home, not a sandbox:
/// like pool channels, listings may navigate to any absolute path — the
/// user's OS permissions bound the reach, and confinement is 03 §7.2's
/// app-side `ScopedPathAccess` seam (v1 desktop grants are pass-through),
/// never this request. The engine canonicalizes [rootPath] (03 §2.2's
/// realpath semantics; `~` expands through the engine's environment) and
/// answers [BrowseChannelOpened] on the same channel-id routing as pool
/// channels, so listing and closing reuse the existing requests unchanged.
/// Only a *missing* root is guaranteed to open (surfacing the typed
/// `notFound` at first listing): a root under an unreadable ancestor
/// cannot be traversed, so the open itself fails typed
/// (`permissionDenied`, operation `resolve`) through the local funnel.
final class OpenLocalBrowseChannelRequest extends EngineRequest {
  final String rootPath;

  const OpenLocalBrowseChannelRequest({
    required super.requestId,
    required this.rootPath,
  });
}

/// Closes the pane-tab's browse channel; idempotent per channel.
final class CloseBrowseChannelRequest extends EngineRequest {
  final int channelId;

  const CloseBrowseChannelRequest({
    required super.requestId,
    required this.channelId,
  });
}

final class ListDirectoryRequest extends EngineRequest {
  final int channelId;
  final String path;

  const ListDirectoryRequest({
    required super.requestId,
    required this.channelId,
    required this.path,
  });
}

/// Start (or restart) forwarding this server's state as [ServerStateEvent]s;
/// the first forwarded event is the current state.
final class WatchServerRequest extends EngineRequest {
  final String serverId;

  const WatchServerRequest({required super.requestId, required this.serverId});
}

/// Stop forwarding this server's state.
final class UnwatchServerRequest extends EngineRequest {
  final String serverId;

  const UnwatchServerRequest({
    required super.requestId,
    required this.serverId,
  });
}

final class ConnectedServerIdsRequest extends EngineRequest {
  const ConnectedServerIdsRequest({required super.requestId});
}

/// Probe permission combines foreground visibility with the global setting.
enum ProbeActivity { paused, running }

/// Replaces eligible, locally seen targets; an empty list clears them.
/// Config ids are bookmark-derived serverIds (03 §3.5). The caller applies
/// per-favorite settings and sync-provenance eligibility before sending.
final class SetProbeTargetsRequest extends EngineRequest {
  final List<ServerConfig> targets;

  SetProbeTargetsRequest({
    required super.requestId,
    required List<ServerConfig> targets,
  }) : targets = List.unmodifiable(targets);
}

/// No probes run until explicitly enabled; pause invalidates stale work.
final class SetProbeActivityRequest extends EngineRequest {
  final ProbeActivity activity;

  const SetProbeActivityRequest({
    required super.requestId,
    required this.activity,
  });
}

/// Drops this serverId's pool reference (03 §3.5): closes its browse
/// channels, force-releases its transfer leases, trips in-flight credential
/// resolutions.
final class DisconnectServerRequest extends EngineRequest {
  final String serverId;

  const DisconnectServerRequest({
    required super.requestId,
    required this.serverId,
  });
}

/// Deletes the bookmark's connection state and its trust-incident records
/// (owner decision 2026-09-09, option 3a). Like [DisconnectServerRequest] for
/// the pool, plus the incident cascade; the engine also forgets the id's
/// config and watch. The cascade runs even when the pool teardown throws:
/// the error still reaches the caller, but the removal is final and must not
/// be retried — the app has already deleted the bookmark.
final class RemoveBookmarkRequest extends EngineRequest {
  final String serverId;

  const RemoveBookmarkRequest({
    required super.requestId,
    required this.serverId,
  });
}

/// Answers an open [EnginePromptEvent]. Deliberately un-acked: a reply
/// whose promptId is closed, unknown, kind-mismatched, or already answered
/// is ignored at debug level — promptId and kind only, never the payload,
/// since credential replies carry secrets (03 §5) — so there is no result
/// to report back.
final class PromptReplyRequest extends EngineRequest {
  final String promptId;
  final EnginePromptKind kind;
  final PromptReply reply;

  const PromptReplyRequest({
    required super.requestId,
    required this.promptId,
    required this.kind,
    required this.reply,
  });
}

/// Orderly engine shutdown: open prompts are dismissed, references dropped,
/// an ack is sent, then the UI kills the isolate.
final class ShutdownRequest extends EngineRequest {
  const ShutdownRequest({required super.requestId});
}

// ── Responses ───────────────────────────────────────────────────────────

/// The payload of a [ResponseEvent] — always typed, never a bare Object.
sealed class EngineResult {
  const EngineResult();
}

/// A failed request, reconstructed client-side as a [RemoteFileException].
/// `cause` does not cross the port (arbitrary exceptions are not sendable);
/// the message carries the user-facing summary.
final class EngineError extends EngineResult {
  final RemoteFileErrorKind kind;
  final String operation;
  final String? path;
  final String message;

  const EngineError({
    required this.kind,
    required this.operation,
    this.path,
    required this.message,
  });

  factory EngineError.fromException(RemoteFileException error) => EngineError(
    kind: error.kind,
    operation: error.operation,
    path: error.path,
    message: error.message,
  );

  RemoteFileException toException() => RemoteFileException(
    kind: kind,
    operation: operation,
    path: path,
    message: message,
  );
}

final class BrowseChannelOpened extends EngineResult {
  final int channelId;
  final String homePath;

  const BrowseChannelOpened({required this.channelId, required this.homePath});
}

final class DirectoryListed extends EngineResult {
  final List<RemoteFileEntry> entries;

  const DirectoryListed({required this.entries});
}

final class ServerIdsListed extends EngineResult {
  final List<String> ids;

  const ServerIdsListed({required this.ids});
}

/// Void results: channel close, disconnect, shutdown.
final class EngineAck extends EngineResult {
  const EngineAck();
}

// ── Spawn configuration ─────────────────────────────────────────────────

/// The first message sent after spawn (03 §5): everything the engine must
/// not resolve itself. Storage/journal directories and initial bandwidth
/// limits join with the slices that consume them (M4).
final class EngineConfig {
  /// The pool policy (D9's frozen numbers). Invalid values fail the engine's
  /// construction, which surfaces UI-side as engine termination.
  final PoolPolicy policy;

  /// Host keys pinned by the UI-side store; the engine seeds its TOFU
  /// verifier from these (pin storage itself stays app-side).
  final List<HostKey> hostKeyPins;

  /// Trust-incident records restored from the app-owned store; the engine
  /// seeds its in-memory incident store from these. A record is not restored
  /// unless its `pinnedFingerprintSha256` matches the pin [hostKeyPins] holds
  /// for the record's own endpoint — the verifier's `(host, port)` lookup,
  /// never a fingerprint found anywhere in the list, because only that
  /// endpoint's pin can review or lift the block (audit finding A).
  /// Re-detection covers the endpoint on the next connect. A skipped record
  /// is deleted only when the endpoint holds a *different* pin: with no pin
  /// at all the app keeps it, because an empty pin seed is indistinguishable
  /// from a pin store that failed to load.
  final List<IncidentRecord> incidents;

  const EngineConfig({
    this.policy = const PoolPolicy(),
    this.hostKeyPins = const [],
    this.incidents = const [],
  });
}
