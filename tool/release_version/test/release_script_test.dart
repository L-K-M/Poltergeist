@TestOn('posix')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late File fakeEngine;
  late File fakeGit;
  late String realGit;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-script-test-',
    );
    fakeEngine = File(p.join(sandbox.path, 'fake-release'));
    fakeEngine.writeAsStringSync('''#!/usr/bin/env bash
set -euo pipefail

if [[ "\${FAKE_POST_BUMP_MODE:-skip}" == failSynchronization ]]; then
  cd "\$FAKE_POST_BUMP_ROOT"
  RELEASE_DART_BIN=false RELEASE_NEW_VERSION=0.2.0 bash -c "\$RELEASE_POST_BUMP"
  printf 'post-ran\\n'
  exit 0
fi

printf 'pubspecs=%s\n' "\$RELEASE_PUBSPECS"
printf 'regex=%s\n' "\$RELEASE_VERSION_REGEX"
printf 'post=%s\n' "\$RELEASE_POST_BUMP"
printf 'args=%s\n' "\$*"
''');
    fakeGit = File(p.join(sandbox.path, 'git'));
    fakeGit.writeAsStringSync(r'''#!/usr/bin/env bash
if [[ "$1" == "-C" && "$3" == "tag" && "$4" == "--list" ]]; then
  [[ "${FAKE_GIT_FAILURE:-none}" == localTags ]] && exit 2
  printf '%s\n' "${FAKE_RELEASE_TAGS:-}"
  exit 0
fi
if [[ "$1" == "-C" && "$3" == "ls-remote" ]]; then
  [[ "${FAKE_GIT_FAILURE:-none}" == remoteTags ]] && exit 2
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    printf '0000000000000000000000000000000000000000\trefs/tags/%s\n' "$tag"
  done <<< "${FAKE_REMOTE_TAGS:-}"
  exit 0
fi
exec "$REAL_GIT" "$@"
''');
    realGit = (Process.runSync('sh', ['-c', 'command -v git']).stdout as String)
        .trim();
    Process.runSync('chmod', ['+x', fakeEngine.path, fakeGit.path]);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('validates and forwards a supported version family', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99', '--push'],
      git: fakeGit,
      realGit: realGit,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('tool/bench/pubspec.yaml'));
    expect(result.stdout, contains('app/poltergeist_app/pubspec.yaml'));
    expect(result.stdout, contains('release_version/bin/release_version.dart'));
    expect(result.stdout, contains('    sync'));
    expect(result.stdout, contains('args=2099.99.99 --push'));
  });

  test('rejects an invalid version before invoking the engine', () async {
    final result = await _runRelease(
      fakeEngine,
      ['0.2.0-alpha1'],
      git: fakeGit,
      realGit: realGit,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('invalid release version'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('rejects a version-code downgrade before invoking the engine', () async {
    final result = await _runRelease(
      fakeEngine,
      ['0.0.1'],
      git: fakeGit,
      realGit: realGit,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('current tree'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('rejects a target behind a prior release tag', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.98'],
      git: fakeGit,
      priorTags: 'v2099.99.99',
      realGit: realGit,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('prior tag v2099.99.99'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('rejects a target behind a remote release tag', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.98'],
      git: fakeGit,
      realGit: realGit,
      remoteTags: 'v2099.99.99',
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('prior tag v2099.99.99'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('fails closed when local release tags cannot be read', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      gitFailure: _GitFailure.localTags,
      realGit: realGit,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('could not read local release tags'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('fails closed when remote release tags cannot be read', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      gitFailure: _GitFailure.remoteTags,
      realGit: realGit,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('could not read remote release tags'));
    expect(result.stdout, isNot(contains('pubspecs=')));
  });

  test('--check permits the current release tag', () async {
    final current = _currentSemanticVersion();
    final result = await _runRelease(
      fakeEngine,
      ['--check'],
      git: fakeGit,
      priorTags: 'v$current',
      realGit: realGit,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('args=--check'));
  });

  test('post-bump stops when app version synchronization fails', () async {
    final result = await _runRelease(
      fakeEngine,
      ['2099.99.99'],
      git: fakeGit,
      realGit: realGit,
      postBumpMode: _PostBumpMode.failSynchronization,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stdout, isNot(contains('post-ran')));
  });

  test('checks the current version before a no-argument release', () async {
    final result = await _runRelease(
      fakeEngine,
      const [],
      git: fakeGit,
      realGit: realGit,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('preserves release order'));
    expect(result.stdout, contains('args=\n'));
  });
}

Future<ProcessResult> _runRelease(
  File engine,
  List<String> arguments, {
  required File git,
  required String realGit,
  _GitFailure gitFailure = _GitFailure.none,
  _PostBumpMode postBumpMode = _PostBumpMode.skip,
  String priorTags = '',
  String remoteTags = '',
}) {
  final root = _repositoryRoot();
  return Process.run(
    'bash',
    ['scripts/release.sh', ...arguments],
    workingDirectory: root.path,
    environment: {
      ...Platform.environment,
      'FAKE_GIT_FAILURE': gitFailure.name,
      'FAKE_POST_BUMP_MODE': postBumpMode.name,
      'FAKE_POST_BUMP_ROOT': git.parent.path,
      'FAKE_REMOTE_TAGS': remoteTags,
      'FAKE_RELEASE_TAGS': priorTags,
      'LKM_RELEASE_BIN': engine.path,
      'DART_BIN': Platform.resolvedExecutable,
      'PATH': '${git.parent.path}:${Platform.environment['PATH']}',
      'REAL_GIT': realGit,
    },
  );
}

enum _GitFailure { localTags, none, remoteTags }

enum _PostBumpMode { skip, failSynchronization }

String _currentSemanticVersion() {
  final line = File(
    p.join(_repositoryRoot().path, 'app/poltergeist_app/pubspec.yaml'),
  ).readAsLinesSync().singleWhere((line) => line.startsWith('version:'));
  return line.substring('version:'.length).trim().split('+').first;
}

Directory _repositoryRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(p.join(candidate.path, 'scripts/release.sh')).existsSync() &&
        File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate;
    }

    final parent = candidate.parent;
    if (p.equals(parent.path, candidate.path)) {
      throw StateError('repository root not found from ${Directory.current}');
    }
    candidate = parent;
  }
}
