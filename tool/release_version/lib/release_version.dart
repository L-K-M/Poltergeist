import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const int _componentLimit = 99;
const int _finalOrdinal = 99;
const int _majorMultiplier = 1_000_000;
const int _minorMultiplier = 10_000;
const int _patchMultiplier = 100;
const int _androidVersionCodeLimit = 2_100_000_000;
const int _majorComponentLimit =
    (_androidVersionCodeLimit - _finalOrdinal) ~/ _majorMultiplier;
const int _temporaryTokenByteCount = 16;
const int _byteValueCount = 256;
const int _hexRadix = 16;
const int _hexByteWidth = 2;
const String _temporaryPrefix = '.poltergeist-';
const String _temporarySuffix = '.tmp';
const String _appPubspecPath = 'app/poltergeist_app/pubspec.yaml';
const String _appLockPath = 'app/poltergeist_app/pubspec.lock';
const String _readmePath = 'README.md';
const List<String> _appleInfoPlistPaths = [
  'app/poltergeist_app/ios/Runner/Info.plist',
  'app/poltergeist_app/macos/Runner/Info.plist',
];
const List<String> _dependencySections = [
  'dependencies',
  'dev_dependencies',
  'dependency_overrides',
];

final RegExp _versionPattern = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
);
final RegExp _appVersionPattern = RegExp(r'^(.+)\+([0-9]+)$');
final RegExp _versionLinePattern = RegExp(
  r'^(version:[ \t]*)([^#\s]+)([ \t]*(?:#[^\r\n]*)?)$',
  multiLine: true,
);
final RegExp _readmeVersionPattern = RegExp(
  r'<!-- version -->([^<]+)<!-- /version -->',
);
final RegExp _appleBundleVersionPattern = RegExp(
  r'(<key>CFBundleVersion</key>\s*<string>)([^<]*)(</string>)',
);
final Random _secureRandom = Random.secure();
const Set<String> _ignoredDirectories = {
  '.dart_tool',
  '.git',
  '.plugin_symlinks',
  '.symlinks',
  'build',
  'ephemeral',
  'Pods',
};

/// A release version whose Android build code preserves semantic ordering.
final class ReleaseVersion {
  final int _major;
  final int _minor;
  final int _patch;

  const ReleaseVersion._({
    required this._major,
    required this._minor,
    required this._patch,
  });

  factory ReleaseVersion.parse(String source) {
    final match = _versionPattern.firstMatch(source);
    if (match == null) {
      throw ReleaseVersionFormatException(
        'invalid release version "$source"; expected X.Y.Z',
      );
    }

    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[2]!);
    final patch = int.tryParse(match[3]!);
    if (major == null || minor == null || patch == null) {
      throw ReleaseVersionFormatException(
        'release version "$source" contains an integer outside the '
        'supported range',
      );
    }
    if (minor > _componentLimit || patch > _componentLimit) {
      throw ReleaseVersionFormatException(
        'release version "$source" requires minor and patch values '
        'between 0 and $_componentLimit',
      );
    }
    if (major > _majorComponentLimit) {
      throw ReleaseVersionFormatException(
        'release version "$source" exceeds Android versionCode '
        '$_androidVersionCodeLimit',
      );
    }

    final version = ReleaseVersion._(major: major, minor: minor, patch: patch);
    // Keep the platform ceiling explicit if component constants drift.
    if (version.androidVersionCode > _androidVersionCodeLimit) {
      throw ReleaseVersionFormatException(
        'release version "$source" exceeds Android versionCode '
        '$_androidVersionCodeLimit',
      );
    }

    return version;
  }

  String get semantic => '$_major.$_minor.$_patch';

  int get androidVersionCode {
    return _major * _majorMultiplier +
        _minor * _minorMultiplier +
        _patch * _patchMultiplier +
        _finalOrdinal;
  }

  String get appVersion => '$semantic+$androidVersionCode';

  // Offset zero-major releases because Apple's first component is positive.
  String get _appleBundleVersion => '${_major + 1}.$_minor.$_patch';
}

final class ReleaseVersionFormatException implements Exception {
  final String message;

  const ReleaseVersionFormatException(this.message);

  @override
  String toString() => message;
}

final class ReleaseVersionStateException implements Exception {
  final String message;

  const ReleaseVersionStateException(this.message);

  @override
  String toString() => message;
}

final class ReleaseVersionReport {
  final ReleaseVersion version;
  final int pubspecCount;
  final int lockedPackageCount;

  const ReleaseVersionReport({
    required this.version,
    required this.pubspecCount,
    required this.lockedPackageCount,
  });
}

/// Synchronizes and verifies the repository's release-version declarations.
final class ReleaseVersionWorkspace {
  final Directory _root;

  ReleaseVersionWorkspace(Directory root)
    : _root = Directory(p.normalize(p.absolute(root.path))) {
    if (!_root.existsSync()) {
      throw ReleaseVersionStateException(
        'repository root does not exist: ${_root.path}',
      );
    }
  }

  void syncAppMetadata({
    required ReleaseVersion version,
    required String pubspecPath,
  }) {
    final requestedPubspec = _resolveInsideRoot(pubspecPath);
    final appPubspec = _resolveInsideRoot(_appPubspecPath);
    if (!p.equals(requestedPubspec.path, appPubspec.path)) {
      throw ReleaseVersionStateException(
        'sync must target $_appPubspecPath; got $pubspecPath',
      );
    }

    final rewrites = [
      _prepareAppPubspec(version: version, pubspecPath: pubspecPath),
      for (final path in _appleInfoPlistPaths)
        _prepareAppleInfoPlist(version: version, path: path),
    ];

    final staged = <_StagedRewrite>[];
    var committedCount = 0;
    try {
      // Validate every rewrite before replacing any release metadata.
      for (final rewrite in rewrites) {
        if (!rewrite.changed) continue;

        staged.add(_stageRewrite(rewrite));
      }
      for (final rewrite in staged) {
        rewrite.temporary.renameSync(rewrite.target.path);
        committedCount++;
      }
    } finally {
      // A successful rename ends ownership of the vacated temporary path.
      for (var index = committedCount; index < staged.length; index++) {
        _deleteTemporaryBestEffort(staged[index].temporary);
      }
    }
  }

  _PreparedRewrite _prepareAppPubspec({
    required ReleaseVersion version,
    required String pubspecPath,
  }) {
    final file = _resolveInsideRoot(pubspecPath);
    if (!file.existsSync()) {
      throw ReleaseVersionStateException(
        'app pubspec does not exist: $pubspecPath',
      );
    }

    _readYamlMap(file, 'app pubspec');
    final original = file.readAsStringSync();
    final matches = _versionLinePattern.allMatches(original).toList();
    if (matches.length != 1) {
      throw ReleaseVersionStateException(
        'app pubspec must contain exactly one top-level version',
      );
    }

    final rewritten = original.replaceRange(
      matches.single.start,
      matches.single.end,
      '${matches.single[1]}${version.appVersion}${matches.single[3]}',
    );

    return _PreparedRewrite(
      file: file,
      contents: rewritten,
      changed: rewritten != original,
      validate: (temporary) {
        final stored = _readPubspecVersion(
          temporary,
          requirement: _VersionRequirement.required,
        )!;
        if (stored == version.appVersion) return;

        throw ReleaseVersionStateException(
          'app pubspec version sync produced "$stored" instead of '
          '"${version.appVersion}"',
        );
      },
    );
  }

  _PreparedRewrite _prepareAppleInfoPlist({
    required ReleaseVersion version,
    required String path,
  }) {
    final file = _resolveInsideRoot(path);
    final original = _readRequiredFile(file, 'Apple Info.plist $path');
    final match = _appleBundleVersionMatch(original, path);
    final expected = version._appleBundleVersion;
    final rewritten = original.replaceRange(
      match.start,
      match.end,
      '${match[1]}$expected${match[3]}',
    );

    return _PreparedRewrite(
      file: file,
      contents: rewritten,
      changed: rewritten != original,
      validate: (temporary) {
        final stored = _appleBundleVersionMatch(
          temporary.readAsStringSync(),
          path,
        )[2];
        if (stored == expected) return;

        throw ReleaseVersionStateException(
          'Apple bundle version sync produced "$stored" instead of '
          '"$expected" in $path',
        );
      },
    );
  }

  _StagedRewrite _stageRewrite(_PreparedRewrite rewrite) {
    final temporary = File(
      p.join(rewrite.file.parent.path, _newTemporaryFileName()),
    );
    final temporaryType = FileSystemEntity.typeSync(
      temporary.path,
      followLinks: false,
    );
    if (temporaryType != FileSystemEntityType.notFound) {
      throw ReleaseVersionStateException(
        'stale release-version file exists: ${temporary.path}',
      );
    }

    var created = false;
    try {
      // Exclusive creation also closes the lstat/create collision window.
      temporary.createSync(exclusive: true);
      created = true;
      temporary.writeAsStringSync(rewrite.contents, flush: true);
      rewrite.validate(temporary);
    } on Object {
      if (created) _deleteTemporaryBestEffort(temporary);

      rethrow;
    }

    return _StagedRewrite(target: rewrite.file, temporary: temporary);
  }

  ReleaseVersionReport check({ReleaseVersion? expected}) {
    final pubspecs = _findPubspecs();
    final app = _resolveInsideRoot(_appPubspecPath);
    if (!app.existsSync()) {
      throw const ReleaseVersionStateException(
        'app pubspec is missing: $_appPubspecPath',
      );
    }

    final declarations = <_PubspecVersion>[];
    for (final file in pubspecs) {
      final value = _readPubspecVersion(file);
      if (value == null) continue;

      declarations.add(
        _PubspecVersion(
          file: file,
          relativePath: p.relative(file.path, from: _root.path),
          value: value,
        ),
      );
    }

    final appDeclaration = declarations
        .where((declaration) => p.equals(declaration.file.path, app.path))
        .singleOrNull;
    if (appDeclaration == null) {
      throw const ReleaseVersionStateException(
        'app pubspec has no top-level version',
      );
    }

    final parsedApp = _parseAppVersion(appDeclaration);
    final ordinary = declarations
        .where((declaration) => !p.equals(declaration.file.path, app.path))
        .toList();
    final inferred = ordinary.isEmpty
        ? parsedApp.version
        : _parsePubspecVersion(ordinary.first);
    final version = expected ?? inferred;

    for (final declaration in ordinary) {
      final actual = _parsePubspecVersion(declaration);
      if (actual.semantic == version.semantic) continue;

      throw ReleaseVersionStateException(
        'pubspec ${declaration.relativePath} declares ${actual.semantic}; '
        'expected ${version.semantic}',
      );
    }
    if (parsedApp.version.semantic != version.semantic) {
      throw ReleaseVersionStateException(
        'app pubspec declares ${parsedApp.version.semantic}; expected '
        '${version.semantic}',
      );
    }
    if (parsedApp.buildCode != version.androidVersionCode) {
      throw ReleaseVersionStateException(
        'app pubspec version code is ${parsedApp.buildCode}; expected '
        '${version.androidVersionCode}',
      );
    }

    final lockedPackageCount = _checkAppLock(app, declarations, version);
    _checkAppleBundleVersions(version);
    _checkReadme(version);

    return ReleaseVersionReport(
      version: version,
      pubspecCount: declarations.length,
      lockedPackageCount: lockedPackageCount,
    );
  }

  ReleaseVersionReport checkTag(String tag) {
    final version = _parseReleaseTag(tag);
    return check(expected: version);
  }

  ReleaseVersion checkReleaseOrder({
    ReleaseVersion? target,
    Iterable<String> priorTags = const [],
  }) {
    final current = check().version;
    final candidate = target ?? current;
    if (candidate.semantic != current.semantic &&
        candidate.androidVersionCode <= current.androidVersionCode) {
      throw ReleaseVersionStateException(
        'target ${candidate.appVersion} must exceed current tree '
        '${current.appVersion}',
      );
    }

    String? newestTag;
    ReleaseVersion? newestVersion;
    for (final tag in priorTags) {
      final version = _parsePriorTag(tag);
      if (newestVersion != null &&
          version.androidVersionCode <= newestVersion.androidVersionCode) {
        continue;
      }

      newestTag = tag;
      newestVersion = version;
    }
    if (newestVersion != null &&
        candidate.androidVersionCode <= newestVersion.androidVersionCode) {
      throw ReleaseVersionStateException(
        'target ${candidate.appVersion} must exceed prior tag $newestTag '
        '(${newestVersion.appVersion})',
      );
    }

    return candidate;
  }

  List<File> _findPubspecs() {
    final files = <File>[];
    final pending = <Directory>[_root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is Directory) {
          if (_ignoredDirectories.contains(p.basename(entity.path))) continue;

          pending.add(entity);
          continue;
        }
        if (entity is File && p.basename(entity.path) == 'pubspec.yaml') {
          files.add(entity);
        }
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  File _resolveInsideRoot(String pathFromRoot) {
    final candidate = p.isAbsolute(pathFromRoot)
        ? pathFromRoot
        : p.join(_root.path, pathFromRoot);
    final resolved = File(p.normalize(p.absolute(candidate)));

    // Resolve links before containment so root/link -> outside cannot escape.
    final rootPath = _root.resolveSymbolicLinksSync();
    final resolvedPath = _canonicalPath(resolved);
    if (p.equals(resolvedPath, rootPath)) {
      throw ReleaseVersionStateException(
        'path must identify a file inside repository root: $pathFromRoot',
      );
    }
    if (p.isWithin(rootPath, resolvedPath)) {
      return resolved;
    }

    throw ReleaseVersionStateException(
      'path leaves repository root: $pathFromRoot',
    );
  }

  String _canonicalPath(File file) {
    if (file.existsSync()) return file.resolveSymbolicLinksSync();

    var ancestor = file.parent;
    while (!ancestor.existsSync()) {
      final parent = ancestor.parent;
      if (p.equals(ancestor.path, parent.path)) return file.path;

      ancestor = parent;
    }

    // Resolve the existing prefix so links cannot hide in a missing tail.
    return p.join(
      ancestor.resolveSymbolicLinksSync(),
      p.relative(file.path, from: ancestor.path),
    );
  }

  int _checkAppLock(
    File appPubspec,
    List<_PubspecVersion> declarations,
    ReleaseVersion expected,
  ) {
    final dependencies = _pathDependencies(appPubspec);
    final lock = _resolveInsideRoot(_appLockPath);
    final lockYaml = _readYamlMap(lock, 'app lock');
    final packages = lockYaml['packages'];
    if (packages is! YamlMap) {
      throw const ReleaseVersionStateException('app lock has no packages map');
    }

    var checked = 0;
    for (final dependency in dependencies.entries) {
      final matchingPubspec = declarations
          .where(
            (declaration) =>
                _readPubspecName(declaration.file) == dependency.key,
          )
          .toList();
      if (matchingPubspec.length != 1) {
        throw ReleaseVersionStateException(
          'app path dependency ${dependency.key} must resolve to exactly one '
          'versioned pubspec',
        );
      }

      final locked = packages[dependency.key];
      final description = locked is YamlMap ? locked['description'] : null;
      final lockedPath = description is YamlMap ? description['path'] : null;
      final lockedRelative = description is YamlMap
          ? description['relative']
          : null;
      final lockedPathKind = switch (lockedRelative) {
        true => _DependencyPathKind.relative,
        false => _DependencyPathKind.absolute,
        _ => null,
      };
      final declaredPathKind = p.isAbsolute(dependency.value)
          ? _DependencyPathKind.absolute
          : _DependencyPathKind.relative;
      final packageDirectory = matchingPubspec.single.file.parent;
      final declaredDirectory = _resolveDependencyDirectory(
        appPubspec,
        dependency.value,
      );
      final lockedDirectory = lockedPath is String && lockedPathKind != null
          ? _resolveLockedDependencyDirectory(
              appPubspec,
              lockedPath,
              lockedPathKind,
            )
          : null;
      if (locked is! YamlMap ||
          locked['source'] != 'path' ||
          locked['version'] != expected.semantic ||
          !_sameDirectory(declaredDirectory, packageDirectory) ||
          lockedPathKind != declaredPathKind ||
          lockedDirectory == null ||
          !_sameDirectory(lockedDirectory, packageDirectory)) {
        throw ReleaseVersionStateException(
          'app lock does not pin path dependency ${dependency.key} at '
          '${expected.semantic}',
        );
      }
      checked++;
    }
    return checked;
  }

  Map<String, String> _pathDependencies(File appPubspec) {
    final yaml = _readYamlMap(appPubspec, 'app pubspec');
    final paths = <String, String>{};
    for (final section in _dependencySections) {
      final dependencies = yaml[section];
      if (dependencies is! YamlMap) continue;

      for (final entry in dependencies.entries) {
        if (entry.key is! String || entry.value is! YamlMap) continue;

        final declaration = entry.value as YamlMap;
        if (!declaration.containsKey('path')) continue;

        final path = declaration['path'];
        if (path is! String) {
          throw ReleaseVersionStateException(
            'app path dependency ${entry.key} has a non-string path',
          );
        }
        paths[entry.key as String] = path;
      }
    }

    return paths;
  }

  Directory _resolveDependencyDirectory(File appPubspec, String path) {
    final candidate = p.isAbsolute(path)
        ? path
        : p.join(appPubspec.parent.path, path);

    return Directory(p.normalize(p.absolute(candidate)));
  }

  Directory? _resolveLockedDependencyDirectory(
    File appPubspec,
    String path,
    _DependencyPathKind kind,
  ) {
    final pathIsAbsolute = p.isAbsolute(path);
    if (kind == _DependencyPathKind.relative && pathIsAbsolute) return null;
    if (kind == _DependencyPathKind.absolute && !pathIsAbsolute) return null;

    return _resolveDependencyDirectory(appPubspec, path);
  }

  bool _sameDirectory(Directory left, Directory right) {
    final leftPath = left.existsSync()
        ? left.resolveSymbolicLinksSync()
        : left.path;
    final rightPath = right.existsSync()
        ? right.resolveSymbolicLinksSync()
        : right.path;

    return p.equals(leftPath, rightPath);
  }

  void _checkReadme(ReleaseVersion expected) {
    final readme = _resolveInsideRoot(_readmePath);
    if (!readme.existsSync()) {
      throw const ReleaseVersionStateException('README.md is missing');
    }

    final matches = _readmeVersionPattern
        .allMatches(readme.readAsStringSync())
        .toList();
    if (matches.length != 1 || matches.single[1] != expected.semantic) {
      throw ReleaseVersionStateException(
        'README version marker must equal ${expected.semantic}',
      );
    }
  }

  void _checkAppleBundleVersions(ReleaseVersion expected) {
    for (final path in _appleInfoPlistPaths) {
      final file = _resolveInsideRoot(path);
      final contents = _readRequiredFile(file, 'Apple Info.plist $path');
      final actual = _appleBundleVersionMatch(contents, path)[2];
      if (actual == expected._appleBundleVersion) continue;

      throw ReleaseVersionStateException(
        'Apple bundle version in $path is "$actual"; expected '
        '"${expected._appleBundleVersion}"',
      );
    }
  }
}

RegExpMatch _appleBundleVersionMatch(String contents, String path) {
  final matches = _appleBundleVersionPattern.allMatches(contents).toList();
  if (matches.length == 1) return matches.single;

  throw ReleaseVersionStateException(
    'Apple Info.plist $path must contain exactly one CFBundleVersion string',
  );
}

String _readRequiredFile(File file, String label) {
  if (file.existsSync()) return file.readAsStringSync();

  throw ReleaseVersionStateException('$label is missing: ${file.path}');
}

ReleaseVersion _parseReleaseTag(String tag) {
  if (!tag.startsWith('v')) {
    throw ReleaseVersionFormatException(
      'invalid release tag "$tag"; expected vX.Y.Z',
    );
  }

  return ReleaseVersion.parse(tag.substring(1));
}

ReleaseVersion _parsePriorTag(String tag) {
  try {
    return _parseReleaseTag(tag);
  } on ReleaseVersionFormatException catch (error) {
    throw ReleaseVersionStateException(
      'cannot establish release order from prior tag "$tag": '
      '${error.message}',
    );
  }
}

final class _PubspecVersion {
  final File file;
  final String relativePath;
  final String value;

  const _PubspecVersion({
    required this.file,
    required this.relativePath,
    required this.value,
  });
}

final class _AppVersion {
  final ReleaseVersion version;
  final int buildCode;

  const _AppVersion(this.version, this.buildCode);
}

final class _PreparedRewrite {
  final File file;
  final String contents;
  final bool changed;
  final void Function(File temporary) validate;

  const _PreparedRewrite({
    required this.file,
    required this.contents,
    required this.changed,
    required this.validate,
  });
}

final class _StagedRewrite {
  final File target;
  final File temporary;

  const _StagedRewrite({required this.target, required this.temporary});
}

String _newTemporaryFileName() {
  final token = StringBuffer();
  for (var index = 0; index < _temporaryTokenByteCount; index++) {
    token.write(
      _secureRandom
          .nextInt(_byteValueCount)
          .toRadixString(_hexRadix)
          .padLeft(_hexByteWidth, '0'),
    );
  }

  return '$_temporaryPrefix$token$_temporarySuffix';
}

void _deleteTemporaryBestEffort(File temporary) {
  try {
    final type = FileSystemEntity.typeSync(temporary.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) temporary.deleteSync();
  } on Object {
    // Preserve the write, validation, or rename failure that matters.
  }
}

_AppVersion _parseAppVersion(_PubspecVersion declaration) {
  final match = _appVersionPattern.firstMatch(declaration.value);
  if (match == null) {
    throw ReleaseVersionStateException(
      'app pubspec version "${declaration.value}" lacks a numeric build code',
    );
  }

  final version = _parsePubspecSemantic(match[1]!, 'app pubspec');
  final buildCode = int.tryParse(match[2]!);
  if (buildCode == null || '$buildCode' != match[2]) {
    throw ReleaseVersionStateException(
      'app pubspec version code "${match[2]}" is not canonical',
    );
  }

  return _AppVersion(version, buildCode);
}

ReleaseVersion _parsePubspecVersion(_PubspecVersion declaration) {
  return _parsePubspecSemantic(
    declaration.value,
    'pubspec ${declaration.relativePath}',
  );
}

ReleaseVersion _parsePubspecSemantic(String value, String source) {
  try {
    return ReleaseVersion.parse(value);
  } on ReleaseVersionFormatException catch (error) {
    throw ReleaseVersionStateException('$source is invalid: ${error.message}');
  }
}

enum _VersionRequirement { optional, required }

enum _DependencyPathKind { absolute, relative }

String? _readPubspecVersion(
  File file, {
  _VersionRequirement requirement = _VersionRequirement.optional,
}) {
  final yaml = _readYamlMap(file, 'pubspec ${file.path}');
  final value = yaml['version'];
  if (value == null && requirement == _VersionRequirement.optional) return null;
  if (value is String) return value;

  throw ReleaseVersionStateException(
    'pubspec ${file.path} has a missing or non-string version',
  );
}

String? _readPubspecName(File file) {
  final yaml = _readYamlMap(file, 'pubspec ${file.path}');
  final value = yaml['name'];
  return value is String ? value : null;
}

YamlMap _readYamlMap(File file, String label) {
  if (!file.existsSync()) {
    throw ReleaseVersionStateException('$label is missing: ${file.path}');
  }

  try {
    final yaml = loadYaml(file.readAsStringSync());
    if (yaml is YamlMap) return yaml;
  } on YamlException catch (error) {
    throw ReleaseVersionStateException('$label is malformed: $error');
  }

  throw ReleaseVersionStateException('$label must contain a YAML map');
}
