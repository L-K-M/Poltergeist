// The sync feature's app-side composition root (05 §11's environment
// seam): where journals and sync_state live, which device identity
// stamps run ids, and how a pair's endpoints resolve to the
// RemoteFileSystem objects the scanner and executor speak. Local
// endpoints bind a LocalFileSystem directly (D3 — one VFS contract);
// remote endpoints answer the honest `unsupported` refusal until the
// engine protocol carries filesystem verbs (docs/STATUS.md item 23 —
// the same posture the app-side transfer queue takes, never a stub).
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import 'sync_state_store.dart';

/// The `sync_runs/` directory name under app support (05 §8's journal
/// home).
const String kSyncRunsDirectoryName = 'sync_runs';

/// Everything a sync session needs that is not the pair itself: the
/// state store, the journal directory, the run-id device prefix, and
/// the endpoint → filesystem resolution. Constructed once at the app
/// composition root and shared by every plan-view session.
final class SyncEnvironment {
  SyncEnvironment({
    required this.states,
    required this.syncRunsDirectory,
    required this.deviceId,
    RemoteFileSystem Function()? localFileSystem,
  }) : _localFileSystem = localFileSystem ?? LocalFileSystem.new;

  /// The production shape: file-backed state under the app-support
  /// directory, the enrollment state's device id, the real local fs.
  factory SyncEnvironment.forSupportDirectory(
    String supportDirectoryPath, {
    required Future<String> Function() deviceId,
  }) => SyncEnvironment(
    states: FileSyncStateStore(
      Directory(
        '$supportDirectoryPath${Platform.pathSeparator}'
        '$kSyncStateDirectoryName',
      ),
    ),
    syncRunsDirectory:
        '$supportDirectoryPath${Platform.pathSeparator}'
        '$kSyncRunsDirectoryName',
    deviceId: deviceId,
  );

  /// §9's per-pair local state (mtime-trust flags, probe cache, trash
  /// cache, last-run stamps).
  final SyncStateStore states;

  /// `<app-support>/sync_runs` — where SyncRunJournal files live.
  final String syncRunsDirectory;

  /// 04 §3.1's device identity — the runId prefix source (05 §6).
  final Future<String> Function() deviceId;
  final RemoteFileSystem Function() _localFileSystem;

  /// Whether [endpoint] can serve a filesystem in this process — false
  /// for remote sides until the engine protocol carries the verbs.
  bool endpointAvailable(SyncEndpoint endpoint) =>
      endpoint is LocalEndpoint;

  /// The filesystem [endpoint] resolves to. Remote endpoints throw the
  /// typed `unsupported` refusal — the plan view catches it and renders
  /// the honest-absence state rather than a dead scan.
  RemoteFileSystem fileSystemFor(SyncEndpoint endpoint) =>
      switch (endpoint) {
        LocalEndpoint() => _localFileSystem(),
        RemoteEndpoint() => throw RemoteFileException(
          kind: RemoteFileErrorKind.unsupported,
          operation: 'sync endpoint',
          path: endpoint.path,
          message: 'remote sync endpoints are not available yet',
        ),
      };

  /// The root path a scan/executor runs under for [endpoint].
  String rootFor(SyncEndpoint endpoint) => switch (endpoint) {
    LocalEndpoint(:final path) => path,
    RemoteEndpoint(:final path) => path,
  };
}
