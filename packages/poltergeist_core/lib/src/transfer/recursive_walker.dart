import 'dart:async';
import 'dart:collection';

import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

import '../fs/local_fs_safety.dart';
import 'transfer_task.dart';

/// The app-level recursive walker (07 §3.5).
///
/// Enumerates a source tree over the one VFS (D3 — `RemoteFileSystem`,
/// local or remote alike) as a pull-driven [Stream]: each [WalkEvent] is
/// produced only when the consumer asks for it, so a huge tree never
/// materializes more than the in-flight directory listing plus the
/// not-yet-listed directory backlog — the scan feeds execution as items
/// arrive (03 §4.2's scan-then-execute). The pinned VFS has no
/// streaming listing (`listDirectory` materializes one directory per
/// call), so one listing is the atomic unit; a consumer that stops
/// pulling stops all further listing work.
///
/// Two purposes (07 §3.5's recursive operations):
/// - [WalkPurpose.transfer] — upload/download plan building: parents
///   first, breadth order, symlinks reported as skips, destination leaf
///   names validated per the destination filesystem's rules.
/// - [WalkPurpose.delete] — enumerate-and-report for the D15 trash
///   follow-up: children emit before their container (a consumer can
///   delete deepest-first as items arrive) and symlinks are leaf targets
///   (deleting a link never follows it). **No delete ever executes
///   here** — the destructive action belongs to the D15 follow-up.
///
/// Safety, ported from Séance's `RemoteFilesController` validation
/// (docs/PORTS.md): every listed child must resolve inside its
/// container — a `.`/`..`, separator-carrying, or path-mismatched entry
/// fails the walk loudly instead of escaping the root — and a §13
/// flagged (undecodable) name is reported, never silently skipped; a
/// flagged directory is never listed because its lossy name can never
/// round-trip to the wire. Flag detection rides the [isFlaggedEntry]
/// seam until the pinned `RemoteFileEntry` exposes raw-name metadata
/// (docs/STATUS.md open item 13); a literal U+FFFD in an otherwise valid
/// name is never treated as evidence of invalid encoding.
///
/// Cancellation is the no-token reality (03 §4.4): a tripped
/// [cancellation] token throws a typed `cancelled` error at the next
/// check point and stops all further enumeration; an in-flight listing
/// may still complete engine-side (the VFS has no cancellable listing —
/// STATUS open item 12) and its result is discarded.
class RecursiveWalker {
  RecursiveWalker({
    required this.location,
    required this.purpose,
    this.source,
    this.destination,
    this.isFlaggedEntry,
    this.cancellation,
    Future<RemoteFileEntry> Function(String path)? stat,
    Future<List<RemoteFileEntry>> Function(String path)? listDirectory,
  }) : _stat = stat,
       _listDirectory = listDirectory {
    if (source == null && (stat == null || listDirectory == null)) {
      throw ArgumentError(
        'a source filesystem or both stat/listDirectory operations '
        'are required',
      );
    }
    if (purpose == WalkPurpose.transfer && destination == null) {
      // A transfer walk validates destination leaf names per entry —
      // without a destination there is nothing to validate against.
      throw ArgumentError.notNull('destination');
    }
  }

  /// The endpoint being walked — selects the source join rule used by
  /// the containment check (remote `/` joins vs the platform's).
  final FsLocation location;

  /// What the enumeration is for — see the class doc.
  final WalkPurpose purpose;

  /// The source VFS, used when [stat]/[listDirectory] are not injected.
  /// The transfer queue injects both so each call rides its scan leases
  /// and `disconnected` retry seam.
  final RemoteFileSystem? source;
  final Future<RemoteFileEntry> Function(String path)? _stat;
  final Future<List<RemoteFileEntry>> Function(String path)?
  _listDirectory;

  /// The destination endpoint — transfer walks validate each leaf name
  /// against its rules ([validateLocalName] for local targets,
  /// [validatePathComponent] for remote ones).
  final FsLocation? destination;

  /// The §13 flag detector — null until the upstream raw-name metadata
  /// lands (STATUS item 13), in which case nothing is flagged.
  final bool Function(RemoteFileEntry entry)? isFlaggedEntry;

  /// Optional cancellation token — the same `RemoteTransferCancellation`
  /// the queue hands its scans.
  final RemoteTransferCancellation? cancellation;

  // Growing discovery totals (02 §5.3's floor: each count only grows
  // while the walk runs; all are final once [isComplete] flips).
  int discoveredFiles = 0;
  int discoveredDirectories = 0;
  int discoveredBytes = 0;
  int discoveredSymlinks = 0;

  /// §13 flagged entries reported so far.
  int flaggedEntries = 0;

  /// Destination-name rejections (transfer walks only).
  int rejectedEntries = 0;

  /// Entries with no transferable content (fifos, sockets, …).
  int unsupportedEntries = 0;

  /// Roots and directories whose stat/listing failed.
  int failedEntries = 0;

  /// Flips when the walk drains — the scan-complete marker's source.
  bool isComplete = false;

  bool _started = false;

  /// Enumerates [roots] once. The stream is pull-driven: the generator
  /// suspends at every yielded event, so a paused or cancelled
  /// subscription halts enumeration at the next check point.
  Stream<WalkEvent> walk(List<String> roots) {
    if (_started) {
      throw StateError('a RecursiveWalker walks once; create another');
    }
    _started = true;
    return purpose == WalkPurpose.transfer
        ? _walkTransfer(roots)
        : _walkDelete(roots);
  }

  // ---------------------------------------------------------------------
  // Transfer walk — breadth-first, parents first (the queue's scan
  // order since #147; a directory's children emit as its listing is
  // consumed, and the closed-listing marker follows them).
  // ---------------------------------------------------------------------

  Stream<WalkEvent> _walkTransfer(List<String> roots) async* {
    final pending = Queue<WalkNode>();
    for (final rootPath in roots) {
      _throwIfCancelled();
      final RemoteFileEntry entry;
      try {
        entry = await _statEntry(rootPath);
      } on RemoteFileException catch (error) {
        _rethrowIfWalkEnding(error);
        failedEntries++;
        yield WalkRootFailedEvent(rootPath: rootPath, error: error);
        continue;
      }
      yield* _emitTransferEntry(
        WalkNode._(entry: entry, parent: null, depth: 0),
        pending,
      );
    }
    while (pending.isNotEmpty) {
      _throwIfCancelled();
      final node = pending.removeFirst();
      final List<RemoteFileEntry> children;
      try {
        children = await _listEntries(node.path);
      } on RemoteFileException catch (error) {
        _rethrowIfWalkEnding(error);
        failedEntries++;
        yield WalkListingFailedEvent(directory: node, error: error);
        continue;
      }
      for (final child in children) {
        _throwIfCancelled();
        _checkContainment(node, child);
        yield* _emitTransferEntry(
          WalkNode._(entry: child, parent: node, depth: node.depth + 1),
          pending,
        );
      }
      // The listing closed — the directory's planned children are final
      // (03 §4.2's case-collision window rule).
      yield WalkListingClosedEvent(directory: node);
    }
    isComplete = true;
  }

  Stream<WalkEvent> _emitTransferEntry(
    WalkNode node,
    Queue<WalkNode> pending,
  ) async* {
    final classified = _classify(node.entry);
    if (classified.kind == WalkItemKind.directory) {
      pending.addLast(node);
    }
    yield WalkEntryEvent(
      node: node,
      kind: classified.kind,
      detail: classified.detail,
    );
  }

  // ---------------------------------------------------------------------
  // Delete walk — depth-first, post-order: children emit before their
  // container so the D15 follow-up can delete deepest-first as items
  // arrive. Enumeration and reporting only; nothing here deletes.
  // ---------------------------------------------------------------------

  Stream<WalkEvent> _walkDelete(List<String> roots) async* {
    final stack = ListQueue<_WalkFrame>();
    for (final rootPath in roots) {
      _throwIfCancelled();
      final RemoteFileEntry entry;
      try {
        entry = await _statEntry(rootPath);
      } on RemoteFileException catch (error) {
        _rethrowIfWalkEnding(error);
        failedEntries++;
        yield WalkRootFailedEvent(rootPath: rootPath, error: error);
        continue;
      }
      final node = WalkNode._(entry: entry, parent: null, depth: 0);
      final classified = _classify(entry);
      if (classified.kind != WalkItemKind.directory) {
        yield WalkEntryEvent(
          node: node,
          kind: classified.kind,
          detail: classified.detail,
        );
        continue;
      }
      stack.addLast(_WalkFrame(node));
      while (stack.isNotEmpty) {
        _throwIfCancelled();
        final frame = stack.last;
        if (frame.children == null) {
          try {
            frame.children = await _listEntries(frame.node.path);
          } on RemoteFileException catch (error) {
            _rethrowIfWalkEnding(error);
            failedEntries++;
            // The directory could not be listed — it is reported failed
            // (its delete is the consumer's call) and its subtree stays
            // undiscovered.
            yield WalkListingFailedEvent(
              directory: frame.node,
              error: error,
            );
            stack.removeLast();
            continue;
          }
        }
        if (frame.index >= frame.children!.length) {
          stack.removeLast();
          // Post-order: the container's own delete entry lands after
          // every descendant it still holds.
          yield WalkEntryEvent(
            node: frame.node,
            kind: WalkItemKind.directory,
          );
          continue;
        }
        final child = frame.children![frame.index++];
        _throwIfCancelled();
        _checkContainment(frame.node, child);
        final childNode = WalkNode._(
          entry: child,
          parent: frame.node,
          depth: frame.node.depth + 1,
        );
        final childClassified = _classify(child);
        if (childClassified.kind == WalkItemKind.directory) {
          stack.addLast(_WalkFrame(childNode));
        } else {
          yield WalkEntryEvent(
            node: childNode,
            kind: childClassified.kind,
            detail: childClassified.detail,
          );
        }
      }
    }
    isComplete = true;
  }

  // ---------------------------------------------------------------------
  // Classification and safety
  // ---------------------------------------------------------------------

  /// Per-entry classification, run at discovery time so the totals grow
  /// as entries arrive. [WalkItemKind.directory] defers emission for
  /// [WalkPurpose.delete] (post-order) — everything else emits inline.
  ({WalkItemKind kind, String? detail}) _classify(RemoteFileEntry entry) {
    // §13 before everything: a flagged name cannot round-trip, so the
    // entry is reported and never listed or planned. (A flagged symlink
    // reports as flagged — the name problem dominates the link skip.)
    if (isFlaggedEntry?.call(entry) ?? false) {
      flaggedEntries++;
      return (
        kind: WalkItemKind.flagged,
        detail: 'the entry name is not valid UTF-8',
      );
    }
    if (entry.isSymbolicLink) {
      discoveredSymlinks++;
      // Transfer: links never transfer (03 §4.2). Delete: the link
      // itself is the leaf target — deleting it never follows it.
      return (
        kind: WalkItemKind.symbolicLink,
        detail: purpose == WalkPurpose.transfer
            ? 'symbolic links are not transferred'
            : null,
      );
    }
    if (purpose == WalkPurpose.transfer) {
      try {
        _validateDestinationName(entry.name);
      } on FormatException catch (error) {
        rejectedEntries++;
        return (kind: WalkItemKind.rejectedName, detail: error.message);
      }
    }
    switch (entry.type) {
      case RemoteFileType.file:
        discoveredFiles++;
        discoveredBytes += entry.size ?? 0;
        return (kind: WalkItemKind.file, detail: null);
      case RemoteFileType.directory:
        discoveredDirectories++;
        return (kind: WalkItemKind.directory, detail: null);
      default:
        unsupportedEntries++;
        return (
          kind: WalkItemKind.unsupported,
          detail: 'unsupported source entry type ${entry.type.name}',
        );
    }
  }

  /// The ported boundary rules: [validateLocalName] (Windows reserved
  /// names, forbidden characters, trailing dot/space) for local
  /// destinations, [validatePathComponent] for remote ones.
  void _validateDestinationName(String name) {
    if (destination is ServerFsLocation) {
      validatePathComponent(name);
    } else {
      validateLocalName(name);
    }
  }

  /// Traversal containment: a listed child must be a bare name joined
  /// under its container. An empty, `.`/`..`, or separator-carrying name — or
  /// a path that is not exactly `join(parent, name)` — means the VFS
  /// handed back an entry resolving outside the walk root; the walk
  /// fails loudly rather than letting a delete or download escape
  /// (symlink loops cannot form — links are never followed). Other
  /// illegal-name shapes (NUL, overlong) are not escapes: the
  /// destination-name rules reject them per item.
  void _checkContainment(WalkNode parent, RemoteFileEntry child) {
    final name = child.name;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        // `\` is a separator only for a local source — a remote POSIX
        // name may legitimately carry one (the destination-side rules
        // still reject it there).
        (location is LocalFsLocation && name.contains(r'\'))) {
      throw _escape(parent, child);
    }
    if (child.path != _joinSource(parent.path, name)) {
      throw _escape(parent, child);
    }
  }

  RemoteFileException _escape(WalkNode parent, RemoteFileEntry child) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'recursive-walk',
        path: child.path,
        message:
            'listed entry "${child.path}" resolves outside the walk root '
            '(container "${parent.path}")',
      );

  String _joinSource(String directory, String name) =>
      location is ServerFsLocation
          ? remoteJoin(directory, name)
          : p.join(directory, name);

  // ---------------------------------------------------------------------
  // VFS access — injected seams ride the consumer's lease/retry path;
  // the defaults hit [source] directly.
  // ---------------------------------------------------------------------

  Future<RemoteFileEntry> _statEntry(String path) =>
      _stat != null
          ? _stat(path)
          : source!.stat(path, followLinks: false);

  Future<List<RemoteFileEntry>> _listEntries(String path) =>
      _listDirectory != null
          ? _listDirectory(path)
          : source!.listDirectory(path);

  void _throwIfCancelled() {
    if (cancellation?.isCancelled ?? false) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'recursive-walk',
        message: 'walk cancelled',
      );
    }
  }

  /// `disconnected` and `cancelled` are walk-ending conditions the
  /// consumer owns (the queue re-leases and retries inside its scan-op
  /// seam; a cancelled token trips the task). Per-node failures —
  /// permission denied, not found mid-walk — are reported as events.
  void _rethrowIfWalkEnding(RemoteFileException error) {
    if (error.kind == RemoteFileErrorKind.disconnected ||
        error.kind == RemoteFileErrorKind.cancelled) {
      throw error;
    }
  }
}

/// What a walk enumerates for (07 §3.5's recursive operations).
enum WalkPurpose {
  /// Upload/download plan building — parents-first, symlinks reported
  /// as skips, destination names validated.
  transfer,

  /// Enumerate-and-report for the D15 delete story — post-order
  /// (children before containers), symlinks are leaf targets, and no
  /// destination exists. The destructive action is the follow-up's.
  delete,
}

/// Per-entry classification — the walker reports; consumers decide.
enum WalkItemKind {
  /// A regular file — a work item.
  file,

  /// A directory — parents-first for [WalkPurpose.transfer], post-order
  /// for [WalkPurpose.delete].
  directory,

  /// A symlink — skipped by a transfer walk (03 §4.2), a leaf target in
  /// a delete enumeration.
  symbolicLink,

  /// A §13 flagged (undecodable) name — reported, never silently
  /// skipped; never listed, since the lossy name cannot round-trip.
  flagged,

  /// The destination name rules refused the leaf (transfer only).
  rejectedName,

  /// A type with no transferable content (fifo, socket, …).
  unsupported,
}

/// One enumerated node — the container linkage consumers key
/// per-directory state on (identity-keyed).
final class WalkNode {
  WalkNode._({required this.entry, required this.parent, required this.depth});

  /// The source entry as listed (or stat'd, for a root).
  final RemoteFileEntry entry;

  /// The containing directory's node; null for a walk root.
  final WalkNode? parent;

  /// Root depth is 0; children are `parent.depth + 1`.
  final int depth;

  String get path => entry.path;
  String get name => entry.name;
}

/// Walk output — a pull-driven event stream (see [RecursiveWalker]).
sealed class WalkEvent {
  const WalkEvent();
}

/// One enumerated entry. [container] links to the parent's node; [kind]
/// is the classification, and [detail] carries reason text for the
/// report kinds (`symbolicLink`, `flagged`, `rejectedName`,
/// `unsupported`).
final class WalkEntryEvent extends WalkEvent {
  const WalkEntryEvent({
    required this.node,
    required this.kind,
    this.detail,
  });

  final WalkNode node;
  final WalkItemKind kind;
  final String? detail;

  RemoteFileEntry get entry => node.entry;
  WalkNode? get container => node.parent;
  int get depth => node.depth;
}

/// A root whose initial stat failed — a per-root report; the walk
/// continues with the remaining roots.
final class WalkRootFailedEvent extends WalkEvent {
  const WalkRootFailedEvent({required this.rootPath, required this.error});

  final String rootPath;
  final RemoteFileException error;
}

/// A directory's listing finished — the transfer scan's signal that its
/// planned children are final (03 §4.2's closed-listing rule). Transfer
/// walks emit one per successfully listed directory; delete walks omit
/// it (the post-order directory entry is already the close signal).
final class WalkListingClosedEvent extends WalkEvent {
  const WalkListingClosedEvent({required this.directory});

  final WalkNode directory;
}

/// A directory's listing failed — the container reports failed and its
/// subtree stays undiscovered.
final class WalkListingFailedEvent extends WalkEvent {
  const WalkListingFailedEvent({required this.directory, required this.error});

  final WalkNode directory;
  final RemoteFileException error;
}

/// One pending delete-walk frame: a directory plus the not-yet-consumed
/// remainder of its listing.
final class _WalkFrame {
  _WalkFrame(this.node);

  final WalkNode node;
  List<RemoteFileEntry>? children;
  int index = 0;
}
