import 'dart:math';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  test('natural names compare every digit run without integer overflow', () {
    final huge = '9' * 100;
    final larger = '1${'0' * 100}';
    expect(
      _names(
        sortFileEntries([
          _file('file$larger'),
          _file('file10'),
          _file('file$huge'),
          _file('file9part10'),
          _file('file9part2'),
          _file('file9'),
        ]),
      ),
      [
        'file9',
        'file9part2',
        'file9part10',
        'file10',
        'file$huge',
        'file$larger',
      ],
    );
  });

  test('equal numbers defer spelling ties until after the entire suffix', () {
    expect(
      _names(
        sortFileEntries([
          _file('file1b'),
          _file('file01a'),
          _file('file1a'),
          _file('file0'),
          _file('file00'),
          _file('file'),
        ]),
      ),
      ['file', 'file0', 'file00', 'file01a', 'file1a', 'file1b'],
    );
  });

  test('case folding precedes case-sensitive ties and preserves accents', () {
    expect(
      _names(
        sortFileEntries([
          _file('b'),
          _file('á'),
          _file('a'),
          _file('A'),
          _file('FILE10'),
          _file('file2'),
        ]),
      ),
      ['A', 'a', 'b', 'file2', 'FILE10', 'á'],
    );

    // Final sigma and long s distinguish Unicode folding from lowercasing.
    expect(
      _names(
        sortFileEntries([_file('σa'), _file('ςz'), _file('sz'), _file('ſa')]),
      ),
      ['ſa', 'sz', 'σa', 'ςz'],
    );
  });

  test('punctuation, Unicode digits and empty names use literal ordering', () {
    expect(
      _names(
        sortFileEntries([
          _file('a1'),
          _file('a-2'),
          _file('a'),
          _file(''),
          _file('a١'),
          _file('a２'),
          _file('a.2'),
        ]),
      ),
      ['', 'a', 'a-2', 'a.2', 'a1', 'a١', 'a２'],
    );
  });

  test('directories stay first for every column and direction', () {
    final directory = _file('z', type: RemoteFileType.directory);
    final file = _file('a', size: 999);
    for (final key in FileSortKey.values) {
      for (final direction in FileSortDirection.values) {
        expect(
          sortFileEntries([file, directory], key: key, direction: direction),
          [directory, file],
          reason: '$key $direction',
        );
      }
    }
  });

  test('mixed grouping obeys the selected column including links', () {
    final directory = _file('z', type: RemoteFileType.directory);
    final link = _file('a', type: RemoteFileType.symbolicLink);
    final file = _file('b');
    expect(sortFileEntries([link, directory, file]), [directory, link, file]);
    expect(
      sortFileEntries([
        directory,
        file,
        link,
      ], directories: DirectoryGrouping.mixed),
      [link, file, directory],
    );
  });

  test('first-click directions match the column contract', () {
    for (final key in FileSortKey.values) {
      final expected = switch (key) {
        FileSortKey.size ||
        FileSortKey.modified => FileSortDirection.descending,
        _ => FileSortDirection.ascending,
      };
      expect(key.initialDirection, expected);
    }
  });

  test('size defaults to descending and keeps equal-size names ascending', () {
    final entries = [
      _file('file10', size: 2),
      _file('file2', size: 2),
      _file('big', size: 10),
      _file('small', size: 1),
      _file('unknown'),
    ];
    expect(_names(sortFileEntries(entries, key: FileSortKey.size)), [
      'big',
      'file2',
      'file10',
      'small',
      'unknown',
    ]);
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.size,
          direction: FileSortDirection.ascending,
        ),
      ),
      ['small', 'file2', 'file10', 'big', 'unknown'],
    );
  });

  test(
    'directory totals come only from the supplied calculated-size cache',
    () {
      final entries = [
        _file('dir10', type: RemoteFileType.directory, size: 1),
        _file('dir2', type: RemoteFileType.directory, size: 4096),
        _file('file', size: 1),
      ];
      expect(_names(sortFileEntries(entries, key: FileSortKey.size)), [
        'dir2',
        'dir10',
        'file',
      ]);
      expect(
        _names(
          sortFileEntries(
            entries,
            key: FileSortKey.size,
            directories: DirectoryGrouping.mixed,
          ),
        ),
        ['file', 'dir2', 'dir10'],
      );

      final sizes = {'/dir10': 5, '/file': 100};
      expect(
        _names(
          sortFileEntries(
            entries,
            key: FileSortKey.size,
            directories: DirectoryGrouping.mixed,
            calculatedDirectorySizes: sizes,
          ),
        ),
        ['dir10', 'file', 'dir2'],
      );
      expect(sizes, {'/dir10': 5, '/file': 100});
    },
  );

  test('dates compare instants, newest first, with ascending name ties', () {
    final now = DateTime.utc(2026, 9, 12);
    final older = now.subtract(const Duration(days: 1));
    final entries = [
      _file('file10', modified: now.toLocal()),
      _file('old', modified: older),
      _file('file2', modified: now),
      _file('unknown'),
    ];
    expect(_names(sortFileEntries(entries, key: FileSortKey.modified)), [
      'file2',
      'file10',
      'old',
      'unknown',
    ]);
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.modified,
          direction: FileSortDirection.ascending,
        ),
      ),
      ['old', 'file2', 'file10', 'unknown'],
    );
  });

  test('kind has an explicit order and natural ascending secondary key', () {
    final entries = [
      _file('a', type: RemoteFileType.other),
      _file('b', type: RemoteFileType.symbolicLink),
      _file('file10'),
      _file('file2'),
      _file('z', type: RemoteFileType.directory),
    ];
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.kind,
          directories: DirectoryGrouping.mixed,
        ),
      ),
      ['z', 'file2', 'file10', 'b', 'a'],
    );
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.kind,
          direction: FileSortDirection.descending,
          directories: DirectoryGrouping.mixed,
        ),
      ),
      ['a', 'b', 'file2', 'file10', 'z'],
    );
  });

  test('permissions omit type bits and retain special permission bits', () {
    // POSIX modes: regular 0644, directory 0644, regular 0600 and 04644.
    final entries = [
      _file('file10', mode: 0x81a4),
      _file('file2', type: RemoteFileType.directory, mode: 0x41a4),
      _file('private', mode: 0x8180),
      _file('setuid', mode: 0x89a4),
      _file('unknown'),
    ];
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.permissions,
          directories: DirectoryGrouping.mixed,
        ),
      ),
      ['private', 'file2', 'file10', 'setuid', 'unknown'],
    );
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.permissions,
          direction: FileSortDirection.descending,
          directories: DirectoryGrouping.mixed,
        ),
      ),
      ['setuid', 'file2', 'file10', 'private', 'unknown'],
    );
  });

  test('owners and groups sort numerically with unknown values last', () {
    final entries = [
      _file('file10', uid: 10, gid: 2),
      _file('file2', uid: 10, gid: 2),
      _file('other', uid: 2, gid: 10),
      _file('unknown'),
    ];
    expect(_names(sortFileEntries(entries, key: FileSortKey.owner)), [
      'other',
      'file2',
      'file10',
      'unknown',
    ]);
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.owner,
          direction: FileSortDirection.descending,
        ),
      ),
      ['file2', 'file10', 'other', 'unknown'],
    );
    expect(_names(sortFileEntries(entries, key: FileSortKey.group)), [
      'file2',
      'file10',
      'other',
      'unknown',
    ]);
    expect(
      _names(
        sortFileEntries(
          entries,
          key: FileSortKey.group,
          direction: FileSortDirection.descending,
        ),
      ),
      ['other', 'file2', 'file10', 'unknown'],
    );
  });

  test('equal metadata and names use ascending paths even in descending', () {
    final a = _file('same', path: '/a', size: 3);
    final b = _file('same', path: '/b', size: 3);
    for (final key in FileSortKey.values) {
      expect(
        sortFileEntries(
          [b, a],
          key: key,
          direction: FileSortDirection.descending,
        ),
        [a, b],
      );
    }
  });

  test('sorting preserves entries and input and returns an immutable list', () {
    final a = _file('a');
    final b = _file('b');
    final input = [b, a];
    final sorted = sortFileEntries(input);
    expect(input, [b, a]);
    expect(sorted, [a, b]);
    expect(identical(sorted.first, a), isTrue);
    expect(() => sorted.clear(), throwsUnsupportedError);
    expect(sortFileEntries([]), isEmpty);
  });

  test('ordering is repeatable across shuffled mixed metadata', () {
    const seed = 7312;
    final random = Random(seed);
    final entries = List.generate(
      100,
      (i) => _file(
        '${['File', 'file', 'ſ', 's'][i % 4]}${i % 11}part${i % 7}',
        path: '/entry$i',
        type: RemoteFileType.values[i % 4],
        size: i % 3 == 0 ? null : i % 5,
        uid: i % 4 == 0 ? null : i % 2,
        gid: i % 5,
        mode: i % 7 == 0 ? null : i % 8,
        modified: i % 2 == 0 ? null : DateTime.utc(2026, 1, i % 4 + 1),
      ),
    );
    for (final key in FileSortKey.values) {
      for (final direction in FileSortDirection.values) {
        for (final directories in DirectoryGrouping.values) {
          final expected = sortFileEntries(
            entries,
            key: key,
            direction: direction,
            directories: directories,
          );
          for (var run = 0; run < 5; run++) {
            entries.shuffle(random);
            expect(
              sortFileEntries(
                entries,
                key: key,
                direction: direction,
                directories: directories,
              ),
              expected,
              reason: 'seed=$seed $key $direction $directories run=$run',
            );
          }
        }
      }
    }
  });
}

List<String> _names(List<RemoteFileEntry> entries) =>
    entries.map((entry) => entry.name).toList();

RemoteFileEntry _file(
  String name, {
  String? path,
  RemoteFileType type = RemoteFileType.file,
  int? size,
  int? uid,
  int? gid,
  int? mode,
  DateTime? modified,
}) => RemoteFileEntry(
  name: name,
  path: path ?? '/$name',
  type: type,
  size: size,
  uid: uid,
  gid: gid,
  mode: mode,
  modifiedAt: modified,
);
