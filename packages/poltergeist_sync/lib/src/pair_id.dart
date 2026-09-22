// §9's canonical pair identity: the key for `sync_state/<pairId>.json`
// and every run journal — for saved and ad-hoc pairs alike. Each side's
// canonical identity hashes to its own digest first; the two digests
// are sorted and hashed together, so the id survives pane swaps and
// spelling variants and prefix-shaped identities can never alias.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'plan.dart';

/// One endpoint's canonical identity string (05 §9):
/// `local:<absolute path>` for local sides,
/// `<user>@<host>:<port>:<absolute path>` for remote sides (host
/// lowercased, port/user made explicit by the stored identity — a
/// `serverConfigId` resolves through the catalog before reaching this
/// function, so the id never carries an opaque config reference).
String canonicalEndpointIdentity(SyncEndpoint endpoint) => switch (endpoint) {
  LocalEndpoint(:final path) => 'local:${_stripTrailingSeparator(path)}',
  RemoteEndpoint(:final server, :final path) =>
    '${_serverIdentity(server)}:${_stripTrailingSeparator(path)}',
};

String _serverIdentity(BookmarkServerRef ref) {
  final identity = ref.identity;
  if (identity != null) {
    return '${identity.username}@${identity.host.toLowerCase()}:'
        '${identity.port}';
  }
  // The config id stands in until the app layer resolves the stored
  // identity into user@host:port — pairs saved through the editor
  // resolve before persisting, so this form only appears when the
  // catalog entry is still pending resolution.
  return 'server:${ref.serverConfigId}';
}

String _stripTrailingSeparator(String path) {
  var out = path;
  while (out.length > 1 && (out.endsWith('/') || out.endsWith('\\'))) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// The canonical `pairId` for [pair] (05 §9): each side's identity is
/// normalized — NFC-folded when the side is known
/// normalization-insensitive, case-folded when known case-insensitive —
/// hashed to its own digest, and the two digests are sorted then
/// hashed together (never a delimiter-free concatenation, which
/// prefix-shaped identities could alias). The fold flags are resolved
/// at plan time (probe/override per §3) and must be settled before the
/// first sync_state write so the id never changes mid-history.
String syncPairId(
  SyncPair pair, {
  bool leftCaseInsensitive = false,
  bool rightCaseInsensitive = false,
  bool leftNormalizationInsensitive = false,
  bool rightNormalizationInsensitive = false,
}) {
  String digest(SyncEndpoint endpoint, bool foldCase, bool foldForm) {
    var identity = canonicalEndpointIdentity(endpoint);
    if (foldForm) identity = unorm.nfc(identity);
    if (foldCase) identity = identity.toLowerCase();
    return sha256.convert(utf8.encode(identity)).toString();
  }

  final digests = [
    digest(
      pair.left,
      leftCaseInsensitive,
      leftNormalizationInsensitive,
    ),
    digest(
      pair.right,
      rightCaseInsensitive,
      rightNormalizationInsensitive,
    ),
  ]..sort();
  return sha256
      .convert(utf8.encode('${digests[0]}:${digests[1]}'))
      .toString();
}
