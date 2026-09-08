@TestOn('linux')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'fixture_process.dart';

const _scriptPath = 'test/integration/service-control.sh';
const _sharedPort = '2201';
const _scriptTimeout = Duration(seconds: 5);
const _injectedFailureExitCode = 42;

enum _Failure { stop, free, up, banner }

void main() {
  test('restoration port matches both Compose services', () async {
    final script = await (await _repoFile(_scriptPath)).readAsString();
    expect(script, contains("readonly shared_ssh_port='$_sharedPort'"));

    final composeFile = await _repoFile('test/integration/docker-compose.yml');
    final compose = loadYaml(await composeFile.readAsString()) as YamlMap;
    final services = compose['services'] as YamlMap;
    for (final name in ['sshd-modern', 'sshd-keyswap']) {
      final ports = services[name]['ports'] as YamlList;
      expect(ports, hasLength(1));
      expect(ports.single['published'], _sharedPort);
    }
  });

  for (final state in ['modern', 'none', 'keyswap']) {
    test('restores modern when the running service is $state', () async {
      final fixture = await _Fixture._create(state);

      final result = await fixture._restore();

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(fixture._state, 'modern');
      expect(fixture._events, containsAllInOrder(['free', 'up', 'banner']));
    });
  }

  test('repeated restoration leaves the original service ready', () async {
    final fixture = await _Fixture._create('keyswap');

    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await fixture._restore();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(fixture._state, 'modern');
    }

    expect(fixture._events.where((event) => event == 'banner'), hasLength(2));
  });

  for (final failure in _Failure.values) {
    test('restoration retries after ${failure.name} fails', () async {
      final fixture = await _Fixture._create('keyswap');

      final failed = await fixture._restore(failure: failure);
      expect(failed.exitCode, _injectedFailureExitCode);
      expect(fixture._events.last, failure.name);

      final retried = await fixture._restore();
      expect(retried.exitCode, 0, reason: '${retried.stderr}');
      expect(fixture._state, 'modern');
      expect(fixture._events.last, 'banner');
    });
  }
}

Future<File> _repoFile(String path) async {
  final workspace = await Isolate.resolvePackageUri(
    Uri.parse('package:_poltergeist_workspace/'),
  );
  if (workspace == null) throw StateError('Workspace package is unresolved.');

  return File.fromUri(workspace.resolve('../$path'));
}

/// Runs the real helper with private command lookup and fake Docker state.
class _Fixture {
  _Fixture(this._directory, this._script);

  final Directory _directory;
  final String _script;

  String get _state =>
      File('${_directory.path}/state').readAsStringSync().trim();

  List<String> get _events =>
      File('${_directory.path}/events').readAsLinesSync();

  static Future<_Fixture> _create(String state) async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-service-control-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final bin = await Directory('${directory.path}/bin').create();
    await Link('${bin.path}/dirname').create('/usr/bin/dirname');
    await Link('${bin.path}/timeout').create('/usr/bin/timeout');
    await File('${bin.path}/docker').writeAsString(_fakeDocker);
    await File('${bin.path}/dart').writeAsString(_fakeDart);
    final chmod = await Process.run('/bin/chmod', [
      '+x',
      '${bin.path}/docker',
      '${bin.path}/dart',
    ]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

    await File('${directory.path}/state').writeAsString('$state\n');
    await File('${directory.path}/events').writeAsString('');
    return _Fixture(directory, (await _repoFile(_scriptPath)).path);
  }

  Future<ProcessResult> _restore({_Failure? failure}) {
    return runFixtureProcess(
      '/bin/bash',
      [_script, 'restore-modern'],
      timeout: _scriptTimeout,
      workingDirectory: _directory.path,
      environment: {
        'PATH': '${_directory.path}/bin',
        'DART_BIN': '${_directory.path}/bin/dart',
        'FIXTURE_FAILURE': failure?.name ?? '',
        'FIXTURE_FAILURE_EXIT_CODE': '$_injectedFailureExitCode',
        'FIXTURE_PORT': _sharedPort,
      },
    );
  }
}

// Only running services publish ports. Stop/up enforce exclusive port ownership.
const _fakeDocker = r'''#!/bin/bash
set -euo pipefail
[[ "$1 $2 $3 $4" == 'compose --project-name poltergeist-m0 --file' ]]
shift 5
read -r state < state

case "$1" in
  port)
    [[ "$2" == "sshd-$state" ]] || exit 1
    printf '127.0.0.1:%s\n' "$FIXTURE_PORT"
    ;;
  stop)
    printf 'stop\n' >> events
    [[ "$FIXTURE_FAILURE" != stop ]] || exit "$FIXTURE_FAILURE_EXIT_CODE"
    shift
    for service in "$@"; do
      if [[ "$service" == "sshd-$state" ]]; then
        state=none
      fi
    done
    printf '%s\n' "$state" > state
    ;;
  up)
    [[ "$2 $3" == '--detach sshd-modern' ]]
    printf 'up\n' >> events
    [[ "$FIXTURE_FAILURE" != up ]] || exit "$FIXTURE_FAILURE_EXIT_CODE"
    [[ "$state" == none || "$state" == modern ]]
    printf 'modern\n' > state
    ;;
  *) exit 1 ;;
esac
''';

// Readiness and release checks remain ordered, without sockets or real sleeps.
const _fakeDart = r'''#!/bin/bash
set -euo pipefail
[[ "$1" == run && "$2" == */wait_port.dart ]]
[[ "$4 $5" == "127.0.0.1 $FIXTURE_PORT" ]]
read -r state < state
printf '%s\n' "$3" >> events
[[ "$FIXTURE_FAILURE" != "$3" ]] || exit "$FIXTURE_FAILURE_EXIT_CODE"

case "$3" in
  free) [[ "$state" == none ]] ;;
  banner) [[ "$state" == modern ]] ;;
  *) exit 1 ;;
esac
''';
