@TestOn('linux')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'fixture_process.dart';

const _entrypointPath = 'test/integration/sshd-common/entrypoint.sh';
const _startupBoundary = r'if [ ! -s "$user_key" ]; then';
const _account = 'poltergeist-restart-test';
const _unexpectedExecutableExitCode = 77;
const _scriptTimeout = Duration(seconds: 5);

void main() {
  test('reuses the fixture user when a stopped container restarts', () async {
    await _expectReusableAccount('create_user $_account /home/$_account');
  });

  test(
    'reuses auxiliary auth users when a stopped container restarts',
    () async {
      await _expectReusableAccount('create_auxiliary_user $_account 1001');
    },
  );

  test('top-level account setup uses fakes before loading helpers', () async {
    final result = await _runAccountScript('useradd $_account', 'id $_account');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect('${result.stdout}'.trim(), _account);
  });

  test('account preamble has a private PATH and working directory', () async {
    final result = await _runAccountScript(
      r'printf "%s\n" "$PWD"'
          '\n'
          'if command -v chmod >/dev/null 2>&1; then '
          'exit $_unexpectedExecutableExitCode; fi',
      ':',
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      '${result.stdout}'.trim(),
      startsWith('${Directory.systemTemp.path}/poltergeist-account-'),
    );
  });
}

Future<void> _expectReusableAccount(String command) async {
  final workspace = await Isolate.resolvePackageUri(
    Uri.parse('package:_poltergeist_workspace/'),
  );
  if (workspace == null) throw StateError('Workspace package is unresolved.');

  final source = await File.fromUri(
    workspace.resolve('../$_entrypointPath'),
  ).readAsString();
  final startupIndex = source.indexOf(_startupBoundary);
  expect(startupIndex, isNonNegative);

  // Execute the real account helpers; fake OS commands prevent host mutations.
  final preamble = source.substring(0, startupIndex);
  final result = await _runAccountScript(preamble, command);

  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect('${result.stdout}'.trim().split('\n'), [_account]);
}

Future<ProcessResult> _runAccountScript(String preamble, String command) async {
  final directory = await Directory.systemTemp.createTemp(
    'poltergeist-account-',
  );
  addTearDown(() => directory.delete(recursive: true));

  // Resolve GNU timeout first, then isolate shell command lookup and relative I/O.
  return runFixtureProcess(
    '/bin/sh',
    [
      '-eu',
      '-c',
      'PATH="\$1"\nexport PATH\n${_accountScript(preamble, command)}',
      'fixture',
      directory.path,
    ],
    timeout: _scriptTimeout,
    workingDirectory: directory.path,
  );
}

String _accountScript(String preamble, String command) {
  // Install fakes before even top-level code in the extracted source can run.
  return '$_fakeAccountCommands\n$preamble\n$command\n$command';
}

const _fakeAccountCommands = r'''
fixture_accounts=''

id() {
  case " $fixture_accounts " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

create_account() {
  # Both account commands receive the username as their final argument.
  for account in "$@"; do :; done
  if id "$account"; then
    printf 'account already exists: %s\n' "$account" >&2
    return 1
  fi

  fixture_accounts="$fixture_accounts $account"
  printf '%s\n' "$account"
}

adduser() {
  create_account "$@"
}

useradd() {
  create_account "$@"
}
''';
