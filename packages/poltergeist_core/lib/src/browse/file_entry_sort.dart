import 'package:seance_core/seance_core.dart'
    show RemoteFileEntry, RemoteFileType;

import 'unicode_simple_fold.dart';

enum FileSortDirection { ascending, descending }

enum DirectoryGrouping { first, mixed }

/// Column identities also own the initial header-click direction (02 §2.3).
enum FileSortKey {
  name,
  size,
  modified,
  kind,
  permissions,
  owner,
  group;

  FileSortDirection get initialDirection => switch (this) {
    size || modified => FileSortDirection.descending,
    _ => FileSortDirection.ascending,
  };
}

const _permissionBitsMask = 0x0fff;
const _asciiZero = 0x30;
const _asciiNine = 0x39;

/// Sorts a listing snapshot without I/O or changes to its entries.
///
/// Directory grouping and ascending secondary names survive direction changes;
/// absent metadata stays last within each group. Only caller-calculated totals
/// in [calculatedDirectorySizes] count as directory sizes, otherwise zero.
/// The pinned VFS exposes no symlink target kind, so links group with files.
/// Raw-byte collision ordering (02 §13) needs richer VFS metadata; this function
/// orders decoded names only (docs/STATUS.md, open item 13).
List<RemoteFileEntry> sortFileEntries(
  Iterable<RemoteFileEntry> entries, {
  FileSortKey key = FileSortKey.name,
  FileSortDirection? direction,
  DirectoryGrouping directories = DirectoryGrouping.first,
  Map<String, int> calculatedDirectorySizes = const {},
}) {
  // Fold each name once, keeping repeated comparisons cheap on large listings.
  final rows = [
    for (final entry in entries)
      _SortEntry(entry, calculatedDirectorySizes[entry.path]),
  ];
  final order = direction ?? key.initialDirection;
  rows.sort((a, b) => _compareEntries(a, b, key, order, directories));
  return List.unmodifiable(rows.map((row) => row._entry));
}

class _SortEntry {
  _SortEntry(this._entry, int? directorySize)
    : _foldedName = simpleCaseFold(_entry.name),
      _size = _entry.isDirectory ? directorySize ?? 0 : _entry.size;

  final RemoteFileEntry _entry;
  final String _foldedName;
  final int? _size;
}

int _compareEntries(
  _SortEntry a,
  _SortEntry b,
  FileSortKey key,
  FileSortDirection direction,
  DirectoryGrouping directories,
) {
  final left = a._entry;
  final right = b._entry;
  if (directories == DirectoryGrouping.first &&
      left.isDirectory != right.isDirectory) {
    return left.isDirectory ? -1 : 1;
  }

  final primary = switch (key) {
    FileSortKey.name => _directed(_compareNames(a, b), direction),
    FileSortKey.size => _compareNullable(a._size, b._size, direction),
    FileSortKey.modified => _compareNullable(
      left.modifiedAt,
      right.modifiedAt,
      direction,
    ),
    FileSortKey.kind => _directed(
      _kindRank(left.type).compareTo(_kindRank(right.type)),
      direction,
    ),
    FileSortKey.permissions => _compareNullable(
      _permissionBits(left.mode),
      _permissionBits(right.mode),
      direction,
    ),
    FileSortKey.owner => _compareNullable(left.uid, right.uid, direction),
    FileSortKey.group => _compareNullable(left.gid, right.gid, direction),
  };
  if (primary != 0) return primary;

  final name = key == FileSortKey.name ? 0 : _compareNames(a, b);
  if (name != 0) return name;

  return left.path.compareTo(right.path);
}

int? _permissionBits(int? mode) =>
    mode == null ? null : mode & _permissionBitsMask;

int _kindRank(RemoteFileType type) => switch (type) {
  RemoteFileType.directory => 0,
  RemoteFileType.file => 1,
  RemoteFileType.symbolicLink => 2,
  RemoteFileType.other => 3,
};

int _compareNullable<T extends Comparable<T>>(
  T? a,
  T? b,
  FileSortDirection direction,
) {
  // Unknown is an absence, not a zero or an epoch; keep it last both ways.
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return _directed(a.compareTo(b), direction);
}

int _directed(int comparison, FileSortDirection direction) =>
    direction == FileSortDirection.ascending ? comparison : -comparison;

int _compareNames(_SortEntry a, _SortEntry b) {
  final comparison = _compareNatural(a._foldedName, b._foldedName);
  if (comparison != 0) return comparison;
  return a._entry.name.compareTo(b._entry.name);
}

int _compareNatural(String a, String b) {
  var left = 0;
  var right = 0;
  while (left < a.length && right < b.length) {
    final ac = a.codeUnitAt(left);
    final bc = b.codeUnitAt(right);
    if (!_isDigit(ac) || !_isDigit(bc)) {
      final comparison = ac.compareTo(bc);
      if (comparison != 0) return comparison;
      left++;
      right++;
      continue;
    }

    final leftEnd = _digitRunEnd(a, left);
    final rightEnd = _digitRunEnd(b, right);
    // Compare magnitude as text; arbitrarily long numeric runs cannot overflow.
    while (left < leftEnd && a.codeUnitAt(left) == _asciiZero) {
      left++;
    }
    while (right < rightEnd && b.codeUnitAt(right) == _asciiZero) {
      right++;
    }
    final length = (leftEnd - left).compareTo(rightEnd - right);
    if (length != 0) return length;

    while (left < leftEnd) {
      final comparison = a.codeUnitAt(left).compareTo(b.codeUnitAt(right));
      if (comparison != 0) return comparison;
      left++;
      right++;
    }
  }

  return (a.length - left).compareTo(b.length - right);
}

int _digitRunEnd(String value, int start) {
  var end = start;
  while (end < value.length && _isDigit(value.codeUnitAt(end))) {
    end++;
  }
  return end;
}

bool _isDigit(int codeUnit) => codeUnit >= _asciiZero && codeUnit <= _asciiNine;
