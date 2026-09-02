import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

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
      (step) => step['uses'] == 'actions/checkout@v4',
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
  });

  test('release gate fails when tag existence cannot be checked', () async {
    final result = await _runReleaseGate(
      sandbox,
      _GitScenario.tagExistenceError,
    );

    expect(result.exitCode, isNot(0));
  });

  test('release gate rejects a tag that does not point to a commit', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.nonCommitTag);

    expect(result.exitCode, isNot(0));
  });

  test('release gate rejects a tag on another commit', () async {
    final result = await _runReleaseGate(sandbox, _GitScenario.mismatchedTag);

    expect(result.exitCode, isNot(0));
  });

  test('Android consumes Flutter release version metadata', () {
    final gradle = File(
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
    final resource = File(
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
        loadYaml(File('app/poltergeist_app/pubspec.yaml').readAsStringSync())
            as YamlMap;
    final semantic = '${pubspec['version']}'.split('+').first;
    final components = semantic.split('.').map(int.parse).toList();
    final appleBundleVersion =
        '${components[0] + 1}.${components[1]}.${components[2]}';

    for (final path in [
      'app/poltergeist_app/ios/Runner/Info.plist',
      'app/poltergeist_app/macos/Runner/Info.plist',
    ]) {
      final plist = File(path).readAsStringSync();

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
        allOf(contains('apkanalyzer'), contains('expected_code')),
      );
    }
  });

  test('zero-major versions publish as pre-releases', () {
    final jobs = _workflow('.github/workflows/release.yml')['jobs'] as YamlMap;
    final clientSteps = (jobs['client'] as YamlMap)['steps'] as YamlList;
    final publisher = clientSteps.whereType<YamlMap>().singleWhere(
      (step) => step['uses'] == 'softprops/action-gh-release@v2',
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
  _GitScenario scenario,
) {
  final fakeBin = Directory(p.join(sandbox.path, 'bin'))..createSync();
  final fakeDart = File(p.join(fakeBin.path, 'dart'));
  final fakeGit = File(p.join(fakeBin.path, 'git'));
  fakeDart.writeAsStringSync('#!/usr/bin/env bash\nexit 0\n');
  fakeGit.writeAsStringSync(r'''#!/usr/bin/env bash
case "$1" in
  show-ref)
    [[ "$FAKE_GIT_SCENARIO" == tagExistenceError ]] && exit 2
    if [[ "$FAKE_GIT_SCENARIO" == nonCommitTag ||
          "$FAKE_GIT_SCENARIO" == mismatchedTag ]]; then
      exit 0
    fi
    exit 1
    ;;
  tag)
    [[ "$FAKE_GIT_SCENARIO" == tagHistoryError ]] && exit 2
    exit 0
    ;;
  rev-parse)
    [[ "$FAKE_GIT_SCENARIO" == nonCommitTag ]] && exit 1
    if [[ "$FAKE_GIT_SCENARIO" == mismatchedTag && "$2" == HEAD ]]; then
      printf '%040d\n' 1
      exit 0
    fi
    printf '%040d\n' 0
    ;;
esac
exit 0
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
      'FAKE_GIT_SCENARIO': scenario.name,
      'PATH': '${fakeBin.path}:${Platform.environment['PATH']}',
      'RELEASE_TAG': 'v0.1.0',
    },
  );
}

enum _GitScenario {
  mismatchedTag,
  nonCommitTag,
  tagExistenceError,
  tagHistoryError,
}

YamlMap _workflow(String path) {
  final parsed = loadYaml(File(path).readAsStringSync());
  if (parsed is YamlMap) return parsed;

  throw StateError('$path is not a YAML map');
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
