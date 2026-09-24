// The sync feature's app-side composition root (05 §11's environment
// seam): where journals and sync_state live, which device identity
// stamps run ids, and how a pair's endpoints resolve to the
// RemoteFileSystem objects the scanner and executor speak. Local
// endpoints bind a LocalFileSystem directly (D3 — one VFS contract);
// remote endpoints lease engine-side channels through the bridged
// transfer lease (protocol v13, STATUS item 23) — and answer the honest
// `unsupported` refusal only when the engine failed to spawn.
import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import 'server_config_source.dart';
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
    this._connections,
    this._serverConfigs,
  }) : _localFileSystem = localFileSystem ?? LocalFileSystem.new;

  /// The production shape: file-backed state under the app-support
  /// directory, the enrollment state's device id, the real local fs.
  factory SyncEnvironment.forSupportDirectory(
    String supportDirectoryPath, {
    required Future<String> Function() deviceId,
    ConnectionManager? connections,
    AppServerConfigSource? serverConfigs,
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
    connections: connections,
    serverConfigs: serverConfigs,
  );

  /// §9's per-pair local state (mtime-trust flags, probe cache, trash
  /// cache, last-run stamps).
  final SyncStateStore states;

  /// `<app-support>/sync_runs` — where SyncRunJournal files live.
  final String syncRunsDirectory;

  /// 04 §3.1's device identity — the runId prefix source (05 §6).
  final Future<String> Function() deviceId;
  final RemoteFileSystem Function() _localFileSystem;

  /// The engine's bridged lease seam; null when the engine failed to
  /// spawn — remote endpoints then refuse typed.
  final ConnectionManager? _connections;
  final AppServerConfigSource? _serverConfigs;

  /// One lease-on-demand filesystem per remote server, shared by every
  /// scan, diff, and run of every pair naming that server.
  final Map<String, LeasedRemoteFileSystem> _remote = {};

  /// Whether [endpoint] can serve a filesystem in this process — local
  /// always; remote once the engine bridge is composed.
  bool endpointAvailable(SyncEndpoint endpoint) => switch (endpoint) {
    LocalEndpoint() => true,
    RemoteEndpoint() => _connections != null && _serverConfigs != null,
  };

  /// The filesystem [endpoint] resolves to. A remote endpoint leases a
  /// transfer channel of its server on first use and keeps it until
  /// [releaseRemoteLeases] (or its idle backstop); without the engine
  /// bridge it throws the typed `unsupported` refusal — the plan view
  /// catches it and renders the honest-absence state.
  RemoteFileSystem fileSystemFor(SyncEndpoint endpoint) {
    switch (endpoint) {
      case LocalEndpoint():
        return _localFileSystem();
      case RemoteEndpoint(:final server, :final path):
        final connections = _connections;
        final configs = _serverConfigs;
        if (connections == null || configs == null) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.unsupported,
            operation: 'sync endpoint',
            path: path,
            message: 'remote sync endpoints are not available yet',
          );
        }
        final serverId = configs.registerEndpoint(server);
        return _remote[serverId] ??= LeasedRemoteFileSystem(
          connections,
          serverId,
        );
    }
  }

  /// Returns every remote lease sync holds — called when a scan, run,
  /// retry, or restore settles and when a plan view disposes, so an idle
  /// pair never pins pool channels. The next remote call leases again.
  Future<void> releaseRemoteLeases() async {
    await Future.wait([for (final fs in _remote.values) fs.release()]);
  }

  /// The root path a scan/executor runs under for [endpoint].
  String rootFor(SyncEndpoint endpoint) => switch (endpoint) {
    LocalEndpoint(:final path) => path,
    RemoteEndpoint(:final path) => path,
  };
}
