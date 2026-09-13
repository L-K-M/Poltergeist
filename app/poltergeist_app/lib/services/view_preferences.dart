import 'package:poltergeist_core/poltergeist_core.dart'
    show DirectoryGrouping, FileSortDirection, FileSortKey;

enum PaneViewMode { list, details }

enum PaneDensity { comfortable, compact }

enum HiddenFiles { hidden, shown }

enum FileDateStyle { relative, absolute }

enum ViewLocationKind { local, remote }

/// A device-local location identity, distinct across volumes and servers.
///
/// The caller supplies the volume or server identity and a canonical path.
/// Canonicalization belongs to the location boundary, not this storage model.
final class ViewLocationKey {
  ViewLocationKey({
    required this.kind,
    required this.identity,
    required this.canonicalPath,
  }) {
    if (identity.isEmpty) {
      throw ArgumentError.value(identity, _identityKey, _emptyValueMessage);
    }
    if (canonicalPath.isEmpty) {
      throw ArgumentError.value(canonicalPath, _pathKey, _emptyValueMessage);
    }
  }

  static const _kindKey = 'kind';
  static const _identityKey = 'identity';
  static const _pathKey = 'canonicalPath';
  static const _emptyValueMessage = 'Must not be empty';

  final ViewLocationKind kind;
  final String identity;
  final String canonicalPath;

  Map<String, Object?> toJson() => {
    _kindKey: kind.name,
    _identityKey: identity,
    _pathKey: canonicalPath,
  };

  static ViewLocationKey fromJson(Object? value) {
    final json = _readObject(value);
    final identity = json[_identityKey];
    final path = json[_pathKey];
    if (identity is! String || identity.isEmpty) {
      throw const FormatException('Invalid view location identity');
    }
    if (path is! String || path.isEmpty) {
      throw const FormatException('Invalid view location canonical path');
    }

    return ViewLocationKey(
      kind: _readEnum(json[_kindKey], ViewLocationKind.values, _kindKey),
      identity: identity,
      canonicalPath: path,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewLocationKey &&
      kind == other.kind &&
      identity == other.identity &&
      canonicalPath == other.canonicalPath;

  @override
  int get hashCode => Object.hash(kind, identity, canonicalPath);
}

/// Persisted view options shared by tabs visiting the same location (02 §2.4).
///
/// Hidden-file keyboard overrides belong to the tab and never enter this model.
final class ViewPreferences {
  ViewPreferences({
    this.mode = PaneViewMode.details,
    this.density = PaneDensity.comfortable,
    this.directories = DirectoryGrouping.first,
    this.hiddenFiles = HiddenFiles.hidden,
    this.dates = FileDateStyle.relative,
    this.sortKey = FileSortKey.name,
    this.sortDirection = FileSortDirection.ascending,
    List<FileSortKey> columns = _defaultColumns,
    Map<FileSortKey, double> columnWidths = const {},
  }) : columns = List.unmodifiable(columns),
       columnWidths = Map.unmodifiable(columnWidths) {
    if (this.columns.isEmpty || this.columns.first != FileSortKey.name) {
      throw ArgumentError.value(columns, _columnsKey, 'Name must be first');
    }
    if (this.columns.toSet().length != this.columns.length) {
      throw ArgumentError.value(columns, _columnsKey, 'Columns must be unique');
    }
    if (this.columnWidths.values.any(
      (width) => !width.isFinite || width <= 0,
    )) {
      throw ArgumentError.value(
        columnWidths,
        _columnWidthsKey,
        'Widths must be positive and finite',
      );
    }
  }

  static const _modeKey = 'mode';
  static const _densityKey = 'density';
  static const _directoriesKey = 'directories';
  static const _hiddenFilesKey = 'hiddenFiles';
  static const _datesKey = 'dates';
  static const _sortKeyKey = 'sortKey';
  static const _sortDirectionKey = 'sortDirection';
  static const _columnsKey = 'columns';
  static const _columnWidthsKey = 'columnWidths';
  static const _defaultColumns = [
    FileSortKey.name,
    FileSortKey.size,
    FileSortKey.modified,
  ];

  final PaneViewMode mode;
  final PaneDensity density;
  final DirectoryGrouping directories;
  final HiddenFiles hiddenFiles;
  final FileDateStyle dates;
  final FileSortKey sortKey;
  final FileSortDirection sortDirection;
  final List<FileSortKey> columns;

  /// Missing widths use renderer defaults; hidden columns retain their widths.
  final Map<FileSortKey, double> columnWidths;

  ViewPreferences copyWith({
    PaneViewMode? mode,
    PaneDensity? density,
    DirectoryGrouping? directories,
    HiddenFiles? hiddenFiles,
    FileDateStyle? dates,
    FileSortKey? sortKey,
    FileSortDirection? sortDirection,
    List<FileSortKey>? columns,
    Map<FileSortKey, double>? columnWidths,
  }) => ViewPreferences(
    mode: mode ?? this.mode,
    density: density ?? this.density,
    directories: directories ?? this.directories,
    hiddenFiles: hiddenFiles ?? this.hiddenFiles,
    dates: dates ?? this.dates,
    sortKey: sortKey ?? this.sortKey,
    sortDirection: sortDirection ?? this.sortDirection,
    columns: columns ?? this.columns,
    columnWidths: columnWidths ?? this.columnWidths,
  );

  Map<String, Object?> toJson() => {
    _modeKey: mode.name,
    _densityKey: density.name,
    _directoriesKey: directories.name,
    _hiddenFilesKey: hiddenFiles.name,
    _datesKey: dates.name,
    _sortKeyKey: sortKey.name,
    _sortDirectionKey: sortDirection.name,
    _columnsKey: columns.map((column) => column.name).toList(),
    _columnWidthsKey: {
      for (final entry in columnWidths.entries) entry.key.name: entry.value,
    },
  };

  static ViewPreferences fromJson(Object? value) {
    final json = _readObject(value);
    final defaults = ViewPreferences();

    // Absence permits additive schemas; malformed known fields fail the record.
    T option<T extends Enum>(String key, List<T> values, T fallback) =>
        json.containsKey(key) ? _readEnum(json[key], values, key) : fallback;

    try {
      return ViewPreferences(
        mode: option(_modeKey, PaneViewMode.values, defaults.mode),
        density: option(_densityKey, PaneDensity.values, defaults.density),
        directories: option(
          _directoriesKey,
          DirectoryGrouping.values,
          defaults.directories,
        ),
        hiddenFiles: option(
          _hiddenFilesKey,
          HiddenFiles.values,
          defaults.hiddenFiles,
        ),
        dates: option(_datesKey, FileDateStyle.values, defaults.dates),
        sortKey: option(_sortKeyKey, FileSortKey.values, defaults.sortKey),
        sortDirection: option(
          _sortDirectionKey,
          FileSortDirection.values,
          defaults.sortDirection,
        ),
        columns: json.containsKey(_columnsKey)
            ? _readColumns(json[_columnsKey])
            : defaults.columns,
        columnWidths: json.containsKey(_columnWidthsKey)
            ? _readWidths(json[_columnWidthsKey])
            : defaults.columnWidths,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid view preferences: ${error.message}');
    }
  }

  static List<FileSortKey> _readColumns(Object? value) {
    if (value is! List) {
      throw const FormatException('View columns must be a list');
    }
    return [
      for (final column in value)
        _readEnum(column, FileSortKey.values, _columnsKey),
    ];
  }

  static Map<FileSortKey, double> _readWidths(Object? value) {
    final json = _readObject(value);
    final widths = <FileSortKey, double>{};
    for (final entry in json.entries) {
      final key = _readEnum(entry.key, FileSortKey.values, _columnWidthsKey);
      final width = entry.value;
      if (width is! num) {
        throw const FormatException('View column widths must be numbers');
      }
      widths[key] = width.toDouble();
    }
    return widths;
  }

  @override
  bool operator ==(Object other) =>
      other is ViewPreferences &&
      mode == other.mode &&
      density == other.density &&
      directories == other.directories &&
      hiddenFiles == other.hiddenFiles &&
      dates == other.dates &&
      sortKey == other.sortKey &&
      sortDirection == other.sortDirection &&
      _sameColumns(columns, other.columns) &&
      columnWidths.length == other.columnWidths.length &&
      columnWidths.entries.every(
        (entry) => other.columnWidths[entry.key] == entry.value,
      );

  @override
  int get hashCode => Object.hash(
    mode,
    density,
    directories,
    hiddenFiles,
    dates,
    sortKey,
    sortDirection,
    Object.hashAll(columns),
    // Width-map insertion order has no effect on value equality.
    Object.hashAll([
      for (final key in FileSortKey.values)
        if (columnWidths.containsKey(key)) Object.hash(key, columnWidths[key]),
    ]),
  );
}

Map<String, Object?> _readObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('View preferences require a JSON object');
  }
  return value.cast<String, Object?>();
}

T _readEnum<T extends Enum>(Object? value, List<T> options, String field) {
  for (final option in options) {
    if (value == option.name) return option;
  }
  throw FormatException('Invalid view preference: $field');
}

bool _sameColumns(List<FileSortKey> first, List<FileSortKey> second) {
  if (first.length != second.length) return false;

  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
