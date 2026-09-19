/// 04 §3.2's `SeanceServerCatalog`: the in-memory, read-only
/// materialization of pulled `serverConfig` records, present only in
/// shared mode (§4.2). It owns no file — [BookmarkCoordinator] rebuilds it
/// from the persistent record store on every `applyPulled`, so a tombstone
/// or a config edit Séance pushed lands on the next round without any
/// cache-invalidation bookkeeping.
library;

import 'package:seance_core/seance_core.dart';

/// A read-only view over the Séance servers visible to the shared account.
/// `servers` is replaced wholesale by the coordinator's rebuild; consumers
/// hold no reference into it.
final class SeanceServerCatalog {
  List<ServerConfig> _servers = const [];

  /// The pulled Séance server configs, sorted by label for display. The
  /// list is unmodifiable and identity-stable between [replace] calls.
  List<ServerConfig> get servers => _servers;

  /// Swap in a fresh materialization — the coordinator calls this after
  /// diffing the store's prefixless records on each apply pass.
  void replace(Iterable<ServerConfig> servers) {
    _servers = List.unmodifiable(servers.toList()
      ..sort((a, b) {
        final byLabel =
            a.label.toLowerCase().compareTo(b.label.toLowerCase());
        return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
      }));
  }
}
