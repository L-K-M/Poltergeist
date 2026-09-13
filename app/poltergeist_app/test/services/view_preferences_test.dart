import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  group('ViewLocationKey', () {
    ViewLocationKey location({
      ViewLocationKind kind = ViewLocationKind.remote,
      String identity = 'server-a',
      String path = '/projects',
    }) => ViewLocationKey(kind: kind, identity: identity, canonicalPath: path);

    test('round-trips local and remote locations as structured JSON', () {
      for (final kind in ViewLocationKind.values) {
        final key = location(kind: kind);
        expect(key.toJson(), {
          'kind': kind.name,
          'identity': 'server-a',
          'canonicalPath': '/projects',
        });
        expect(ViewLocationKey.fromJson(jsonDecode(jsonEncode(key))), key);
      }
    });

    test('equality includes kind, identity, and exact canonical path', () {
      final key = location();
      expect(key, location());
      expect(key.hashCode, location().hashCode);
      expect(key, isNot(location(kind: ViewLocationKind.local)));
      expect(key, isNot(location(identity: 'server-b')));
      expect(key, isNot(location(path: '/other')));
      expect(key, isNot(location(path: '/Projects')));
      expect(key, isNot(location(path: '/projects/')));
      expect(key, isNot('/projects'));
    });

    test('does not combine identity and path with an ambiguous delimiter', () {
      expect(
        location(identity: 'a:b', path: 'c'),
        isNot(location(identity: 'a', path: 'b:c')),
      );
    });

    test('constructor rejects empty identity and path', () {
      expect(() => location(identity: ''), throwsArgumentError);
      expect(() => location(path: ''), throwsArgumentError);
    });

    test('unknown JSON fields do not change the key', () {
      expect(
        ViewLocationKey.fromJson({...location().toJson(), 'future': true}),
        location(),
      );
    });

    test('malformed JSON always throws FormatException', () {
      final valid = location().toJson();
      final invalid = <Object?>[
        null,
        false,
        [],
        'location',
        <int, Object?>{1: 'invalid key'},
        {},
        {...valid}..remove('kind'),
        {...valid}..remove('identity'),
        {...valid}..remove('canonicalPath'),
        {...valid, 'kind': 'unknown'},
        {...valid, 'kind': null},
        {...valid, 'identity': 1},
        {...valid, 'identity': ''},
        {...valid, 'canonicalPath': null},
        {...valid, 'canonicalPath': ''},
      ];

      for (final value in invalid) {
        expect(
          () => ViewLocationKey.fromJson(value),
          throwsFormatException,
          reason: '$value',
        );
      }
    });
  });

  group('ViewPreferences', () {
    test('defaults match the view options contract', () {
      final preferences = ViewPreferences();
      expect(preferences.mode, PaneViewMode.details);
      expect(preferences.density, PaneDensity.comfortable);
      expect(preferences.directories, DirectoryGrouping.first);
      expect(preferences.hiddenFiles, HiddenFiles.hidden);
      expect(preferences.dates, FileDateStyle.relative);
      expect(preferences.sortKey, FileSortKey.name);
      expect(preferences.sortDirection, FileSortDirection.ascending);
      expect(preferences.columns, [
        FileSortKey.name,
        FileSortKey.size,
        FileSortKey.modified,
      ]);
      expect(preferences.columnWidths, isEmpty);
    });

    test('persists every option without transient tab state', () {
      final preferences = ViewPreferences(
        mode: PaneViewMode.list,
        density: PaneDensity.compact,
        directories: DirectoryGrouping.mixed,
        hiddenFiles: HiddenFiles.shown,
        dates: FileDateStyle.absolute,
        sortKey: FileSortKey.modified,
        sortDirection: FileSortDirection.descending,
        columns: [FileSortKey.name, FileSortKey.owner, FileSortKey.size],
        columnWidths: {FileSortKey.name: 320, FileSortKey.modified: 150.5},
      );

      expect(preferences.toJson(), {
        'mode': 'list',
        'density': 'compact',
        'directories': 'mixed',
        'hiddenFiles': 'shown',
        'dates': 'absolute',
        'sortKey': 'modified',
        'sortDirection': 'descending',
        'columns': ['name', 'owner', 'size'],
        'columnWidths': {'name': 320.0, 'modified': 150.5},
      });
      final restored = ViewPreferences.fromJson(
        jsonDecode(jsonEncode(preferences)),
      );
      expect(restored, preferences);
      expect(restored.hashCode, preferences.hashCode);
    });

    test('every enum value can round-trip', () {
      final defaults = ViewPreferences();
      final variants = [
        for (final mode in PaneViewMode.values) defaults.copyWith(mode: mode),
        for (final density in PaneDensity.values)
          defaults.copyWith(density: density),
        for (final directories in DirectoryGrouping.values)
          defaults.copyWith(directories: directories),
        for (final hiddenFiles in HiddenFiles.values)
          defaults.copyWith(hiddenFiles: hiddenFiles),
        for (final dates in FileDateStyle.values)
          defaults.copyWith(dates: dates),
        for (final key in FileSortKey.values) defaults.copyWith(sortKey: key),
        for (final direction in FileSortDirection.values)
          defaults.copyWith(sortDirection: direction),
        defaults.copyWith(
          columns: FileSortKey.values,
          columnWidths: {for (final key in FileSortKey.values) key: 100},
        ),
      ];

      for (final preferences in variants) {
        expect(
          ViewPreferences.fromJson(jsonDecode(jsonEncode(preferences))),
          preferences,
        );
      }
    });

    test('absent fields default and unknown extra fields are ignored', () {
      expect(ViewPreferences.fromJson({}), ViewPreferences());
      expect(
        ViewPreferences.fromJson({'density': 'compact', 'future': true}),
        ViewPreferences(density: PaneDensity.compact),
      );
    });

    test('columns and widths are defensively copied and immutable', () {
      final columns = [FileSortKey.name, FileSortKey.size];
      final widths = {FileSortKey.name: 320.0};
      final preferences = ViewPreferences(
        columns: columns,
        columnWidths: widths,
      );

      columns.add(FileSortKey.owner);
      widths[FileSortKey.name] = 10;
      expect(preferences.columns, [FileSortKey.name, FileSortKey.size]);
      expect(preferences.columnWidths, {FileSortKey.name: 320.0});
      expect(
        () => preferences.columns.add(FileSortKey.owner),
        throwsUnsupportedError,
      );
      expect(
        () => preferences.columnWidths[FileSortKey.name] = 10,
        throwsUnsupportedError,
      );

      final json = preferences.toJson();
      (json['columns']! as List).clear();
      (json['columnWidths']! as Map).clear();
      expect(preferences.columns, [FileSortKey.name, FileSortKey.size]);
      expect(preferences.columnWidths, {FileSortKey.name: 320.0});
    });

    test('copyWith replaces supplied fields and preserves the rest', () {
      final original = ViewPreferences(columnWidths: {FileSortKey.name: 320});
      expect(original.copyWith(), original);
      final replacement = original.copyWith(
        mode: PaneViewMode.list,
        density: PaneDensity.compact,
        directories: DirectoryGrouping.mixed,
        hiddenFiles: HiddenFiles.shown,
        dates: FileDateStyle.absolute,
        sortKey: FileSortKey.size,
        sortDirection: FileSortDirection.descending,
        columns: [FileSortKey.name, FileSortKey.kind],
        columnWidths: {},
      );

      expect(
        replacement,
        ViewPreferences.fromJson({
          'mode': 'list',
          'density': 'compact',
          'directories': 'mixed',
          'hiddenFiles': 'shown',
          'dates': 'absolute',
          'sortKey': 'size',
          'sortDirection': 'descending',
          'columns': ['name', 'kind'],
          'columnWidths': <String, Object?>{},
        }),
      );
      expect(original.mode, PaneViewMode.details);
      expect(original.columnWidths, {FileSortKey.name: 320});
      expect(
        original.copyWith(density: PaneDensity.compact),
        ViewPreferences(
          density: PaneDensity.compact,
          columnWidths: {FileSortKey.name: 320},
        ),
      );
    });

    test('equality distinguishes every option and column order', () {
      final original = ViewPreferences();
      final changed = [
        original.copyWith(mode: PaneViewMode.list),
        original.copyWith(density: PaneDensity.compact),
        original.copyWith(directories: DirectoryGrouping.mixed),
        original.copyWith(hiddenFiles: HiddenFiles.shown),
        original.copyWith(dates: FileDateStyle.absolute),
        original.copyWith(sortKey: FileSortKey.size),
        original.copyWith(sortDirection: FileSortDirection.descending),
        original.copyWith(columns: [FileSortKey.name]),
        original.copyWith(
          columns: [FileSortKey.name, FileSortKey.modified, FileSortKey.size],
        ),
        original.copyWith(columnWidths: {FileSortKey.name: 320}),
      ];

      expect(original, ViewPreferences());
      expect(original.hashCode, ViewPreferences().hashCode);
      expect(original, isNot('preferences'));
      for (final preferences in changed) {
        expect(preferences, isNot(original));
      }
    });

    test('width equality and hashing ignore map insertion order', () {
      final first = ViewPreferences(
        columnWidths: {FileSortKey.name: 320, FileSortKey.size: 100},
      );
      final reversed = ViewPreferences(
        columnWidths: {FileSortKey.size: 100, FileSortKey.name: 320},
      );
      expect(first, reversed);
      expect(first.hashCode, reversed.hashCode);
      expect(
        first,
        isNot(first.copyWith(columnWidths: {FileSortKey.name: 100})),
      );
      expect(
        first,
        isNot(
          first.copyWith(
            columnWidths: {FileSortKey.name: 321, FileSortKey.size: 100},
          ),
        ),
      );
    });

    test('constructor and copyWith require unique columns with Name first', () {
      for (final columns in <List<FileSortKey>>[
        [],
        [FileSortKey.size],
        [FileSortKey.size, FileSortKey.name],
        [FileSortKey.name, FileSortKey.name],
        [FileSortKey.name, FileSortKey.size, FileSortKey.size],
      ]) {
        expect(() => ViewPreferences(columns: columns), throwsArgumentError);
        expect(
          () => ViewPreferences().copyWith(columns: columns),
          throwsArgumentError,
        );
      }
    });

    test('constructor requires positive finite widths', () {
      for (final width in [
        0.0,
        -1.0,
        double.nan,
        double.infinity,
        -double.infinity,
      ]) {
        expect(
          () => ViewPreferences(columnWidths: {FileSortKey.name: width}),
          throwsArgumentError,
        );
      }
      expect(
        ViewPreferences(columnWidths: {FileSortKey.name: 0.1}).columnWidths,
        {FileSortKey.name: 0.1},
      );
    });

    test('malformed known JSON fields always throw FormatException', () {
      final invalid = <Object?>[
        null,
        [],
        false,
        'preferences',
        <int, Object?>{1: 'invalid key'},
        for (final field in [
          'mode',
          'density',
          'directories',
          'hiddenFiles',
          'dates',
          'sortKey',
          'sortDirection',
          'columns',
          'columnWidths',
        ]) ...[
          {field: null},
          {field: 'unknown'},
          {field: true},
          {field: 1},
        ],
        {'columns': []},
        {
          'columns': ['size'],
        },
        {
          'columns': ['size', 'name'],
        },
        {
          'columns': ['name', 'name'],
        },
        {
          'columns': ['name', 'size', 'size'],
        },
        {
          'columns': ['name', 'unknown'],
        },
        {
          'columns': ['name', null],
        },
        {'columnWidths': []},
        {
          'columnWidths': {'unknown': 100},
        },
        {
          'columnWidths': <int, Object?>{1: 100},
        },
        for (final width in [
          null,
          '100',
          false,
          0,
          -1,
          double.nan,
          double.infinity,
        ])
          {
            'columnWidths': {'name': width},
          },
      ];

      for (final value in invalid) {
        expect(
          () => ViewPreferences.fromJson(value),
          throwsFormatException,
          reason: '$value',
        );
      }
    });

    test('integer JSON widths become doubles and hidden widths survive', () {
      final preferences = ViewPreferences.fromJson({
        'columns': ['name'],
        'columnWidths': {'name': 320, 'owner': 120},
      });
      expect(preferences.columnWidths, {
        FileSortKey.name: 320.0,
        FileSortKey.owner: 120.0,
      });
      expect(preferences.columnWidths[FileSortKey.name], isA<double>());
    });
  });
}
