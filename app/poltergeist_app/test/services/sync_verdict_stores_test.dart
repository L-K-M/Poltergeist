// 04 §3.2/§4.2's durable verdict stores over SettingsStore: the pin
// verdicts and decode tripwires must survive restarts and the record
// store's corruption quarantine, and concurrent read-modify-writes must
// not lose each other.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/sync_verdict_stores.dart';

void main() {
  late Directory temp;
  late SettingsStore settings;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('verdict-stores-test');
    settings = SettingsStore(path: '${temp.path}/settings.json');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('SettingsPinVerdictStore', () {
    test('negative pins add, read, remove — and persist across instances',
        () async {
      final store = SettingsPinVerdictStore(store: settings);
      await store.addNegativePin('a.example:22');
      await store.addNegativePin('b.example:22');
      await store.addNegativePin('a.example:22'); // idempotent
      expect(await store.negativePins(),
          {'a.example:22', 'b.example:22'});

      // A fresh instance over the same file sees the durable set.
      final reopened = SettingsPinVerdictStore(store: settings);
      expect(await reopened.negativePins(),
          {'a.example:22', 'b.example:22'});

      await reopened.removeNegativePin('a.example:22');
      expect(await reopened.negativePins(), {'b.example:22'});
    });

    test('kept verdicts record the rejected fingerprint durably', () async {
      final store = SettingsPinVerdictStore(store: settings);
      await store.recordKeptVerdict('a.example:22', 'SHA256:rejected');
      expect(await store.rejectedFingerprintFor('a.example:22'),
          'SHA256:rejected');
      expect(await store.rejectedFingerprintFor('other:22'), isNull);

      final reopened = SettingsPinVerdictStore(store: settings);
      expect(await reopened.rejectedFingerprintFor('a.example:22'),
          'SHA256:rejected');

      // A new fingerprint for the same locator replaces the verdict —
      // the newer key must warn again.
      await reopened.recordKeptVerdict('a.example:22', 'SHA256:newer');
      expect(await reopened.rejectedFingerprintFor('a.example:22'),
          'SHA256:newer');
    });

    test('overlapping mutations serialize without loss', () async {
      final store = SettingsPinVerdictStore(store: settings);
      await Future.wait([
        store.addNegativePin('one:22'),
        store.addNegativePin('two:22'),
        store.recordKeptVerdict('one:22', 'SHA256:x'),
        store.addNegativePin('three:22'),
      ]);
      expect(await store.negativePins(),
          {'one:22', 'two:22', 'three:22'});
      expect(await store.rejectedFingerprintFor('one:22'), 'SHA256:x');
    });
  });

  group('SettingsSyncTripwireStore', () {
    test('tripped ids flag, read, clear — durably', () async {
      final store = SettingsSyncTripwireStore(store: settings);
      await store.trip('bookmark:x');
      await store.trip('bookmark:x'); // idempotent
      await store.trip('hostkey:a:22');
      expect(await store.trippedIds(), {'bookmark:x', 'hostkey:a:22'});

      final reopened = SettingsSyncTripwireStore(store: settings);
      expect(await reopened.trippedIds(), {'bookmark:x', 'hostkey:a:22'});

      await reopened.clear('bookmark:x');
      expect(await reopened.trippedIds(), {'hostkey:a:22'});
    });
  });
}
