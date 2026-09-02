import 'dart:io';

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
const String _appPubspecPath = 'app/poltergeist_app/pubspec.yaml';
const String _appLockPath = 'app/poltergeist_app/pubspec.lock';
const String _readmePath = 'README.md';
const List<String> _appleInfoPlistPaths = [
  'app/poltergeist_app/ios/Runner/Info.plist',
  'app/poltergeist_app/macos/Runner/Info.plist',
];

final RegExp _versionPattern = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
);
final RegExp _appVersionPattern = RegExp(r'^(.+)\+([0-9]+)$');
final RegExp _versionLinePattern = RegExp(
  r'^version:[ \t]*[^\r\n]*$',
  multiLine: true,
);
final RegExp _readmeVersionPattern = RegExp(
  r'<!-- version -->([^<]+)<!-- /version -->',
);
final RegExp _appleBundleVersionPattern = RegExp(
  r'(<key>CFBundleVersion</key>\s*<string>)([^<]*)(</string>)',
);
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

  // Apple requires a positive, four-digit first build component.
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
    final rewrites = [
      _prepareAppPubspec(version: version, pubspecPath: pubspecPath),
      for (final path in _appleInfoPlistPaths)
        _prepareAppleInfoPlist(version: version, path: path),
    ];

    final staged = <_StagedRewrite>[];
    try {
      // Validate every rewrite before replacing any release metadata.
      for (final rewrite in rewrites) {
        if (!rewrite.changed) continue;

        staged.add(_stageRewrite(rewrite));
      }
      for (final rewrite in staged) {
        rewrite.temporary.renameSync(rewrite.target.path);
      }
    } finally {
      for (final rewrite in staged) {
        if (rewrite.temporary.existsSync()) rewrite.temporary.deleteSync();
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
      'version: ${version.appVersion}',
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
    final temporary = File('${rewrite.file.path}.$pid.release-version.tmp');
    if (temporary.existsSync()) {
      throw ReleaseVersionStateException(
        'stale release-version file exists: ${temporary.path}',
      );
    }

    try {
      temporary.writeAsStringSync(rewrite.contents, flush: true);
      rewrite.validate(temporary);
    } on Object {
      if (temporary.existsSync()) temporary.deleteSync();

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
    if (p.equals(resolvedPath, rootPath) ||
        p.isWithin(rootPath, resolvedPath)) {
      return resolved;
    }

    throw ReleaseVersionStateException(
      'path leaves repository root: $pathFromRoot',
    );
  }

  String _canonicalPath(File file) {
    if (file.existsSync()) return file.resolveSymbolicLinksSync();

    final parent = file.parent;
    if (!parent.existsSync()) return file.path;

    return p.join(parent.resolveSymbolicLinksSync(), p.basename(file.path));
  }

  int _checkAppLock(
    File appPubspec,
    List<_PubspecVersion> declarations,
    ReleaseVersion expected,
  ) {
    final dependencies = _pathDependencyNames(appPubspec);
    final lock = _resolveInsideRoot(_appLockPath);
    final lockYaml = _readYamlMap(lock, 'app lock');
    final packages = lockYaml['packages'];
    if (packages is! YamlMap) {
      throw const ReleaseVersionStateException('app lock has no packages map');
    }

    var checked = 0;
    for (final dependency in dependencies) {
      final matchingPubspec = declarations
          .where(
            (declaration) => _readPubspecName(declaration.file) == dependency,
          )
          .toList();
      if (matchingPubspec.length != 1) {
        throw ReleaseVersionStateException(
          'app path dependency $dependency must resolve to exactly one '
          'versioned pubspec',
        );
      }

      final locked = packages[dependency];
      if (locked is! YamlMap ||
          locked['source'] != 'path' ||
          locked['version'] != expected.semantic) {
        throw ReleaseVersionStateException(
          'app lock does not pin path dependency $dependency at '
          '${expected.semantic}',
        );
      }
      checked++;
    }
    return checked;
  }

  Set<String> _pathDependencyNames(File appPubspec) {
    final yaml = _readYamlMap(appPubspec, 'app pubspec');
    final dependencies = yaml['dependencies'];
    if (dependencies is! YamlMap) return const {};

    return {
      for (final entry in dependencies.entries)
        if (entry.key is String &&
            entry.value is YamlMap &&
            (entry.value as YamlMap).containsKey('path'))
          entry.key as String,
    };
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
