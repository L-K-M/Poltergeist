@TestOn('vm')
library;

import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  group('SyncPairState codec (05 §9)', () {
    test('a full state round-trips through JSON text', () {
      final state = SyncPairState(
        lastRunAt: DateTime.utc(2026, 3, 1, 12),
        mtimeUnreliableLeft: true,
        caseSensitiveOverrideRight: false,
        touchedAt: DateTime.utc(2026, 3, 2),
      );
      state.caseProbe['/data'] = CaseProbeRecord(
        caseSensitive: true,
        volumeIdentity: 'vol-9',
        probedAt: DateTime.utc(2026, 3, 1),
        normalizationInsensitive: true,
      );
      state.trashCacheRight = TrashCacheEntry(
        lastListedAt: DateTime.utc(2026, 3, 1, 13),
        runs: [
          TrashCacheRun(
            runId: 'abcd1234-run-1',
            ageBasis: DateTime.utc(2026, 3, 1, 12, 30),
            fileCount: 7,
          ),
          TrashCacheRun(
            runId: 'rsync-20260301-123000',
            ageBasis: DateTime.utc(2026, 3, 1, 12, 45),
            fileCount: null,
          ),
        ],
      );

      final decoded = syncPairStateFromJsonText(
        syncPairStateToJsonText(state),
      );
      expect(decoded.mtimeUnreliableLeft, isTrue);
      expect(decoded.mtimeUnreliableRight, isFalse);
      expect(decoded.caseSensitiveOverrideRight, isFalse);
      expect(decoded.caseSensitiveOverrideLeft, isNull);
      expect(decoded.caseProbe['/data']?.caseSensitive, isTrue);
      expect(decoded.caseProbe['/data']?.volumeIdentity, 'vol-9');
      expect(
        decoded.caseProbe['/data']?.normalizationInsensitive,
        isTrue,
      );
      expect(decoded.trashCacheRight?.runs, hasLength(2));
      expect(decoded.trashCacheRight?.runs[0].fileCount, 7);
      expect(decoded.trashCacheRight?.runs[1].fileCount, isNull);
      expect(decoded.trashCacheLeft, isNull);
      expect(decoded.lastRunAt?.toUtc(), DateTime.utc(2026, 3, 1, 12));
    });

    test('a minimal JSON object decodes to defaults', () {
      final decoded = syncPairStateFromJsonText('{}');
      expect(decoded.mtimeUnreliableLeft, isFalse);
      expect(decoded.caseProbe, isEmpty);
      expect(decoded.trashCacheLeft, isNull);
    });

    test('corrupt text decodes to a fresh state, never throws', () {
      final decoded = syncPairStateFromJsonText('{not json');
      expect(decoded.mtimeUnreliableLeft, isFalse);
      expect(decoded.caseProbe, isEmpty);
    });

    test('a non-object JSON value decodes to a fresh state', () {
      final decoded = syncPairStateFromJsonText('[1,2,3]');
      expect(decoded.touchedAt, isNull);
    });
  });

  group('validateSyncPairId', () {
    test('accepts a sha256-shaped id', () {
      expect(
        () => validateSyncPairId(
          'a' * 64,
        ),
        returnsNormally,
      );
    });

    test('rejects path-shaped keys', () {
      for (final bad in ['', '.', '..', 'a/b', 'a\\b', '../x']) {
        expect(
          () => validateSyncPairId(bad),
          throwsA(isA<ArgumentError>()),
          reason: bad,
        );
      }
    });
  });
}
