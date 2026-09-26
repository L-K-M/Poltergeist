import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart' show basicLocaleListResolution;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import 'engine_session.dart' show serverConfigForBookmark;
import 'jump_host_guard.dart';

/// The app's answer to "what does this serverId dial" for the bridged
/// transfer lease (protocol v13): a transfer, a checkout, a preview, or a
/// sync run can lease a server no pane has opened this session — a task
/// restored from the journal after a relaunch above all — so the lease
/// carries the config the same way a pane's connect does.
///
/// Resolution order mirrors the sidebar's open path
/// (`WorkspaceShell._openBookmark`):
/// 1. an ad-hoc registration ([register]) — sync pairs built from the
///    panes and other callers that dial without a stored bookmark;
/// 2. the stored bookmark: a `serverConfigId` reference resolves through
///    the pulled catalog (it carries fields an embedded identity cannot
///    express), falling back to the embedded identity beside it;
/// 3. otherwise null — a Quick Connect `adhoc:` id lives only in its
///    tab, and the engine then uses the config that tab's browse open
///    supplied (refusing typed when there was none).
final class AppServerConfigSource implements ServerConfigSource {
  AppServerConfigSource({required this._bookmarks, this._catalogLookup});

  final BookmarkRepository _bookmarks;

  /// Late-bindable: the pulled catalog is composed after the transfer
  /// queue in `main.dart`, so the lookup is assigned once it exists.
  ServerConfig? Function(String serverConfigId)? _catalogLookup;

  final Map<String, ServerConfig> _adHoc = {};
  final Map<String, BookmarkServerRef> _refs = {};

  /// Wires the pulled-catalog lookup once the backup service exists.
  set catalogLookup(ServerConfig? Function(String serverConfigId)? lookup) =>
      _catalogLookup = lookup;

  /// Registers [config] under [serverId] for callers that dial without a
  /// stored bookmark. Re-registering replaces.
  void register(String serverId, ServerConfig config) =>
      _adHoc[serverId] = config;

  /// The serverId a sync endpoint's [ref] leases under, registering the
  /// ref so [configFor] can answer it. Endpoints naming the same server
  /// share one id — and, through the pool's endpoint key (03 §3.5), the
  /// same transports and trust state as the panes browsing it, so a sync
  /// run never triggers a second TOFU or 2FA prompt.
  String registerEndpoint(BookmarkServerRef ref) {
    final catalogId = ref.serverConfigId;
    final identity = ref.identity;
    final serverId = catalogId != null
        ? '$_syncServerIdPrefix$catalogId'
        : '$_syncServerIdPrefix${identity!.username}@${identity.host}:'
              '${identity.port}';
    _refs[serverId] = ref;
    return serverId;
  }

  /// Every lease dials what this answers, so a route this build cannot
  /// execute is refused here: a transfer, checkout, preview, or sync run
  /// reaches a server no pane opened (a task restored after a relaunch),
  /// and must not dial it directly either.
  @override
  Future<ServerConfig?> configFor(String serverId) async {
    final config = await _resolve(serverId);
    if (config != null) {
      refuseJumpHostRoute(config, operation: 'resolve server');
    }
    return config;
  }

  Future<ServerConfig?> _resolve(String serverId) async {
    final registered = _adHoc[serverId];
    if (registered != null) return registered;
    final endpointRef = _refs[serverId];
    if (endpointRef != null) {
      return _configForRef(serverId, endpointRef, label: serverId);
    }

    final bookmark = (await _bookmarks.load())
        .where((candidate) => candidate.id == serverId)
        .firstOrNull;
    final ref = bookmark?.server;
    if (bookmark == null || ref == null) return null;

    final catalogId = ref.serverConfigId;
    if (catalogId != null) {
      final pulled = _catalogLookup?.call(catalogId);
      if (pulled != null) return pulled;
      if (ref.identity == null) throw _catalogMiss(bookmark.label);
    }
    return serverConfigForBookmark(bookmark);
  }

  ServerConfig _configForRef(
    String serverId,
    BookmarkServerRef ref, {
    required String label,
  }) {
    final catalogId = ref.serverConfigId;
    if (catalogId != null) {
      final pulled = _catalogLookup?.call(catalogId);
      if (pulled != null) return pulled;
    }
    final identity = ref.identity;
    if (identity == null) throw _catalogMiss(label);
    return ServerConfig(
      id: serverId,
      label: label,
      host: identity.host,
      port: identity.port,
      username: identity.username,
      authMethod: identity.authMethod,
      secretRef: identity.secretRef,
      identityFilePath: identity.identityFilePath,
      createdAt: 0,
      updatedAt: 0,
    );
  }

  /// The message is ARB copy — the failed task row renders it verbatim
  /// (the same posture as the engine-less queue's refusal).
  static RemoteFileException _catalogMiss(String label) => RemoteFileException(
    kind: RemoteFileErrorKind.notFound,
    operation: 'resolve server',
    message: lookupAppLocalizations(
      basicLocaleListResolution(
        PlatformDispatcher.instance.locales,
        AppLocalizations.supportedLocales,
      ),
    ).activityTaskServerNotInCatalog(label),
  );
}

/// The serverId prefix sync endpoints lease under — distinct from
/// bookmark ids and Quick Connect's `adhoc:` so the three never collide.
const String _syncServerIdPrefix = 'sync-endpoint:';
