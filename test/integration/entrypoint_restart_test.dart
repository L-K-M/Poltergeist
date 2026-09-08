import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

const _entrypointPath = 'test/integration/sshd-common/entrypoint.sh';
const _startupBoundary = r'if [ ! -s "$user_key" ]; then';
const _account = 'poltergeist-restart-test';

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
  final definitions = source.substring(0, startupIndex);
  final result = await Process.run('sh', [
    '-eu',
    '-c',
    '$definitions\n$_fakeAccountCommands\n$command\n$command',
  ]);

  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect('${result.stdout}'.trim().split('\n'), [_account]);
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
