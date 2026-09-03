import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Steps are selected by action name, never by tag: these tests assert step
/// *inputs* (`fetch-depth`, `prerelease`), so a routine `@v4` → `@v5` bump
/// must not turn them into an opaque `singleWhere` "No element" failure.
const _checkoutAction = 'actions/checkout';
const _releaseAction = 'softprops/action-gh-release';

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-workflow-test-',
    );
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('CI tests and verifies the release version tool', () {
    final dartSteps = _jobSteps('.github/workflows/ci.yml', 'dart');

    expect(
      _stepRun(dartSteps, 'Analyze release version tool'),
      contains('dart analyze tool/release_version'),
    );
    expect(
      _stepRun(dartSteps, 'Test release version tool'),
      contains('dart test tool/release_version/test'),
    );
    expect(
      _stepRun(dartSteps, 'Verify release versions'),
      contains('release_version.dart check'),
    );
  });

  test('release builds depend on the tag and tree version gate', () {
    final workflow = _workflow('.github/workflows/release.yml');
    final jobs = workflow['jobs'] as YamlMap;
    final client = jobs['client'] as YamlMap;
    final testSteps = (jobs['test'] as YamlMap)['steps'] as YamlList;
    final checkout = testSteps.whereType<YamlMap>().singleWhere(
      (step) => '${step['uses']}'.startsWith('$_checkoutAction@'),
    );
    final gate = _step(testSteps, 'Verify release tag and versions');
    final gateEnvironment = gate['env'] as YamlMap;
    final gateRun = '${gate['run']}';

    expect(client['needs'], 'test');
    expect((checkout['with'] as YamlMap)['fetch-depth'], 0);
    expect(
      gateEnvironment['RELEASE_TAG'],
      r'${{ inputs.tag || github.ref_name }}',
    );
    expect(gateRun, contains(r'check-tag --tag "$RELEASE_TAG"'));
    expect(gateRun, contains('show-ref --verify --quiet'));
    expect(gateRun, contains(r'refs/tags/${RELEASE_TAG}^{commit}'));
    expect(gateRun, contains(r'"$tag_commit" != "$checkout_commit"'));
    expect(gateRun, contains('check-order'));
    expect(gateRun, isNot(contains(r'${{')));
    expect(
      _stepRun(testSteps, 'Test release version tool'),
      contains('dart test tool/release_version/test'),
    );
  });

  test('release gate fails when tag history cannot be read', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.tagHistoryError);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('could not read release tag history'));
  }, skip: _posixOnly);

  test('release gate fails when tag existence cannot be checked', () async {
    final result = await _runReleaseGate(
      sandbox,
      _GitScenario.tagExistenceError,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('could not inspect release tag'));
  }, skip: _posixOnly);

  test('release gate rejects a tag that does not point to a commit', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.nonCommitTag);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('release tag does not point at a commit'));
  }, skip: _posixOnly);

  test('release gate rejects a tag on another commit', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.mismatchedTag);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('release tag points at'));
  }, skip: _posixOnly);

  test('release gate accepts a matching tag', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.ok);

    expect(result.exitCode, 0, reason: result.stderr as String);
  }, skip: _posixOnly);

  test('release gate accepts a missing dispatch tag', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.missingTag);

    expect(result.exitCode, 0, reason: result.stderr as String);
  }, skip: _posixOnly);

  test('release gate forwards prior tags except the target', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.priorHistory);

    expect(result.exitCode, 0, reason: result.stderr as String);
  }, skip: _posixOnly);

  for (final mode in const [
    _VersionToolMode.checkTag,
    _VersionToolMode.checkOrder,
  ]) {
    test('release gate stops when ${mode.name} fails', () async {
      final result = await _runReleaseGate(
        sandbox,
        _GitScenario.ok,
        versionToolMode: mode,
      );

      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('fake version tool failure: ${mode.name}'),
      );
    }, skip: _posixOnly);
  }

  test('Android consumes Flutter release version metadata', () {
    final gradle = _repositoryFile(
      'app/poltergeist_app/android/app/build.gradle.kts',
    ).readAsStringSync();

    expect(
      gradle,
      allOf(
        contains('versionCode = flutter.versionCode'),
        contains('versionName = flutter.versionName'),
      ),
    );
  });

  test('Windows keeps the Android code out of 16-bit version fields', () {
    final resource = _repositoryFile(
      'app/poltergeist_app/windows/runner/Runner.rc',
    ).readAsStringSync();

    expect(
      resource,
      contains(
        '#define VERSION_AS_NUMBER '
        'FLUTTER_VERSION_MAJOR,FLUTTER_VERSION_MINOR,'
        'FLUTTER_VERSION_PATCH,0',
      ),
    );
  });

  test('Apple keeps the Android code out of bundle version fields', () {
    final pubspec =
        loadYaml(
              _repositoryFile(
                'app/poltergeist_app/pubspec.yaml',
              ).readAsStringSync(),
            )
            as YamlMap;
    final semantic = '${pubspec['version']}'.split('+').first;
    final components = semantic.split('.').map(int.parse).toList();
    final appleBundleVersion =
        '${components[0] + 1}.${components[1]}.${components[2]}';

    for (final path in [
      'app/poltergeist_app/ios/Runner/Info.plist',
      'app/poltergeist_app/macos/Runner/Info.plist',
    ]) {
      final plist = _repositoryFile(path).readAsStringSync();

      expect(
        plist,
        contains(
          '<key>CFBundleVersion</key>\n\t'
          '<string>$appleBundleVersion</string>',
        ),
      );
      expect(
        plist,
        isNot(
          contains(
            '<key>CFBundleVersion</key>\n\t'
            '<string>\$(FLUTTER_BUILD_NUMBER)</string>',
          ),
        ),
      );
    }
  });

  test('client builds cannot override the synchronized Android code', () {
    for (final path in [
      '.github/workflows/ci.yml',
      '.github/workflows/release.yml',
    ]) {
      final jobs = _workflow(path)['jobs'] as YamlMap;
      final client = jobs['client'] as YamlMap;
      final strategy = client['strategy'] as YamlMap;
      final matrix = strategy['matrix'] as YamlMap;
      final includes = matrix['include'] as YamlList;
      final steps = client['steps'] as YamlList;

      for (final entry in includes.whereType<YamlMap>()) {
        expect('${entry['build']}', isNot(contains('--build-number')));
      }
      expect(_stepRun(steps, 'Build'), isNot(contains('--build-number')));
    }
  });

  test('client builds verify the APK manifest version code', () {
    for (final path in [
      '.github/workflows/ci.yml',
      '.github/workflows/release.yml',
    ]) {
      final jobs = _workflow(path)['jobs'] as YamlMap;
      final steps = (jobs['client'] as YamlMap)['steps'] as YamlList;
      final verifier = _step(steps, 'Verify Android version code');

      expect(verifier['if'], "matrix.target == 'android'");
      expect(
        '${verifier['run']}',
        contains(r'bash "$GITHUB_WORKSPACE/scripts/verify-android-version.sh"'),
      );
    }
  });

  test('Android version verifier accepts the synchronized code', () async {
    final result = await _runAndroidVersionVerifier(
      sandbox,
      code: _expectedAndroidCode(),
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
  }, skip: _posixOnly);

  test('Android version verifier accepts a trailing version comment', () async {
    final result = await _runAndroidVersionVerifier(
      sandbox,
      code: _expectedAndroidCode(),
      pubspecState: _PubspecState.commented,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
  }, skip: _posixOnly);

  test('Android version verifier rejects manifest drift', () async {
    final result = await _runAndroidVersionVerifier(sandbox, code: '1');

    expect(result.exitCode, isNot(0));
    expect(
      result.stderr,
      contains('APK versionCode 1, expected ${_expectedAndroidCode()}'),
    );
  }, skip: _posixOnly);

  test('Android version verifier finds apkanalyzer on PATH', () async {
    final result = await _runAndroidVersionVerifier(
      sandbox,
      code: _expectedAndroidCode(),
      analyzerLocation: _AnalyzerLocation.path,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
  }, skip: _posixOnly);

  test('Android version verifier rejects a missing APK', () async {
    final result = await _runAndroidVersionVerifier(
      sandbox,
      code: _expectedAndroidCode(),
      apkState: _ApkState.missing,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('expected APK not found'));
  }, skip: _posixOnly);

  test('Android version verifier rejects a missing pubspec', () async {
    final result = await _runAndroidVersionVerifier(
      sandbox,
      code: _expectedAndroidCode(),
      pubspecState: _PubspecState.missing,
    );

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('expected app pubspec not found'));
  }, skip: _posixOnly);

  test('zero-major versions publish as pre-releases', () {
    final jobs = _workflow('.github/workflows/release.yml')['jobs'] as YamlMap;
    final clientSteps = (jobs['client'] as YamlMap)['steps'] as YamlList;
    final publisher = clientSteps.whereType<YamlMap>().singleWhere(
      (step) => '${step['uses']}'.startsWith('$_releaseAction@'),
    );
    final inputs = publisher['with'] as YamlMap;

    expect(
      '${inputs['prerelease']}',
      allOf(contains('startsWith('), contains("'v0.'")),
    );
  });
}

Future<ProcessResult> _runReleaseGate(
  Directory sandbox,
  _GitScenario scenario, {
  _VersionToolMode versionToolMode = _VersionToolMode.normal,
}) {
  final fakeBin = Directory(p.join(sandbox.path, 'bin'))..createSync();
  final fakeDart = File(p.join(fakeBin.path, 'dart'));
  final fakeGit = File(p.join(fakeBin.path, 'git'));
  fakeDart.writeAsStringSync(r'''#!/usr/bin/env bash
set -euo pipefail

readonly version_tool=tool/release_version/bin/release_version.dart
readonly command_argument_count=3
readonly history_command_argument_count=5
readonly expected_prior_tag=v0.0.1
readonly expected_tag=v0.1.0
readonly expected_version=0.1.0

check_order_arguments() {
  [[ "$1" == check-order && "$2" == --version &&
     "$3" == "$expected_version" ]] || return 1

  if [[ "$FAKE_GIT_SCENARIO" == priorHistory ]]; then
    [[ "$#" -eq "$history_command_argument_count" &&
       "$4" == --prior-tag && "$5" == "$expected_prior_tag" ]]
    return
  fi

  [[ "$#" -eq "$command_argument_count" ]]
}

if [[ "$1" != run || "$2" != "$version_tool" ]]; then
  echo "fake dart: unexpected invocation: $*" >&2
  exit 1
fi

shift 2
case "$1" in
  check-tag)
    if [[ "$#" -eq "$command_argument_count" &&
          "$2" == --tag && "$3" == "$expected_tag" ]]; then
      if [[ "$FAKE_VERSION_TOOL_MODE" == checkTag ]]; then
        echo "fake version tool failure: checkTag" >&2
        exit 1
      fi
      exit 0
    fi
    ;;
  check-order)
    if check_order_arguments "$@"; then
      if [[ "$FAKE_VERSION_TOOL_MODE" == checkOrder ]]; then
        echo "fake version tool failure: checkOrder" >&2
        exit 1
      fi
      exit 0
    fi
    ;;
esac

echo "fake dart: unexpected release-version arguments: $*" >&2
exit 1
''');
  fakeGit.writeAsStringSync(r'''#!/usr/bin/env bash
unexpected() {
  echo "fake git: unexpected invocation: $*" >&2
  exit 1
}

readonly expected_ref=refs/tags/v0.1.0
readonly expected_commit_ref="${expected_ref}^{commit}"

case "$1" in
  show-ref)
    [[ "$#" -eq 4 && "$2" == --verify && "$3" == --quiet &&
       "$4" == "$expected_ref" ]] || unexpected "$@"
    [[ "$FAKE_GIT_SCENARIO" == tagExistenceError ]] && exit 2
    if [[ "$FAKE_GIT_SCENARIO" == nonCommitTag ||
          "$FAKE_GIT_SCENARIO" == mismatchedTag ||
          "$FAKE_GIT_SCENARIO" == priorHistory ||
          "$FAKE_GIT_SCENARIO" == ok ]]; then
      exit 0
    fi
    exit 1
    ;;
  tag)
    [[ "$#" -eq 3 && "$2" == --list && "$3" == 'v*' ]] || unexpected "$@"
    [[ "$FAKE_GIT_SCENARIO" == tagHistoryError ]] && exit 2
    if [[ "$FAKE_GIT_SCENARIO" == priorHistory ]]; then
      printf '%s\n' v0.1.0 v0.0.1
    fi
    exit 0
    ;;
  rev-parse)
    if [[ "$#" -eq 3 && "$2" == --verify &&
          "$3" == "$expected_commit_ref" ]]; then
      [[ "$FAKE_GIT_SCENARIO" == nonCommitTag ]] && exit 1
      printf '%040d\n' 0
      exit 0
    fi
    if [[ "$#" -eq 2 && "$2" == HEAD ]]; then
      if [[ "$FAKE_GIT_SCENARIO" != mismatchedTag ]]; then
        printf '%040d\n' 0
        exit 0
      fi
      printf '%040d\n' 1
      exit 0
    fi
    unexpected "$@"
    ;;
esac
unexpected "$@"
''');
  Process.runSync('chmod', ['+x', fakeDart.path, fakeGit.path]);

  final workflow = _workflow('.github/workflows/release.yml');
  final jobs = workflow['jobs'] as YamlMap;
  final steps = (jobs['test'] as YamlMap)['steps'] as YamlList;
  final script = '${_step(steps, 'Verify release tag and versions')['run']}';

  return Process.run(
    'bash',
    ['-euo', 'pipefail', '-c', script],
    environment: {
      ...Platform.environment,
      'GITHUB_WORKSPACE': p.join(sandbox.path, 'unrelated-workspace'),
      'FAKE_GIT_SCENARIO': scenario.name,
      'FAKE_VERSION_TOOL_MODE': versionToolMode.name,
      'PATH': _prependExecutablePath(fakeBin.path),
      'RELEASE_TAG': 'v0.1.0',
    },
    workingDirectory: _repositoryRoot.path,
  );
}

Future<ProcessResult> _runAndroidVersionVerifier(
  Directory sandbox, {
  required String code,
  _AnalyzerLocation analyzerLocation = _AnalyzerLocation.androidHome,
  _ApkState apkState = _ApkState.present,
  _PubspecState pubspecState = _PubspecState.present,
}) {
  final repository = Directory(p.join(sandbox.path, 'repository'))
    ..createSync();
  final verifier = File(
    p.join(repository.path, 'scripts/verify-android-version.sh'),
  );
  verifier.parent.createSync(recursive: true);
  _repositoryFile('scripts/verify-android-version.sh').copySync(verifier.path);

  final expectedCode = _expectedAndroidCode();
  final pubspec = File(
    p.join(repository.path, 'app/poltergeist_app/pubspec.yaml'),
  );
  if (pubspecState != _PubspecState.missing) {
    final comment = switch (pubspecState) {
      _PubspecState.commented => ' # release metadata',
      _PubspecState.missing || _PubspecState.present => '',
    };
    pubspec.parent.createSync(recursive: true);
    pubspec.writeAsStringSync(
      'name: poltergeist_app\nversion: 0.1.0+$expectedCode$comment\n',
    );
  }

  final apk = File(
    p.join(
      repository.path,
      'app/poltergeist_app/build/app/outputs/flutter-apk/app-release.apk',
    ),
  );
  if (apkState == _ApkState.present) {
    apk.parent.createSync(recursive: true);
    apk.createSync();
  }

  final androidHome = p.join(sandbox.path, 'android');
  final analyzer = File(switch (analyzerLocation) {
    _AnalyzerLocation.androidHome => p.join(
      androidHome,
      'cmdline-tools/latest/bin/apkanalyzer',
    ),
    _AnalyzerLocation.path => p.join(sandbox.path, 'bin', 'apkanalyzer'),
  });
  analyzer.parent.createSync(recursive: true);
  analyzer.writeAsStringSync(r'''#!/usr/bin/env bash
[[ "$*" == "manifest version-code $FAKE_EXPECTED_APK_PATH" ]] || exit 64
printf '%s\n' "$FAKE_ANDROID_VERSION_CODE"
''');
  Process.runSync('chmod', ['+x', analyzer.path]);

  late final String executablePath;
  if (analyzerLocation == _AnalyzerLocation.androidHome) {
    final decoy = File(p.join(sandbox.path, 'bin', 'apkanalyzer'));
    decoy.parent.createSync(recursive: true);
    decoy.writeAsStringSync('#!/usr/bin/env bash\nexit 1\n');
    Process.runSync('chmod', ['+x', decoy.path]);
    executablePath = _prependExecutablePath(decoy.parent.path);
  } else {
    executablePath = _prependExecutablePath(analyzer.parent.path);
  }

  return Process.run(
    'bash',
    [verifier.path],
    environment: {
      ...Platform.environment,
      'GITHUB_WORKSPACE': p.join(sandbox.path, 'unrelated-workspace'),
      'ANDROID_HOME': switch (analyzerLocation) {
        _AnalyzerLocation.androidHome => androidHome,
        _AnalyzerLocation.path => '',
      },
      'FAKE_ANDROID_VERSION_CODE': code,
      'FAKE_EXPECTED_APK_PATH': apk.path,
      'PATH': executablePath,
    },
    workingDirectory: repository.path,
  );
}

String _prependExecutablePath(String directory) {
  final inherited = Platform.environment['PATH'];
  if (inherited == null || inherited.isEmpty) return directory;

  return '$directory:$inherited';
}

enum _GitScenario {
  mismatchedTag,
  missingTag,
  nonCommitTag,
  ok,
  priorHistory,
  tagExistenceError,
  tagHistoryError,
}

enum _AnalyzerLocation { androidHome, path }

enum _ApkState { missing, present }

enum _PubspecState { commented, missing, present }

enum _VersionToolMode { checkOrder, checkTag, normal }

YamlMap _workflow(String path) {
  final parsed = loadYaml(_repositoryFile(path).readAsStringSync());
  if (parsed is YamlMap) return parsed;

  throw StateError('$path is not a YAML map');
}

final Directory _repositoryRoot = _findRepositoryRoot();

final Object _posixOnly = Platform.isWindows
    ? 'requires POSIX bash and executable scripts'
    : false;

File _repositoryFile(String path) {
  return File(p.join(_repositoryRoot.path, path));
}

String _expectedAndroidCode() {
  final pubspec =
      loadYaml(
            _repositoryFile(
              'app/poltergeist_app/pubspec.yaml',
            ).readAsStringSync(),
          )
          as YamlMap;
  final version = '${pubspec['version']}';
  if (!version.contains('+')) {
    throw StateError('app pubspec version has no build code: $version');
  }

  return version.split('+').last;
}

Directory _findRepositoryRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(p.join(candidate.path, '.github/workflows/ci.yml')).existsSync() &&
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

YamlList _jobSteps(String path, String jobName) {
  final jobs = _workflow(path)['jobs'] as YamlMap;
  return (jobs[jobName] as YamlMap)['steps'] as YamlList;
}

String _stepRun(YamlList steps, String name) {
  return '${_step(steps, name)['run']}';
}

YamlMap _step(YamlList steps, String name) {
  final matches = steps.whereType<YamlMap>().where(
    (step) => step['name'] == name,
  );
  expect(matches, hasLength(1), reason: 'missing or duplicate step: $name');

  return matches.single;
}
