import 'package:poltergeist_core/poltergeist_core.dart';

import 'engine_session.dart';

/// Where an on-demand folder-size walk stands (02 §2.6's "folders
/// compute on demand").
enum FolderSizeStatus {
  /// The walk is still listing directories.
  running,

  /// The walk visited every reachable entry. [FolderSizeProgress]'s
  /// counters hold the total.
  done,

  /// The caller's cancellation token fired; the counters hold the
  /// partial walk, never presented as a total.
  cancelled,

  /// The ROOT listing refused (a nested directory's refusal only counts
  /// toward [FolderSizeProgress.unreadable]).
  failed,
}

/// One folder-size walk's snapshot: live progress while running, the
/// terminal answer once settled. Immutable — the controller swaps the
/// whole value per update so a stale read can never observe a
/// half-mutated counter set.
final class FolderSizeProgress {
  const FolderSizeProgress({
    required this.targetPath,
    required this.status,
    this.bytes = 0,
    this.entries = 0,
    this.unmeasured = 0,
    this.unreadable = 0,
    this.error,
  });

  /// The directory the walk is measuring — the inspector matches it
  /// against its current target, so a retarget never displays a walk
  /// started for a different folder.
  final String targetPath;

  final FolderSizeStatus status;

  /// Summed byte count of every non-directory entry that carried a size.
  final int bytes;

  /// Entries visited so far — files, links, and directories alike, in
  /// the "N items" sense the panel reports beside the total.
  final int entries;

  /// Entries whose listing row carried no size. They count toward
  /// [entries] but contribute nothing to [bytes] — the panel flags the
  /// total as partial rather than presenting it as exact.
  final int unmeasured;

  /// Directory entries that refused their listing. The walk continues
  /// past them (one unreadable subdirectory must not void the rest) and
  /// counts them so the result is never silent about being partial.
  final int unreadable;

  /// The failure that ended a [FolderSizeStatus.failed] walk. The
  /// walker only ever records the root listing's typed VFS refusal
  /// here — an untyped fault (a dying channel, a broken seam) is never
  /// folded into a snapshot: it propagates to the caller, whose own
  /// failure path records it (see [measureFolderSize]).
  final Object? error;
}

/// Measures [path] recursively through the pane's browse channel — the
/// existing `listDirectory` seam, so local and remote folders measure
/// identically and no widget ever touches a filesystem (D8). The walk
/// is depth-first over an explicit stack; every directory's listing is
/// one channel round trip, and [onProgress] fires after each lands.
///
/// Cancellation is cooperative: the token is checked before every
/// listing request, so a held answer settles and the loop exits on the
/// next check — a cancelled walk's result reports
/// [FolderSizeStatus.cancelled] with its partial counters.
///
/// A nested directory that refuses its listing is skipped and counted
/// in [FolderSizeProgress.unreadable]; only the ROOT listing's refusal
/// fails the walk. Both those cases are TYPED [RemoteFileException]s —
/// an untyped fault (a dying channel, a broken seam) always propagates
/// out of the walk rather than masquerading as a partial accounting;
/// the caller's own catch is what records it into a failed snapshot.
/// Entries without a size add nothing to the byte
/// total and count toward [FolderSizeProgress.unmeasured]. Symbolic
/// links are never followed — a link counts its own size, and the
/// visited-set guards against a pathological listing that recurses.
/// The set keys on separator-normalized spellings so a server echoing
/// '/a/b' and '/a/b/' cannot defeat it; case is deliberately NOT
/// folded, since remote case sensitivity is the server's property.
/// Beyond cycles, the trust model is cancellability, not a hard cap:
/// the channel is a trusted peer, and a hostile server minting endless
/// unique paths is stopped by the user's cancel, not a counter.
Future<FolderSizeProgress> measureFolderSize(
  AppBrowseChannel channel,
  String path, {
  required RemoteTransferCancellation cancellation,
  void Function(FolderSizeProgress progress)? onProgress,
}) async {
  var bytes = 0;
  var entries = 0;
  var unmeasured = 0;
  var unreadable = 0;
  FolderSizeProgress snapshot(FolderSizeStatus status, {Object? error}) =>
      FolderSizeProgress(
        targetPath: path,
        status: status,
        bytes: bytes,
        entries: entries,
        unmeasured: unmeasured,
        unreadable: unreadable,
        error: error,
      );

  final visited = <String>{_dedupeKey(path)};
  final pending = <String>[path];
  var first = true;
  while (pending.isNotEmpty) {
    if (cancellation.isCancelled) {
      return snapshot(FolderSizeStatus.cancelled);
    }
    final next = pending.removeLast();
    final isRoot = first;
    first = false;
    final List<RemoteFileEntry> listed;
    try {
      listed = await channel.listDirectory(next);
    } on RemoteFileException catch (error) {
      // The root's refusal voids the measure — there is nothing to sum.
      // A nested refusal only loses that subtree, which the unreadable
      // count keeps honest.
      if (isRoot) return snapshot(FolderSizeStatus.failed, error: error);
      unreadable++;
      continue;
    }
    for (final entry in listed) {
      // Defensive: a server that echoes '.'/'..' must not recurse.
      if (entry.name == '.' || entry.name == '..') continue;
      entries++;
      if (entry.isDirectory) {
        // Dedupe on the normalized spelling but list the server's own
        // — the channel may be spelling-sensitive.
        if (visited.add(_dedupeKey(entry.path))) pending.add(entry.path);
      } else if (entry.size != null) {
        bytes += entry.size!;
      } else {
        unmeasured++;
      }
    }
    onProgress?.call(snapshot(FolderSizeStatus.running));
  }
  return snapshot(FolderSizeStatus.done);
}

/// The visited-set's dedupe key: strips trailing separators so a
/// server spelling one directory two ways cannot recurse it twice.
/// Only dedupe — the stripped key never reaches the channel.
String _dedupeKey(String path) {
  var key = path;
  // '\' is a separator only in Windows-style spellings — on a POSIX
  // remote it is a legal filename character, so strip it only when
  // the path contains no '/'.
  final windowsStyle = !key.contains('/');
  while (key.length > 1 &&
      (key.endsWith('/') || (windowsStyle && key.endsWith(r'\')))) {
    key = key.substring(0, key.length - 1);
  }
  return key;
}
