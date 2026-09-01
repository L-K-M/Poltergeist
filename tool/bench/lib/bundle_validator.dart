import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'result_aggregator.dart';
import 'result_manifest.dart';

const reportDigestMarkerPrefix = '<!-- m0-evidence-sha256: ';
const reportEvidenceStateMarkerPrefix = '<!-- m0-evidence-state: ';
const reportEvidencePendingMarker =
    '${reportEvidenceStateMarkerPrefix}pending -->';
const reportEvidenceRequiredMarker =
    '${reportEvidenceStateMarkerPrefix}required -->';
const reportResultMappingStartMarker = '<!-- m0-result-map-start -->';
const reportResultMappingEndMarker = '<!-- m0-result-map-end -->';
const _measurementAffectingPaths = [
  '.github/workflows/ci.yml',
  'docs/plan/07-MILESTONES.md',
  'docs/plan/08-TESTING.md',
  'packages',
  'pubspec.lock',
  'pubspec.yaml',
  'test/integration',
  'tool/bench',
];
const _reportResultHeader = '| Scenario | Bytes | Elapsed µs | Note |';
const _reportResultDivider = '|---|---:|---:|---|';
final _evidenceStateMarker = RegExp(
  '${RegExp.escape(reportEvidenceStateMarkerPrefix)}([a-z]+) -->',
);
final _digestMarker = RegExp(
  '${RegExp.escape(reportDigestMarkerPrefix)}([0-9a-f]{64}) -->',
);
final _sumLine = RegExp(r'^([0-9a-f]{64})  ([^\r\n]+)$');
final _gitObjectPattern = RegExp(r'^[0-9a-f]{40}$');

enum BundleValidationOutcome { neutral, valid }

enum _ReportEvidenceState { pending, required }

class BundleValidationException implements Exception {
  final String message;

  const BundleValidationException(this.message);

  @override
  String toString() => message;
}

abstract interface class MeasurementDiffChecker {
  Future<void> ensureUnchanged({
    required String repositoryRoot,
    required String recordedSha,
    required String fixtureTree,
    required String canonicalPath,
    required String reportPath,
  });
}

class GitMeasurementDiffChecker implements MeasurementDiffChecker {
  const GitMeasurementDiffChecker();

  @override
  Future<void> ensureUnchanged({
    required String repositoryRoot,
    required String recordedSha,
    required String fixtureTree,
    required String canonicalPath,
    required String reportPath,
  }) async {
    if (!_gitObjectPattern.hasMatch(recordedSha) ||
        !_gitObjectPattern.hasMatch(fixtureTree)) {
      throw const BundleValidationException(
        'Recorded commit and fixture tree must be Git object IDs.',
      );
    }
    await _requireGitSuccess(repositoryRoot, [
      'cat-file',
      '-e',
      '$recordedSha^{commit}',
    ], 'Recorded measurement commit does not exist.');
    final canonicalRelative = await _repositoryRelativeFile(
      repositoryRoot,
      canonicalPath,
    );
    final reportRelative = await _repositoryRelativeFile(
      repositoryRoot,
      reportPath,
    );
    final evidenceBoundary = await _resolveEvidenceBoundary(
      repositoryRoot: repositoryRoot,
      canonicalRelative: canonicalRelative,
      reportRelative: reportRelative,
    );
    final recordedFixtureTree = await _requireGitOutput(repositoryRoot, [
      'rev-parse',
      '--verify',
      '$recordedSha:test/integration',
    ], 'Recorded fixture tree does not exist.');
    if (recordedFixtureTree != fixtureTree) {
      throw const BundleValidationException(
        'Canonical fixture tree does not match the recorded commit.',
      );
    }
    await _requireGitSuccess(repositoryRoot, [
      'merge-base',
      '--is-ancestor',
      recordedSha,
      evidenceBoundary,
    ], 'Evidence predates the recorded measurement commit.');
    await _requireGitSuccess(repositoryRoot, [
      'merge-base',
      '--is-ancestor',
      evidenceBoundary,
      'HEAD',
    ], 'Evidence introduction commit is not an ancestor of HEAD.');
    final diff = await Process.run('git', [
      '-C',
      repositoryRoot,
      'diff',
      '--quiet',
      recordedSha,
      evidenceBoundary,
      '--',
      ..._measurementAffectingPaths,
    ]);
    if (diff.exitCode == 1) {
      throw const BundleValidationException(
        'Measurement-affecting files changed before evidence capture.',
      );
    }
    if (diff.exitCode != 0) {
      throw BundleValidationException(
        'git diff failed: ${'${diff.stderr}'.trim()}.',
      );
    }
    final bundleDiff = await Process.run('git', [
      '-C',
      repositoryRoot,
      'diff',
      '--quiet',
      evidenceBoundary,
      '--',
      _parentGitPath(canonicalRelative),
    ]);
    if (bundleDiff.exitCode == 1) {
      throw const BundleValidationException(
        'Committed evidence changed after its introduction commit.',
      );
    }
    if (bundleDiff.exitCode != 0) {
      throw BundleValidationException(
        'git evidence diff failed: ${'${bundleDiff.stderr}'.trim()}.',
      );
    }
  }
}

Future<BundleValidationOutcome> validateCommittedEvidence({
  required String bundleDirectory,
  required String reportPath,
  required String repositoryRoot,
  MeasurementDiffChecker diffChecker = const GitMeasurementDiffChecker(),
}) async {
  final bundle = Directory(bundleDirectory);
  final report = File(reportPath);
  final reportText = await report.exists() ? await report.readAsString() : '';
  final reportState = _parseReportEvidenceState(reportText);
  final markers = _digestMarker.allMatches(reportText).toList();
  final digestPrefixCount = _markerOffsets(
    reportText,
    reportDigestMarkerPrefix,
  ).length;
  final hasResultMapping =
      reportText.contains(reportResultMappingStartMarker) ||
      reportText.contains(reportResultMappingEndMarker);
  final bundleExists = await bundle.exists();
  final bundleIsFile = await File(bundleDirectory).exists();
  if (reportState == _ReportEvidenceState.pending) {
    if (!bundleExists &&
        !bundleIsFile &&
        digestPrefixCount == 0 &&
        !hasResultMapping) {
      return BundleValidationOutcome.neutral;
    }

    throw const BundleValidationException(
      'Pending report state cannot include committed evidence.',
    );
  }
  if (!bundleExists) {
    if (bundleIsFile) {
      throw const BundleValidationException(
        'Evidence bundle path is not a directory.',
      );
    }

    throw const BundleValidationException(
      'Required report state needs a committed evidence bundle.',
    );
  }
  if (digestPrefixCount != 1 || markers.length != 1) {
    throw const BundleValidationException(
      'A present evidence bundle needs exactly one report digest marker.',
    );
  }

  await validateBundleDigests(bundle.path);
  await _validateBundleLayout(bundle.path);
  final canonical = File('${bundle.path}/$canonicalEvidenceFileName');
  final canonicalBytes = await canonical.readAsBytes();
  final canonicalDigest = sha256.convert(canonicalBytes).toString();
  if (markers.single.group(1) != canonicalDigest) {
    throw const BundleValidationException(
      'Report digest does not match canonical evidence.',
    );
  }
  final canonicalJson = _decodeObject(canonicalBytes, canonical.path);
  final identity = _objectField(canonicalJson, 'identity');
  final fixture = _objectField(identity, 'fixture');
  final recordedSha = _stringField(identity, 'poltergeistSha');
  final fixtureTree = _stringField(fixture, 'tree');
  final runId = _stringField(identity, 'workflowRunId');
  final runAttempt = _integerField(identity, 'workflowRunAttempt');
  validateReportResultMapping(
    reportText: reportText,
    canonicalResults: _objectListField(canonicalJson, 'results'),
  );
  await _reaggregate(
    bundle.path,
    expectedCanonical: canonicalBytes,
    recordedSha: recordedSha,
    runId: runId,
    runAttempt: runAttempt,
  );
  await diffChecker.ensureUnchanged(
    repositoryRoot: repositoryRoot,
    recordedSha: recordedSha,
    fixtureTree: fixtureTree,
    canonicalPath: canonical.path,
    reportPath: report.path,
  );

  return BundleValidationOutcome.valid;
}

/// Renders the exact canonical projection copied into the final report.
String renderReportResultMapping(List<Map<String, Object?>> canonicalResults) {
  final output = StringBuffer()
    ..writeln(reportResultMappingStartMarker)
    ..writeln(_reportResultHeader)
    ..writeln(_reportResultDivider);
  for (final result in canonicalResults) {
    final projected = _reportResult(result);
    output.writeln(
      '| ${_markdownCell(projected['scenario'])} '
      '| ${projected['bytes']} '
      '| ${projected['elapsedUs']} '
      '| ${_markdownCell(projected['note'])} |',
    );
  }
  output.write(reportResultMappingEndMarker);

  return '$output';
}

/// Rejects a report whose visible result map differs from canonical evidence.
void validateReportResultMapping({
  required String reportText,
  required List<Map<String, Object?>> canonicalResults,
}) {
  final starts = _markerOffsets(reportText, reportResultMappingStartMarker);
  final ends = _markerOffsets(reportText, reportResultMappingEndMarker);
  if (starts.length != 1 || ends.length != 1) {
    throw const BundleValidationException(
      'Required report state needs exactly one canonical result map.',
    );
  }
  final contentStart = starts.single + reportResultMappingStartMarker.length;
  final contentEnd = ends.single;
  if (contentStart >= contentEnd) {
    throw const BundleValidationException('Report result map is malformed.');
  }
  final reported = reportText.substring(
    starts.single,
    contentEnd + reportResultMappingEndMarker.length,
  );
  final expected = renderReportResultMapping(canonicalResults);
  if (reported != expected) {
    throw const BundleValidationException(
      'Report scenario/value map does not match canonical evidence.',
    );
  }
}

_ReportEvidenceState _parseReportEvidenceState(String reportText) {
  final matches = _evidenceStateMarker.allMatches(reportText).toList();
  final prefixCount = _markerOffsets(
    reportText,
    reportEvidenceStateMarkerPrefix,
  ).length;
  if (prefixCount != 1 || matches.length != 1) {
    throw const BundleValidationException(
      'Report needs exactly one M0 evidence state marker.',
    );
  }
  final value = matches.single.group(1);
  for (final state in _ReportEvidenceState.values) {
    if (state.name == value) return state;
  }

  throw BundleValidationException('Unknown report evidence state: $value.');
}

Map<String, Object?> _reportResult(Map<String, Object?> result) {
  final scenario = result['scenario'];
  final bytes = result['bytes'];
  final elapsedUs = result['elapsedUs'];
  final note = result['note'];
  if (scenario is! String ||
      scenario.isEmpty ||
      bytes is! int ||
      elapsedUs is! int ||
      (note != null && note is! String)) {
    throw const BundleValidationException(
      'Report result fields have invalid types.',
    );
  }

  return {
    'scenario': scenario,
    'bytes': bytes,
    'elapsedUs': elapsedUs,
    'note': note,
  };
}

String _markdownCell(Object? value) {
  if (value == null) return 'null';

  return '$value'
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('&', '&amp;')
      .replaceAll('|', '&#124;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('\n', '<br>');
}

List<int> _markerOffsets(String text, String marker) {
  final offsets = <int>[];
  var start = 0;
  while (true) {
    final offset = text.indexOf(marker, start);
    if (offset == -1) return offsets;
    offsets.add(offset);
    start = offset + marker.length;
  }
}

Future<void> _validateBundleLayout(String bundleDirectory) async {
  final root = Directory(bundleDirectory).absolute;
  final expected = <String>{
    canonicalEvidenceFileName,
    sha256ManifestFileName,
    for (final source in m0SourceManifest)
      '$rawEvidenceDirectoryName/${source.id}.json',
  };
  final actual = <String>{};
  final directories = <String>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File) actual.add(_relativePath(root.path, entity.path));
    if (entity is Directory) {
      directories.add(_relativePath(root.path, entity.path));
    }
  }
  if (!_setEquals(actual, expected) ||
      !_setEquals(directories, const {rawEvidenceDirectoryName})) {
    throw const BundleValidationException('Evidence bundle layout is invalid.');
  }
}

Future<void> validateBundleDigests(String bundleDirectory) async {
  final root = Directory(bundleDirectory).absolute;
  final manifest = File('${root.path}/$sha256ManifestFileName');
  if (!await manifest.exists()) {
    throw const BundleValidationException('Evidence SHA256SUMS is absent.');
  }
  final lines = await manifest.readAsLines();
  if (lines.isEmpty || lines.any((line) => line.isEmpty)) {
    throw const BundleValidationException('Evidence SHA256SUMS is malformed.');
  }
  final listed = <String>[];
  final digests = <String, String>{};
  for (final line in lines) {
    final match = _sumLine.firstMatch(line);
    if (match == null) {
      throw const BundleValidationException(
        'Evidence SHA256SUMS is malformed.',
      );
    }
    final relativePath = match.group(2)!;
    if (!_safeRelativePath(relativePath) || digests.containsKey(relativePath)) {
      throw BundleValidationException('Invalid digest path: $relativePath.');
    }
    listed.add(relativePath);
    digests[relativePath] = match.group(1)!;
  }
  final sorted = [...listed]..sort();
  if (!_listEquals(listed, sorted)) {
    throw const BundleValidationException(
      'Evidence SHA256SUMS paths are not sorted.',
    );
  }
  final actualPaths = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is Link) {
      throw const BundleValidationException('Evidence bundle contains a link.');
    }
    if (entity is! File || entity.path == manifest.path) continue;
    actualPaths.add(_relativePath(root.path, entity.path));
  }
  actualPaths.sort();
  if (!_listEquals(listed, actualPaths)) {
    throw const BundleValidationException(
      'Evidence SHA256SUMS does not cover exactly every bundle file.',
    );
  }
  for (final relativePath in listed) {
    final bytes = await File(
      _platformPath(root.path, relativePath),
    ).readAsBytes();
    if (sha256.convert(bytes).toString() != digests[relativePath]) {
      throw BundleValidationException(
        'Evidence digest mismatch: $relativePath.',
      );
    }
  }
}

Future<void> _reaggregate(
  String bundleDirectory, {
  required List<int> expectedCanonical,
  required String recordedSha,
  required String runId,
  required int runAttempt,
}) async {
  final raw = Directory('$bundleDirectory/$rawEvidenceDirectoryName');
  final expectedRawNames = {
    for (final source in m0SourceManifest) '${source.id}.json',
  };
  if (!await raw.exists()) {
    throw const BundleValidationException('Raw evidence directory is absent.');
  }
  final entries = await raw.list(followLinks: false).toList();
  final rawNames = {
    for (final entity in entries)
      if (entity is File) _basename(entity.path),
  };
  if (entries.any((entity) => entity is! File) ||
      !_setEquals(rawNames, expectedRawNames)) {
    throw const BundleValidationException(
      'Raw evidence source set is invalid.',
    );
  }
  final temporary = await Directory.systemTemp.createTemp(
    'poltergeist-evidence-validation-',
  );
  try {
    final input = Directory('${temporary.path}/input');
    await input.create();
    for (final source in m0SourceManifest) {
      final artifact = Directory(
        '${input.path}/$sourceArtifactPrefix-${source.id}',
      );
      await artifact.create();
      await File(
        '${raw.path}/${source.id}.json',
      ).copy('${artifact.path}/$sourceEnvelopeFileName');
    }
    final regenerated = '${temporary.path}/regenerated';
    try {
      await aggregateEvidenceDirectory(
        inputRoot: input.path,
        outputDirectory: regenerated,
        expectedRunId: runId,
        expectedRunAttempt: runAttempt,
        expectedGitSha: recordedSha,
      );
    } on ResultAggregationException catch (error) {
      throw BundleValidationException('Canonical evidence is invalid: $error');
    }
    final regeneratedBytes = await File(
      '$regenerated/$canonicalEvidenceFileName',
    ).readAsBytes();
    if (!_bytesEqual(expectedCanonical, regeneratedBytes)) {
      throw const BundleValidationException(
        'Canonical evidence does not match its raw sources.',
      );
    }
  } finally {
    await temporary.delete(recursive: true);
  }
}

Future<String> _resolveEvidenceBoundary({
  required String repositoryRoot,
  required String canonicalRelative,
  required String reportRelative,
}) async {
  // The canonical file is added once, when pending evidence becomes durable.
  final output = await _requireGitOutput(repositoryRoot, [
    'log',
    '--format=%H',
    '--diff-filter=A',
    'HEAD',
    '--',
    canonicalRelative,
  ], 'Canonical evidence has no introduction commit.');
  final additions = const LineSplitter()
      .convert(output)
      .where((line) => line.isNotEmpty)
      .toList();
  if (additions.length != 1 || !_gitObjectPattern.hasMatch(additions.single)) {
    throw const BundleValidationException(
      'Canonical evidence needs one introduction commit.',
    );
  }
  final boundary = additions.single;
  final reportAtBoundary = await _requireGitOutput(repositoryRoot, [
    'show',
    '$boundary:$reportRelative',
  ], 'Evidence report is absent from its introduction commit.');
  if (_parseReportEvidenceState(reportAtBoundary) !=
      _ReportEvidenceState.required) {
    throw const BundleValidationException(
      'Evidence report was not required at its introduction commit.',
    );
  }

  return boundary;
}

Future<String> _repositoryRelativeFile(
  String repositoryRoot,
  String filePath,
) async {
  final root = await Directory(repositoryRoot).resolveSymbolicLinks();
  final file = await File(filePath).resolveSymbolicLinks();
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  if (!file.startsWith(prefix)) {
    throw const BundleValidationException(
      'Evidence paths must be inside the repository.',
    );
  }
  final relative = file
      .substring(prefix.length)
      .split(Platform.pathSeparator)
      .join('/');
  if (_safeRelativePath(relative)) return relative;

  throw const BundleValidationException('Evidence path is invalid.');
}

String _parentGitPath(String path) {
  final separator = path.lastIndexOf('/');
  if (separator > 0) return path.substring(0, separator);

  throw const BundleValidationException(
    'Canonical evidence must be inside a bundle directory.',
  );
}

Future<void> _requireGitSuccess(
  String repositoryRoot,
  List<String> arguments,
  String failure,
) async {
  final result = await Process.run('git', ['-C', repositoryRoot, ...arguments]);
  if (result.exitCode == 0) return;

  throw BundleValidationException(failure);
}

Future<String> _requireGitOutput(
  String repositoryRoot,
  List<String> arguments,
  String failure,
) async {
  final result = await Process.run('git', ['-C', repositoryRoot, ...arguments]);
  if (result.exitCode != 0) throw BundleValidationException(failure);
  final output = '${result.stdout}'.trim();
  if (output.isEmpty) throw BundleValidationException(failure);

  return output;
}

Map<String, Object?> _decodeObject(List<int> bytes, String label) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on Object catch (error) {
    throw BundleValidationException('$label is invalid JSON: $error.');
  }
  if (decoded is Map<Object?, Object?> &&
      decoded.keys.every((key) => key is String)) {
    return decoded.cast<String, Object?>();
  }

  throw BundleValidationException('$label must be a JSON object.');
}

Map<String, Object?> _objectField(Map<String, Object?> value, String field) {
  final nested = value[field];
  if (nested is Map<Object?, Object?> &&
      nested.keys.every((key) => key is String)) {
    return nested.cast<String, Object?>();
  }

  throw BundleValidationException('$field must be an object.');
}

List<Map<String, Object?>> _objectListField(
  Map<String, Object?> value,
  String field,
) {
  final nested = value[field];
  if (nested is! List<Object?>) {
    throw BundleValidationException('$field must be an array.');
  }
  final objects = <Map<String, Object?>>[];
  for (final item in nested) {
    if (item is! Map<Object?, Object?> ||
        !item.keys.every((key) => key is String)) {
      throw BundleValidationException('$field must contain objects.');
    }
    objects.add(item.cast<String, Object?>());
  }

  return objects;
}

String _stringField(Map<String, Object?> value, String field) {
  final nested = value[field];
  if (nested is String && nested.isNotEmpty) return nested;

  throw BundleValidationException('$field must be a string.');
}

int _integerField(Map<String, Object?> value, String field) {
  final nested = value[field];
  if (nested is int) return nested;

  throw BundleValidationException('$field must be an integer.');
}

bool _safeRelativePath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  final segments = path.split('/');
  return segments.every(
    (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
  );
}

String _relativePath(String root, String path) =>
    path.substring(root.length + 1).split(Platform.pathSeparator).join('/');

String _platformPath(String root, String relativePath) =>
    '$root${Platform.pathSeparator}'
    '${relativePath.split('/').join(Platform.pathSeparator)}';

String _basename(String path) => path.split(Platform.pathSeparator).last;

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);
