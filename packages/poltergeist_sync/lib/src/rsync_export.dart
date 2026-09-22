// The rsync exporter (05 §2.1, D6): renders a pair's ruleset as the
// equivalent `rsync` invocation for the clipboard — pure text
// generation. Nothing here executes a process (05 §11's invariant test
// rejects a `Process` reference anywhere in this package); the native
// engine remains the only executor, and rsync is a human-readable
// equivalent a power user can paste, audit, and adjust.
//
// Safety contract, in brief:
// - every generated argument is POSIX single-quoted (`'` → `'\''`);
// - a remote spec is ONE single-quoted word `'user@host:path'`, and the
//   path portion is additionally backslash-escaped against an allowlist
//   because the remote shell re-parses it (quote twice, once per shell —
//   never `-s`/`--protect-args`, which the common peers lack);
// - positional paths always follow `--` so a `-…` path cannot be read
//   as bundled options;
// - every unrepresentable piece lands as a `# note:` in the leading
//   comment block — nothing is silently dropped.
import 'ignore.dart';
import 'plan.dart';

/// The OS tag a [ResolvedSyncEndpoint] carries (05 §2.1): the app layer
/// fills the local side from `Platform.operatingSystem` and the remote
/// side from connection-time detection — the pure exporter cannot probe
/// either. `unknown` keeps the Windows-attribute note silent rather than
/// guessed.
enum SyncEndpointOs { windows, posix, unknown }

/// A connection-shape flag the rendered command cannot carry (05 §2.1):
/// the pair dials with it, but threading it into generated text would
/// open a second credential surface — the export notes the gap instead.
enum SyncConnectionFlag {
  /// The side authenticates with an on-disk OpenSSH private key.
  identityFile,

  /// The side tunnels through a ProxyJump host.
  jumpHost,
}

/// One resolved endpoint of the exported pair — `user`/`host`/`port`
/// already resolved by the app layer (05 §2.1: `BookmarkServerRef` →
/// identity before calling).
sealed class ResolvedSyncEndpoint {
  const ResolvedSyncEndpoint({required this.path, required this.os});

  /// The endpoint's root path, rendered verbatim.
  final String path;

  /// See [SyncEndpointOs].
  final SyncEndpointOs os;
}

/// A local endpoint — [path] renders as a local rsync path.
final class ResolvedLocalEndpoint extends ResolvedSyncEndpoint {
  const ResolvedLocalEndpoint({required super.path, required super.os});
}

/// A remote endpoint — renders as the one-word `'user@host:path'` spec.
final class ResolvedRemoteEndpoint extends ResolvedSyncEndpoint {
  const ResolvedRemoteEndpoint({
    required this.user,
    required this.host,
    this.port = 22,
    required super.path,
    super.os = SyncEndpointOs.unknown,
    this.connectionShape = const {},
  });

  final String user;
  final String host;
  final int port;

  /// The pair's connection settings the command cannot express — every
  /// flag set here produces its `# note:`; an empty set is the plain
  /// case.
  final Set<SyncConnectionFlag> connectionShape;
}

/// Both resolved sides of a pair, in the pair's left/right order.
final class ResolvedSyncEndpoints {
  const ResolvedSyncEndpoints({required this.left, required this.right});

  final ResolvedSyncEndpoint left;
  final ResolvedSyncEndpoint right;
}

/// The paths the plan refused to touch for engine reasons (05 §2.1):
/// scan-error subtree roots (§6 rule 8's mirrored exclusions) and
/// symlink paths — the §3 surfaces the exporter must exclude or a pasted
/// Mirror would delete inside territory the preview never entered.
/// Ancestor-covered paths collapse into their root's exclusion (rsync
/// does not descend into an excluded directory), and the result is
/// sorted so the emitted `--exclude` block is canonical.
List<String> rsyncEngineSkipPaths(SyncPlan plan) {
  final paths = <String>{};
  for (final warning in plan.warnings) {
    if (warning.kind == ScanWarningKind.listingFailure &&
        warning.relativePath.isNotEmpty) {
      paths.add(warning.relativePath);
    }
  }
  for (final item in plan.items) {
    final symlinked =
        item.left?.kind == EntryKind.symlink ||
        item.right?.kind == EntryKind.symlink;
    if (symlinked || item.reason == SyncReason.scanError) {
      paths.add(item.relativePath);
    }
  }
  final sorted = paths.toList()..sort();
  final kept = <String>[];
  for (final path in sorted) {
    if (kept.any((root) => path.startsWith('$root/'))) continue;
    kept.add(path);
  }
  return kept;
}

/// Renders [rules] over [endpoints] as the commented rsync block
/// (05 §2.1): every `# note:` first — auth caveat, override count,
/// approximation notes in the order §2.1's rules introduce them — then
/// the commented dry-run line, then the real command (two dry-run/live
/// pairs for Additive; no command at all when both sides are remote).
///
/// [rules] is the EFFECTIVE ruleset — the caller resolves §4's
/// `mtimeUnreliable` fallback to `sizeOnly` before calling, exactly as
/// it resolves the endpoints. [now] is required so the timestamped
/// backup-dir stays a pure function of the inputs (golden-tested).
String buildRsyncCommand(
  ResolvedSyncEndpoints endpoints,
  SyncRuleSet rules, {
  int manualOverrides = 0,
  required List<String> engineSkipPaths,
  required DateTime now,
}) {
  final remoteSides = [
    endpoints.left,
    endpoints.right,
  ].whereType<ResolvedRemoteEndpoint>().toList();
  final bothRemote = remoteSides.length == 2;
  final mirror =
      rules.direction != SyncDirection.bidirectional &&
      rules.deletions != DeletionPolicy.none;
  final deletionsTrash = rules.deletions == DeletionPolicy.trash;
  final backupsTrash = rules.backups == BackupPolicy.trash;
  // §2.1's preserveMtime:false downgrade lives here (it is a ruleset
  // field); the mtimeUnreliable fallback is the caller's, since that
  // state lives in sync_state outside the ruleset.
  final effectiveComparison =
      rules.comparison == ComparisonMode.sizeAndMtime &&
          !rules.preserveMtime
      ? ComparisonMode.sizeOnly
      : rules.comparison;
  final filters = _filtersFor(rules);
  final trashSkipPaths = _trashSkipPaths(rules);

  final notes = <String>[];
  if (remoteSides.isNotEmpty) {
    notes.add(
      "uses your OpenSSH config and known_hosts, not Poltergeist's "
      'connections',
    );
  }
  if (manualOverrides > 0) {
    notes.add(
      '$manualOverrides manual per-item overrides are not reflected — '
      'this command applies the ruleset only and may copy or delete '
      'items you excluded in the plan',
    );
  }
  if (engineSkipPaths.isNotEmpty) {
    notes.add(
      'scan-error subtrees and symlinks are excluded to match the plan',
    );
  }
  for (final side in remoteSides) {
    if (side.connectionShape.contains(SyncConnectionFlag.identityFile)) {
      notes.add(
        'this pair authenticates with an identity file — the command '
        'below does not pass -i and will use your OpenSSH defaults '
        'instead',
      );
    }
    if (side.connectionShape.contains(SyncConnectionFlag.jumpHost)) {
      notes.add(
        'this pair connects through a jump host — the command below '
        'connects directly and will not traverse it',
      );
    }
  }

  // Approximation notes in the order §2.1's table introduces them.
  if (mirror && rules.maxDelete >= 1) {
    notes.add(
      "--delete-delay approximates the plan's delete-after-clean-copy "
      'gate — on a partial failure that is not an I/O error rsync may '
      'still delete where the executor would not',
    );
    notes.add(
      '--max-delete=${rules.maxDelete} caps deletions per run — rsync '
      'performs up to the cap and stops with an error, where the plan '
      'refuses to start at all',
    );
  } else if (mirror) {
    // Unreachable through SyncRuleSet's constructor (it clamps to ≥1) —
    // kept as the §2.1 contract anyway: a 0 must never render as
    // --max-delete=0, whose meaning is version-dependent (rsync ≤ 2.6.9
    // reads it as unlimited), nor as a bare --delete-delay that reads
    // as "deletions allowed".
    notes.add(
      'maxDelete is 0 — this command performs no deletions; if any '
      'deletion were pending, the plan would have refused to run at '
      'all (transfers included), so this transfer-only command is an '
      'approximation',
    );
  }
  if (deletionsTrash && !backupsTrash) {
    notes.add(
      "rsync's one --backup-dir rescues overwritten files too — the "
      'plan keeps only deletions there; the command preserves more '
      'than the plan (the safe direction)',
    );
  }
  if (rules.deletions == DeletionPolicy.permanent && backupsTrash) {
    notes.add(
      "rsync's --backup-dir also rescues the deleted files the plan "
      'would delete permanently — the command deletes less than the '
      'plan (the safe direction)',
    );
  }
  if (rules.deletions == DeletionPolicy.permanent && !backupsTrash) {
    notes.add(
      'pasting runs the real sync — its deletions are permanent (no '
      'trash, no backup-dir)',
    );
  }
  for (final pattern in filters.divergent) {
    notes.add(
      'pattern ${_sq(pattern)} is approximated — the engine\'s '
      'gitignore dialect treats it literally where rsync reads filter '
      'syntax',
    );
  }
  if (!rules.includeHidden &&
      (endpoints.left.os == SyncEndpointOs.windows ||
          endpoints.right.os == SyncEndpointOs.windows)) {
    notes.add(
      "'.*' covers dot-prefixed names only — a Windows side's "
      'hidden-attribute files are not excludable this way',
    );
  }
  if (rules.direction == SyncDirection.bidirectional) {
    notes.add(
      '-u approximates conflicts as newer-wins; Poltergeist surfaces '
      'them instead',
    );
  }
  if (rules.transferConcurrency != 1) {
    notes.add('rsync is single-stream');
  }
  if (rules.acceptedTimeShifts.isNotEmpty) {
    notes.add(
      'accepted time shifts '
      '(${rules.acceptedTimeShifts.map((s) => '${s}s').join(', ')}) '
      'have no rsync equivalent beyond --modify-window',
    );
  }
  if ((endpoints.left is ResolvedLocalEndpoint &&
          endpoints.left.os == SyncEndpointOs.windows) ||
      (endpoints.right is ResolvedLocalEndpoint &&
          endpoints.right.os == SyncEndpointOs.windows)) {
    notes.add('adjust the local Windows path for your rsync build');
  }

  final lines = <String>[for (final note in notes) '# note: $note'];
  if (bothRemote) {
    lines.add(
      '# note: both endpoints are remote — rsync refuses a '
      'remote-to-remote transfer; Poltergeist routes such pairs through '
      'the local machine, so no runnable command is emitted',
    );
    return '${lines.join('\n')}\n';
  }

  final remote = remoteSides.singleOrNull;
  final directions = switch (rules.direction) {
    SyncDirection.leftToRight => const [
      (SyncSide.left, SyncSide.right),
    ],
    SyncDirection.rightToLeft => const [
      (SyncSide.right, SyncSide.left),
    ],
    SyncDirection.bidirectional => const [
      (SyncSide.left, SyncSide.right),
      (SyncSide.right, SyncSide.left),
    ],
  };
  for (final (sourceSide, destinationSide) in directions) {
    final flags = _flags(
      rules: rules,
      effectiveComparison: effectiveComparison,
      mirror: mirror,
      backups: deletionsTrash || backupsTrash,
      backupDir: _backupDir(destinationSide, rules, now),
      remote: remote,
      engineSkipPaths: engineSkipPaths,
      trashSkipPaths: trashSkipPaths,
      filters: filters.args,
    );
    final source = _renderEndpoint(
      sourceSide == SyncSide.left ? endpoints.left : endpoints.right,
      source: true,
    );
    final destination = _renderEndpoint(
      destinationSide == SyncSide.left ? endpoints.left : endpoints.right,
      source: false,
    );
    lines.add(
      "# Preview first (matches Poltergeist's plan):  "
      'rsync -n -i $flags -- $source $destination',
    );
    lines.add('rsync $flags -- $source $destination');
  }
  return '${lines.join('\n')}\n';
}

/// The shared flag list for one direction (§2.1) — everything between
/// `rsync` and `--`, in a fixed order the goldens pin.
String _flags({
  required SyncRuleSet rules,
  required ComparisonMode effectiveComparison,
  required bool mirror,
  required bool backups,
  required String backupDir,
  required ResolvedRemoteEndpoint? remote,
  required List<String> engineSkipPaths,
  required List<String> trashSkipPaths,
  required List<String> filters,
}) {
  return [
    '-r',
    '-p',
    if (rules.preserveMtime) '-t',
    switch (effectiveComparison) {
      ComparisonMode.sizeAndMtime =>
        '--modify-window=${rules.mtimeToleranceSecs}',
      ComparisonMode.sizeOnly => '--size-only',
      ComparisonMode.contentHash => '-c',
    },
    if (rules.direction == SyncDirection.bidirectional) '-u',
    if (mirror && rules.maxDelete >= 1) ...[
      '--delete-delay',
      '--max-delete=${rules.maxDelete}',
    ],
    if (backups) ...[
      '--backup',
      '--backup-dir=${_sq(backupDir)}',
    ],
    if (remote != null)
      remote.port == 22 ? "-e 'ssh'" : '-e ${_sq('ssh -p ${remote.port}')}',
    // Engine-imposed exclusions lead every ruleset filter — rsync is
    // first-match-wins, so nothing downstream can re-admit them (§2.1).
    for (final path in engineSkipPaths) '--exclude=${_sq('/$path')}',
    for (final path in trashSkipPaths) '--exclude=${_sq('/$path')}',
    ...filters,
  ].join(' ');
}

/// The destination side's backup-dir (05 §2.1): the configured
/// `trashPath*` verbatim — rsync resolves a relative value against the
/// destination root, matching §8 rail 5's resolution — else the in-root
/// default stamped with [now] (`rsync-<yyyyMMdd-HHmmss>`).
String _backupDir(SyncSide destinationSide, SyncRuleSet rules, DateTime now) {
  final configured = switch (destinationSide) {
    SyncSide.left => rules.trashPathLeft,
    SyncSide.right => rules.trashPathRight,
  };
  if (configured != null) return configured;
  String two(int n) => n.toString().padLeft(2, '0');
  return '.poltergeist-trash/rsync-${now.year}${two(now.month)}'
      '${two(now.day)}-${two(now.hour)}${two(now.minute)}'
      '${two(now.second)}';
}

/// Configured per-side trash paths that sit INSIDE the root (relative
/// spellings) — the scan excludes them, so the export must too or a
/// Mirror's `--delete-delay` could delete inside the destination's
/// trash (and a relative source-side trash would copy into the
/// transfer). Absolute trash paths live outside the tree by
/// construction and need no filter.
List<String> _trashSkipPaths(SyncRuleSet rules) {
  bool inRoot(String path) =>
      !path.startsWith('/') && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  return {
    for (final path in [rules.trashPathLeft, rules.trashPathRight])
      if (path != null && inRoot(path)) path,
  }.toList();
}

/// The reversed ruleset filters (§2.1's excludeGlobs row): rsync is
/// first-match-wins where the engine's gitignore dialect is
/// last-match-wins, so the engine's evaluation order — user globs, the
/// `.*` hidden filter, app defaults — emits backwards: app defaults
/// first, `.*` between, user globs last. `!` negations become
/// `--include`. [divergent] collects the patterns whose syntax the two
/// dialects genuinely disagree on (character classes, backslash
/// escapes — literal to the engine, live filter syntax to rsync).
({List<String> args, List<String> divergent}) _filtersFor(
  SyncRuleSet rules,
) {
  final args = <String>[];
  final divergent = <String>[];
  void emit(String pattern, {required bool include}) {
    args.add(
      include ? '--include=${_sq(pattern)}' : '--exclude=${_sq(pattern)}',
    );
    if (pattern.contains('[') || pattern.contains(r'\')) {
      divergent.add(pattern);
    }
  }

  // The engine ignores comment/blank glob lines — the export does too.
  for (final raw in SyncIgnoreRules.appDefaults.reversed) {
    emit(raw, include: false);
  }
  if (!rules.includeHidden) emit('.*', include: false);
  for (final raw in rules.excludeGlobs.reversed) {
    var pattern = raw.trim();
    var negated = false;
    if (pattern.startsWith('!')) {
      negated = true;
      pattern = pattern.substring(1);
    } else if (pattern.startsWith(r'\!') || pattern.startsWith(r'\#')) {
      // gitignore's escape — a literal `!`/`#` leading character, which
      // is exactly the plain pattern to emit.
      pattern = pattern.substring(1);
    }
    if (pattern.startsWith('#') || pattern.isEmpty) continue;
    emit(pattern, include: negated);
  }
  return (args: args, divergent: divergent);
}

/// One positional argument: a remote spec as a single quoted word
/// (host bracketed for IPv6 BEFORE the path's allowlist escaping, then
/// the whole `user@host:path` single-quoted — §2.1's two-layer rule),
/// a local path single-quoted as-is. The source renders with a
/// trailing `/` (rsync's contents-of-directory form).
String _renderEndpoint(ResolvedSyncEndpoint endpoint, {required bool source}) {
  return switch (endpoint) {
    ResolvedLocalEndpoint(:final path, :final os) => _sq(
        source ? _sourceTail(path, windows: os == SyncEndpointOs.windows) : path,
      ),
    ResolvedRemoteEndpoint(
      :final user,
      :final host,
      :final path,
    ) =>
      _sq(
        '${user.isEmpty ? '' : '$user@'}'
        '${host.contains(':') ? '[$host]' : host}:'
        '${_escapeRemotePath(source ? _sourceTail(path, windows: false) : path)}',
      ),
  };
}

/// The source's trailing-`/` normalization: strips existing trailing
/// separators (plus `\` on Windows roots) so the emitted path ends in
/// exactly one `/`; an all-separator root collapses to `/`.
String _sourceTail(String path, {required bool windows}) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') ||
          (windows && trimmed.endsWith(r'\')))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty) return '/';
  return trimmed.endsWith('/') ? trimmed : '$trimmed/';
}

/// POSIX single-quoting for one generated argument: `'` → `'\''`.
String _sq(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// The remote-path byte escaping (§2.1): anything outside
/// `[A-Za-z0-9._/+@%=:,-]` takes a backslash so the REMOTE shell's
/// re-parse can never see an operator — `~` included, so a `~/`-relative
/// spelling that slipped past the app's absolute-path rule still
/// arrives inert. Non-ASCII code units pass through verbatim: no shell
/// operator lives above ASCII, and backslash-escaping single UTF-8
/// bytes would corrupt the name once the clipboard text re-encodes.
String _escapeRemotePath(String path) {
  const safe = '._/+@%=:,-';
  final buffer = StringBuffer();
  for (final unit in path.codeUnits) {
    final isAlnum =
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A);
    if (isAlnum || unit > 0x7F || safe.contains(String.fromCharCode(unit))) {
      buffer.writeCharCode(unit);
    } else {
      buffer
        ..write(r'\')
        ..writeCharCode(unit);
    }
  }
  return buffer.toString();
}
