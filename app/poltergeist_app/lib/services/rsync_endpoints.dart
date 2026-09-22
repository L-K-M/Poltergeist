// The app half of the rsync export seam (05 §2.1): a pair's
// BookmarkServerRef endpoints resolve to the exporter's
// ResolvedSyncEndpoints here — the pure package function cannot look
// anything up. An embedded identity resolves directly; a shared-mode
// `serverConfigId` resolves through the pulled Séance catalog — an
// absent catalog leaves the ref unresolved and the caller surfaces the
// honest "cannot build" state rather than a silently wrong host.
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

/// The shared-mode catalog lookup a `serverConfigId` ref resolves
/// through (04 §3.2) — returns null for an unknown id.
typedef ServerConfigLookup = ServerConfig? Function(String id);

/// The resolver a [SyncPlanController] holds — null when a remote side
/// cannot be resolved to a dialable identity.
typedef RsyncEndpointResolver =
    ResolvedSyncEndpoints? Function(SyncPair pair);

/// Resolves [pair]'s endpoints for [buildRsyncCommand]. Null when a
/// `serverConfigId` side has no [serverConfig] answer. Remote sides tag
/// [SyncEndpointOs.unknown] — §2.1's connection-time OS detection lands
/// with remote sync itself (the `.*` hidden-file note simply stays
/// silent for a remote whose OS is untagged, never guessed).
ResolvedSyncEndpoints? resolveRsyncEndpoints(
  SyncPair pair, {
  ServerConfigLookup? serverConfig,
  String? localOsName,
}) {
  final localOs = (localOsName ?? Platform.operatingSystem) == 'windows'
      ? SyncEndpointOs.windows
      : SyncEndpointOs.posix;
  ResolvedSyncEndpoint? resolve(SyncEndpoint endpoint) {
    return switch (endpoint) {
      LocalEndpoint(:final path) => ResolvedLocalEndpoint(
        path: path,
        os: localOs,
      ),
      RemoteEndpoint(:final server, :final path) => _remote(
        server,
        path,
        serverConfig,
      ),
    };
  }

  final left = resolve(pair.left);
  final right = resolve(pair.right);
  if (left == null || right == null) return null;
  return ResolvedSyncEndpoints(left: left, right: right);
}

ResolvedRemoteEndpoint? _remote(
  BookmarkServerRef ref,
  String path,
  ServerConfigLookup? serverConfig,
) {
  final identity = ref.identity;
  if (identity != null) {
    return ResolvedRemoteEndpoint(
      user: identity.username,
      host: identity.host,
      port: identity.port,
      path: path,
      connectionShape: {
        if (identity.identityFilePath != null)
          SyncConnectionFlag.identityFile,
      },
    );
  }
  final id = ref.serverConfigId;
  if (id == null) return null;
  final config = serverConfig?.call(id);
  if (config == null) return null;
  return ResolvedRemoteEndpoint(
    user: config.username,
    host: config.host,
    port: config.port,
    path: path,
    connectionShape: {
      if (config.identityFilePath != null)
        SyncConnectionFlag.identityFile,
      if (config.jumpHostId != null) SyncConnectionFlag.jumpHost,
    },
  );
}
