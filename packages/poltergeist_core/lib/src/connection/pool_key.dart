import 'package:seance_core/seance_core.dart';

/// The key a connection pool is shared under (03 §3.5).
///
/// Credentials are deliberately not part of the key: the first bookmark to
/// connect authenticates the shared transports for every sibling at the
/// same (host, port, username) — if that auth fails, siblings sharing the
/// pool fail with it (03 §3.2 rule 3 reuses the resolved credentials).
///
/// Pools are shared *by endpoint*, not by bookmark id: two bookmarks at the
/// same (host, port, username) with the same connection-security context are
/// one server behind one reference-counted pool, so the TOFU prompt fires
/// once and transports are not doubled.
///
/// The connection-security context half of §3.5's key is, today, exactly the
/// `jumpHostId` seam: every v1 connection resolves host-key trust through
/// the same shared TOFU store, so the "pinned known_hosts entry vs.
/// TOFU-accepted key" distinction does not exist yet. A future strict-pinning
/// mode extends this key — it does not get a second pool structure.
class PoolKey {
  /// Hostname, normalized: trimmed, lowercased — DNS names are
  /// case-insensitive and `Example.com`/`example.com` are one endpoint.
  final String host;

  final int port;

  /// Usernames stay case-sensitive: Unix treats them that way.
  final String username;

  /// D10 seam prep: carried, compared, never executed in v1. Two bookmarks
  /// that route through different jump hosts must never share a transport,
  /// because one would silently bypass the other's routing.
  final String? jumpHostId;

  const PoolKey({
    required this.host,
    required this.port,
    required this.username,
    this.jumpHostId,
  });

  factory PoolKey.of(ServerConfig config) => PoolKey.normalize(
    host: config.host,
    port: config.port,
    username: config.username,
    jumpHostId: config.jumpHostId,
  );

  /// The single normalization both config-derived keys and persisted
  /// incident records key under: any drift between them would silently
  /// detach a persisted block from the pool it belongs to.
  factory PoolKey.normalize({
    required String host,
    required int port,
    required String username,
    String? jumpHostId,
  }) => PoolKey(
    host: host.trim().toLowerCase(),
    port: port,
    username: username.trim(),
    jumpHostId: jumpHostId,
  );

  @override
  bool operator ==(Object other) =>
      other is PoolKey &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.jumpHostId == jumpHostId;

  @override
  int get hashCode => Object.hash(host, port, username, jumpHostId);
}
