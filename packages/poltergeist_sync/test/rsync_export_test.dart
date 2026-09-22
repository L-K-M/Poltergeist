// The rsync exporter's golden contract (05 §2.1): every listed plan
// shape pins its exact emitted text — the notes block, the commented
// dry-run line, the live line — so a "harmless" flag or quoting change
// cannot drift the clipboard's safety surface. Regenerate with
// `UPDATE_GOLDENS=1 dart test test/rsync_export_test.dart`, then diff.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

/// One pinned timestamp for every fixture — `--backup-dir` renders it.
final _now = DateTime(2026, 9, 22, 15, 4, 7);

const _localLeft = ResolvedLocalEndpoint(
  path: '/home/me/site',
  os: SyncEndpointOs.posix,
);
const _localRight = ResolvedLocalEndpoint(
  path: '/srv/site',
  os: SyncEndpointOs.posix,
);
const _localPair = ResolvedSyncEndpoints(
  left: _localLeft,
  right: _localRight,
);
const _remote = ResolvedRemoteEndpoint(
  user: 'deploy',
  host: 'example.com',
  path: '/var/www/site',
);
const _localRemote = ResolvedSyncEndpoints(
  left: _localLeft,
  right: _remote,
);

typedef _Fixture = ({
  String name,
  ResolvedSyncEndpoints endpoints,
  SyncRuleSet rules,
  int manualOverrides,
  List<String> engineSkipPaths,
});

_Fixture _f(
  String name, {
  ResolvedSyncEndpoints endpoints = _localPair,
  SyncRuleSet rules = const SyncRuleSet(),
  int manualOverrides = 0,
  List<String> engineSkipPaths = const [],
}) => (
  name: name,
  endpoints: endpoints,
  rules: rules,
  manualOverrides: manualOverrides,
  engineSkipPaths: engineSkipPaths,
);

final _fixtures = <_Fixture>[
  // The three modes (05 §6's direction × deletions projection).
  _f('update_local'),
  _f(
    'mirror_trash',
    rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
  ),
  _f(
    'additive_two_way',
    rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
  ),
  _f(
    'right_to_left',
    rules: const SyncRuleSet(direction: SyncDirection.rightToLeft),
  ),
  _f(
    'empty_excludes_no_backup',
    rules: const SyncRuleSet(backups: BackupPolicy.none),
  ),
  // Deletion-policy variants (05 §2.1's permanent rows).
  _f(
    'mirror_permanent_none',
    rules: const SyncRuleSet(
      deletions: DeletionPolicy.permanent,
      backups: BackupPolicy.none,
    ),
  ),
  _f(
    'mirror_permanent_trash',
    rules: const SyncRuleSet(deletions: DeletionPolicy.permanent),
  ),
  _f(
    'mirror_trash_only',
    rules: const SyncRuleSet(
      deletions: DeletionPolicy.trash,
      backups: BackupPolicy.none,
    ),
  ),
  _f(
    'mirror_maxdelete_12',
    rules: const SyncRuleSet(
      deletions: DeletionPolicy.trash,
      maxDelete: 12,
    ),
  ),
  // Connection shapes — the interim D6 ruling's flagged notes.
  _f('remote_plain', endpoints: _localRemote),
  _f(
    'remote_port',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        port: 2222,
        path: '/var/www/site',
      ),
    ),
  ),
  _f(
    'remote_identity_file',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: '/var/www/site',
        connectionShape: {SyncConnectionFlag.identityFile},
      ),
    ),
  ),
  _f(
    'remote_jump_host',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: '/var/www/site',
        connectionShape: {SyncConnectionFlag.jumpHost},
      ),
    ),
  ),
  _f(
    'remote_both_flags',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: '/var/www/site',
        connectionShape: {
          SyncConnectionFlag.identityFile,
          SyncConnectionFlag.jumpHost,
        },
      ),
    ),
  ),
  _f(
    'remote_source',
    endpoints: const ResolvedSyncEndpoints(
      left: _remote,
      right: _localRight,
    ),
  ),
  _f(
    'remote_both_sides',
    endpoints: const ResolvedSyncEndpoints(
      left: _remote,
      right: ResolvedRemoteEndpoint(
        user: 'cdn',
        host: 'mirror.example.com',
        path: '/srv/mirror',
      ),
    ),
  ),
  // Path-shape pins: space, injection bytes, embedded quote, IPv6,
  // Unicode, Windows-local.
  _f(
    'remote_space_path',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: '/var/www/my site',
      ),
    ),
  ),
  _f(
    'remote_injection_path',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: r'/var/www/a;$(rm -rf b)|tee',
      ),
    ),
  ),
  _f(
    'remote_quoted_path',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: "/var/www/it's",
      ),
    ),
  ),
  _f(
    'remote_ipv6',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: '2001:db8::1',
        path: '/var/www/site',
      ),
    ),
  ),
  _f(
    'unicode_paths',
    endpoints: const ResolvedSyncEndpoints(
      left: ResolvedLocalEndpoint(
        path: '/home/me/bibliothèque',
        os: SyncEndpointOs.posix,
      ),
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: '/srv/日本語',
      ),
    ),
  ),
  _f(
    'local_windows',
    endpoints: const ResolvedSyncEndpoints(
      left: ResolvedLocalEndpoint(
        path: r'C:\Users\me\site',
        os: SyncEndpointOs.windows,
      ),
      right: _localRight,
    ),
  ),
  _f(
    'local_quoted_path',
    endpoints: const ResolvedSyncEndpoints(
      left: ResolvedLocalEndpoint(
        path: "/home/me/it's here",
        os: SyncEndpointOs.posix,
      ),
      right: _localRight,
    ),
  ),
  // Hidden-file filter + the Windows-attribute approximation note.
  _f(
    'hidden_excluded',
    rules: const SyncRuleSet(includeHidden: false),
  ),
  _f(
    'hidden_excluded_windows_remote',
    endpoints: const ResolvedSyncEndpoints(
      left: _localLeft,
      right: ResolvedRemoteEndpoint(
        user: 'deploy',
        host: 'example.com',
        path: '/var/www/site',
        os: SyncEndpointOs.windows,
      ),
    ),
    rules: const SyncRuleSet(includeHidden: false),
  ),
  // Trash/backup shapes.
  _f(
    'trash_absolute_path',
    rules: const SyncRuleSet(
      deletions: DeletionPolicy.trash,
      trashPathRight: '/var/trash/site',
    ),
  ),
  _f(
    'trash_relative_path',
    rules: const SyncRuleSet(
      deletions: DeletionPolicy.trash,
      trashPathRight: 'tmp/trash',
    ),
  ),
  _f(
    'additive_trash_paths',
    rules: const SyncRuleSet(
      direction: SyncDirection.bidirectional,
      trashPathLeft: 'tmp/trash-left',
      trashPathRight: '/srv/trash-right',
    ),
  ),
  // Overrides, engine skips, filters.
  _f('manual_overrides', manualOverrides: 3),
  _f(
    'engine_skips',
    engineSkipPaths: const ['locked', 'tools/link'],
  ),
  _f(
    'exclude_globs',
    rules: const SyncRuleSet(
      excludeGlobs: ['*.log', '!keep.log', 'build/'],
    ),
  ),
  _f(
    'exclude_glob_divergence',
    rules: const SyncRuleSet(excludeGlobs: ['releases[0-9]']),
  ),
  // Comparison-mode mapping.
  _f(
    'comparison_content_hash',
    rules: const SyncRuleSet(comparison: ComparisonMode.contentHash),
  ),
  _f(
    'comparison_size_only',
    rules: const SyncRuleSet(comparison: ComparisonMode.sizeOnly),
  ),
  _f(
    'preserve_mtime_off',
    rules: const SyncRuleSet(preserveMtime: false),
  ),
  _f(
    'mtime_tolerance_30',
    rules: const SyncRuleSet(mtimeToleranceSecs: 30),
  ),
  _f(
    'accepted_time_shifts',
    rules: const SyncRuleSet(acceptedTimeShifts: [3600, 7200]),
  ),
  _f(
    'single_stream',
    rules: const SyncRuleSet(transferConcurrency: 1),
  ),
];

Future<Directory> _goldenDir() async {
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:poltergeist_sync/poltergeist_sync.dart'),
  );
  final dir = Directory.fromUri(libUri!.resolve('../test/goldens/rsync/'));
  await dir.create(recursive: true);
  return dir;
}

void main() {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';

  group('goldens (05 §2.1)', () {
    for (final fixture in _fixtures) {
      test(fixture.name, () async {
        final dir = await _goldenDir();
        final file = File('${dir.path}/${fixture.name}.golden');
        final actual = buildRsyncCommand(
          fixture.endpoints,
          fixture.rules,
          manualOverrides: fixture.manualOverrides,
          engineSkipPaths: fixture.engineSkipPaths,
          now: _now,
        );
        if (update) {
          file.writeAsStringSync(actual);
          return;
        }
        expect(
          file.existsSync(),
          isTrue,
          reason:
              'missing golden ${file.path} — regenerate with '
              'UPDATE_GOLDENS=1',
        );
        // The exporter always emits LF; a Windows checkout may hand
        // the file back with CRLF — normalize before comparing.
        expect(actual, file.readAsStringSync().replaceAll('\r\n', '\n'));
      });
    }
  });

  group('verbatim contract details', () {
    test('notes precede commands; dry-run comments; live line bare', () {
      final out = buildRsyncCommand(
        _localRemote,
        const SyncRuleSet(),
        engineSkipPaths: const [],
        now: _now,
      );
      final lines = out.split('\n');
      final lastNote = lines.lastIndexWhere((l) => l.startsWith('# note:'));
      final firstCommand = lines.indexWhere(
        (l) => l.startsWith('# Preview first'),
      );
      expect(lastNote, lessThan(firstCommand));
      expect(
        lines[firstCommand],
        startsWith(
          "# Preview first (matches Poltergeist's plan):  rsync -n -i ",
        ),
      );
      expect(lines[firstCommand + 1], startsWith('rsync '));
      expect(out.endsWith('\n'), isTrue);
    });

    test('never emits the flags §2.1/§11 rule out', () {
      // --delete-excluded would let a Mirror delete inside the in-root
      // trash (the §11 mirror-protection invariant); -s/--protect-args
      // is unsupported on the peers §2 names; --ignore-errors would
      // re-admit deletions after I/O failures the executor gates on.
      for (final fixture in _fixtures) {
        final out = buildRsyncCommand(
          fixture.endpoints,
          fixture.rules,
          manualOverrides: fixture.manualOverrides,
          engineSkipPaths: fixture.engineSkipPaths,
          now: _now,
        );
        for (final banned in ['--delete-excluded', '--ignore-errors']) {
          expect(
            out,
            isNot(contains(banned)),
            reason: '${fixture.name} emitted $banned',
          );
        }
        final tokens = out.split(RegExp(r'\s+'));
        for (final banned in ['-s', '--protect-args']) {
          expect(
            tokens,
            isNot(contains(banned)),
            reason: '${fixture.name} emitted $banned',
          );
        }
      }
    });

    test('both-remote emits no rsync line at all', () {
      final out = buildRsyncCommand(
        const ResolvedSyncEndpoints(
          left: _remote,
          right: ResolvedRemoteEndpoint(
            user: 'cdn',
            host: 'mirror.example.com',
            path: '/srv/mirror',
          ),
        ),
        const SyncRuleSet(),
        engineSkipPaths: const [],
        now: _now,
      );
      expect(out, isNot(contains('rsync -')));
      expect(out, isNot(startsWith('rsync')));
      expect(out, contains('no runnable command is emitted'));
    });

    test('engine skip paths lead every ruleset filter', () {
      final out = buildRsyncCommand(
        _localPair,
        const SyncRuleSet(excludeGlobs: ['!allowed']),
        engineSkipPaths: const ['locked'],
        now: _now,
      );
      final skipAt = out.indexOf("--exclude='/locked'");
      final defaultAt = out.indexOf("--exclude='*.poltergeist-*'");
      final includeAt = out.indexOf("--include='allowed'");
      expect(skipAt, greaterThanOrEqualTo(0));
      expect(skipAt, lessThan(defaultAt));
      expect(skipAt, lessThan(includeAt));
      // The anchored form — '/locked' — can only match the transfer
      // root's entry, never a same-named directory deeper in the tree.
      expect(out, contains("--exclude='/locked'"));
    });

    test('maxDelete clamps above zero — a 0 can never reach the flags', () {
      // SyncRuleSet's constructor clamps maxDelete < 1 to 1, so the
      // version-dependent --max-delete=0 is unconstructible; the
      // exporter still carries §2.1's 0-branch as the contract's
      // belt-and-suspenders (a golden cannot pin an unreachable input).
      expect(
        const SyncRuleSet(
          deletions: DeletionPolicy.trash,
          maxDelete: 0,
        ).maxDelete,
        1,
      );
    });

    test('deterministic output for identical inputs', () {
      String render() => buildRsyncCommand(
        _localRemote,
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        manualOverrides: 1,
        engineSkipPaths: const ['a', 'b'],
        now: _now,
      );
      expect(render(), render());
    });
  });

  group('rsyncEngineSkipPaths', () {
    SyncPlan plan({List<ScanWarning> warnings = const [], List<SyncItem> items = const []}) =>
        SyncPlan(
          pair: SyncPair(
            id: 'p',
            name: 'p',
            left: const LocalEndpoint('/l'),
            right: const LocalEndpoint('/r'),
            rules: const SyncRuleSet(),
          ),
          scannedAt: _now,
          items: items,
          warnings: warnings,
          totals: const PlanTotals(
            counts: {},
            bytes: {},
            replacedFiles: 0,
            replacedBytes: 0,
          ),
        );

    test('empty plan yields no skip paths', () {
      expect(rsyncEngineSkipPaths(plan()), isEmpty);
    });

    test('listing failures and symlinks, deduped under their roots', () {
      final result = rsyncEngineSkipPaths(
        plan(
          warnings: const [
            ScanWarning(
              relativePath: 'locked',
              side: SyncSide.left,
              message: 'denied',
              kind: ScanWarningKind.listingFailure,
            ),
          ],
          items: [
            // Under the failed subtree — folds into its root.
            SyncItem(
              relativePath: 'locked/inner.txt',
              left: const EntrySnapshot(kind: EntryKind.file),
              right: null,
              suggested: SyncActionType.skip,
              effective: SyncActionType.skip,
              reason: SyncReason.scanError,
            ),
            SyncItem(
              relativePath: 'tools/link',
              left: const EntrySnapshot(kind: EntryKind.symlink),
              right: null,
              suggested: SyncActionType.skip,
              effective: SyncActionType.skip,
              reason: SyncReason.excluded,
            ),
            // An informational warning carries no exclusion.
          ],
        ),
      );
      expect(result, ['locked', 'tools/link']);
    });
  });
}
