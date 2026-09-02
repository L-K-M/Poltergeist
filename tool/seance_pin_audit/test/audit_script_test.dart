import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _ownerName = 'Fixture Owner';
const _ownerEmail = 'owner@example.test';
const _authorEmail = 'author.only@example.test';
const _committerEmail = 'committer.only@example.test';
const _trailerEmail = 'trailer+only@example.test';
const _strandedEmail = 'stranded@example.test';
const _unknownEmail = 'unknown@example.test';
const _unrelatedEmail = 'unrelated@example.test';
const _replacementEmail = 'replacement@example.test';
const _bmpSortName = '\uE000';
const _nonBmpSortName = '\u{10000}';

enum _CheckoutSource { fixture, arguments }

enum _TagState { valid, missing, moved }

void main() {
  late Directory sandbox;
  late _Fixture fixture;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('seance-pin-audit-test-');
    fixture = await _Fixture.create(sandbox.path);
  });

  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  test(
    'audits recorded history and tree without local config rewrites',
    () async {
      final findings = await _audit(fixture, ['--print-findings']);

      expect(findings.exitCode, 0, reason: findings.stderr as String);
      final output = findings.stdout as String;

      expect(output, contains('$_ownerName <$_ownerEmail>'));
      expect(output, isNot(contains('laundered@example.test')));
      expect(output, isNot(contains(_unrelatedEmail)));
      expect(output, isNot(contains(_replacementEmail)));
      expect(output, contains('docs/café.txt'));
      expect(output, contains('NOTICE.md'));
      expect(output, contains('packages/seance_core/lib/core.dart'));
      expect(
        output.indexOf(_bmpSortName),
        lessThan(output.indexOf(_nonBmpSortName)),
      );
      expect(output, contains('$_strandedEmail\t${fixture.strandedCommit}'));
      expect(output, contains('$_unknownEmail\t${fixture.strandedCommit}'));
      expect(
        output,
        contains('Mentored-by: Bare Name\t${fixture.strandedCommit}'),
      );
      expect(
        output,
        isNot(contains('$_trailerEmail\t${fixture.strandedCommit}\t')),
      );
    },
  );

  test('unions author, committer, and trailer pinpoint hits', () async {
    final findings = await _audit(fixture, ['--print-findings']);

    expect(findings.exitCode, 0, reason: findings.stderr as String);
    final output = findings.stdout as String;

    expect(output, contains('$_authorEmail\t${fixture.authorCommit}'));
    expect(output, contains('$_committerEmail\t${fixture.committerCommit}'));
    expect(output, contains('$_trailerEmail\t${fixture.trailerCommit}'));
  });

  test('fails when any recorded audit section changes', () async {
    final generated = await _audit(fixture, ['--print-record']);
    expect(generated.exitCode, 0, reason: generated.stderr as String);

    final ports = File(p.join(fixture.root.path, 'docs', 'PORTS.md'));
    final record = generated.stdout as String;
    await ports.parent.create(recursive: true);
    await ports.writeAsString('# Ports\n\n$record');

    final passing = await _audit(fixture);
    expect(passing.exitCode, 0, reason: passing.stderr as String);

    for (final section in [
      'Identity',
      'Companion',
      'Companion orphans',
      'Pinpoints',
      'License scan',
      'Vendored paths',
      'Gitlinks',
      'Tree',
    ]) {
      final expression = RegExp('($section:.*sha256:)([0-9a-f])');
      final tampered = record.replaceFirstMapped(
        expression,
        (match) => '${match[1]}${match[2] == '0' ? '1' : '0'}',
      );
      expect(tampered, isNot(record), reason: 'missing $section digest');
      await ports.writeAsString('# Ports\n\n$tampered');

      final failing = await _audit(fixture);
      expect(failing.exitCode, isNot(0), reason: '$section was accepted');
      expect(failing.stderr, contains('record does not match'));
    }
  });

  test('rejects shallow checkouts and manifest-lock drift', () async {
    final shallow = Directory(p.join(sandbox.path, 'shallow'));
    await _run('git', [
      'clone',
      '--depth=1',
      fixture.repository.uri.toString(),
      shallow.path,
    ]);

    final shallowResult = await _audit(fixture, [
      '--checkout',
      shallow.path,
      '--print-record',
    ], _CheckoutSource.arguments);
    expect(shallowResult.exitCode, isNot(0));
    expect(shallowResult.stderr, contains('non-shallow'));

    final manifest = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.yaml'),
    );
    await manifest.writeAsString(
      (await manifest.readAsString()).replaceFirst(
        fixture.pin,
        '0000000000000000000000000000000000000000',
      ),
    );

    final drift = await _audit(fixture, ['--print-record']);
    expect(drift.exitCode, isNot(0));
    expect(drift.stderr, contains('manifest and lock'));
  });

  test('rejects unaudited gitlinks', () async {
    await fixture.addGitlink();

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('gitlinks requiring a separate audit'));
  });

  test('does not let an unrelated lock cover the manifest', () async {
    final benchLock = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.lock'),
    );
    final decoy = File(p.join(fixture.root.path, 'pubspec.lock'));
    await decoy.writeAsString(await benchLock.readAsString());
    await benchLock.delete();

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('has no resolving lock'));
  });

  test('audits a tag ref at its exact resolved revision', () async {
    await fixture.useTagRef(_TagState.valid);

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains(fixture.pin));
  });

  for (final state in [_TagState.missing, _TagState.moved]) {
    test('rejects a ${state.name} tag ref', () async {
      await fixture.useTagRef(state);

      final result = await _audit(fixture, ['--print-record']);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('does not resolve'));
    });
  }
}

Future<ProcessResult> _audit(
  _Fixture fixture, [
  List<String> extraArguments = const [],
  _CheckoutSource checkoutSource = _CheckoutSource.fixture,
]) {
  final script = p.join(
    Directory.current.path,
    'scripts',
    'audit-seance-pin.sh',
  );
  final arguments = <String>[
    '--root',
    fixture.root.path,
    if (checkoutSource == _CheckoutSource.fixture) ...[
      '--checkout',
      fixture.repository.path,
    ],
    ...extraArguments,
  ];

  return Process.run(
    script,
    arguments,
    environment: {'DART_EXECUTABLE': Platform.resolvedExecutable},
  );
}

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed:\n${result.stderr}',
    );
  }

  return result;
}

final class _Fixture {
  final Directory root;
  final Directory repository;
  final String pin;
  final String authorCommit;
  final String committerCommit;
  final String trailerCommit;
  final String strandedCommit;

  const _Fixture({
    required this.root,
    required this.repository,
    required this.pin,
    required this.authorCommit,
    required this.committerCommit,
    required this.trailerCommit,
    required this.strandedCommit,
  });

  static Future<_Fixture> create(String sandboxPath) async {
    final root = Directory(p.join(sandboxPath, 'poltergeist'))
      ..createSync(recursive: true);
    final repository = Directory(p.join(sandboxPath, 'seance'))
      ..createSync(recursive: true);

    await _run('git', [
      'init',
      '-b',
      'main',
    ], workingDirectory: repository.path);
    await _run('git', [
      'config',
      'grep.patternType',
      'fixed',
    ], workingDirectory: repository.path);
    await _run('git', [
      'config',
      'core.quotepath',
      'true',
    ], workingDirectory: repository.path);

    await _write(
      repository,
      '.mailmap',
      'Laundered <laundered@example.test> <$_ownerEmail>\n',
    );
    await _write(
      repository,
      'LICENSE',
      'This work is dedicated to the public domain.\n',
    );
    await _write(repository, 'NOTICE.md', 'Licence inventory.\n');
    await _write(repository, 'docs/café.txt', 'fixture\n');
    await _write(
      repository,
      'packages/seance_core/lib/core.dart',
      'const core = 1;\n',
    );
    await _write(
      repository,
      'packages/seance_protocol/lib/protocol.dart',
      'const protocol = 1;\n',
    );
    await _commit(repository, 'Initial fixture');

    await _write(repository, 'bmp-sort.txt', 'bmp\n');
    await _commit(
      repository,
      'BMP sort fixture',
      authorName: _bmpSortName,
      authorEmail: 'bmp@example.test',
    );

    await _write(repository, 'non-bmp-sort.txt', 'non-bmp\n');
    await _commit(
      repository,
      'Non-BMP sort fixture',
      authorName: _nonBmpSortName,
      authorEmail: 'non-bmp@example.test',
    );

    await _write(repository, 'author.txt', 'author\n');
    final authorCommit = await _commit(
      repository,
      'Author-only change',
      authorName: 'Author Only',
      authorEmail: _authorEmail,
    );

    await _write(repository, 'committer.txt', 'committer\n');
    final committerCommit = await _commit(
      repository,
      'Committer-only change',
      committerName: 'Committer Only',
      committerEmail: _committerEmail,
    );

    await _write(repository, 'trailer.txt', 'trailer\n');
    final trailerCommit = await _commit(
      repository,
      'Trailer-only change\n\nCo-authored-by: Trailer Only <$_trailerEmail>',
    );

    await _write(repository, 'stranded.txt', 'stranded\n');
    final strandedCommit = await _commit(
      repository,
      'Stranded attribution\n\n'
      'Co-Authored-By: Trailer Only <$_trailerEmail>\n'
      'Reported-by: Stranded Person <$_strandedEmail>\n'
      'Original-Author: Unknown Person <$_unknownEmail>\n'
      'Mentored-by: Bare Name\n\n'
      'This paragraph strands the attribution.',
    );
    final pin = await _head(repository);

    await _run('git', [
      'checkout',
      '-b',
      'unrelated',
    ], workingDirectory: repository.path);
    await _write(repository, 'unrelated.txt', 'unrelated\n');
    await _commit(
      repository,
      'Unrelated branch',
      authorName: 'Unrelated',
      authorEmail: _unrelatedEmail,
    );
    await _run('git', ['checkout', 'main'], workingDirectory: repository.path);

    final tree = (await _run('git', [
      'rev-parse',
      '$pin^{tree}',
    ], workingDirectory: repository.path)).stdout.toString().trim();
    final replacement = (await _run(
      'git',
      ['commit-tree', tree, '-m', 'Replacement commit'],
      workingDirectory: repository.path,
      environment: _identityEnvironment(
        authorName: 'Replacement',
        authorEmail: _replacementEmail,
        committerName: 'Replacement',
        committerEmail: _replacementEmail,
      ),
    )).stdout.toString().trim();
    await _run('git', [
      'replace',
      pin,
      replacement,
    ], workingDirectory: repository.path);

    await _writePinFiles(root, repository.path, pin);

    return _Fixture(
      root: root,
      repository: repository,
      pin: pin,
      authorCommit: authorCommit,
      committerCommit: committerCommit,
      trailerCommit: trailerCommit,
      strandedCommit: strandedCommit,
    );
  }

  Future<void> addGitlink() async {
    await _run('git', [
      'update-index',
      '--add',
      '--cacheinfo',
      '160000,$pin,external/module',
    ], workingDirectory: repository.path);
    await _run(
      'git',
      ['commit', '-m', 'Add gitlink'],
      workingDirectory: repository.path,
      environment: _identityEnvironment(
        authorName: _ownerName,
        authorEmail: _ownerEmail,
        committerName: _ownerName,
        committerEmail: _ownerEmail,
      ),
    );
    final advancedPin = await _head(repository);
    await _writePinFiles(root, repository.path, advancedPin);
  }

  Future<void> useTagRef(_TagState state) async {
    const tag = 'v0.8.0';
    final target = switch (state) {
      _TagState.valid => pin,
      _TagState.moved => '$pin^',
      _TagState.missing => null,
    };
    if (target != null) {
      await _run('git', [
        '--no-replace-objects',
        'tag',
        tag,
        target,
      ], workingDirectory: repository.path);
    }

    for (final relative in [
      'tool/bench/pubspec.yaml',
      'tool/bench/pubspec.lock',
    ]) {
      final file = File(p.join(root.path, relative));
      final contents = await file.readAsString();
      await file.writeAsString(
        contents.replaceAll('\n      ref: $pin\n', '\n      ref: $tag\n'),
      );
    }
  }
}

Future<void> _writePinFiles(Directory root, String url, String pin) async {
  await _write(root, 'tool/bench/pubspec.yaml', '''name: fixture
dependencies:
  seance_core:
    git:
      url: "$url"
      ref: $pin
      path: packages/seance_core
''');
  await _write(root, 'tool/bench/pubspec.lock', '''packages:
  seance_core:
    dependency: "direct main"
    description:
      path: packages/seance_core
      ref: $pin
      resolved-ref: $pin
      url: "$url"
    source: git
    version: "0.0.0"
  seance_protocol:
    dependency: transitive
    description:
      path: packages/seance_protocol
      ref: $pin
      resolved-ref: $pin
      url: "$url"
    source: git
    version: "0.0.0"
''');
}

Future<void> _write(
  Directory root,
  String relativePath,
  String contents,
) async {
  final file = File(p.join(root.path, relativePath));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

Future<String> _commit(
  Directory repository,
  String message, {
  String authorName = _ownerName,
  String authorEmail = _ownerEmail,
  String committerName = _ownerName,
  String committerEmail = _ownerEmail,
}) async {
  await _run('git', ['add', '.'], workingDirectory: repository.path);
  await _run(
    'git',
    ['commit', '-m', message],
    workingDirectory: repository.path,
    environment: _identityEnvironment(
      authorName: authorName,
      authorEmail: authorEmail,
      committerName: committerName,
      committerEmail: committerEmail,
    ),
  );

  return _head(repository);
}

Map<String, String> _identityEnvironment({
  required String authorName,
  required String authorEmail,
  required String committerName,
  required String committerEmail,
}) => {
  'GIT_AUTHOR_NAME': authorName,
  'GIT_AUTHOR_EMAIL': authorEmail,
  'GIT_COMMITTER_NAME': committerName,
  'GIT_COMMITTER_EMAIL': committerEmail,
};

Future<String> _head(Directory repository) async {
  final result = await _run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: repository.path);

  return result.stdout.toString().trim();
}
