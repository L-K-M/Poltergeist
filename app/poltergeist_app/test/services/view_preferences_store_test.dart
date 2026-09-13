import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/view_preferences_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/controlled_settings_writer.dart';

const _settingsKey = 'view.preferences';
const _stateVersion = 1;
const _locationLimit = 500;

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;
  late ViewPreferencesStore preferences;

  ViewPreferencesStore reopened({ControlledSettingsWriter? writer}) =>
      ViewPreferencesStore(
        store: SettingsStore(
          path: settingsFile.path,
          atomicWriter: writer?.call,
        ),
      );

  Future<void> seed(Object? state) => settingsFile.writeAsString(
    jsonEncode({_settingsKey: state, 'unrelated.setting': 'retained'}),
  );

  Future<Map<String, dynamic>> readState() async =>
      (jsonDecode(await settingsFile.readAsString())
              as Map<String, dynamic>)[_settingsKey]
          as Map<String, dynamic>;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_view_preferences_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
    preferences = reopened();
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('fresh locations inherit defaults without creating settings', () async {
    final defaults = ViewPreferences();

    expect(ViewPreferencesStore.locationLimit, _locationLimit);
    expect(await preferences.loadDefaults(), defaults);
    expect(await preferences.load(_local('/fresh')), defaults);
    expect(await preferences.load(_remote('server', '/fresh')), defaults);
    expect(await settingsFile.exists(), isFalse);
  });

  test('global defaults and folder snapshots survive restart', () async {
    final folder = _local('/photos');
    final originalDefaults = ViewPreferences(mode: PaneViewMode.list);
    final folderPreferences = originalDefaults.copyWith(
      density: PaneDensity.compact,
      hiddenFiles: HiddenFiles.shown,
    );
    final replacementDefaults = ViewPreferences(
      dates: FileDateStyle.absolute,
      directories: DirectoryGrouping.mixed,
    );

    await preferences.saveDefaults(originalDefaults);
    await preferences.save(folder, folderPreferences);
    await preferences.saveDefaults(replacementDefaults);

    final restored = reopened();
    expect(await restored.loadDefaults(), replacementDefaults);
    expect(await restored.load(folder), folderPreferences);
    expect(await restored.load(_local('/other')), replacementDefaults);

    await restored.reset(folder);
    expect(await reopened().load(folder), replacementDefaults);
    expect((await readState())['locations'], isEmpty);

    await restored.saveDefaults(originalDefaults);
    expect(await reopened().load(folder), originalDefaults);
  });

  test('location kind, identity, and full path remain isolated', () async {
    final locations = [
      _local('/same', identity: 'shared'),
      _remote('shared', '/same'),
      _remote('other', '/same'),
      _remote('shared', '/different'),
      _local('/same', identity: 'other'),
      // Delimited string keys would collide for these identity/path pairs.
      _remote('server:/folder', '/child'),
      _remote('server', '/folder:/child'),
    ];
    final values = [
      for (final column in FileSortKey.values) ViewPreferences(sortKey: column),
    ];
    expect(
      values.length,
      greaterThanOrEqualTo(locations.length),
      reason: 'Each location needs a distinct preference fixture.',
    );

    for (var index = 0; index < locations.length; index++) {
      await preferences.save(locations[index], values[index]);
    }

    final restored = reopened();
    for (var index = 0; index < locations.length; index++) {
      expect(await restored.load(locations[index]), values[index]);
    }
    expect((await readState())['locations'], hasLength(locations.length));
  });

  test('all view fields, column order, and widths round-trip', () async {
    final value = ViewPreferences(
      mode: PaneViewMode.list,
      density: PaneDensity.compact,
      directories: DirectoryGrouping.mixed,
      hiddenFiles: HiddenFiles.shown,
      dates: FileDateStyle.absolute,
      sortKey: FileSortKey.modified,
      sortDirection: FileSortDirection.descending,
      columns: [FileSortKey.name, FileSortKey.owner, FileSortKey.size],
      columnWidths: {FileSortKey.name: 260, FileSortKey.owner: 120},
    );
    final folder = _remote('server', '/home');

    await preferences.saveDefaults(value);
    await preferences.save(folder, value);

    final restored = reopened();
    expect(await restored.loadDefaults(), value);
    expect(await restored.load(folder), value);
  });

  test(
    'a derived hidden reveal does not alter persisted preferences',
    () async {
      final folder = _local('/private');
      await preferences.save(folder, ViewPreferences());
      final saved = await settingsFile.readAsString();

      final presentation = (await preferences.load(
        folder,
      )).copyWith(hiddenFiles: HiddenFiles.shown);

      expect(presentation.hiddenFiles, HiddenFiles.shown);
      expect((await reopened().load(folder)).hiddenFiles, HiddenFiles.hidden);
      expect(await settingsFile.readAsString(), saved);
    },
  );

  test('durable read recency determines the next LRU eviction', () async {
    final cached = ViewPreferences(mode: PaneViewMode.list);
    await seed(
      _state([
        for (var index = 0; index < _locationLimit; index++)
          _entry(_local('/folder-$index'), cached),
      ]),
    );

    await preferences.load(_local('/folder-0'));
    final restored = reopened();
    await restored.save(_local('/new'), cached);

    final afterInsertion = reopened();
    expect(await afterInsertion.load(_local('/folder-0')), cached);
    expect(await afterInsertion.load(_local('/folder-1')), ViewPreferences());
    expect(await afterInsertion.load(_local('/new')), cached);
    expect((await readState())['locations'], hasLength(_locationLimit));
  });

  test('absent reads neither fill the LRU nor write recency', () async {
    final cached = ViewPreferences(mode: PaneViewMode.list);
    await seed(
      _state([
        for (var index = 0; index < _locationLimit; index++)
          _entry(_local('/folder-$index'), cached),
      ]),
    );
    final writer = ControlledSettingsWriter();
    preferences = reopened(writer: writer);

    for (var index = 0; index <= _locationLimit; index++) {
      expect(
        await preferences.load(_local('/absent-$index')),
        ViewPreferences(),
      );
    }
    expect(writer.writeCount, 0);

    expect(await reopened().load(_local('/folder-0')), cached);
    expect((await readState())['locations'], hasLength(_locationLimit));
  });

  test(
    'loading the most recent location avoids an unnecessary write',
    () async {
      final first = _local('/first');
      final last = _local('/last');
      await seed(_state([_entry(first), _entry(last)]));
      final writer = ControlledSettingsWriter();
      preferences = reopened(writer: writer);

      await preferences.load(last);
      expect(writer.writeCount, 0);

      await preferences.load(first);
      expect(writer.writeCount, 1);
      await preferences.load(first);
      expect(writer.writeCount, 1);
    },
  );

  test('oversized snapshots discard the oldest locations on load', () async {
    final cached = ViewPreferences(mode: PaneViewMode.list);
    await seed(
      _state([
        for (var index = 0; index <= _locationLimit; index++)
          _entry(_local('/folder-$index'), cached),
      ]),
    );

    expect(await preferences.load(_local('/folder-0')), ViewPreferences());
    expect(await preferences.load(_local('/folder-1')), cached);
    expect((await readState())['locations'], hasLength(_locationLimit));
  });

  test(
    'duplicate locations retain the latest preferences and recency',
    () async {
      final duplicate = _local('/duplicate');
      final first = ViewPreferences(mode: PaneViewMode.list);
      final latest = ViewPreferences(density: PaneDensity.compact);
      await seed(
        _state([
          _entry(duplicate, first),
          _entry(_local('/middle')),
          _entry(duplicate, latest),
        ]),
      );

      expect(await preferences.load(duplicate), latest);
      await preferences.save(_local('/new'), first);
      final entries = (await readState())['locations'] as List;
      expect(entries, hasLength(3));
      expect((entries[0] as Map)['location'], _local('/middle').toJson());
      expect((entries[1] as Map)['location'], duplicate.toJson());
      expect((entries[2] as Map)['location'], _local('/new').toJson());
    },
  );

  test('overlapping saves, reset, and defaults preserve call order', () async {
    final first = _local('/first');
    final second = _local('/second');
    final third = _local('/third');
    final cached = ViewPreferences(mode: PaneViewMode.list);
    final defaults = ViewPreferences(density: PaneDensity.compact);
    final writer = ControlledSettingsWriter()..blockWrites = true;
    preferences = reopened(writer: writer);
    addTearDown(writer.releaseWrites);

    final firstSave = preferences.save(first, cached);
    await writer.firstWriteStarted.future;
    final pending = [
      firstSave,
      preferences.save(second, cached),
      preferences.reset(first),
      preferences.saveDefaults(defaults),
      preferences.save(third, defaults),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(writer.writeCount, 1);

    writer.releaseWrites();
    await Future.wait(pending);

    final restored = reopened();
    expect(await restored.load(first), defaults);
    expect(await restored.load(second), cached);
    expect(await restored.load(third), defaults);
    expect(await restored.loadDefaults(), defaults);
    expect((await readState())['locations'], hasLength(2));
  });

  test('write failure propagates, rolls back, and permits retry', () async {
    final folder = _local('/folder');
    final original = ViewPreferences(mode: PaneViewMode.list);
    final replacement = ViewPreferences(density: PaneDensity.compact);
    await seed(_state([_entry(folder, original)]));
    final saved = await settingsFile.readAsString();
    final writer = ControlledSettingsWriter()..failWrites = true;
    preferences = reopened(writer: writer);

    await expectLater(preferences.save(folder, replacement), throwsStateError);
    expect(await preferences.load(folder), original);
    expect(await settingsFile.readAsString(), saved);
    expect(await reopened().load(folder), original);

    writer.failWrites = false;
    await preferences.save(folder, replacement);
    expect(await reopened().load(folder), replacement);
  });

  test('failed recency writes do not influence later eviction', () async {
    final cached = ViewPreferences(mode: PaneViewMode.list);
    await seed(
      _state([
        for (var index = 0; index < _locationLimit; index++)
          _entry(_local('/folder-$index'), cached),
      ]),
    );
    final saved = await settingsFile.readAsString();
    final writer = ControlledSettingsWriter()..failFirstWrite = true;
    preferences = reopened(writer: writer);

    await expectLater(preferences.load(_local('/folder-0')), throwsStateError);
    expect(await settingsFile.readAsString(), saved);
    await preferences.save(_local('/new'), cached);

    final restored = reopened();
    expect(await restored.load(_local('/folder-0')), ViewPreferences());
    expect(await restored.load(_local('/folder-1')), cached);
  });

  test('server removal preserves local and other-server preferences', () async {
    final cached = ViewPreferences(mode: PaneViewMode.list);
    final removed = [_remote('server', '/one'), _remote('server', '/two')];
    final retained = [
      _remote('other', '/one'),
      _local('/one', identity: 'server'),
    ];
    await seed(
      _state([
        for (final location in [...removed, ...retained])
          _entry(location, cached),
      ]),
    );

    await preferences.removeServer('server');

    final restored = reopened();
    for (final location in removed) {
      expect(await restored.load(location), ViewPreferences());
    }
    for (final location in retained) {
      expect(await restored.load(location), cached);
    }
    expect((await readState())['locations'], hasLength(retained.length));
  });

  test('view mutations preserve unrelated settings', () async {
    await seed(_state([]));
    await preferences.saveDefaults(ViewPreferences(mode: PaneViewMode.list));
    await preferences.save(_local('/folder'), ViewPreferences());
    await preferences.reset(_local('/folder'));

    expect(
      await SettingsStore(
        path: settingsFile.path,
      ).get<String>('unrelated.setting'),
      'retained',
    );
  });

  test('unknown fields preserve valid defaults and location records', () async {
    final folder = _local('/folder');
    final cached = ViewPreferences(mode: PaneViewMode.list);
    await seed({
      ..._state([
        {..._entry(folder, cached), 'future': []},
      ]),
      'future': {'enabled': true},
    });

    expect(await preferences.loadDefaults(), ViewPreferences());
    expect(await preferences.load(folder), cached);
  });

  final absentStates = <String, Object?>{
    'null section': null,
    'missing defaults': {'version': _stateVersion, 'locations': []},
    'missing locations': {
      'version': _stateVersion,
      'defaults': ViewPreferences().toJson(),
    },
  };
  for (final absent in absentStates.entries) {
    test('${absent.key} inherits built-in defaults without writing', () async {
      await seed(absent.value);
      final saved = await settingsFile.readAsString();

      expect(await preferences.loadDefaults(), ViewPreferences());
      expect(await preferences.load(_local('/folder')), ViewPreferences());
      expect(await settingsFile.readAsString(), saved);
    });
  }

  final malformedStates = <String, Object?>{
    'non-map': [],
    'missing version': {
      'defaults': ViewPreferences().toJson(),
      'locations': [],
    },
    'unsupported version': {..._state([]), 'version': _stateVersion + 1},
    'non-integer version': {..._state([]), 'version': _stateVersion.toDouble()},
    'null defaults': {..._state([]), 'defaults': null},
    'invalid defaults': {..._state([]), 'defaults': []},
    'null locations': {..._state([]), 'locations': null},
    'invalid locations': {..._state([]), 'locations': {}},
    'invalid entry': _state(['invalid']),
    'missing location': _state([
      {'preferences': ViewPreferences().toJson()},
    ]),
    'invalid location': _state([
      {'location': {}, 'preferences': ViewPreferences().toJson()},
    ]),
    'missing preferences': _state([
      {'location': _local('/folder').toJson()},
    ]),
    'invalid preferences': _state([
      {'location': _local('/folder').toJson(), 'preferences': []},
    ]),
  };
  for (final malformed in malformedStates.entries) {
    test(
      'malformed ${malformed.key} fails without replacing settings',
      () async {
        await seed(malformed.value);
        final saved = await settingsFile.readAsString();

        await expectLater(preferences.loadDefaults(), throwsFormatException);
        await expectLater(
          preferences.load(_local('/folder')),
          throwsFormatException,
        );
        await expectLater(
          preferences.save(_local('/folder'), ViewPreferences()),
          throwsFormatException,
        );
        expect(await settingsFile.readAsString(), saved);
      },
    );
  }
}

ViewLocationKey _local(String path, {String identity = 'volume'}) =>
    ViewLocationKey(
      kind: ViewLocationKind.local,
      identity: identity,
      canonicalPath: path,
    );

ViewLocationKey _remote(String serverId, String path) => ViewLocationKey(
  kind: ViewLocationKind.remote,
  identity: serverId,
  canonicalPath: path,
);

Map<String, Object?> _entry(
  ViewLocationKey location, [
  ViewPreferences? preferences,
]) => {
  'location': location.toJson(),
  'preferences': (preferences ?? ViewPreferences()).toJson(),
};

Map<String, Object?> _state(List<Object?> locations) => {
  'version': _stateVersion,
  'defaults': ViewPreferences().toJson(),
  'locations': locations,
};
