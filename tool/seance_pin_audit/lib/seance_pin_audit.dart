import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _recordStart = '<!-- SEANCE_PIN_AUDIT_V1:START -->';
const _recordEnd = '<!-- SEANCE_PIN_AUDIT_V1:END -->';
const _portsPath = 'docs/PORTS.md';
const _successExitCode = 0;
const _failureExitCode = 1;
const _noMatchesExitCode = 1;
const _unknownRevisionExitCode = 128;
const _shaLength = 40;
const _missingEmailMarker = '(no-email)';
const _gitlinkModePrefix = '160000 ';

const _seancePackages = {'seance_core', 'seance_protocol'};
const _dependencySections = {
  'dependencies',
  'dev_dependencies',
  'dependency_overrides',
};
const _ignoredDirectories = {'.dart_tool', '.git', 'build'};
const _vendoredComponents = {
  'third_party',
  'third-party',
  'vendor',
  'vendors',
  'node_modules',
  'ext',
  'external',
  'deps',
  'Pods',
  'packages',
};
const _companionPatterns = {
  'co-authored-by',
  'signed-off-by',
  'reported-by',
  'helped-by',
  'reviewed-by',
  'tested-by',
  'suggested-by',
  'co-developed-by',
  'acked-by',
  'mentored-by',
};
const _licensePatterns = {
  'copyright',
  'spdx',
  'apache license',
  'gnu general',
  'permission is hereby granted',
  'redistribution and use',
  'mozilla public',
  'creative commons',
  'public domain',
  'apache-2',
  'bsd-2',
  'bsd-3',
  'mpl-2',
  '"mit"',
  '"isc"',
  'licen[cs]e',
};

final _shaPattern = RegExp(r'^[0-9a-f]{40}$');
final _emailPattern = RegExp(r'<([^<>]*@[^<>]*)>');
final _byAttributionPattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_-]*-by:[ \t]+\S.*$',
  caseSensitive: false,
);
final _emailAttributionPattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_-]*:[ \t]+\S.*<[^<>]*@[^<>]*>[ \t]*$',
);

enum _OutputMode { verify, printRecord, printFindings }

/// Runs the deterministic Séance pin audit command.
Future<int> runSeancePinAudit(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    final pins = _readLockedPins(options.root);
    _verifyManifestPins(options.root, pins);

    final evidence = await _collectEvidence(options, pins);
    final record = _renderRecord(pins, evidence);

    if (options.outputMode == _OutputMode.printRecord) {
      stdout.write(record);
      return _successExitCode;
    }
    if (options.outputMode == _OutputMode.printFindings) {
      stdout.write(evidence.renderFindings());
      return _successExitCode;
    }

    _verifyRecord(options.root, record);
    stdout.writeln('Séance pin audit matches $_portsPath');
    return _successExitCode;
  } on _AuditFailure catch (error) {
    stderr.writeln('Séance pin audit failed: ${error.message}');
    return _failureExitCode;
  } on FormatException catch (error) {
    stderr.writeln('Séance pin audit failed: ${error.message}');
    return _failureExitCode;
  }
}

Future<_Evidence> _collectEvidence(
  _Options options,
  List<_LockedPin> pins,
) async {
  final temporaryDirectories = <Directory>[];
  final checkouts = <String, Directory>{};

  try {
    for (final url in pins.map((pin) => pin.url).toSet()) {
      if (options.checkout case final checkout?) {
        if (checkouts.isNotEmpty) {
          throw const _AuditFailure(
            '--checkout supports one Séance repository URL',
          );
        }
        checkouts[url] = checkout;
        continue;
      }

      final temporary = await Directory.systemTemp.createTemp(
        'poltergeist-seance-audit-',
      );
      temporaryDirectories.add(temporary);
      final checkout = Directory(p.join(temporary.path, 'repository'));
      await _cloneFullRepository(url, checkout, pins);
      checkouts[url] = checkout;
    }

    final audits = <_PinEvidence>[];
    for (final pin in pins) {
      final checkout = checkouts[pin.url]!;
      await _verifyCheckout(checkout, pin);
      audits.add(await _auditPin(checkout, pin));
    }

    return _Evidence(audits);
  } finally {
    for (final temporary in temporaryDirectories) {
      await temporary.delete(recursive: true);
    }
  }
}

Future<void> _cloneFullRepository(
  String url,
  Directory checkout,
  List<_LockedPin> pins,
) async {
  await _run('git', [
    'clone',
    '--no-checkout',
    '--no-single-branch',
    url,
    checkout.path,
  ]);

  // The explicit fetch proves the exact locked object is reachable.
  for (final pin in pins.where((pin) => pin.url == url)) {
    await _run('git', [
      '-C',
      checkout.path,
      'fetch',
      '--no-tags',
      '--force',
      'origin',
      pin.revision,
    ]);
  }
}

Future<void> _verifyCheckout(Directory checkout, _LockedPin pin) async {
  final shallow = await _runGit(checkout, [
    'rev-parse',
    '--is-shallow-repository',
  ]);
  if (shallow.stdout.trim() != 'false') {
    throw const _AuditFailure('Séance checkout must be full and non-shallow');
  }

  final resolved = await _runGit(checkout, [
    'rev-parse',
    '--verify',
    '${pin.revision}^{commit}',
  ]);
  if (resolved.stdout.trim() != pin.revision) {
    throw _AuditFailure(
      'checkout does not contain exact locked pin ${pin.revision}',
    );
  }

  if (_shaPattern.hasMatch(pin.requestedRef)) {
    if (pin.requestedRef == pin.revision) return;

    throw _AuditFailure(
      'requested SHA ${pin.requestedRef} differs from ${pin.revision}',
    );
  }

  await _runGit(checkout, [
    'check-ref-format',
    'refs/tags/${pin.requestedRef}',
  ]);
  final tag = await _runGit(
    checkout,
    ['rev-parse', '--verify', 'refs/tags/${pin.requestedRef}^{commit}'],
    acceptedExitCodes: {_successExitCode, _unknownRevisionExitCode},
  );
  if (tag.stdout.trim() != pin.revision) {
    throw _AuditFailure(
      'tag ${pin.requestedRef} does not resolve to ${pin.revision}',
    );
  }
}

Future<_PinEvidence> _auditPin(Directory checkout, _LockedPin pin) async {
  final identity = await _identityAudit(checkout, pin.revision);
  final companion = await _companionAudit(checkout, pin.revision, identity);
  final license = await _licenseAudit(checkout, pin.revision);
  final tree = await _treeAudit(checkout, pin.revision);
  final vendored = _vendoredPaths(tree);
  final gitlinks = _gitlinks(tree);
  if (gitlinks.isNotEmpty) {
    throw _AuditFailure(
      'pin ${pin.revision} contains gitlinks requiring a separate audit',
    );
  }
  final pinpoints = await _pinpointAudit(
    checkout,
    pin.revision,
    identity,
    companion.orphans,
  );

  return _PinEvidence(
    pin: pin,
    identity: identity,
    companion: companion.output,
    companionOrphans: companion.orphans,
    license: license,
    tree: tree,
    vendored: vendored,
    gitlinks: gitlinks,
    pinpoints: pinpoints,
  );
}

Future<String> _identityAudit(Directory checkout, String pin) async {
  final result = await _runGit(checkout, [
    '-c',
    'log.mailmap=false',
    '-c',
    'i18n.logOutputEncoding=utf-8',
    'log',
    pin,
    '--format=%an <%ae>%n%cn <%ce>%n%(trailers)',
  ]);

  return _sortUnique(result.stdout);
}

Future<_CompanionEvidence> _companionAudit(
  Directory checkout,
  String pin,
  String identity,
) async {
  final arguments = <String>[
    '-c',
    'grep.patternType=basic',
    '-c',
    'log.mailmap=false',
    '-c',
    'i18n.logOutputEncoding=utf-8',
    'log',
    pin,
    '-i',
    for (final pattern in _companionPatterns) '--grep=$pattern',
    r'--grep=<[^>]*@[^>]*>',
    '--format=%H %an <%ae>',
  ];
  final result = await _runGit(checkout, arguments);
  final identityAttributions = identity
      .split('\n')
      .where(_isAttribution)
      .map(_normalizeAttribution)
      .toSet();
  final orphans = <String>[];

  for (final summary in _nonEmptyLines(result.stdout)) {
    final commit = summary.substring(0, _shaLength);
    final message = await _runGit(checkout, [
      '-c',
      'log.mailmap=false',
      '-c',
      'i18n.logOutputEncoding=utf-8',
      'show',
      '-s',
      '--format=%B',
      commit,
    ]);
    for (final line in message.stdout.split('\n')) {
      final attribution = line.trimRight();
      if (!_isAttribution(attribution)) continue;
      if (identityAttributions.contains(_normalizeAttribution(attribution))) {
        continue;
      }

      final email =
          _emailPattern.firstMatch(attribution)?.group(1) ??
          _missingEmailMarker;
      orphans.add('$email\t$commit\t$attribution');
    }
  }

  return _CompanionEvidence(
    _normalize(result.stdout),
    _sortUnique(orphans.join('\n')),
  );
}

Future<String> _licenseAudit(Directory checkout, String pin) async {
  final arguments = <String>[
    '-c',
    'grep.patternType=basic',
    '-c',
    'core.quotepath=false',
    'grep',
    '-I',
    '-i',
    for (final pattern in _licensePatterns) ...['-e', pattern],
    pin,
  ];
  final result = await _runGit(
    checkout,
    arguments,
    acceptedExitCodes: {_successExitCode, _noMatchesExitCode},
  );

  return _normalize(result.stdout);
}

Future<String> _treeAudit(Directory checkout, String pin) async {
  final result = await _runGit(checkout, [
    '-c',
    'core.quotepath=false',
    'ls-tree',
    '-r',
    pin,
  ]);

  return _normalize(result.stdout);
}

String _vendoredPaths(String tree) {
  final matches = <String>[];
  for (final line in _nonEmptyLines(tree)) {
    final separator = line.indexOf('\t');
    if (separator < 0) continue;

    final path = line.substring(separator + 1);
    final components = p.posix.split(path).toSet();
    if (components.intersection(_vendoredComponents).isEmpty) continue;

    matches.add(path);
  }

  return matches.join('\n');
}

String _gitlinks(String tree) => _nonEmptyLines(
  tree,
).where((line) => line.startsWith(_gitlinkModePrefix)).join('\n');

Future<String> _pinpointAudit(
  Directory checkout,
  String pin,
  String identity,
  String orphans,
) async {
  final emails =
      _emailPattern.allMatches(identity).map((match) => match.group(1)!).toSet()
        ..addAll(
          _nonEmptyLines(orphans)
              .map((line) => line.split('\t').first)
              .where((email) => email != _missingEmailMarker),
        );
  final sortedEmails = emails.toList()..sort();
  final lines = <String>[];

  for (final email in sortedEmails) {
    final escaped = _escapeBasicExpression(email);
    final commits = <String>[];

    // Git ANDs different limiting categories, so union three searches.
    for (final limiter in [
      '--author=$escaped',
      '--committer=$escaped',
      '--grep=$escaped',
    ]) {
      final result = await _runGit(checkout, [
        '-c',
        'grep.patternType=basic',
        '-c',
        'log.mailmap=false',
        '-c',
        'i18n.logOutputEncoding=utf-8',
        'log',
        pin,
        '-i',
        limiter,
        '--format=%H',
      ]);
      commits.addAll(_nonEmptyLines(result.stdout));
    }

    for (final commit in _sortUnique(commits.join('\n')).split('\n')) {
      if (commit.isEmpty) continue;
      lines.add('$email\t$commit');
    }
  }

  for (final orphan in _nonEmptyLines(orphans)) {
    final fields = orphan.split('\t');
    if (fields.first != _missingEmailMarker) continue;

    final attribution = fields.skip(2).join('\t');
    final escaped = _escapeBasicExpression(attribution);
    final result = await _runGit(checkout, [
      '-c',
      'grep.patternType=basic',
      '-c',
      'log.mailmap=false',
      '-c',
      'i18n.logOutputEncoding=utf-8',
      'log',
      pin,
      '-i',
      '--grep=$escaped',
      '--format=%H',
    ]);
    for (final commit in _nonEmptyLines(result.stdout)) {
      lines.add('$attribution\t$commit');
    }
  }

  return _sortUnique(lines.join('\n'));
}

String _escapeBasicExpression(String value) {
  final output = StringBuffer();
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    final edgeAnchor =
        (index == 0 && character == '^') ||
        (index == value.length - 1 && character == r'$');
    if (edgeAnchor ||
        character == r'\' ||
        character == '.' ||
        character == '[' ||
        character == '*') {
      output.write(r'\');
    }
    output.write(character);
  }

  return output.toString();
}

String _normalizeAttribution(String value) {
  final separator = value.indexOf(':');
  if (separator < 0) return value;

  final key = value.substring(0, separator).toLowerCase();
  final attribution = value.substring(separator + 1).trimLeft();
  return '$key: $attribution';
}

bool _isAttribution(String value) =>
    _byAttributionPattern.hasMatch(value) ||
    _emailAttributionPattern.hasMatch(value);

List<_LockedPin> _readLockedPins(Directory root) {
  final pins = <_LockedPin>{};
  for (final file in _findFiles(root, 'pubspec.lock')) {
    final yaml = loadYaml(file.readAsStringSync());
    if (yaml is! YamlMap) continue;
    final packages = yaml['packages'];
    if (packages is! YamlMap) continue;

    for (final entry in packages.entries) {
      final package = entry.key?.toString() ?? '';
      final details = entry.value;
      if (details is! YamlMap || details['source'] != 'git') continue;
      final description = details['description'];
      if (description is! YamlMap) continue;
      final url = description['url']?.toString() ?? '';
      if (!_isSeanceDependency(package, url)) continue;

      final ref = description['ref']?.toString() ?? '';
      final revision = description['resolved-ref']?.toString() ?? '';
      if (ref.isEmpty || !_shaPattern.hasMatch(revision)) {
        throw _AuditFailure(
          '${p.relative(file.path, from: root.path)} must resolve an exact 40-hex Séance SHA',
        );
      }

      pins.add(_LockedPin(url, ref, revision));
    }
  }

  if (pins.isEmpty) {
    throw const _AuditFailure('no locked Séance pin found');
  }

  final sorted = pins.toList()
    ..sort((left, right) {
      final byUrl = left.url.compareTo(right.url);
      if (byUrl != 0) return byUrl;
      final byRevision = left.revision.compareTo(right.revision);
      if (byRevision != 0) return byRevision;
      return left.requestedRef.compareTo(right.requestedRef);
    });
  return sorted;
}

void _verifyManifestPins(Directory root, List<_LockedPin> pins) {
  var declarationCount = 0;
  for (final file in _findFiles(root, 'pubspec.yaml')) {
    final yaml = loadYaml(file.readAsStringSync());
    if (yaml is! YamlMap) continue;

    for (final sectionName in _dependencySections) {
      final section = yaml[sectionName];
      if (section is! YamlMap) continue;

      for (final entry in section.entries) {
        final package = entry.key?.toString() ?? '';
        final details = entry.value;
        if (details is! YamlMap) continue;
        final git = details['git'];
        if (git is! YamlMap) continue;
        final url = git['url']?.toString() ?? '';
        if (!_isSeanceDependency(package, url)) continue;

        declarationCount++;
        final ref = git['ref']?.toString() ?? '';
        final lock = _resolvingLock(root, file);
        if (lock == null) {
          throw _AuditFailure(
            '${p.relative(file.path, from: root.path)} has no resolving lock',
          );
        }
        final lockedPin = _lockedPackagePin(lock, package);
        final matches =
            lockedPin != null &&
            lockedPin.url == url &&
            lockedPin.requestedRef == ref &&
            pins.contains(lockedPin.pin);
        if (matches) continue;

        throw _AuditFailure(
          '${p.relative(file.path, from: root.path)} manifest and lock Séance pins differ',
        );
      }
    }
  }

  if (declarationCount == 0) {
    throw const _AuditFailure('no Séance git dependency declared');
  }
}

File? _resolvingLock(Directory root, File manifest) {
  final adjacent = File(p.join(manifest.parent.path, 'pubspec.lock'));
  if (adjacent.existsSync()) return adjacent;

  var ancestor = manifest.parent.parent;
  while (p.isWithin(root.path, ancestor.path) ||
      p.equals(root.path, ancestor.path)) {
    final ancestorManifest = File(p.join(ancestor.path, 'pubspec.yaml'));
    final lock = File(p.join(ancestor.path, 'pubspec.lock'));
    if (ancestorManifest.existsSync() && lock.existsSync()) {
      final yaml = loadYaml(ancestorManifest.readAsStringSync());
      final workspace = yaml is YamlMap ? yaml['workspace'] : null;
      final relative = p.normalize(
        p.relative(manifest.parent.path, from: ancestor.path),
      );
      if (workspace is YamlList &&
          workspace
              .map((entry) => p.normalize(entry.toString()))
              .contains(relative)) {
        return lock;
      }
    }
    if (p.equals(root.path, ancestor.path)) break;

    ancestor = ancestor.parent;
  }

  return null;
}

_LockedPackagePin? _lockedPackagePin(File lock, String package) {
  final yaml = loadYaml(lock.readAsStringSync());
  if (yaml is! YamlMap) return null;
  final packages = yaml['packages'];
  if (packages is! YamlMap) return null;
  final details = packages[package];
  if (details is! YamlMap || details['source'] != 'git') return null;
  final description = details['description'];
  if (description is! YamlMap) return null;

  final url = description['url']?.toString() ?? '';
  final ref = description['ref']?.toString() ?? '';
  final revision = description['resolved-ref']?.toString() ?? '';
  if (ref.isEmpty || !_shaPattern.hasMatch(revision)) return null;

  return _LockedPackagePin(url, ref, revision);
}

Iterable<File> _findFiles(Directory root, String name) sync* {
  for (final entity in root.listSync(followLinks: false)) {
    if (entity is File && p.basename(entity.path) == name) {
      yield entity;
      continue;
    }
    if (entity is! Directory) continue;
    if (_ignoredDirectories.contains(p.basename(entity.path))) continue;

    yield* _findFiles(entity, name);
  }
}

bool _isSeanceDependency(String package, String url) {
  if (_seancePackages.contains(package) || package.startsWith('seance_')) {
    return true;
  }

  final normalized = url.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  return normalized.endsWith('/seance') || normalized.endsWith('/seance.git');
}

String _renderRecord(List<_LockedPin> pins, _Evidence evidence) {
  final buffer = StringBuffer()
    ..writeln(_recordStart)
    ..writeln('## Séance pin audit')
    ..writeln()
    ..writeln('Full, non-shallow ancestor and tree audit. Raw streams are')
    ..writeln('content-addressed by SHA-256; line counts aid review. Use')
    ..writeln(
      '`--print-findings` to reproduce them without adding names to docs.',
    )
    ..writeln();
  for (final pin in pins) {
    buffer.writeln('- Pin: `${pin.revision}` from `${pin.url}`');
  }
  buffer
    ..writeln(
      '- Identity: ${evidence.identity.lineCount} lines; `${evidence.identity.digest}`',
    )
    ..writeln(
      '- Companion: ${evidence.companion.lineCount} lines; `${evidence.companion.digest}`',
    )
    ..writeln(
      '- Companion orphans: ${evidence.companionOrphans.lineCount} lines; `${evidence.companionOrphans.digest}`',
    )
    ..writeln(
      '- Pinpoints: ${evidence.pinpoints.lineCount} lines; `${evidence.pinpoints.digest}`',
    )
    ..writeln(
      '- License scan: ${evidence.license.lineCount} lines; `${evidence.license.digest}`',
    )
    ..writeln(
      '- Vendored paths: ${evidence.vendored.lineCount} lines; `${evidence.vendored.digest}`',
    )
    ..writeln(
      '- Gitlinks: ${evidence.gitlinks.lineCount} lines; `${evidence.gitlinks.digest}`',
    )
    ..writeln(
      '- Tree: ${evidence.tree.lineCount} lines; `${evidence.tree.digest}`',
    )
    ..writeln(_recordEnd);
  return buffer.toString();
}

void _verifyRecord(Directory root, String expected) {
  final file = File(p.join(root.path, _portsPath));
  if (!file.existsSync()) {
    throw const _AuditFailure('$_portsPath is missing the pin audit record');
  }

  final contents = file.readAsStringSync();
  final start = contents.indexOf(_recordStart);
  final end = contents.indexOf(_recordEnd);
  final duplicateStart =
      start >= 0 && contents.indexOf(_recordStart, start + 1) >= 0;
  final duplicateEnd = end >= 0 && contents.indexOf(_recordEnd, end + 1) >= 0;
  if (start < 0 || end < start || duplicateStart || duplicateEnd) {
    throw const _AuditFailure('$_portsPath must contain one pin audit record');
  }

  final actual = '${contents.substring(start, end + _recordEnd.length)}\n';
  if (actual == expected) return;

  throw const _AuditFailure(
    '$_portsPath record does not match; run scripts/audit-seance-pin.sh --print-record',
  );
}

Future<_CommandResult> _runGit(
  Directory checkout,
  List<String> arguments, {
  Set<int> acceptedExitCodes = const {_successExitCode},
}) => _run('git', [
  '-C',
  checkout.path,
  '--no-replace-objects',
  ...arguments,
], acceptedExitCodes: acceptedExitCodes);

Future<_CommandResult> _run(
  String executable,
  List<String> arguments, {
  Set<int> acceptedExitCodes = const {_successExitCode},
}) async {
  final result = await Process.run(
    executable,
    arguments,
    environment: const {'LC_ALL': 'C'},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (!acceptedExitCodes.contains(result.exitCode)) {
    throw _AuditFailure(
      '$executable ${arguments.join(' ')} exited ${result.exitCode}: '
      '${(result.stderr as String).trim()}',
    );
  }

  return _CommandResult(result.stdout as String, result.stderr as String);
}

String _normalize(String value) {
  var normalized = value.replaceAll('\r\n', '\n');
  while (normalized.endsWith('\n')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }

  return normalized;
}

String _sortUnique(String value) {
  final lines = _normalize(value).split('\n').toSet().toList()
    ..sort(_compareCBytes);
  return lines.join('\n');
}

int _compareCBytes(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final sharedLength = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < sharedLength; index++) {
    final difference = leftBytes[index] - rightBytes[index];
    if (difference != 0) return difference;
  }

  return leftBytes.length - rightBytes.length;
}

Iterable<String> _nonEmptyLines(String value) =>
    _normalize(value).split('\n').where((line) => line.isNotEmpty);

final class _Options {
  final Directory root;
  final Directory? checkout;
  final _OutputMode outputMode;

  const _Options(this.root, this.checkout, this.outputMode);

  factory _Options.parse(List<String> arguments) {
    var root = Directory.current;
    Directory? checkout;
    var outputMode = _OutputMode.verify;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--root' || argument == '--checkout') {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a path');
        }
        final directory = Directory(p.absolute(arguments[++index]));
        if (argument == '--root') {
          root = directory;
        } else {
          checkout = directory;
        }
        continue;
      }
      if (argument == '--print-record') {
        if (outputMode != _OutputMode.verify) {
          throw const FormatException('choose one output mode');
        }
        outputMode = _OutputMode.printRecord;
        continue;
      }
      if (argument == '--print-findings') {
        if (outputMode != _OutputMode.verify) {
          throw const FormatException('choose one output mode');
        }
        outputMode = _OutputMode.printFindings;
        continue;
      }

      throw FormatException('unknown argument: $argument');
    }

    if (!root.existsSync()) {
      throw FormatException('root does not exist: ${root.path}');
    }
    if (checkout != null && !checkout.existsSync()) {
      throw FormatException('checkout does not exist: ${checkout.path}');
    }

    return _Options(root, checkout, outputMode);
  }
}

final class _LockedPin {
  final String url;
  final String requestedRef;
  final String revision;

  const _LockedPin(this.url, this.requestedRef, this.revision);

  @override
  bool operator ==(Object other) =>
      other is _LockedPin &&
      other.url == url &&
      other.requestedRef == requestedRef &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(url, requestedRef, revision);
}

final class _LockedPackagePin {
  final String url;
  final String requestedRef;
  final String revision;

  const _LockedPackagePin(this.url, this.requestedRef, this.revision);

  _LockedPin get pin => _LockedPin(url, requestedRef, revision);
}

final class _Evidence {
  final List<_PinEvidence> audits;

  const _Evidence(this.audits);

  _Section get identity => _combine((audit) => audit.identity);
  _Section get companion => _combine((audit) => audit.companion);
  _Section get companionOrphans => _combine((audit) => audit.companionOrphans);
  _Section get pinpoints => _combine((audit) => audit.pinpoints);
  _Section get license => _combine((audit) => audit.license);
  _Section get tree => _combine((audit) => audit.tree);
  _Section get vendored => _combine((audit) => audit.vendored);
  _Section get gitlinks => _combine((audit) => audit.gitlinks);

  _Section _combine(String Function(_PinEvidence) select) {
    final buffer = StringBuffer();
    var lineCount = 0;
    for (final audit in audits) {
      final output = select(audit);
      buffer
        ..writeln('${audit.pin.url}@${audit.pin.revision}')
        ..writeln(output);
      lineCount += _countLines(output);
    }
    return _Section(buffer.toString().trimRight(), lineCount);
  }

  String renderFindings() {
    final buffer = StringBuffer();
    for (final audit in audits) {
      buffer.writeln('[pin]\n${audit.pin.url}@${audit.pin.revision}');
      for (final section in audit.sections.entries) {
        buffer.writeln('[${section.key}]\n${section.value}');
      }
    }
    return buffer.toString();
  }
}

final class _PinEvidence {
  final _LockedPin pin;
  final String identity;
  final String companion;
  final String companionOrphans;
  final String license;
  final String tree;
  final String vendored;
  final String gitlinks;
  final String pinpoints;

  const _PinEvidence({
    required this.pin,
    required this.identity,
    required this.companion,
    required this.companionOrphans,
    required this.license,
    required this.tree,
    required this.vendored,
    required this.gitlinks,
    required this.pinpoints,
  });

  Map<String, String> get sections => {
    'identity': identity,
    'companion': companion,
    'companion-orphans': companionOrphans,
    'pinpoints': pinpoints,
    'license': license,
    'vendored': vendored,
    'gitlinks': gitlinks,
    'tree': tree,
  };
}

final class _Section {
  final String output;
  final int lineCount;

  const _Section(this.output, this.lineCount);

  String get digest => 'sha256:${sha256.convert(utf8.encode(output))}';
}

int _countLines(String output) =>
    output.isEmpty ? 0 : '\n'.allMatches(output).length + 1;

final class _CompanionEvidence {
  final String output;
  final String orphans;

  const _CompanionEvidence(this.output, this.orphans);
}

final class _CommandResult {
  final String stdout;
  final String stderr;

  const _CommandResult(this.stdout, this.stderr);
}

final class _AuditFailure implements Exception {
  final String message;

  const _AuditFailure(this.message);
}
