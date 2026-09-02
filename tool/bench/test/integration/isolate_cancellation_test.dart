@Tags(['integration'])
library;

import 'dart:io';

import 'package:poltergeist_m0_bench/config.dart';
import 'package:poltergeist_m0_bench/isolate_poc.dart';
import 'package:test/test.dart';

const _hostVariable = 'POLTERGEIST_SSHD';
const _portVariable = 'POLTERGEIST_SSHD_MODERN';
const _userVariable = 'POLTERGEIST_SSHD_USER';
const _passwordVariable = 'POLTERGEIST_SSHD_PASSWORD';
const _identityVariable = 'POLTERGEIST_SSHD_KEY';
const _remoteRootVariable = 'POLTERGEIST_SSHD_REMOTE_ROOT';

void main() {
  final environment = Platform.environment;
  final enabled = [
    _hostVariable,
    _portVariable,
    _userVariable,
    _passwordVariable,
    _identityVariable,
    _remoteRootVariable,
  ].every(environment.containsKey);

  test(
    'cancelled pipelined read closes without a detached SFTP error',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'poltergeist-isolate-cancel.',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final config = BenchConfig(
        endpoint: BenchEndpoint(
          host: environment[_hostVariable]!,
          port: int.parse(environment[_portVariable]!),
          username: environment[_userVariable]!,
          password: environment[_passwordVariable]!,
          identityFile: environment[_identityVariable]!,
        ),
        remoteRoot: environment[_remoteRootVariable]!,
        identityFile: environment[_identityVariable]!,
        outputFile: '${scratch.path}/results.json',
        linkName: 'lan',
        fixtureRoot: scratch.path,
        uploadRoot: scratch.path,
        rttEvidence: null,
      );

      final latency = await runIsolateCancellationProbe(config);

      expect(latency, lessThan(cancellationLatencyLimit));
    },
    skip: enabled ? false : 'Set the integration fixture variables to enable.',
  );
}
