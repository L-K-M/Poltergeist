// Tree scanning (05 §3): one TreeScanner per side, each a
// RemoteFileSystem (D3 — the same object that owns SFTP transfers for
// remote sides and is LocalFileSystem for local roots). The walk is
// pipelined: up to [readdirConcurrency] listDirectory calls stay in
// flight (M0-tuned 8, 05 §2 D9). Scan errors are exclusions, never
// emptiness: an unlistable directory drops its subtree on this side
// (the differ mirrors the exclusion on the other side, §6 rule 8) and
// records a ScanWarning; an unlistable ROOT aborts the scan instead of
// returning an empty map. Symlinks are never followed (v1
// SymlinkPolicy.skip): they appear as kind:symlink entries so the
// differ can plan skip and exclude the counterpart on the other side —
// Mirror must never delete across a link.

import 'dart:async';
import 'dart:collection';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'ignore.dart';
import 'plan.dart';

/// Largest mtime an SFTP v3 uint32 seconds field can carry (05 §4).
const int maxSftpMtimeSecs = 0xFFFFFFFF;

/// Clamps an original mtime (seconds) into the SFTP v3 range — 05 §4's
/// rule, applied only when an original lies outside it.
int clampSftpMtimeSecs(int seconds) => seconds.clamp(0, maxSftpMtimeSecs);

/// Whether an mtime (seconds) fits the SFTP v3 wire field unmodified.
bool sftpMtimeInRange(int seconds) =>
    seconds >= 0 && seconds <= maxSftpMtimeSecs;

/// Cooperative cancellation for a scan — 09 §3: every long operation
/// takes a token, and cancels are cooperative (check between READDIRs).
final class ScanCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Thrown when a [ScanCancellation] fires mid-scan.
final class ScanCancelled implements Exception {
  const ScanCancelled();

  @override
  String toString() => 'ScanCancelled';
}

/// How a [ScanResult]'s case sensitivity was decided (05 §3: a defaulted
/// or assumed sensitivity is second-class; only a probe result or an
/// explicit per-pair override counts as authoritative).
enum CaseSensitivityBasis {
  /// A write probe on this side's root answered it.
  probe,

  /// Per-pair caseSensitiveOverride.
  override,

  /// Fallback when probing is unavailable or was not attempted.
  assumption,
}

/// Output of one side's scan: a flat map relativePath → EntrySnapshot
/// plus the warnings produced along the way (05 §3).
final class ScanResult {
  ScanResult({
    required this.rootPath,
    required Map<String, EntrySnapshot> entries,
    required this.warnings,
    required this.caseSensitive,
    required this.caseSensitivityBasis,
  }) : entries = Map.unmodifiable(entries);

  /// The canonicalized root the scan ran under.
  final String rootPath;

  /// '/'-separated relative paths (no trailing separator), sorted.
  final Map<String, EntrySnapshot> entries;
  final List<ScanWarning> warnings;

  /// The naming truth the comparison operates under.
  final bool caseSensitive;
  final CaseSensitivityBasis caseSensitivityBasis;
}

/// Pipelined tree scanner over one [RemoteFileSystem] (05 §3).
final class TreeScanner {
  TreeScanner(
    this._fileSystem, {
    int readdirConcurrency = defaultReaddirConcurrency,
  }) : readdirConcurrency = readdirConcurrency < 1
           ? 1
           : readdirConcurrency;

  /// M0-tuned pipeline depth (05 §2 D9): 8 outstanding READDIRs measured
  /// 3,639 LAN entries/s versus 482 serially.
  static const int defaultReaddirConcurrency = 8;

  /// Prefix of the write-probe name. Each probe appends a uuidV4 so no
  /// pre-existing case-variant file can spoof the insensitivity check,
  /// and the `.poltergeist*` app default plus the explicit skip below
  /// keep a stranded probe out of every snapshot.
  static const String caseProbePrefix = '.poltergeist-caseprobe';

  final RemoteFileSystem _fileSystem;
  final int readdirConcurrency;

  /// Random once per scanner: repeated probes overwrite the same name
  /// (bounding crash debris to one file per scanner instance) while a
  /// pre-existing case-variant still cannot spoof the check.
  late final String _probeSuffix = secureRandomBytes(
    8,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Scans [rootPath] and returns the flat snapshot map plus warnings.
  ///
  /// [side] labels every [ScanWarning].
  /// [trashPath] is this side's effective trash root on this host (the
  /// SyncRuleSet.trashPath* value the caller resolved); anything under it
  /// is excluded regardless of rules. [caseSensitivityOverride] is the
  /// per-pair override; when it is null and [probeCaseSensitivity] is
  /// true the scanner write-probes the root before the walk starts —
  /// the probe fails cleanly on a read-only root (assume case-sensitive,
  /// warning) and never races because the fixed probe name is excluded
  /// from the scan itself.
  Future<ScanResult> scan(
    String rootPath, {
    required SyncSide side,
    SyncRuleSet rules = const SyncRuleSet(),
    String? trashPath,
    bool? caseSensitivityOverride,
    bool probeCaseSensitivity = false,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  }) async {
    // The one rule-set boundary that exists in this slice: a malformed
    // set fails fast here rather than after the walk (release builds
    // strip the constructor's assert).
    rules.ensureSupported();
    final root = await _fileSystem.canonicalize(rootPath);
    final trashRelative = await _trashRelative(root, trashPath);
    final ignores = SyncIgnoreRules(
      excludeGlobs: rules.excludeGlobs,
      includeHidden: rules.includeHidden,
      trashRelativePath: trashRelative,
    );

    final warnings = <ScanWarning>[];
    final (caseSensitive, caseBasis, probeWarning) =
        await _resolveCaseSensitivity(
          root,
          side: side,
          override: caseSensitivityOverride,
          probe: probeCaseSensitivity,
        );
    if (probeWarning != null) warnings.add(probeWarning);

    final entries = <String, EntrySnapshot>{};
    var symlinkCount = 0;
    var scanned = 0;

    // Pending (absolute, relative) directories and completed listings.
    // Results arrive via a queue drained each iteration so in-flight
    // READDIRs keep the pipe full while entries are absorbed.
    final pending = Queue<({String absolute, String relative})>()
      ..add((absolute: root, relative: ''));
    final results = Queue<({String relative, Object? error, List<RemoteFileEntry>? entries})>();
    var inFlight = 0;
    Completer<void>? signal;

    void start(String absolute, String relative) {
      inFlight++;
      () async {
        try {
          results.add((
            relative: relative,
            entries: await _fileSystem.listDirectory(absolute),
            error: null,
          ));
        } catch (error) {
          results.add((relative: relative, entries: null, error: error));
        } finally {
          inFlight--;
          final s = signal;
          if (s != null && !s.isCompleted) s.complete();
        }
      }();
    }

    while (pending.isNotEmpty || inFlight > 0) {
      if (cancellation?.isCancelled ?? false) throw const ScanCancelled();
      while (pending.isNotEmpty && inFlight < readdirConcurrency) {
        final task = pending.removeFirst();
        start(task.absolute, task.relative);
      }
      if (results.isEmpty) {
        signal = Completer<void>();
        await signal.future;
        signal = null;
      }
      while (results.isNotEmpty) {
        final listing = results.removeFirst();
        final error = listing.error;
        if (error != null) {
          if (listing.relative.isEmpty) {
            // Root listing failure aborts the scan — an empty map would
            // look like an empty tree and Mirror would delete the whole
            // other side (05 §3's "exclusions, never emptiness").
            throw error;
          }
          warnings.add(
            ScanWarning(
              relativePath: listing.relative,
              side: side,
              message:
                  'Could not list "${listing.relative}/" — $error. '
                  'The subtree is excluded on both sides.',
            ),
          );
          continue;
        }
        for (final entry in listing.entries!) {
          final name = entry.name;
          if (name.isEmpty ||
              name == '.' ||
              name == '..' ||
              name.contains('/')) {
            warnings.add(
              ScanWarning(
                relativePath: listing.relative,
                side: side,
                message:
                    'Skipping malformed entry name "$name" under '
                    '"${listing.relative}/".',
              ),
            );
            continue;
          }
          final relative = listing.relative.isEmpty
              ? name
              : '${listing.relative}/$name';
          final isDirectory = entry.type == RemoteFileType.directory;
          // A stranded probe file never enters a snapshot, rules or no
          // rules — it is engine debris, not tree content.
          if (name.startsWith(caseProbePrefix) ||
              ignores.isExcluded(relative, isDirectory: isDirectory)) {
            continue;
          }
          final snapshot = _snapshot(entry);
          final mtimeSecs = snapshot.mtimeSecs;
          if (mtimeSecs != null && !sftpMtimeInRange(mtimeSecs)) {
            warnings.add(
              ScanWarning(
                relativePath: relative,
                side: side,
                message:
                    'Modification time on "$relative" is outside the '
                    'SFTP v3 range; it will compare clamped.',
              ),
            );
          }
          entries[relative] = snapshot;
          scanned++;
          switch (entry.type) {
            case RemoteFileType.directory:
              pending.add((absolute: entry.path, relative: relative));
            case RemoteFileType.symbolicLink:
              // Never followed (05 §3): a link whose target is a
              // directory — or the root itself — is a skipped entry, not
              // a recursion step. The count feeds one aggregated warning
              // below; the entries plan as skip via the differ.
              symlinkCount++;
            case RemoteFileType.file || RemoteFileType.other:
              break;
          }
        }
        onProgress?.call(scanned);
      }
    }

    if (symlinkCount > 0) {
      warnings.add(
        ScanWarning(
          relativePath: '',
          side: side,
          message:
              '$symlinkCount symbolic ${symlinkCount == 1 ? 'link' : 'links'} '
              'skipped.',
        ),
      );
    }

    final sorted = Map.fromEntries(
      entries.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );
    return ScanResult(
      rootPath: root,
      entries: sorted,
      warnings: warnings,
      caseSensitive: caseSensitive,
      caseSensitivityBasis: caseBasis,
    );
  }

  /// The root-relative path of [trashPath] on this host, or null when it
  /// sits outside the scanned root (then nothing extra is excluded).
  Future<String?> _trashRelative(String root, String? trashPath) async {
    if (trashPath == null) return null;
    final String resolved;
    try {
      resolved = await _fileSystem.canonicalize(trashPath);
    } on RemoteFileException catch (e) {
      if (e.kind != RemoteFileErrorKind.notFound) rethrow;
      // Trash commonly does not exist yet on a first run (the executor
      // creates it on the first delete); nothing to exclude until then.
      return null;
    }
    final normalizedRoot = _stripTrailingSeparator(root);
    final normalizedTrash = _stripTrailingSeparator(resolved);
    // Backslash-separator canonical roots are Windows-local volumes —
    // case-insensitive by default — so a differently-cased trashPath
    // must still be recognized (and rejected when it IS the root).
    final caseInsensitive = normalizedRoot.contains('\\');
    final rootCmp = caseInsensitive ? normalizedRoot.toLowerCase() : normalizedRoot;
    final trashCmp = caseInsensitive ? normalizedTrash.toLowerCase() : normalizedTrash;
    if (trashCmp == rootCmp) {
      // A trash root equal to the sync root would exclude every entry —
      // an empty scan that Mirror reads as "delete the other side".
      // Refuse the configuration rather than produce it.
      throw ArgumentError.value(
        trashPath,
        'trashPath',
        'cannot be the sync root itself',
      );
    }
    final inside =
        trashCmp.length > rootCmp.length &&
        trashCmp.startsWith(rootCmp) &&
        (rootCmp.endsWith('/') ||
            rootCmp.endsWith('\\') ||
            trashCmp[rootCmp.length] == '/' ||
            trashCmp[rootCmp.length] == '\\');
    if (!inside) return null;
    var relative = normalizedTrash.substring(normalizedRoot.length);
    if (relative.startsWith('/') || relative.startsWith('\\')) {
      relative = relative.substring(1);
    }
    // On hosts whose canonical form uses '\' (Windows), the relative
    // path arrives backslash-separated; scan keys are always '/'.
    if (normalizedRoot.contains('\\')) {
      relative = relative.replaceAll('\\', '/');
    }
    return relative.isEmpty ? null : relative;
  }

  static String _stripTrailingSeparator(String path) =>
      path.length > 1 && (path.endsWith('/') || path.endsWith('\\'))
      ? path.substring(0, path.length - 1)
      : path;

  /// Joins a child name onto a scan-side path. '/' is required on SFTP
  /// and accepted by dart:io on every platform including Windows, so the
  /// same join serves local and remote sides.
  static String _joinPath(String parent, String name) =>
      parent.endsWith('/') ? '$parent$name' : '$parent/$name';

  /// Resolves this side's case sensitivity per 05 §3: an explicit
  /// per-pair override wins; otherwise a write probe (when requested)
  /// answers the question on the filesystem itself; an unwritable root
  /// falls back to assuming case-sensitive and says so.
  Future<(bool, CaseSensitivityBasis, ScanWarning?)> _resolveCaseSensitivity(
    String root, {
    required SyncSide side,
    required bool? override,
    required bool probe,
  }) async {
    if (override != null) return (override, CaseSensitivityBasis.override, null);
    if (!probe) return (true, CaseSensitivityBasis.assumption, null);
    RemoteFileEntry? probeEntry;
    try {
      // A randomly-suffixed name: a pre-existing case-variant of a
      // FIXED probe name would spoof case-insensitivity on a sensitive
      // filesystem; a random name cannot have a pre-existing variant.
      final probeName = '$caseProbePrefix-$_probeSuffix';
      probeEntry = await _fileSystem.upload(
        _joinPath(root, probeName),
        const Stream<List<int>>.empty(),
        overwrite: true,
      );
      bool sensitive;
      try {
        await _fileSystem.stat(
          _joinPath(root, probeName.toUpperCase()),
          followLinks: false,
        );
        sensitive = false;
      } on RemoteFileException catch (e) {
        if (e.kind != RemoteFileErrorKind.notFound) rethrow;
        sensitive = true;
      }
      try {
        await _fileSystem.delete(probeEntry);
      } catch (_) {
        // Best effort: a stranded probe is invisible to scans (the
        // .poltergeist* default) and harmless to the next run's
        // overwrite:true.
      }
      return (sensitive, CaseSensitivityBasis.probe, null);
    } catch (_) {
      return (
        true,
        CaseSensitivityBasis.assumption,
        ScanWarning(
          relativePath: '',
          side: side,
          message:
              'Could not probe case sensitivity under "$root"; assuming '
              'case-sensitive.',
        ),
      );
    }
  }

  static EntrySnapshot _snapshot(RemoteFileEntry entry) {
    final modified = entry.modifiedAt;
    final mtimeSecs = modified == null
        ? null
        : modified.millisecondsSinceEpoch ~/ 1000;
    return EntrySnapshot(
      kind: switch (entry.type) {
        RemoteFileType.file => EntryKind.file,
        RemoteFileType.directory => EntryKind.directory,
        RemoteFileType.symbolicLink => EntryKind.symlink,
        RemoteFileType.other => EntryKind.other,
      },
      size: entry.size,
      mtimeSecs: mtimeSecs,
      mode: entry.mode,
    );
  }
}
