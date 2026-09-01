import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'check_config.dart';

const _m0TimeoutMinutes = 360;
const _m0MeasurementTimeoutMinutes = 330;
const _m0BenchmarkJobName = 'm0_bench';
const _m0AggregateJobName = 'm0_bench_aggregate';
const _m0ShardNames = [
  'standard',
  'rtt100-1gb-download-dart-hash-on-r1',
  'rtt100-1gb-download-dart-hash-on-r2',
  'rtt100-1gb-download-dart-hash-off-r1',
  'rtt100-1gb-download-dart-hash-off-r2',
  'rtt100-1gb-download-openssh-r1',
  'rtt100-1gb-download-openssh-r2',
  'rtt100-1gb-upload-dart-hash-on-r1',
  'rtt100-1gb-upload-dart-hash-on-r2',
  'rtt100-1gb-upload-dart-hash-off-r1',
  'rtt100-1gb-upload-dart-hash-off-r2',
  'rtt100-1gb-upload-openssh-r1',
  'rtt100-1gb-upload-openssh-r2',
];
const _m0SourceArtifactPrefix = 'm0-bench-source';
const _m0CanonicalArtifact = 'm0-bench-results';
const _m0ShardPath = 'tool/bench/bench-shard.json';
const _m0EvidencePath = 'tool/bench/evidence';
const _m0CommittedEvidencePath = 'docs/evidence/m0';
const _m0ReportPath = 'docs/M0-DARTSSH2-REPORT.md';
const _checkoutAction = 'actions/checkout@v4';
const _m0CommandLogVariable = 'POLTERGEIST_M0_COMMAND_LOG';
const _m0ProfileScriptVariable = 'POLTERGEIST_M0_PROFILE_SCRIPT';
const _m0BenchCommandVariable = 'POLTERGEIST_M0_BENCH_COMMAND';
const _m0PackageCommandVariable = 'POLTERGEIST_M0_PACKAGE_COMMAND';
const _m0SourceFileVariable = 'POLTERGEIST_M0_SOURCE_FILE';
const _m0LifecycleCommandVariable = 'POLTERGEIST_M0_LIFECYCLE_COMMAND';
const _m0LifecycleStatusVariable = 'POLTERGEIST_M0_LIFECYCLE_STATUS';
const _m0CleanupStatusVariable = 'POLTERGEIST_M0_CLEANUP_STATUS';
const _m0FinalizationOwnerVariable = 'POLTERGEIST_M0_FINALIZATION_OWNER';
const _integrationFinalizerVariable =
    'POLTERGEIST_INTEGRATION_LIFECYCLE_FINALIZER';
const _deadlineStartMs = '1788220800000';
const _deadlineStartMonotonicUs = '123456789';
const _cleanupFailureExitCode = 41;
const _measuredRttJson =
    '{"samplesUs":[99000,100000,101000,101000,102000,103000,104000],'
    '"medianMs":101,"capturedAtUtc":"2026-09-01T00:00:00.000Z"}';
const _benchFailureExitCode = 23;
const _packageFailureExitCode = 29;
const _usageExitCode = 2;
const _modernAlpineImage =
    'alpine:20260805@sha256:'
    '020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000';
const _modernOpenSshVersion = '10.5_p1-r1';
const _modernOpenSshPackages = [
  'openssh-client-common',
  'openssh-server-pam',
  'openssh-sftp-server',
];

enum _OutputMode { append, reset }

void main() {
  test('accepts loopback long-form publishing', () {
    final errors = findExposureErrors({
      'services': {
        'safe': {
          'ports': [
            {'host_ip': '127.0.0.1', 'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors, isEmpty);
  });

  test('rejects a resolved short-form mapping without host IP', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {
          'ports': [
            {'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors.single, contains('all interfaces'));
  });

  test('rejects a non-loopback long-form mapping', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {
          'ports': [
            {'host_ip': '0.0.0.0', 'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors.single, contains('0.0.0.0'));
  });

  test('rejects host networking without published ports', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {'network_mode': 'host'},
      },
    });

    expect(errors.single, contains('host networking'));
  });

  test('audits the OpenSSH 10 post-quantum default', () {
    final config = File(
      'test/integration/sshd-common/config/sshd_config.chacha',
    ).readAsStringSync();

    expect(config, contains('mlkem768x25519-sha256'));
    expect(config, isNot(contains('sntrup761x25519-sha512')));
  });

  test('pins the current modern OpenSSH fixture', () {
    final dockerfile = File(
      'test/integration/sshd-modern/Dockerfile',
    ).readAsStringSync();

    expect(dockerfile.split('\n').first, 'FROM $_modernAlpineImage');
    for (final package in _modernOpenSshPackages) {
      expect(dockerfile, contains('$package=$_modernOpenSshVersion'));
    }
  });

  test('pins matching legacy OpenSSH client and server packages', () {
    final dockerfile = File(
      'test/integration/sshd-legacy/Dockerfile',
    ).readAsStringSync();

    expect(dockerfile, contains(r'ARG OPENSSH_VERSION='));
    expect(dockerfile, contains(r'openssh-client=${OPENSSH_VERSION}'));
    expect(dockerfile, contains(r'openssh-server=${OPENSSH_VERSION}'));
  });

  test('exports attributable M0 runtime identity', () {
    final runner = File('test/integration/run.sh').readAsStringSync();

    for (final variable in [
      'POLTERGEIST_M0_STARTED_AT_EPOCH_MS',
      'POLTERGEIST_M0_FIXTURE_IMAGE_ID',
      'POLTERGEIST_M0_FIXTURE_TREE',
      'POLTERGEIST_M0_OPENSSH_CLIENT_VERSION',
      'POLTERGEIST_M0_OPENSSH_SERVER_VERSION',
    ]) {
      expect(runner, contains('export $variable='), reason: variable);
    }
    expect(runner, contains('compose images --quiet sshd-modern'));
    expect(
      runner,
      contains(r'git -C "$repo_root" rev-parse HEAD:test/integration'),
    );
    expect(runner, contains("ssh -V"));
    expect(runner, contains("apk info --verbose openssh-server-pam"));
  });

  test('runs the generic lifecycle finalizer after fixture teardown', () {
    final runner = File('test/integration/run.sh').readAsStringSync();
    final teardown = runner.indexOf('down || cleanup_status=');
    final finalizer = runner.indexOf(
      r'"$lifecycle_finalizer" "$effective_status"',
    );

    expect(teardown, isNonNegative);
    expect(finalizer, greaterThan(teardown));
  });

  test('pulls the frozen legacy image by digest', () {
    final compose =
        loadYaml(File('test/integration/docker-compose.yml').readAsStringSync())
            as YamlMap;
    final services = compose['services'] as YamlMap;
    final legacy = services['sshd-legacy'] as YamlMap;

    expect(
      legacy['image'],
      matches(
        RegExp(r'^ghcr\.io/l-k-m/poltergeist-sshd-legacy@sha256:[a-f0-9]{64}$'),
      ),
    );
    expect(legacy.containsKey('build'), isFalse);
  });

  test('shards M0 measurements without shortening their budget', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final benchmark = jobs[_m0BenchmarkJobName] as YamlMap;
    final strategy = benchmark['strategy'] as YamlMap;
    final matrix = strategy['matrix'] as YamlMap;

    expect((benchmark['needs'] as YamlList).toList(), [
      'dart',
      'seance_pin_audit',
    ]);
    expect(strategy['fail-fast'], isFalse);
    expect((matrix['shard'] as YamlList).toList(), _m0ShardNames);
    expect(_m0ShardNames.toSet(), hasLength(_m0ShardNames.length));
    expect(benchmark['timeout-minutes'], _m0TimeoutMinutes);
    expect(
      '${benchmark['if']}'.trim(),
      "github.event_name == 'workflow_dispatch'",
    );

    final steps = (benchmark['steps'] as YamlList).cast<YamlMap>();
    final sourceStart = _stepNamed(steps, 'Start M0 source evidence');
    final measurement = _stepNamed(steps, 'Run fixture and measurements');
    expect(steps.indexOf(sourceStart), lessThan(steps.indexOf(measurement)));
    expect(sourceStart['working-directory'], 'tool/bench');
    final sourceStartCommand = '${sourceStart['run']}'
        .replaceAll('\\\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(
      sourceStartCommand,
      contains(r'POLTERGEIST_M0_STARTED_AT_EPOCH_MS="$(date +%s%3N)"'),
    );
    expect(sourceStartCommand, contains('/proc/uptime'));
    expect(
      sourceStartCommand,
      contains('POLTERGEIST_M0_STARTED_AT_MONOTONIC_US='),
    );
    expect(
      sourceStartCommand,
      contains(
        r'POLTERGEIST_M0_STARTED_AT_EPOCH_MS='
        r'$POLTERGEIST_M0_STARTED_AT_EPOCH_MS',
      ),
    );
    expect(sourceStartCommand, contains(r'>> "$GITHUB_ENV"'));
    expect(
      sourceStartCommand.indexOf('date +%s%3N'),
      lessThan(sourceStartCommand.indexOf('package_source.dart start')),
    );
    expect(
      sourceStartCommand.indexOf('/proc/uptime'),
      lessThan(sourceStartCommand.indexOf('package_source.dart start')),
    );
    expect(
      sourceStartCommand,
      contains(
        'dart run bin/package_source.dart start '
        '--output bench-shard.json --shard "\${{ matrix.shard }}"',
      ),
    );
    expect(measurement['id'], 'measurements');
    expect(measurement['timeout-minutes'], _m0MeasurementTimeoutMinutes);
    final measurementCommand = '${measurement['run']}'
        .replaceAll('\\\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(
      measurementCommand,
      contains(r'tool/bench/run-ci-shard.sh "${{ matrix.shard }}"'),
    );

    final uploads = _expectRetriedArtifactUpload(
      steps,
      firstStepId: 'upload_shard',
      expectedCondition: 'always()',
    );
    for (final upload in uploads) {
      final options = upload['with'] as YamlMap;
      expect(options['name'], '$_m0SourceArtifactPrefix-\${{ matrix.shard }}');
      expect(options['path'], _m0ShardPath);
      expect(options['if-no-files-found'], 'error');
      expect(options['overwrite'], isTrue);
    }
  });

  test('aggregates exact M0 sources into one canonical artifact', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final aggregate = jobs[_m0AggregateJobName] as YamlMap;

    expect(aggregate['needs'], _m0BenchmarkJobName);
    expect('${aggregate['if']}', contains('always()'));
    expect('${aggregate['if']}', contains("result == 'success'"));
    expect('${aggregate['if']}', contains("event_name == 'workflow_dispatch'"));
    expect('${aggregate['if']}', isNot(contains("'m0-bench'")));

    final steps = (aggregate['steps'] as YamlList).cast<YamlMap>();
    final download = _stepNamed(steps, 'Download M0 source evidence');
    final downloadOptions = download['with'] as YamlMap;
    expect(download['uses'], 'actions/download-artifact@v4');
    expect(downloadOptions['pattern'], '$_m0SourceArtifactPrefix-*');
    expect(downloadOptions['path'], 'tool/bench/shards');
    expect(downloadOptions['merge-multiple'], isFalse);

    final aggregation = _stepNamed(steps, 'Aggregate M0 measurements');
    final command = '${aggregation['run']}'
        .replaceAll('\\\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(aggregation['working-directory'], 'tool/bench');
    expect(
      command,
      contains(
        'dart run bin/aggregate.dart '
        '--input-root shards '
        '--output-dir evidence '
        '--run-id "\${{ github.run_id }}" '
        '--run-attempt "\${{ github.run_attempt }}" '
        '--git-sha "\${{ github.sha }}"',
      ),
    );

    final uploads = _expectRetriedArtifactUpload(
      steps,
      firstStepId: 'upload_evidence',
      expectedCondition: null,
    );
    for (final upload in uploads) {
      final options = upload['with'] as YamlMap;
      expect(options['name'], _m0CanonicalArtifact);
      expect(options['path'], _m0EvidencePath);
      expect(options['if-no-files-found'], 'error');
      expect(options['overwrite'], isTrue);
    }
  });

  test('validates committed M0 evidence in ordinary CI', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final dartJob = jobs['dart'] as YamlMap;
    final steps = (dartJob['steps'] as YamlList).cast<YamlMap>();
    final checkout = steps.singleWhere(
      (step) => step['uses'] == _checkoutAction,
    );
    final validation = _stepNamed(steps, 'Validate committed M0 evidence');
    final command = '${validation['run']}'.replaceAll(RegExp(r'\s+'), ' ');

    expect((checkout['with'] as YamlMap)['fetch-depth'], 0);
    expect(validation['working-directory'], 'tool/bench');
    expect(
      command,
      contains(
        'dart run bin/validate_bundle.dart '
        '--bundle ../../$_m0CommittedEvidencePath '
        '--report ../../$_m0ReportPath --repo ../..',
      ),
    );

    for (final entry in jobs.entries) {
      if (entry.key == 'dart') continue;

      final job = entry.value as YamlMap;
      final otherSteps = (job['steps'] as YamlList).cast<YamlMap>();
      for (final step in otherSteps.where(
        (step) => step['uses'] == _checkoutAction,
      )) {
        final options = step['with'];
        if (options is! YamlMap) continue;

        expect(options['fetch-depth'], isNot(0), reason: '${entry.key}');
      }
    }
  });

  test('routes every M0 shard through measured network profiles', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-runner-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final profileScript = File('${directory.path}/profile.sh');
    final benchCommand = File('${directory.path}/bench.sh');
    final packageCommand = File('${directory.path}/package.sh');
    await _writeExecutable(profileScript, _fakeProfileScript);
    await _writeExecutable(benchCommand, _fakeBenchCommand);
    await _writeExecutable(packageCommand, _fakePackageCommand);

    for (final entry in _expectedCiShardCommands.entries) {
      await commandLog.writeAsString('');
      final result = await Process.run(
        'tool/bench/run.sh',
        [entry.key],
        environment: {
          _m0CommandLogVariable: commandLog.path,
          _m0ProfileScriptVariable: profileScript.path,
          _m0BenchCommandVariable: benchCommand.path,
          _m0PackageCommandVariable: packageCommand.path,
          'POLTERGEIST_M0_STARTED_AT_EPOCH_MS': _deadlineStartMs,
          'POLTERGEIST_M0_STARTED_AT_MONOTONIC_US': _deadlineStartMonotonicUs,
        },
      );

      expect(result.exitCode, 0, reason: '${entry.key}: ${result.stderr}');
      expect(await commandLog.readAsLines(), entry.value);
    }
  });

  test('keeps the unsharded full suite local', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-local-runner-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final profileScript = File('${directory.path}/profile.sh');
    final benchCommand = File('${directory.path}/bench.sh');
    final packageCommand = File('${directory.path}/package.sh');
    await _writeExecutable(profileScript, _fakeProfileScript);
    await _writeExecutable(benchCommand, _fakeBenchCommand);
    await _writeExecutable(packageCommand, _fakePackageCommand);

    final result = await Process.run(
      'tool/bench/run.sh',
      ['full'],
      environment: {
        _m0CommandLogVariable: commandLog.path,
        _m0ProfileScriptVariable: profileScript.path,
        _m0BenchCommandVariable: benchCommand.path,
        _m0PackageCommandVariable: packageCommand.path,
      },
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(await commandLog.readAsLines(), _expectedLocalFullCommands);
  });

  test('uses the source envelope started before fixture setup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-prestarted-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final sourceFile = File('${directory.path}/bench-shard.json');
    final profileScript = File('${directory.path}/profile.sh');
    final benchCommand = File('${directory.path}/bench.sh');
    final packageCommand = File('${directory.path}/package.sh');
    await sourceFile.writeAsString('{}');
    await _writeExecutable(profileScript, _fakeProfileScript);
    await _writeExecutable(benchCommand, _fakeBenchCommand);
    await _writeExecutable(packageCommand, _fakePackageCommand);

    final result = await Process.run(
      'tool/bench/run.sh',
      ['standard'],
      environment: {
        _m0CommandLogVariable: commandLog.path,
        _m0ProfileScriptVariable: profileScript.path,
        _m0BenchCommandVariable: benchCommand.path,
        _m0PackageCommandVariable: packageCommand.path,
        _m0SourceFileVariable: sourceFile.path,
      },
    );
    final expected = [..._expectedCiShardCommands['standard']!]
      ..removeAt(0)
      ..removeLast()
      ..add(_packageFinish(0, source: sourceFile.path));

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(await commandLog.readAsLines(), expected);
  });

  test('defers CI source finalization to the fixture lifecycle', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-deferred-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final sourceFile = File('${directory.path}/bench-shard.json');
    final profileScript = File('${directory.path}/profile.sh');
    final benchCommand = File('${directory.path}/bench.sh');
    final packageCommand = File('${directory.path}/package.sh');
    await sourceFile.writeAsString('{}');
    await _writeExecutable(profileScript, _fakeProfileScript);
    await _writeExecutable(benchCommand, _fakeBenchCommand);
    await _writeExecutable(packageCommand, _fakePackageCommand);

    final result = await Process.run(
      'tool/bench/run.sh',
      ['standard'],
      environment: {
        _m0CommandLogVariable: commandLog.path,
        _m0ProfileScriptVariable: profileScript.path,
        _m0BenchCommandVariable: benchCommand.path,
        _m0PackageCommandVariable: packageCommand.path,
        _m0SourceFileVariable: sourceFile.path,
        _m0FinalizationOwnerVariable: 'lifecycle',
      },
    );
    final expected = [..._expectedCiShardCommands['standard']!]
      ..removeAt(0)
      ..removeLast();

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(await commandLog.readAsLines(), expected);
  });

  test('clears RTT and preserves the benchmark failure', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final profileScript = File('${directory.path}/profile.sh');
    final benchCommand = File('${directory.path}/bench.sh');
    final packageCommand = File('${directory.path}/package.sh');
    await _writeExecutable(profileScript, _fakeProfileScript);
    await _writeExecutable(benchCommand, _fakeFailingBenchCommand);
    await _writeExecutable(packageCommand, _fakeFailingPackageCommand);

    final result = await Process.run(
      'tool/bench/run.sh',
      ['rtt100-1gb-upload-dart-hash-on-r1'],
      environment: {
        _m0CommandLogVariable: commandLog.path,
        _m0ProfileScriptVariable: profileScript.path,
        _m0BenchCommandVariable: benchCommand.path,
        _m0PackageCommandVariable: packageCommand.path,
        'POLTERGEIST_M0_STARTED_AT_EPOCH_MS': _deadlineStartMs,
        'POLTERGEIST_M0_STARTED_AT_MONOTONIC_US': _deadlineStartMonotonicUs,
      },
    );

    expect(result.exitCode, _benchFailureExitCode);
    expect(await commandLog.readAsLines(), [
      _packageStart('rtt100-1gb-upload-dart-hash-on-r1'),
      'profile lan',
      'profile rtt100',
      'profile measure-rtt-json',
      _isolatedBench('rtt100-1gb-upload-dart-hash-on-r1'),
      'profile lan',
      _packageFinish(_benchFailureExitCode),
    ]);
  });

  test('finalizes every CI lifecycle with status precedence', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-ci-wrapper-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final sourceFile = File('${directory.path}/bench-shard.json');
    final lifecycleCommand = File('${directory.path}/lifecycle.sh');
    final packageCommand = File('${directory.path}/package.sh');
    await _writeExecutable(lifecycleCommand, _fakeLifecycleCommand);
    await _writeExecutable(packageCommand, _fakeFailingPackageCommand);

    for (final lifecycleStatus in [0, _benchFailureExitCode]) {
      await commandLog.writeAsString('');
      final result = await Process.run(
        'tool/bench/run-ci-shard.sh',
        ['standard'],
        environment: {
          _m0CommandLogVariable: commandLog.path,
          _m0LifecycleCommandVariable: lifecycleCommand.path,
          _m0LifecycleStatusVariable: '$lifecycleStatus',
          _m0PackageCommandVariable: packageCommand.path,
          _m0SourceFileVariable: sourceFile.path,
          'POLTERGEIST_M0_STARTED_AT_EPOCH_MS': _deadlineStartMs,
          'POLTERGEIST_M0_STARTED_AT_MONOTONIC_US': _deadlineStartMonotonicUs,
        },
      );
      final expectedStatus = lifecycleStatus == 0
          ? _packageFailureExitCode
          : lifecycleStatus;

      expect(result.exitCode, expectedStatus);
      expect(await commandLog.readAsLines(), [
        'lifecycle standard',
        'fixture down 0',
        _packageFinish(lifecycleStatus, source: sourceFile.path),
        _packageFinish(expectedStatus, source: sourceFile.path),
      ]);
    }
  });

  test('records teardown failure with dynamic fixture identity', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-teardown-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final sourceFile = File('${directory.path}/bench-shard.json');
    final lifecycleCommand = File('${directory.path}/lifecycle.sh');
    await _writeExecutable(lifecycleCommand, _fakeLifecycleCommand);
    final environment = {
      _m0CommandLogVariable: commandLog.path,
      _m0LifecycleCommandVariable: lifecycleCommand.path,
      _m0LifecycleStatusVariable: '0',
      _m0CleanupStatusVariable: '$_cleanupFailureExitCode',
      _m0SourceFileVariable: sourceFile.path,
      'POLTERGEIST_M0_STARTED_AT_EPOCH_MS': _deadlineStartMs,
      'DART_BIN': Platform.resolvedExecutable,
      ..._workflowEnvironment,
    };
    final started = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        'bin/package_source.dart',
        'start',
        '--output',
        sourceFile.path,
        '--shard',
        'rtt100-1gb-download-dart-hash-on-r1',
      ],
      workingDirectory: 'tool/bench',
      environment: environment,
    );
    expect(started.exitCode, 0, reason: '${started.stderr}');

    final result = await Process.run('tool/bench/run-ci-shard.sh', [
      'rtt100-1gb-download-dart-hash-on-r1',
    ], environment: environment);

    expect(result.exitCode, _cleanupFailureExitCode);
    final envelope = jsonDecode(await sourceFile.readAsString()) as Map;
    expect(envelope['state'], 'failed');
    expect(envelope['exitStatus'], _cleanupFailureExitCode);
    final fixture = (envelope['identity'] as Map)['fixture'] as Map;
    expect(fixture['tree'], _fixtureTree);
    expect(fixture['imageId'], _fixtureImageId);
  });

  test('finalizes a lifecycle failure before its trap is armed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-pre-trap-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final sourceFile = File('${directory.path}/bench-shard.json');
    final lifecycleCommand = File('${directory.path}/lifecycle.sh');
    final packageCommand = File('${directory.path}/package.sh');
    await _writeExecutable(lifecycleCommand, _fakePreTrapFailureCommand);
    await _writeExecutable(packageCommand, _fakePackageCommand);

    final result = await Process.run(
      'tool/bench/run-ci-shard.sh',
      ['standard'],
      environment: {
        _m0CommandLogVariable: commandLog.path,
        _m0LifecycleCommandVariable: lifecycleCommand.path,
        _m0PackageCommandVariable: packageCommand.path,
        _m0SourceFileVariable: sourceFile.path,
      },
    );

    expect(result.exitCode, _benchFailureExitCode);
    expect(await commandLog.readAsLines(), [
      'pre-trap lifecycle standard',
      _packageFinish(_benchFailureExitCode, source: sourceFile.path),
    ]);
  });

  test('rejects an unknown M0 shard', () async {
    final result = await Process.run('tool/bench/run.sh', ['unknown']);

    expect(result.exitCode, _usageExitCode);
    expect('${result.stderr}', contains('usage: run.sh'));
  });
}

final _repositoryRoot = Directory.current.absolute.path;
final _fixtureRoot = '$_repositoryRoot/test/integration/runtime/data';
final _uploadRoot = '$_repositoryRoot/test/integration/runtime/uploads';
final _benchOutput = '$_repositoryRoot/tool/bench/bench-results.json';
final _benchAttempts = '$_benchOutput.attempts.json';
final _benchSource = '$_repositoryRoot/tool/bench/bench-shard.json';

final _expectedCiShardCommands = <String, List<String>>{
  'standard': [
    _packageStart('standard'),
    'profile lan',
    'bench cancellation-regression',
    'bench isolate --reset',
    'profile lan',
    _throughputBench(link: 'lan'),
    'profile lan',
    'bench pipeline',
    'bench algorithms',
    'profile lan',
    'profile rtt100',
    'profile measure-rtt-json',
    _throughputBench(link: 'rtt100', slice: 'without-shaped-1gb'),
    'profile lan',
    'profile lan',
    'profile rtt100',
    'profile measure-rtt-json',
    'bench pipeline --link=rtt100 --rtt-evidence=$_measuredRttJson',
    'profile lan',
    _packageFinish(0),
  ],
  for (final shard in _m0ShardNames.skip(1))
    shard: [
      _packageStart(shard),
      'profile lan',
      'profile rtt100',
      'profile measure-rtt-json',
      _isolatedBench(shard),
      'profile lan',
      _packageFinish(0),
    ],
};

final _expectedLocalFullCommands = [
  'profile lan',
  'bench cancellation-regression',
  'bench isolate --reset',
  'profile lan',
  _throughputBench(link: 'lan'),
  'profile lan',
  'bench pipeline',
  'bench algorithms',
  'profile lan',
  'profile rtt100',
  'profile measure-rtt-json',
  _throughputBench(link: 'rtt100'),
  'profile lan',
  'profile lan',
  'profile rtt100',
  'profile measure-rtt-json',
  'bench pipeline --link=rtt100 --rtt-evidence=$_measuredRttJson',
  'profile lan',
];

String _throughputBench({
  required String link,
  String? slice,
  _OutputMode outputMode = _OutputMode.append,
}) {
  final arguments = [
    'bench throughput',
    '--link=$link',
    '--fixture-root=$_fixtureRoot',
    '--upload-root=$_uploadRoot',
    if (slice != null) '--throughput-slice=$slice',
    if (link == 'rtt100') '--rtt-evidence=$_measuredRttJson',
    if (outputMode == _OutputMode.reset) '--reset',
  ];

  return arguments.join(' ');
}

String _isolatedBench(String shard) =>
    'bench throughput --throughput-sample=$shard --link=rtt100 '
    '--deadline-start-ms=$_deadlineStartMs '
    '--deadline-start-monotonic-us=$_deadlineStartMonotonicUs '
    '--fixture-root=$_fixtureRoot --upload-root=$_uploadRoot --reset '
    '--rtt-evidence=$_measuredRttJson';

String _packageStart(String shard) =>
    'package start --output $_benchSource --shard $shard';

String _packageFinish(int status, {String? source}) =>
    'package finish --output ${source ?? _benchSource} --exit-status $status '
    '--rows $_benchOutput --attempts $_benchAttempts';

const _fakeProfileScript =
    '''#!/bin/sh
set -eu
printf 'profile %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
if [ "\${1:-}" = 'measure-rtt-json' ]; then
  printf '%s\\n' '$_measuredRttJson'
fi
''';

const _fakeBenchCommand =
    '''#!/bin/sh
set -eu
printf 'bench %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
''';

const _fakeFailingBenchCommand =
    '''#!/bin/sh
set -eu
printf 'bench %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
exit $_benchFailureExitCode
''';

const _fakePackageCommand =
    '''#!/bin/sh
set -eu
printf 'package %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
status=0
previous=''
for argument in "\$@"; do
  if [ "\$previous" = '--exit-status' ]; then
    status="\$argument"
  fi
  previous="\$argument"
done
exit "\$status"
''';

const _fakeFailingPackageCommand =
    '''#!/bin/sh
set -eu
printf 'package %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
if [ "\${1:-}" = 'finish' ]; then
  exit $_packageFailureExitCode
fi
''';

const _fakeLifecycleCommand =
    '''#!/bin/sh
set -eu
test -n "\${POLTERGEIST_M0_STARTED_AT_EPOCH_MS:-}"
test -n "\${POLTERGEIST_M0_STARTED_AT_MONOTONIC_US:-}"
printf 'lifecycle %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
export POLTERGEIST_M0_FIXTURE_TREE='$_fixtureTree'
export POLTERGEIST_M0_FIXTURE_IMAGE_ID='$_fixtureImageId'
export POLTERGEIST_M0_OPENSSH_CLIENT_VERSION='OpenSSH_10.5'
export POLTERGEIST_M0_OPENSSH_SERVER_VERSION='openssh-server-pam-10.5_p1-r1'
lifecycle_status="\$$_m0LifecycleStatusVariable"
cleanup_status="\${$_m0CleanupStatusVariable:-0}"
printf 'fixture down %s\\n' "\$cleanup_status" >> "\$$_m0CommandLogVariable"
effective_status="\$lifecycle_status"
if [ "\$effective_status" -eq 0 ]; then
  effective_status="\$cleanup_status"
fi
set +e
"\$$_integrationFinalizerVariable" "\$effective_status"
finalizer_status="\$?"
set -e
if [ "\$effective_status" -ne 0 ]; then
  exit "\$effective_status"
fi
exit "\$finalizer_status"
''';

const _fakePreTrapFailureCommand =
    '''#!/bin/sh
set -eu
printf 'pre-trap lifecycle %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
exit $_benchFailureExitCode
''';

const _workflowEnvironment = {
  'GITHUB_SHA': '0123456789abcdef0123456789abcdef01234567',
  'GITHUB_RUN_ID': '123',
  'GITHUB_RUN_ATTEMPT': '2',
  'GITHUB_JOB': 'm0_bench',
  'RUNNER_NAME': 'runner',
  'RUNNER_ARCH': 'X64',
  'ImageOS': 'ubuntu24',
  'ImageVersion': '20260901.1',
  'POLTERGEIST_M0_STARTED_AT_EPOCH_MS': _deadlineStartMs,
  'POLTERGEIST_M0_STARTED_AT_MONOTONIC_US': _deadlineStartMonotonicUs,
};
const _fixtureTree = 'fedcba9876543210fedcba9876543210fedcba98';
const _fixtureImageId =
    'sha256:0123456789abcdef0123456789abcdef'
    '0123456789abcdef0123456789abcdef';

YamlMap _stepNamed(Iterable<YamlMap> steps, String name) =>
    steps.singleWhere((step) => step['name'] == name);

List<YamlMap> _expectRetriedArtifactUpload(
  Iterable<YamlMap> steps, {
  required String firstStepId,
  required String? expectedCondition,
}) {
  final uploads = steps
      .where((step) => step['uses'] == 'actions/upload-artifact@v4')
      .toList();
  expect(uploads, hasLength(2));

  final first = uploads.first;
  expect(first['id'], firstStepId);
  expect(first['continue-on-error'], isTrue);
  if (expectedCondition != null) expect(first['if'], expectedCondition);

  final retry = uploads.last;
  expect(retry['if'], "always() && steps.$firstStepId.outcome == 'failure'");
  expect(retry.containsKey('continue-on-error'), isFalse);
  return uploads;
}

Future<void> _writeExecutable(File file, String contents) async {
  await file.writeAsString(contents);
  final chmod = await Process.run('chmod', ['700', file.path]);
  if (chmod.exitCode != 0) {
    throw StateError('chmod failed: ${chmod.stderr}');
  }
}
