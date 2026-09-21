@TestOn('vm')
library;

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  const file = EntrySnapshot(
    kind: EntryKind.file,
    size: 10,
    mtimeSecs: 100,
  );

  EntrySnapshot at(int? secs, {int size = 10, String? sha}) => EntrySnapshot(
    kind: EntryKind.file,
    size: size,
    mtimeSecs: secs,
    sha256: sha,
  );

  group('EntryComparator — sizeAndMtime', () {
    const comparator = EntryComparator();

    test('equal size and mtime compares equal', () {
      expect(comparator.compare(file, file), CompareVerdict.equal);
    });

    test(
      'the 2-second tolerance holds at the boundary: Δ2 equal, Δ3 different',
      () {
        // Whole-second storage (05 §4): stored 100 vs 102 — a real delta
        // of up to ~2.9s — compares equal; stored 100 vs 103 — a real
        // delta of at least ~2.1s — compares different.
        expect(comparator.compare(at(100), at(101)), CompareVerdict.equal);
        expect(comparator.compare(at(100), at(102)), CompareVerdict.equal);
        expect(
          comparator.compare(at(100), at(103)),
          CompareVerdict.rightNewer,
        );
        expect(
          comparator.compare(at(103), at(100)),
          CompareVerdict.leftNewer,
        );
      },
    );

    test('a size difference wins regardless of mtime', () {
      expect(
        comparator.compare(at(100, size: 10), at(100, size: 11)),
        CompareVerdict.sizeDiffers,
      );
      expect(
        comparator.compare(at(100, size: 10), at(99999, size: 11)),
        CompareVerdict.sizeDiffers,
      );
    });

    test('acceptedTimeShifts absorb a ±N skew within tolerance', () {
      const dst = EntryComparator(acceptedTimeShifts: [3600]);

      expect(dst.compare(at(100), at(3700)), CompareVerdict.equal);
      expect(dst.compare(at(100), at(3701)), CompareVerdict.equal);
      expect(dst.compare(at(100), at(3699)), CompareVerdict.equal);
      expect(dst.compare(at(3700), at(100)), CompareVerdict.equal);
      // 3603 lies outside mtimeToleranceSecs of 3600.
      expect(dst.compare(at(100), at(3703)), CompareVerdict.rightNewer);
      // Without the shift the same delta is a real difference.
      expect(
        comparator.compare(at(100), at(3700)),
        CompareVerdict.rightNewer,
      );
    });

    test('missing mtimes degrade explicitly, never silently equal', () {
      expect(
        comparator.compare(at(null), at(null)),
        CompareVerdict.equal,
      );
      expect(
        comparator.compare(at(null), at(100)),
        CompareVerdict.rightNewer,
      );
      expect(
        comparator.compare(at(100), at(null)),
        CompareVerdict.leftNewer,
      );
    });

    test('out-of-range mtimes compare clamped (05 §4)', () {
      // One side out of range -> BOTH clamp. -5 and 0 both become 0.
      expect(comparator.compare(at(-5), at(0)), CompareVerdict.equal);
      // Beyond the uint32 ceiling and AT the ceiling compare equal.
      expect(
        comparator.compare(
          at(maxSftpMtimeSecs + 1),
          at(maxSftpMtimeSecs),
        ),
        CompareVerdict.equal,
      );
      // In-range pairs still use their originals.
      expect(comparator.compare(at(5), at(0)), CompareVerdict.leftNewer);
      // Clamped values keep real ordering evidence.
      expect(comparator.compare(at(-5), at(10)), CompareVerdict.rightNewer);
    });

    test('directories compare by existence only', () {
      const a = EntrySnapshot(kind: EntryKind.directory, mtimeSecs: 1);
      const b = EntrySnapshot(kind: EntryKind.directory, mtimeSecs: 9999);
      expect(comparator.compare(a, b), CompareVerdict.equal);
    });

    test('symlinks never compare contents (v1 skip policy)', () {
      const a = EntrySnapshot(
        kind: EntryKind.symlink,
        symlinkTarget: 'x',
      );
      const b = EntrySnapshot(
        kind: EntryKind.symlink,
        symlinkTarget: 'y',
      );
      expect(comparator.compare(a, b), CompareVerdict.equal);
    });

    test('kind mismatches are typeDiffers', () {
      expect(
        comparator.compare(
          file,
          const EntrySnapshot(kind: EntryKind.directory),
        ),
        CompareVerdict.typeDiffers,
      );
      expect(
        comparator.compare(
          file,
          const EntrySnapshot(kind: EntryKind.symlink),
        ),
        CompareVerdict.typeDiffers,
      );
    });
  });

  group('EntryComparator — sizeOnly', () {
    const comparator = EntryComparator(comparison: ComparisonMode.sizeOnly);

    test('same size compares equal however far the mtimes drift', () {
      expect(
        comparator.compare(at(1), at(999999)),
        CompareVerdict.equal,
      );
    });

    test('different size is the only difference it sees', () {
      expect(
        comparator.compare(at(100, size: 10), at(100, size: 9)),
        CompareVerdict.sizeDiffers,
      );
    });
  });

  group('EntryComparator — contentHash', () {
    const comparator = EntryComparator(
      comparison: ComparisonMode.contentHash,
    );

    test('size still shortcuts before hashing', () {
      expect(
        comparator.compare(
          at(100, size: 10),
          at(100, size: 11),
        ),
        CompareVerdict.sizeDiffers,
      );
    });

    test('equal digests compare equal, different compare contentDiffers',
        () {
      expect(
        comparator.compare(at(100, sha: 'a'), at(100, sha: 'a')),
        CompareVerdict.equal,
      );
      expect(
        comparator.compare(at(100, sha: 'a'), at(100, sha: 'b')),
        CompareVerdict.contentDiffers,
      );
    });

    test('unhashed snapshots are refused, never guessed', () {
      expect(
        () => comparator.compare(at(100), at(100)),
        throwsStateError,
      );
    });
  });

  group('streamedSha256', () {
    late LocalFileSystem fs;
    late Directory root;

    setUp(() async {
      fs = LocalFileSystem();
      root = await Directory.systemTemp.createTemp('poltergeist-hash-');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('hashes content through the RemoteFileSystem seam', () async {
      final a = File('${root.path}/a.bin')..writeAsBytesSync([1, 2, 3]);
      final b = File('${root.path}/b.bin')..writeAsBytesSync([1, 2, 3]);
      final c = File('${root.path}/c.bin')..writeAsBytesSync([1, 2, 4]);

      final ha = await streamedSha256(fs, a.path);
      final hb = await streamedSha256(fs, b.path);
      final hc = await streamedSha256(fs, c.path);

      expect(ha, isNotNull);
      expect(ha, hasLength(64));
      expect(ha, hb);
      expect(ha, isNot(hc));
    });
  });

  group('name hazards (05 §3)', () {
    ScanResult scanOf(Iterable<String> paths) => ScanResult(
      rootPath: '/r',
      entries: {
        for (final p in paths) p: const EntrySnapshot(kind: EntryKind.file),
      },
      warnings: const [],
      caseSensitive: true,
      caseSensitivityBasis: CaseSensitivityBasis.assumption,
    );

    test('nfcKey collapses NFC and NFD spellings', () {
      const nfc = 'café'; // é
      const nfd = 'café'; // cafe + combining acute
      expect(nfc, isNot(nfd));
      expect(nfcKey(nfc), nfcKey(nfd));
    });

    test('normalizationCollisions flags colliding twins', () {
      final hazards = normalizationCollisions(
        scanOf(['caf\u00e9', 'cafe\u0301', 'other.txt']),
      );

      expect(hazards, hasLength(1));
      expect(hazards.single.collidingPaths, hasLength(2));
    });

    test('caseCollisions only fire against insensitive destinations', () {
      final source = scanOf(['Foo.txt', 'foo.txt', 'ok.txt']);

      expect(
        caseCollisions(source, destinationCaseSensitive: true),
        isEmpty,
      );
      final hazards = caseCollisions(
        source,
        destinationCaseSensitive: false,
      );
      expect(hazards, hasLength(1));
      expect(hazards.single.collidingPaths, hasLength(2));
    });

    test('invalidDestinationNames applies the local-safety funnel', () {
      final source = scanOf(['CON.txt', 'dir/trailing.', 'a<b.txt', 'ok']);

      expect(
        invalidDestinationNames(
          source,
          destinationEnforcesLocalNames: false,
        ),
        isEmpty,
      );
      final hazards = invalidDestinationNames(
        source,
        destinationEnforcesLocalNames: true,
      );
      expect(
        hazards.map((h) => h.relativePath),
        containsAll(['CON.txt', 'dir/trailing.', 'a<b.txt']),
      );
      expect(
        hazards.map((h) => h.relativePath),
        isNot(contains('ok')),
      );
    });
  });
}
