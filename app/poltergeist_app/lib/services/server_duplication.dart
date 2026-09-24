// Ported from Séance app/seance_app/lib/services/server_duplication.dart @
// 035b0d8 (tag v0.9.1), plus `duplicationSourceUnchanged` and
// `SourceServerChanged` from app_state.dart (kept beside the planner they
// guard rather than in a state class this port does not carry); see
// docs/PORTS.md.
// Divergence: `IdentityFileBookmark`/`bookmarkFor` dropped — Poltergeist's
// macOS build is not sandboxed, so a referenced key file opens by path and
// there is no security-scoped grant to carry into the copy.
import 'package:poltergeist_core/poltergeist_core.dart';

/// The label a copy of [label] should take, given the labels already [taken].
///
/// Duplicating a duplicate gives "web copy 2" rather than "web copy copy": the
/// suffix is parsed back off before it is re-applied, so a row of copies reads
/// as a numbered series instead of a stutter. Matching is case-insensitive
/// because the list sorts that way — two labels differing only in case are the
/// same name in the place the user reads them.
///
/// Nothing enforces unique labels; this only avoids handing the user two rows
/// they cannot tell apart, which is the whole reason a copy needs a new name.
String duplicateServerLabel(String label, Iterable<String> taken) {
  // The source's own label counts as taken whether or not the caller listed
  // it: a source named "web copy" would otherwise get "web copy" back — the
  // one label this function exists never to return.
  final used = {
    for (final name in taken) name.trim().toLowerCase(),
    label.trim().toLowerCase(),
  };
  final base = _withoutCopySuffix(label.trim());
  // Trimmed because `base` is empty for a server named "copy" (and for an
  // unnamed one), which would otherwise leave the candidate leading-spaced.
  // Terminates: `used` is finite, so some `n` is free.
  for (var n = 1; ; n++) {
    final candidate = (n == 1 ? '$base copy' : '$base copy $n').trim();
    if (!used.contains(candidate.toLowerCase())) return candidate;
  }
}

/// The trailing "copy" / "copy 3" a previous duplication left behind. Anchored
/// at a word start as well as at a space so a server *named* "copy" is
/// recognized as one too — that leaves an empty base, which
/// [duplicateServerLabel] then numbers as "copy", "copy 2", … rather than
/// stuttering. `RegExp` has no inline `(?i)`; case-insensitivity is a flag.
final RegExp _copySuffix =
    RegExp(r'(^|\s+)copy(\s+\d+)?$', caseSensitive: false);

/// Strips repeatedly, because one pass leaves the stutter it exists to
/// prevent: a server hand-named "web copy 2 copy" reduces to "web copy 2",
/// whose first candidate is the taken name it started from, so the duplicate
/// lands on "web copy 2 copy 2". Stripping to "web" gives the next free
/// number instead. Terminating, since each pass either shortens the string
/// or returns.
String _withoutCopySuffix(String label) {
  var base = label.trim();
  while (true) {
    final stripped = base.replaceFirst(_copySuffix, '').trim();
    if (stripped == base) return base;
    base = stripped;
  }
}

/// [source] as a new server: its own id, its own timestamps, a [label] of its
/// own, and a [secretRef] pointing at its own copy of the credential.
///
/// Everything else is carried over deliberately, including
/// [ServerConfig.excludeFromSync] — a copy of a server the user keeps off the
/// sync server starts off it too, which is the direction that cannot surprise
/// anyone — and [ServerConfig.identityFilePath], which is a reference to a file
/// on disk rather than key material and is as valid for the copy as for the
/// original.
///
/// The credential is *copied*, never shared by pointing both configs at one
/// vault entry. Sharing would be cheaper and wrong in three separate ways:
/// deleting either server deletes the credential out from under the other
/// (nothing reference-counts vault entries), editing either rewrites it in
/// place, and the sync layer keys a secret record by the credential rather
/// than the server — so two owners would push two versions of one record, and
/// one owner's "don't sync this credential" would not stop the other from
/// uploading it.
ServerConfig duplicateServerConfig(
  ServerConfig source, {
  required String id,
  required String label,
  required String? secretRef,
  required int now,
}) => ServerConfig(
  id: id,
  label: label,
  host: source.host,
  port: source.port,
  username: source.username,
  authMethod: source.authMethod,
  secretRef: secretRef,
  identityFilePath: source.identityFilePath,
  jumpHostId: source.jumpHostId,
  syncSecret: source.syncSecret,
  group: source.group,
  color: source.color,
  customColor: source.customColor,
  // All three mark fields, not just the glyph: they are one choice to the
  // user, and a copy that lost the emoji or the imported image would look
  // like a different server at a glance — which is the whole point of a mark.
  icon: source.icon,
  iconEmoji: source.iconEmoji,
  iconImage: source.iconImage,
  loginScript: source.loginScript,
  excludeFromSync: source.excludeFromSync,
  // A copy is new, not as old as what it was copied from: `createdAt` is what
  // "added on" would report, and the answer is today.
  createdAt: now,
  updatedAt: now,
);

/// Whether the server a duplicate was planned from still is what it was.
///
/// Only the credential reference matters: the copy carries its own id, label
/// and timestamps, and a rename or a colour change on the source between the
/// plan and the save costs nothing. A missing server or a different ref does,
/// because the credential the plan holds was read against the old one.
bool duplicationSourceUnchanged(ServerConfig? latest, ServerConfig source) =>
    latest != null && latest.secretRef == source.secretRef;

/// The source of a duplicate stopped matching what the copy was planned from.
///
/// Its [toString] is a sentence because the catalog's toast shows it verbatim,
/// the way it shows a locked keyring: a user who is told only "could not
/// duplicate" has nothing to do next.
class SourceServerChanged implements Exception {
  final String label;
  const SourceServerChanged(this.label);

  @override
  String toString() => '"$label" changed while it was being copied — it was '
      'deleted, or it now holds a different credential. Nothing was created.';
}

/// A planned duplicate: the config to store and the vault entry to write
/// first when the source had a credential to copy.
class ServerDuplication {
  final ServerConfig config;
  final Secret? secret;

  const ServerDuplication({required this.config, this.secret});
}

/// Work out what duplicating [source] takes, without writing anything.
///
/// Separated from the service that saves it because this is the part that can
/// lose a credential, and orchestration left inside a service is
/// orchestration nothing can exercise. The ids and the clock are arguments
/// for the same reason.
///
/// A dangling [ServerConfig.secretRef] — the config points at a vault entry
/// that is gone — plans as "no credential" rather than failing: the original
/// is already in that state, and the copy is not the place to discover it. A
/// vault that *throws*, which is what a locked OS keyring does, propagates
/// instead: a duplicate that quietly lost its password would look identical in
/// the list and only admit it at connect time.
Future<ServerDuplication> planServerDuplication(
  ServerConfig source, {
  required SecretVault vault,
  required Iterable<String> takenLabels,
  required String id,
  required String secretId,
  required int now,
}) async {
  Secret? secret;
  final sourceRef = source.secretRef;
  if (sourceRef != null) {
    final original = await vault.getSecret(sourceRef);
    // copyWith rather than a fresh constructor: listing the fields here would
    // silently drop anything Secret gains later, which is the same failure
    // duplicateServerConfig's JSON-compared test exists to catch for configs.
    if (original != null) secret = original.copyWith(id: secretId);
  }
  return ServerDuplication(
    config: duplicateServerConfig(
      source,
      id: id,
      label: duplicateServerLabel(source.label, takenLabels),
      secretRef: secret?.id,
      now: now,
    ),
    secret: secret,
  );
}
