// FileSyncStateStore coverage (M8, 05 §9): the sync_state document's
// round trip, corrupt-file tolerance, and pairId validation.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

void main() {
  late Directory dir;
  late FileSyncStateStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pg-sync-state-');
    store = FileSyncStateStore(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a missing document loads the default state', () async {
    final state = await store.load('a1b2c3d4e5f6a7b8');
    expect(state.lastRunAt, isNull);
    expect(state.caseProbe, isEmpty);
  });

  test('save → load round-trips every field', () async {
    final state = SyncPairState()
      ..lastRunAt = DateTime.utc(2026, 1, 2, 3)
      ..caseSensitiveOverrideLeft = true
      ..mtimeUnreliableRight = true
      ..touchedAt = DateTime.utc(2026, 1, 3);
    state.caseProbe['/root'] = CaseProbeRecord(
      caseSensitive: false,
      volumeIdentity: 'vol-1',
      probedAt: DateTime.utc(2026, 1, 2),
      normalizationInsensitive: true,
    );
    await store.save('a1b2c3d4e5f6a7b8', state);
    final loaded = await store.load('a1b2c3d4e5f6a7b8');
    // Dates decode to local — compare instants, not zones.
    expect(loaded.lastRunAt!.toUtc(), state.lastRunAt);
    expect(loaded.caseSensitiveOverrideLeft, isTrue);
    expect(loaded.caseSensitiveOverrideRight, isNull);
    expect(loaded.mtimeUnreliableRight, isTrue);
    expect(loaded.touchedAt!.toUtc(), state.touchedAt);
    expect(loaded.caseProbe['/root']!.caseSensitive, isFalse);
    expect(loaded.caseProbe['/root']!.volumeIdentity, 'vol-1');
    expect(loaded.caseProbe['/root']!.normalizationInsensitive, isTrue);
  });

  test('a corrupt document loads defaults rather than throwing',
      () async {
    File('${dir.path}/a1b2c3d4e5f6a7b8.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    final loaded = await store.load('a1b2c3d4e5f6a7b8');
    expect(loaded.lastRunAt, isNull);
  });

  test('a non-canonical pairId is rejected', () async {
    expect(
      () => store.load('../escape'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
