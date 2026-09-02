import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Stable workflow marker guarded by CI whenever a Séance pin exists.
const String seanceLicenseGateMarker = 'SEANCE_LICENSE_GATE_V1';

const String _releaseWorkflowPath = '.github/workflows/release.yml';
const String _gateInvocation = 'dart run tool/license_gate/bin/check.dart';
const String _releaseAction = 'softprops/action-gh-release@';
const String _spdxRepository = 'https://github.com/spdx/license-list-data.git';
const String _spdxRevision = 'c4a7237ec8f4654e867546f9f409749300f1bf4c';
const Set<String> _permittedLicenseIds = {
  'Unlicense',
  'MIT',
  'Apache-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'ISC',
};
const Set<String> _licenseFileNames = {
  'LICENSE',
  'LICENSE.txt',
  'LICENSE.md',
  'LICENCE',
  'UNLICENSE',
  'COPYING',
};
const Set<String> _seancePackageNames = {'seance_core', 'seance_protocol'};
const Set<String> _permittedCopyrightHolders = {'L-K-M'};
const Set<String> _ignoredDirectoryNames = {
  '.dart_tool',
  '.git',
  '.plugin_symlinks',
  '.symlinks',
  'build',
  'ephemeral',
  'Pods',
};

final RegExp _gitRevisionPattern = RegExp(r'^[0-9a-fA-F]{40,64}$');
final RegExp _copyrightPrefixPattern = RegExp(
  r'^\s*(?:[#*;/<>\-]+\s*)?copyright\s*:?\s*',
  caseSensitive: false,
);
final RegExp _copyrightYearPattern = RegExp(
  r'^(?:\d{4}|\[yyyy\]|<year>)(?:\s*[-–,]\s*\d{2,4})?(?:\s+|$)',
  caseSensitive: false,
);
const Set<String> _copyrightPlaceholders = {
  '<copyright holder>',
  '<copyright holders>',
  '<owner>',
  '[name of copyright owner]',
};

enum LicenseGateMode {
  /// Checks the CI marker and declaration-to-lock resolution only.
  markerOnly,

  /// Also validates every pinned tree against the SPDX allowlist.
  release,
}

/// Sources are injectable so gate tests stay local and deterministic.
final class LicenseGateSettings {
  final String spdxRepository;
  final String spdxRevision;
  final Set<String> permittedLicenseIds;
  final Set<String> permittedCopyrightHolders;

  const LicenseGateSettings({
    this.spdxRepository = _spdxRepository,
    this.spdxRevision = _spdxRevision,
    this.permittedLicenseIds = _permittedLicenseIds,
    this.permittedCopyrightHolders = _permittedCopyrightHolders,
  });
}

final class LicenseGateReport {
  final int declarationCount;
  final int pinnedRevisionCount;
  final Set<String> matchedLicenseIds;

  const LicenseGateReport({
    required this.declarationCount,
    required this.pinnedRevisionCount,
    required this.matchedLicenseIds,
  });
}

final class LicenseGateException implements Exception {
  final String message;

  const LicenseGateException(this.message);

  @override
  String toString() => message;
}

/// Verifies the D30 marker, lock resolution, and pinned-tree license content.
Future<LicenseGateReport> verifySeanceLicenseGate({
  required Directory repositoryRoot,
  required LicenseGateMode mode,
  LicenseGateSettings settings = const LicenseGateSettings(),
}) async {
  final root = Directory(p.normalize(p.absolute(repositoryRoot.path)));
  if (!root.existsSync()) {
    throw LicenseGateException('repository root does not exist: ${root.path}');
  }

  final pubspecFiles = _findFiles(root, 'pubspec.yaml');
  final lockFiles = _findFiles(root, 'pubspec.lock');
  final declarations = <_GitDeclaration>[
    for (final pubspec in pubspecFiles) ..._readDeclarations(pubspec),
  ];
  final workspaceLocks = _readWorkspaceLocks(pubspecFiles);
  final locks = <String, _LockFile>{
    for (final file in lockFiles)
      p.normalize(p.absolute(file.path)): _readLock(file),
  };

  _verifyDeclarationResolution(declarations, locks, workspaceLocks);

  final pins = <_GitPin>{for (final lock in locks.values) ...lock.seancePins};
  await _verifyCommittedLocks(root, declarations, locks, workspaceLocks);
  _verifyWorkflowGate(root, declarations.isNotEmpty || pins.isNotEmpty);

  if (mode == LicenseGateMode.markerOnly || pins.isEmpty) {
    return LicenseGateReport(
      declarationCount: declarations.length,
      pinnedRevisionCount: pins.length,
      matchedLicenseIds: const {},
    );
  }

  final canonical = await _loadCanonicalLicenses(settings);
  final matchedLicenseIds = <String>{};
  for (final pin in pins) {
    final snapshot = await _GitSnapshot.fetch(pin.url, pin.revision);
    try {
      final found = <String>[];
      for (final fileName in _licenseFileNames) {
        final text = await snapshot.read(fileName);
        if (text == null) continue;

        found.add(fileName);
        final licenseId = _matchLicense(
          text,
          canonical,
          settings.permittedCopyrightHolders,
        );
        if (licenseId == null) {
          throw LicenseGateException(
            '${pin.packageName} at ${pin.revision} has a non-permitted '
            '$fileName',
          );
        }
        matchedLicenseIds.add(licenseId);
      }

      if (found.isEmpty) {
        throw LicenseGateException(
          '${pin.packageName} at ${pin.revision} has no recognized license '
          'file',
        );
      }
    } finally {
      await snapshot.dispose();
    }
  }

  return LicenseGateReport(
    declarationCount: declarations.length,
    pinnedRevisionCount: pins.length,
    matchedLicenseIds: matchedLicenseIds,
  );
}

List<File> _findFiles(Directory root, String fileName) {
  final found = <File>[];
  final pending = <Directory>[root];

  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        if (name == '.git') {
          continue;
        }
        if (_ignoredDirectoryNames.contains(name) &&
            !_containsTrackedFiles(root, entity)) {
          continue;
        }

        pending.add(entity);
        continue;
      }
      if (entity is Link) {
        final targetType = FileSystemEntity.typeSync(
          entity.path,
          followLinks: true,
        );
        if (p.basename(entity.path) != fileName &&
            targetType != FileSystemEntityType.directory) {
          continue;
        }

        throw LicenseGateException(
          '${entity.path}: dependency trees must not use symbolic links',
        );
      }
      if (entity is File && p.basename(entity.path) == fileName) {
        found.add(entity);
      }
    }
  }

  found.sort((left, right) => left.path.compareTo(right.path));
  return found;
}

bool _containsTrackedFiles(Directory root, Directory directory) {
  final relativePath = p
      .relative(directory.path, from: root.path)
      .replaceAll('\\', '/');
  final result = Process.runSync(
    'git',
    ['-C', root.path, 'ls-files', '--', relativePath],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode == 0) {
    return (result.stdout as String).trim().isNotEmpty;
  }

  throw LicenseGateException(
    'git ls-files failed: ${(result.stderr as String).trim()}',
  );
}

List<_GitDeclaration> _readDeclarations(File pubspec) {
  final document = _readYamlMap(pubspec);
  final declarations = <_GitDeclaration>[];

  for (final sectionName in const {
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  }) {
    final section = _asMap(document[sectionName]);
    if (section == null) continue;

    for (final entry in section.entries) {
      final packageName = entry.key;
      final specification = _asMap(entry.value);
      if (packageName is! String || specification == null) continue;

      final git = specification['git'];
      if (git == null) continue;

      final url = switch (git) {
        final String value => value,
        final Map<Object?, Object?> value => value['url'],
        _ => null,
      };
      if (url is! String) {
        if (_seancePackageNames.contains(packageName)) {
          throw LicenseGateException(
            '${pubspec.path}: $packageName has a git dependency without a '
            'URL',
          );
        }
        continue;
      }
      if (!_isSeanceDependency(packageName, url)) continue;

      final gitDetails = _asMap(git);
      final ref = gitDetails?['ref'];
      final path = gitDetails?['path'];
      if (ref is! String || ref.isEmpty) {
        throw LicenseGateException(
          '${pubspec.path}: $packageName must pin a git ref',
        );
      }
      if (path is! String || path.isEmpty) {
        throw LicenseGateException(
          '${pubspec.path}: $packageName must select a package path',
        );
      }

      declarations.add(
        _GitDeclaration(
          packageName: packageName,
          pubspec: pubspec,
          url: url,
          ref: ref,
          path: path,
        ),
      );
    }
  }

  return declarations;
}

_LockFile _readLock(File file) {
  final document = _readYamlMap(file);
  final packages = _asMap(document['packages']);
  if (packages == null) {
    throw LicenseGateException('${file.path}: missing packages map');
  }

  final pins = <_GitPin>[];
  for (final entry in packages.entries) {
    final packageName = entry.key;
    final specification = _asMap(entry.value);
    if (packageName is! String || specification == null) continue;
    if (specification['source'] != 'git') continue;

    final description = _asMap(specification['description']);
    final url = description?['url'];
    if (url is! String || !_isSeanceDependency(packageName, url)) continue;

    final revision = description?['resolved-ref'];
    if (revision is! String || !_gitRevisionPattern.hasMatch(revision)) {
      throw LicenseGateException(
        '${file.path}: $packageName has no full resolved-ref',
      );
    }

    pins.add(
      _GitPin(
        packageName: packageName,
        url: url,
        revision: revision.toLowerCase(),
      ),
    );
  }

  return _LockFile(file: file, packages: packages, seancePins: pins);
}

void _verifyDeclarationResolution(
  List<_GitDeclaration> declarations,
  Map<String, _LockFile> locks,
  Map<String, String> workspaceLocks,
) {
  for (final declaration in declarations) {
    final lockPath = _lockPathForDeclaration(declaration, workspaceLocks);
    final lock = locks[p.normalize(lockPath)];
    if (lock == null) {
      throw LicenseGateException(
        '${declaration.pubspec.path}: ${declaration.packageName} is not '
        'covered by a pubspec.lock',
      );
    }

    final specification = _asMap(lock.packages[declaration.packageName]);
    final description = _asMap(specification?['description']);
    final lockedUrl = description?['url'];
    final lockedRef = description?['ref'];
    final lockedPath = description?['path'];
    final revision = description?['resolved-ref'];
    final resolved =
        specification?['source'] == 'git' &&
        lockedUrl is String &&
        lockedUrl == declaration.url &&
        lockedRef == declaration.ref &&
        lockedPath == declaration.path &&
        revision is String &&
        _gitRevisionPattern.hasMatch(revision);
    if (resolved) continue;

    throw LicenseGateException(
      '${declaration.pubspec.path}: ${declaration.packageName} is not '
      'resolved by ${lock.file.path}',
    );
  }
}

String _lockPathForDeclaration(
  _GitDeclaration declaration,
  Map<String, String> workspaceLocks,
) {
  final pubspecDirectory = p.normalize(
    p.absolute(declaration.pubspec.parent.path),
  );
  return workspaceLocks[pubspecDirectory] ??
      p.join(pubspecDirectory, 'pubspec.lock');
}

Map<String, String> _readWorkspaceLocks(List<File> pubspecFiles) {
  final locks = <String, String>{};
  for (final pubspec in pubspecFiles) {
    final document = _readYamlMap(pubspec);
    final members = _asList(document['workspace']);
    if (members == null) continue;

    final workspaceRoot = p.normalize(p.absolute(pubspec.parent.path));
    final lockPath = p.join(workspaceRoot, 'pubspec.lock');
    for (final member in members) {
      if (member is! String) continue;

      final memberPath = p.normalize(p.join(workspaceRoot, member));
      final previous = locks[memberPath];
      if (previous != null && previous != lockPath) {
        throw LicenseGateException(
          '$memberPath belongs to more than one pub workspace',
        );
      }
      locks[memberPath] = lockPath;
    }
  }
  return locks;
}

Future<void> _verifyCommittedLocks(
  Directory root,
  List<_GitDeclaration> declarations,
  Map<String, _LockFile> locks,
  Map<String, String> workspaceLocks,
) async {
  final relevantPaths = <String>{
    for (final declaration in declarations)
      p.normalize(_lockPathForDeclaration(declaration, workspaceLocks)),
    for (final lock in locks.values)
      if (lock.seancePins.isNotEmpty) p.normalize(p.absolute(lock.file.path)),
  };
  if (relevantPaths.isEmpty) return;

  final topLevel = (await _runRepositoryGit(root, const [
    'rev-parse',
    '--show-toplevel',
  ])).trim();
  if (p.normalize(p.absolute(topLevel)) != root.path) {
    throw const LicenseGateException(
      'repository root must be the Git worktree root',
    );
  }

  for (final lockPath in relevantPaths) {
    final relativePath = p
        .relative(lockPath, from: root.path)
        .replaceAll('\\', '/');
    final tracked = await Process.run(
      'git',
      ['-C', root.path, 'ls-files', '--error-unmatch', '--', relativePath],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final status = await _runRepositoryGit(root, [
      'status',
      '--porcelain=v1',
      '--untracked-files=all',
      '--',
      relativePath,
    ]);
    if (tracked.exitCode == 0 && status.trim().isEmpty) continue;

    throw LicenseGateException(
      '$relativePath must be committed and clean after dependency resolution',
    );
  }
}

Future<String> _runRepositoryGit(Directory root, List<String> arguments) async {
  final result = await Process.run(
    'git',
    ['-C', root.path, ...arguments],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode == 0) return result.stdout as String;

  throw LicenseGateException(
    'git ${arguments.first} failed: ${(result.stderr as String).trim()}',
  );
}

void _verifyWorkflowGate(Directory root, bool required) {
  final workflow = File(p.join(root.path, _releaseWorkflowPath));
  if (!workflow.existsSync()) {
    if (!required) return;

    throw const LicenseGateException(
      'release.yml is missing the required Séance license gate',
    );
  }

  final text = workflow.readAsStringSync();
  final mentionsGate =
      text.contains(seanceLicenseGateMarker) || text.contains(_gateInvocation);
  if (!required && !mentionsGate) return;
  final markerPattern = RegExp(
    '^\\s*(?:-\\s+)?run:\\s*${RegExp.escape(_gateInvocation)}\\s+'
    '#\\s*${RegExp.escape(seanceLicenseGateMarker)}\\s*\$',
    multiLine: true,
  );
  if (markerPattern.allMatches(text).length != 1) {
    throw const LicenseGateException(
      'release.yml is missing the required active license-gate marker',
    );
  }

  final document = _readYamlMap(workflow);
  final jobs = _asMap(document['jobs']);
  if (jobs == null) {
    throw const LicenseGateException('release.yml has no jobs map');
  }

  String? gateJobName;
  int? gateStepIndex;
  var gateJobCount = 0;
  for (final entry in jobs.entries) {
    final jobName = entry.key;
    final job = _asMap(entry.value);
    if (jobName is! String || job == null) continue;

    final steps = _asList(job['steps']);
    if (steps == null) continue;
    var dependencyResolutionSeen = false;
    var gateSeen = false;
    for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
      final stepValue = steps[stepIndex];
      final step = _asMap(stepValue);
      if (step == null) continue;

      final run = step['run'];
      if (run is! String) continue;
      if (gateSeen &&
          (_runsDependencyResolution(run) || _runsFlutterBuildWithPub(run))) {
        throw const LicenseGateException(
          'release.yml resolves dependencies after the license gate',
        );
      }
      if (_runsDependencyResolution(run)) dependencyResolutionSeen = true;
      if (run.trim() != _gateInvocation) continue;

      gateSeen = true;
      gateJobCount += 1;
      gateJobName = jobName;
      gateStepIndex = stepIndex;
      if (job['if'] != null ||
          job['continue-on-error'] != null ||
          step['if'] != null ||
          step['continue-on-error'] != null) {
        throw const LicenseGateException(
          'release.yml license gate must be unconditional and fail closed',
        );
      }
      if (!dependencyResolutionSeen) {
        throw const LicenseGateException(
          'release.yml runs the license gate before dependency resolution',
        );
      }
    }
  }
  if (gateJobCount != 1 || gateJobName == null || gateStepIndex == null) {
    throw const LicenseGateException(
      'release.yml must contain exactly one license-gate invocation',
    );
  }

  for (final entry in jobs.entries) {
    final jobName = entry.key;
    final job = _asMap(entry.value);
    if (jobName is! String || job == null) continue;
    final steps = _asList(job['steps']);
    if (steps == null) continue;
    for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
      final step = _asMap(steps[stepIndex]);
      final uses = step?['uses'];
      if (uses is! String || !uses.startsWith(_releaseAction)) continue;

      if (job['if'] != null ||
          job['continue-on-error'] != null ||
          step?['if'] != null ||
          step?['continue-on-error'] != null) {
        throw LicenseGateException(
          'release publisher job $jobName can bypass failed prerequisites',
        );
      }
      if (jobName == gateJobName && stepIndex > gateStepIndex) continue;

      throw LicenseGateException(
        'release publisher job $jobName bypasses the license gate',
      );
    }
  }
}

bool _runsDependencyResolution(String command) {
  final pubGet = RegExp(r'^(?:dart|flutter)\s+pub\s+get(?:\s+.*)?$');
  return command
      .split(RegExp(r'\r?\n'))
      .any((line) => pubGet.hasMatch(line.trim()));
}

Future<Map<String, String>> _loadCanonicalLicenses(
  LicenseGateSettings settings,
) async {
  if (!_gitRevisionPattern.hasMatch(settings.spdxRevision)) {
    throw const LicenseGateException('SPDX revision must be a full commit');
  }

  final snapshot = await _GitSnapshot.fetch(
    settings.spdxRepository,
    settings.spdxRevision,
  );
  try {
    final canonical = <String, String>{};
    for (final licenseId in settings.permittedLicenseIds) {
      final text = await snapshot.read('text/$licenseId.txt');
      if (text == null) {
        throw LicenseGateException(
          'SPDX revision is missing text/$licenseId.txt',
        );
      }
      canonical[licenseId] = _normalizeLicense(
        text,
        copyrightSource: _CopyrightSource.canonical,
      );
    }
    return canonical;
  } finally {
    await snapshot.dispose();
  }
}

bool _runsFlutterBuildWithPub(String command) {
  final flutterBuild = RegExp(r'^flutter\s+build\b');
  return command.split(RegExp(r'\r?\n')).any((line) {
    final trimmed = line.trim();
    return flutterBuild.hasMatch(trimmed) && !trimmed.contains('--no-pub');
  });
}

String? _matchLicense(
  String text,
  Map<String, String> canonical,
  Set<String> permittedCopyrightHolders,
) {
  final normalized = _normalizeLicense(
    text,
    copyrightSource: _CopyrightSource.candidate,
    permittedCopyrightHolders: permittedCopyrightHolders,
  );
  for (final entry in canonical.entries) {
    if (entry.value == normalized) return entry.key;
  }
  return null;
}

enum _CopyrightSource { canonical, candidate }

String _normalizeLicense(
  String text, {
  required _CopyrightSource copyrightSource,
  Set<String> permittedCopyrightHolders = const {},
}) {
  final withoutBom = text.startsWith('\ufeff') ? text.substring(1) : text;
  final lines = withoutBom.split(RegExp(r'\r\n?|\n'));
  final substantive = lines.where(
    (line) =>
        !_isCopyrightNotice(line, copyrightSource, permittedCopyrightHolders),
  );
  return substantive.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _isCopyrightNotice(
  String line,
  _CopyrightSource source,
  Set<String> permittedCopyrightHolders,
) {
  final prefix = _copyrightPrefixPattern.firstMatch(line);
  if (prefix == null) return false;

  var remainder = line.substring(prefix.end).trim();
  var hasMarker = false;
  for (final marker in const ['(c)', '©']) {
    if (!remainder.toLowerCase().startsWith(marker)) continue;

    hasMarker = true;
    remainder = remainder.substring(marker.length).trimLeft();
    break;
  }

  final year = _copyrightYearPattern.firstMatch(remainder);
  if (year != null) remainder = remainder.substring(year.end).trim();
  if (!hasMarker && year == null) return false;

  remainder = remainder
      .replaceFirst(RegExp(r'\s*[#*;/<>\-]+\s*$'), '')
      .replaceFirst(
        RegExp(r'\.?\s+all rights reserved\.?$', caseSensitive: false),
        '',
      )
      .trim();
  if (source == _CopyrightSource.canonical) return true;
  if (remainder.isEmpty) return true;

  final placeholder = _normalizeCopyrightHolder(remainder);
  if (_copyrightPlaceholders.contains(placeholder)) return true;
  return permittedCopyrightHolders
      .map(_normalizeCopyrightHolder)
      .contains(placeholder);
}

String _normalizeCopyrightHolder(String holder) => holder
    .replaceFirst(RegExp(r'[.]$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

Map<Object?, Object?> _readYamlMap(File file) {
  try {
    final document = loadYaml(file.readAsStringSync());
    final mapping = _asMap(document);
    if (mapping != null) return mapping;
  } on Object catch (error) {
    throw LicenseGateException('${file.path}: invalid YAML: $error');
  }
  throw LicenseGateException('${file.path}: expected a YAML map');
}

Map<Object?, Object?>? _asMap(Object? value) {
  if (value is YamlMap) return value;
  if (value is Map<Object?, Object?>) return value;
  return null;
}

List<Object?>? _asList(Object? value) {
  if (value is YamlList) return value;
  if (value is List<Object?>) return value;
  return null;
}

bool _isSeanceDependency(String packageName, String url) {
  if (_seancePackageNames.contains(packageName) ||
      packageName.startsWith('seance_')) {
    return true;
  }

  final normalized = url.replaceAll('\\', '/').toLowerCase();
  return normalized.endsWith('/seance') ||
      normalized.endsWith('/seance.git') ||
      normalized == 'seance' ||
      normalized == 'seance.git';
}

final class _GitDeclaration {
  final String packageName;
  final File pubspec;
  final String url;
  final String ref;
  final String path;

  const _GitDeclaration({
    required this.packageName,
    required this.pubspec,
    required this.url,
    required this.ref,
    required this.path,
  });
}

final class _LockFile {
  final File file;
  final Map<Object?, Object?> packages;
  final List<_GitPin> seancePins;

  const _LockFile({
    required this.file,
    required this.packages,
    required this.seancePins,
  });
}

final class _GitPin {
  final String packageName;
  final String url;
  final String revision;

  const _GitPin({
    required this.packageName,
    required this.url,
    required this.revision,
  });

  @override
  bool operator ==(Object other) =>
      other is _GitPin && other.url == url && other.revision == revision;

  @override
  int get hashCode => Object.hash(url, revision);
}

final class _GitSnapshot {
  final Directory _directory;

  const _GitSnapshot._(this._directory);

  static Future<_GitSnapshot> fetch(String url, String revision) async {
    if (!_gitRevisionPattern.hasMatch(revision)) {
      throw LicenseGateException(
        'Git revision must be a full commit: $revision',
      );
    }

    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-license-gate-',
    );
    try {
      await _runGit(directory, const ['init', '--quiet']);
      await _runGit(directory, ['remote', 'add', 'origin', url]);
      await _runGit(directory, [
        '-c',
        'protocol.file.allow=always',
        'fetch',
        '--quiet',
        '--depth=1',
        'origin',
        revision,
      ]);

      final resolved = (await _runGit(directory, const [
        'rev-parse',
        'FETCH_HEAD',
      ])).trim().toLowerCase();
      if (resolved != revision.toLowerCase()) {
        throw LicenseGateException(
          'Git fetched $resolved instead of requested $revision',
        );
      }
      return _GitSnapshot._(directory);
    } on Object {
      await _deleteTemporaryDirectory(directory);
      rethrow;
    }
  }

  Future<String?> read(String path) async {
    final result = await Process.run(
      'git',
      ['show', 'FETCH_HEAD:$path'],
      workingDirectory: _directory.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode == 0) return result.stdout as String;

    final stderr = result.stderr as String;
    if (stderr.contains('does not exist in') ||
        stderr.contains('exists on disk, but not in')) {
      return null;
    }
    throw LicenseGateException('git show failed for $path: ${stderr.trim()}');
  }

  Future<void> dispose() => _deleteTemporaryDirectory(_directory);

  static Future<String> _runGit(
    Directory directory,
    List<String> arguments,
  ) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: directory.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode == 0) return result.stdout as String;

    throw LicenseGateException(
      'git ${arguments.first} failed: ${(result.stderr as String).trim()}',
    );
  }
}

Future<void> _deleteTemporaryDirectory(Directory directory) async {
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } on FileSystemException {
    // The gate result matters more than best-effort cleanup of its temp clone.
  }
}
