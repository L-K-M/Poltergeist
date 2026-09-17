// Contract tests for the 02 §5.2 conflict model's pure decision layer
// (packages/poltergeist_core/lib/src/transfer/conflict_policy.dart):
// the per-direction/per-kind settings matrix, the metadata-only
// disposition function, the keep-both naming scheme, and the
// apply-to-all verb mapping. No I/O — every rule §5.2 states is pinned
// here before the queue integration tests exercise it live.

@Timeout(Duration(minutes: 2))
library;

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

DestinationStat fileStat({int? size, DateTime? modifiedAt}) =>
    DestinationStat(
      type: RemoteFileType.file,
      size: size,
      modifiedAt: modifiedAt,
    );

DestinationStat dirStat({DateTime? modifiedAt}) =>
    DestinationStat(type: RemoteFileType.directory, modifiedAt: modifiedAt);

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);
  final tNewer = t0.add(const Duration(seconds: 10));
  final tInsideTolerance = t0.add(const Duration(seconds: 2));
  final tEdge = t0.add(conflictMtimeTolerance + const Duration(seconds: 1));

  group('resolveTransferConflict — no collision', () {
    test('every verb proceeds when the destination is absent', () {
      for (final verb in ConflictResolution.values) {
        for (final isDir in [true, false]) {
          expect(
            resolveTransferConflict(
              verb: verb,
              sourceIsDirectory: isDir,
              existing: null,
              sourceModifiedAt: t0,
            ),
            isA<ConflictProceed>(),
            reason: '$verb on ${isDir ? 'dir' : 'file'} with no occupant',
          );
        }
      }
    });
  });

  group('resolveTransferConflict — file onto file', () {
    DestinationStat? existing() => fileStat(size: 10, modifiedAt: t0);

    test('replace overwrites in place (no occupant removal)', () {
      final d = resolveTransferConflict(
        verb: ConflictResolution.replace,
        sourceIsDirectory: false,
        existing: existing(),
        sourceModifiedAt: t0,
      );
      expect(d, isA<ConflictReplace>());
      expect((d as ConflictReplace).removesOccupant, isFalse);
    });

    test('replaceIfNewer: newer by more than the 2 s tolerance replaces', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: false,
          existing: existing(),
          sourceModifiedAt: tNewer,
        ),
        isA<ConflictReplace>(),
      );
    });

    test('replaceIfNewer: inside the tolerance window skips', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: false,
          existing: existing(),
          sourceModifiedAt: tInsideTolerance,
        ),
        isA<ConflictSkip>(),
      );
      // Exactly at the boundary is still not newer.
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: false,
          existing: existing(),
          sourceModifiedAt: t0.add(conflictMtimeTolerance),
        ),
        isA<ConflictSkip>(),
      );
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: false,
          existing: existing(),
          sourceModifiedAt: tEdge,
        ),
        isA<ConflictReplace>(),
      );
    });

    test('replaceIfNewer: a missing mtime on either side is not newer', () {
      for (final (src, dst) in [
        (null, t0),
        (tNewer, null),
        (null, null),
      ]) {
        expect(
          resolveTransferConflict(
            verb: ConflictResolution.replaceIfNewer,
            sourceIsDirectory: false,
            existing: fileStat(modifiedAt: dst),
            sourceModifiedAt: src,
          ),
          isA<ConflictSkip>(),
          reason: 'src=$src dst=$dst',
        );
      }
    });

    test('keepBoth, skip, and ask hold their shape', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.keepBoth,
          sourceIsDirectory: false,
          existing: existing(),
        ),
        isA<ConflictKeepBoth>(),
      );
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.skip,
          sourceIsDirectory: false,
          existing: existing(),
        ),
        isA<ConflictSkip>(),
      );
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.ask,
          sourceIsDirectory: false,
          existing: existing(),
        ),
        isA<ConflictAsk>(),
      );
    });

    test('merge on a file source falls back to ask (02 §5.2)', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.merge,
          sourceIsDirectory: false,
          existing: existing(),
        ),
        isA<ConflictAsk>(),
      );
    });
  });

  group('resolveTransferConflict — file onto directory', () {
    DestinationStat? existing() => dirStat(modifiedAt: t0);

    test('replace requires occupant removal (the D15 delete story)', () {
      final d = resolveTransferConflict(
        verb: ConflictResolution.replace,
        sourceIsDirectory: false,
        existing: existing(),
        sourceModifiedAt: t0,
      );
      expect(d, isA<ConflictReplace>());
      expect((d as ConflictReplace).removesOccupant, isTrue);
    });

    test('replaceIfNewer newer removes the occupant; not-newer skips', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: false,
          existing: existing(),
          sourceModifiedAt: tNewer,
        ),
        isA<ConflictReplace>(),
      );
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: false,
          existing: existing(),
          sourceModifiedAt: t0,
        ),
        isA<ConflictSkip>(),
      );
    });

    test('keepBoth numbers past the directory; skip and ask hold', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.keepBoth,
          sourceIsDirectory: false,
          existing: existing(),
        ),
        isA<ConflictKeepBoth>(),
      );
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.skip,
          sourceIsDirectory: false,
          existing: existing(),
        ),
        isA<ConflictSkip>(),
      );
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.ask,
          sourceIsDirectory: false,
          existing: existing(),
        ),
        isA<ConflictAsk>(),
      );
    });
  });

  group('resolveTransferConflict — directory onto directory', () {
    DestinationStat? existing() => dirStat(modifiedAt: t0);

    test('merge recurses (stat-else-mkdir, per-file policy inside)', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.merge,
          sourceIsDirectory: true,
          existing: existing(),
        ),
        isA<ConflictMerge>(),
      );
    });

    test('replace is wholesale — the occupant subtree must be removed', () {
      final d = resolveTransferConflict(
        verb: ConflictResolution.replace,
        sourceIsDirectory: true,
        existing: existing(),
      );
      expect(d, isA<ConflictReplace>());
      expect((d as ConflictReplace).removesOccupant, isTrue);
    });

    test('replaceIfNewer: newer replaces wholesale, not-newer merges', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: true,
          existing: existing(),
          sourceModifiedAt: tNewer,
        ),
        isA<ConflictReplace>(),
      );
      // Equal/unknown/older directory mtimes are never newer — the
      // destructive verb must not fire on an unreliable signal (03 §4.1).
      for (final src in [t0, tInsideTolerance, null]) {
        expect(
          resolveTransferConflict(
            verb: ConflictResolution.replaceIfNewer,
            sourceIsDirectory: true,
            existing: existing(),
            sourceModifiedAt: src,
          ),
          isA<ConflictMerge>(),
          reason: 'src=$src',
        );
      }
      // Missing destination mtime is not newer either.
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.replaceIfNewer,
          sourceIsDirectory: true,
          existing: dirStat(),
          sourceModifiedAt: tNewer,
        ),
        isA<ConflictMerge>(),
      );
    });

    test('keepBoth, skip, ask hold their shape', () {
      for (final (verb, type) in [
        (ConflictResolution.keepBoth, ConflictKeepBoth),
        (ConflictResolution.skip, ConflictSkip),
        (ConflictResolution.ask, ConflictAsk),
      ]) {
        expect(
          resolveTransferConflict(
            verb: verb,
            sourceIsDirectory: true,
            existing: existing(),
          ),
          predicate((d) => d.runtimeType == type, 'a $type'),
        );
      }
    });
  });

  group('resolveTransferConflict — directory onto non-directory', () {
    DestinationStat? existing() => fileStat(size: 3, modifiedAt: t0);

    test('merge falls back to ask — it cannot recurse into a file '
        '(03 §4.1)', () {
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.merge,
          sourceIsDirectory: true,
          existing: existing(),
        ),
        isA<ConflictAsk>(),
      );
    });

    test('replace requires occupant removal; skip/keepBoth/ask hold', () {
      final d = resolveTransferConflict(
        verb: ConflictResolution.replace,
        sourceIsDirectory: true,
        existing: existing(),
      );
      expect(d, isA<ConflictReplace>());
      expect((d as ConflictReplace).removesOccupant, isTrue);
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.skip,
          sourceIsDirectory: true,
          existing: existing(),
        ),
        isA<ConflictSkip>(),
      );
      expect(
        resolveTransferConflict(
          verb: ConflictResolution.keepBoth,
          sourceIsDirectory: true,
          existing: existing(),
        ),
        isA<ConflictKeepBoth>(),
      );
    });
  });

  group('numberedConflictName — the keep-both scheme (02 §5.2)', () {
    test('inserts the counter before the last-dot extension', () {
      expect(
        numberedConflictName('report.pdf', 2, isDirectory: false),
        'report (2).pdf',
      );
      expect(
        numberedConflictName('archive.tar.gz', 3, isDirectory: false),
        'archive.tar (3).gz',
      );
    });

    test('strips an existing trailing (n) so retries never stack', () {
      expect(
        numberedConflictName('report (2).pdf', 3, isDirectory: false),
        'report (3).pdf',
      );
      expect(
        numberedConflictName('report (2).pdf', 2, isDirectory: false),
        'report (2).pdf',
      );
    });

    test('a leading-dot name counts as extensionless', () {
      expect(
        numberedConflictName('.env', 2, isDirectory: false),
        '.env (2)',
      );
      expect(
        numberedConflictName('README', 4, isDirectory: false),
        'README (4)',
      );
    });

    test('directories never split a trailing dot name', () {
      expect(
        numberedConflictName('dir', 2, isDirectory: true),
        'dir (2)',
      );
      expect(
        numberedConflictName('dir (2)', 5, isDirectory: true),
        'dir (5)',
      );
      expect(
        numberedConflictName('weird.name', 2, isDirectory: true),
        'weird.name (2)',
      );
    });
  });

  group('taskScopePolicy — apply-to-all analogs (02 §5.2)', () {
    test('every non-merge verb maps identically per kind', () {
      for (final verb in [
        ConflictResolution.replace,
        ConflictResolution.replaceIfNewer,
        ConflictResolution.keepBoth,
        ConflictResolution.skip,
      ]) {
        final policy = taskScopePolicy(verb);
        expect(policy.files, verb, reason: verb.name);
        expect(policy.folders, verb, reason: verb.name);
      }
    });

    test('merge keeps folders merging and overwrites colliding files', () {
      final policy = taskScopePolicy(ConflictResolution.merge);
      expect(policy.folders, ConflictResolution.merge);
      expect(policy.files, ConflictResolution.replace);
    });
  });

  group('ConflictPolicy — the per-direction matrix (02 §5.2)', () {
    test('defaults are ask everywhere', () {
      final policy = ConflictPolicy();
      for (final field in [
        policy.uploadFiles,
        policy.uploadFolders,
        policy.downloadFiles,
        policy.downloadFolders,
        policy.localFiles,
        policy.localFolders,
        policy.remoteToRemoteFiles,
        policy.remoteToRemoteFolders,
      ]) {
        expect(field, ConflictResolution.ask);
      }
    });

    test('every direction maps to exactly one bucket pair', () {
      final policy = ConflictPolicy(
        uploadFiles: ConflictResolution.replace,
        uploadFolders: ConflictResolution.merge,
        downloadFiles: ConflictResolution.skip,
        downloadFolders: ConflictResolution.keepBoth,
        localFiles: ConflictResolution.keepBoth,
        localFolders: ConflictResolution.skip,
        remoteToRemoteFiles: ConflictResolution.replaceIfNewer,
        remoteToRemoteFolders: ConflictResolution.merge,
      );
      const local = LocalFsLocation();
      const s1 = ServerFsLocation('s1');
      const s2 = ServerFsLocation('s2');

      final upload = policy.policyFor(local, s1);
      expect(upload.files, ConflictResolution.replace);
      expect(upload.folders, ConflictResolution.merge);

      final download = policy.policyFor(s1, local);
      expect(download.files, ConflictResolution.skip);
      expect(download.folders, ConflictResolution.keepBoth);

      final localPair = policy.policyFor(local, local);
      expect(localPair.files, ConflictResolution.keepBoth);
      expect(localPair.folders, ConflictResolution.skip);

      // Same-server and cross-server remote→remote share one bucket.
      for (final (src, dst) in [(s1, s2), (s1, s1)]) {
        final rr = policy.policyFor(src, dst);
        expect(rr.files, ConflictResolution.replaceIfNewer);
        expect(rr.folders, ConflictResolution.merge);
      }
    });

    test('merge in a file field normalizes to ask', () {
      final policy = ConflictPolicy(
        uploadFiles: ConflictResolution.merge,
        downloadFiles: ConflictResolution.merge,
        localFiles: ConflictResolution.merge,
        remoteToRemoteFiles: ConflictResolution.merge,
      );
      expect(policy.uploadFiles, ConflictResolution.ask);
      expect(policy.downloadFiles, ConflictResolution.ask);
      expect(policy.localFiles, ConflictResolution.ask);
      expect(policy.remoteToRemoteFiles, ConflictResolution.ask);
      // Folders keep merge.
      final folders = ConflictPolicy(
        uploadFolders: ConflictResolution.merge,
      );
      expect(folders.uploadFolders, ConflictResolution.merge);
    });

    test('JSON round-trips; invalid and missing values decode to ask', () {
      final policy = ConflictPolicy(
        uploadFiles: ConflictResolution.replace,
        uploadFolders: ConflictResolution.merge,
        downloadFolders: ConflictResolution.skip,
        remoteToRemoteFiles: ConflictResolution.keepBoth,
      );
      final decoded = ConflictPolicy.fromJson(policy.toJson());
      expect(decoded.uploadFiles, ConflictResolution.replace);
      expect(decoded.uploadFolders, ConflictResolution.merge);
      expect(decoded.downloadFolders, ConflictResolution.skip);
      expect(decoded.remoteToRemoteFiles, ConflictResolution.keepBoth);
      expect(decoded.downloadFiles, ConflictResolution.ask);

      // A hand-edited merge in a file field falls back to ask, and
      // unknown strings never crash the load (02 §5.2's settings rule).
      final handEdited = ConflictPolicy.fromJson({
        'uploadFiles': 'merge',
        'downloadFiles': 'bogus',
        'localFolders': 'merge',
      });
      expect(handEdited.uploadFiles, ConflictResolution.ask);
      expect(handEdited.downloadFiles, ConflictResolution.ask);
      expect(handEdited.localFolders, ConflictResolution.merge);

      expect(ConflictPolicy.fromJson(const {}).uploadFiles,
          ConflictResolution.ask);
    });
  });
}
