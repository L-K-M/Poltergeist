import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/settings_store.dart';

import 'support/controlled_settings_writer.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_settings_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('creates the settings parent directory', () async {
    settingsFile = File(
      p.join(temporaryDirectory.path, 'nested', 'settings.json'),
    );
    final store = SettingsStore(path: settingsFile.path);

    await store.get<Object>('missing');

    expect(await settingsFile.parent.exists(), isTrue);
  });

  test('writes the complete settings snapshot atomically', () async {
    final store = SettingsStore(path: settingsFile.path);

    await store.set('window.width', 1180.0);
    await store.set('window.height', 760.0);

    expect(jsonDecode(await settingsFile.readAsString()), {
      'window.width': 1180.0,
      'window.height': 760.0,
    });
  });

  test('serializes overlapping writes', () async {
    final writer = ControlledSettingsWriter()..blockWrites = true;
    final store = SettingsStore(
      path: settingsFile.path,
      atomicWriter: writer.call,
    );

    final first = store.set('first', 1);
    await writer.firstWriteStarted.future;
    final second = store.set('second', 2);
    await Future<void>.delayed(Duration.zero);

    expect(writer.writeCount, 1);

    writer.releaseWrites();
    await Future.wait([first, second]);

    expect(jsonDecode(await settingsFile.readAsString()), {
      'first': 1,
      'second': 2,
    });
  });

  test('update sees the value the writes queued before it left', () async {
    final writer = ControlledSettingsWriter()..blockWrites = true;
    final store = SettingsStore(
      path: settingsFile.path,
      atomicWriter: writer.call,
    );

    final first = store.set('ids', ['a']);
    await writer.firstWriteStarted.future;
    Object? seen;
    final second = store.update('ids', (current) {
      seen = current;
      return [...current! as List, 'b'];
    });
    await Future<void>.delayed(Duration.zero);
    expect(seen, isNull, reason: 'the transform waits for its turn');

    writer.releaseWrites();
    await first;
    expect(await second, ['a', 'b']);
    expect(seen, ['a']);
    expect(jsonDecode(await settingsFile.readAsString()), {
      'ids': ['a', 'b'],
    });
  });

  test('update fails, writing nothing, while the load fails', () async {
    await settingsFile.writeAsBytes([0xff]);
    final store = SettingsStore(path: settingsFile.path, onError: (_, _) {});
    var transformed = false;

    await expectLater(
      store.update('ids', (_) {
        transformed = true;
        return ['a'];
      }),
      throwsA(isA<FileSystemException>()),
    );

    expect(transformed, isFalse);
    expect(await settingsFile.readAsBytes(), [0xff]);
  });

  test('quarantines corrupt settings and starts empty', () async {
    await settingsFile.writeAsString('{broken');
    final errors = <Object>[];
    final store = SettingsStore(
      path: settingsFile.path,
      now: () => DateTime.utc(2026, 9, 2, 12),
      onError: (error, _) => errors.add(error),
    );

    expect(await store.get<double>('missing'), isNull);

    final quarantined = File(
      '${settingsFile.path}.corrupt-20260902T120000000Z',
    );
    expect(await settingsFile.exists(), isFalse);
    expect(await quarantined.readAsString(), '{broken');
    expect(errors, [isA<FormatException>()]);
  });

  test('reports a transient load failure and retries', () async {
    await settingsFile.writeAsBytes([0xff]);
    final errors = <Object>[];
    final store = SettingsStore(
      path: settingsFile.path,
      onError: (error, _) => errors.add(error),
    );

    Object? loadFailure;
    try {
      await store.get<int>('density');
    } catch (error) {
      loadFailure = error;
    }

    expect(loadFailure, isNotNull);

    await settingsFile.writeAsString('{"density":2}');

    expect(await store.get<int>('density'), 2);
    expect(errors, [same(loadFailure)]);
  });

  test('reports both corrupt input and a failed quarantine', () async {
    await settingsFile.writeAsString('{broken');
    final now = DateTime.utc(2026, 9, 2, 12);
    final quarantinePath = '${settingsFile.path}.corrupt-20260902T120000000Z';
    await Directory(quarantinePath).create();
    final errors = <Object>[];
    final store = SettingsStore(
      path: settingsFile.path,
      now: () => now,
      onError: (error, _) => errors.add(error),
    );

    expect(await store.get<double>('missing'), isNull);

    expect(errors, [isA<FileSystemException>(), isA<FormatException>()]);
  });

  test('reverts failed writes for the caller to report', () async {
    final writer = ControlledSettingsWriter()..failWrites = true;
    final errors = <Object>[];
    final store = SettingsStore(
      path: settingsFile.path,
      atomicWriter: writer.call,
      onError: (error, _) => errors.add(error),
    );

    await expectLater(store.set('density', 2), throwsA(isA<StateError>()));

    expect(await store.get<int>('density'), isNull);
    expect(await settingsFile.exists(), isFalse);
    expect(errors, isEmpty);
  });

  test('does not reintroduce a rolled-back value in a queued write', () async {
    final writer = ControlledSettingsWriter()
      ..blockWrites = true
      ..failFirstWrite = true;
    final store = SettingsStore(
      path: settingsFile.path,
      atomicWriter: writer.call,
    );

    final first = store.set('first', 1);
    await writer.firstWriteStarted.future;
    final second = store.set('second', 2);
    writer.releaseWrites();

    await expectLater(first, throwsA(isA<StateError>()));
    await second;

    expect(jsonDecode(await settingsFile.readAsString()), {'second': 2});
  });
}
