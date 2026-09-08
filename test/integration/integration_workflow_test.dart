import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _fixturePath = 'test/integration/docker-compose.yml';
const _requiredEvents = ['push', 'workflow_dispatch'];

void main() {
  late String guard;

  setUpAll(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_poltergeist_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');

    final workflow =
        loadYaml(
              await File.fromUri(
                workspace.resolve('../.github/workflows/ci.yml'),
              ).readAsString(),
            )
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final detection = jobs['detect_integration'] as YamlMap;
    final steps = (detection['steps'] as YamlList).cast<YamlMap>();
    guard =
        steps.singleWhere((step) => step['id'] == 'fixture')['run'] as String;
  });

  for (final event in _requiredEvents) {
    test('$event fails closed when the SSH fixture is absent', () async {
      final result = await _runGuard(guard, event: event);
      expect(result.exitCode, isNonZero);
      expect(
        result.stdout,
        contains('Missing integration fixture: $_fixturePath'),
      );
      expect(result.output, isEmpty);
    });
  }

  test('fixture or workflow PR deletion fails closed', () async {
    final result = await _runGuard(guard, changed: 'true');
    expect(result.exitCode, isNonZero);
    expect(
      result.stdout,
      contains('Missing integration fixture: $_fixturePath'),
    );
    expect(result.output, isEmpty);
  });

  test('source-only PR without the fixture remains skipped', () async {
    final result = await _runGuard(guard);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.output, 'run=false');
  });

  for (final event in [..._requiredEvents, 'pull_request']) {
    test('$event runs the existing SSH fixture', () async {
      final result = await _runGuard(
        guard,
        event: event,
        fixture: _FixtureState.present,
      );
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.output, 'run=true');
    });
  }
}

enum _FixtureState { absent, present }

typedef _GuardResult = ({
  int exitCode,
  String stdout,
  String stderr,
  String output,
});

Future<_GuardResult> _runGuard(
  String guard, {
  String event = 'pull_request',
  String changed = 'false',
  _FixtureState fixture = _FixtureState.absent,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'poltergeist-ci-guard-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final output = File('${directory.path}/output');
  await output.create();
  if (fixture == _FixtureState.present) {
    await File('${directory.path}/$_fixturePath').create(recursive: true);
  }

  // Execute the committed guard in an isolated checkout shape.
  final result = await Process.run(
    'bash',
    ['-euo', 'pipefail', '-c', guard],
    workingDirectory: directory.path,
    environment: {
      'EVENT_NAME': event,
      'FIXTURE_CHANGED': changed,
      'GITHUB_OUTPUT': output.path,
    },
  );
  return (
    exitCode: result.exitCode,
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
    output: (await output.readAsString()).trim(),
  );
}
