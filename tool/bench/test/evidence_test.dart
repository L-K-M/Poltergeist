import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_m0_bench/evidence.dart';
import 'package:poltergeist_m0_bench/evidence_store.dart';
import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/monotonic_clock.dart';
import 'package:poltergeist_m0_bench/result_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('creates a running envelope before finalization', () async {
    final directory = await Directory.systemTemp.createTemp('m0-envelope-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/bench-shard.json';
    final identity = _identity();

    await EvidenceStore(path).start(identity);

    final decoded = jsonDecode(await File(path).readAsString()) as Map;
    expect(decoded['schemaVersion'], sourceEnvelopeSchemaVersion);
    expect(decoded['state'], EvidenceState.running.name);
    expect(decoded['identity'], identity.toJson());
    expect(decoded['deadlineStartedAtUtc'], decoded['startedAtUtc']);
    expect(decoded['finishedAtUtc'], isNull);
    expect(decoded['rows'], isEmpty);
    expect(decoded['attempts'], isEmpty);
  });

  test('rejects a lifecycle anchor beyond current uptime', () async {
    final directory = await Directory.systemTemp.createTemp(
      'm0-future-anchor-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const currentUptime = Duration(seconds: 10);
    final store = EvidenceStore(
      '${directory.path}/bench-shard.json',
      monotonicClock: () => currentUptime,
    );

    await expectLater(
      store.start(
        _identity(),
        deadlineStartedAtMonotonic:
            currentUptime + const Duration(microseconds: 1),
      ),
      throwsA(isA<EvidenceException>()),
    );
  });

  test('finalizes success from rows and attempts atomically', () async {
    final directory = await Directory.systemTemp.createTemp('m0-finalize-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/bench-shard.json';
    final rowsPath = '${directory.path}/rows.json';
    final attemptsPath = '${directory.path}/attempts.json';
    await File(rowsPath).writeAsString('[{"scenario":"example"}]');
    await File(attemptsPath).writeAsString('[{"reference":"trial-1"}]');
    final store = EvidenceStore(path);
    await store.start(_identity());

    await store.finish(
      exitStatus: 0,
      rowsPath: rowsPath,
      attemptsPath: attemptsPath,
      finalIdentity: _identity(),
    );

    final envelope = await store.read();
    expect(envelope.state, EvidenceState.succeeded);
    expect(envelope.rows, hasLength(1));
    expect(envelope.attempts, hasLength(1));
    expect(envelope.finishedAtUtc, isNotNull);
    expect(envelope.failure, isNull);
    final terminalBytes = await File(path).readAsBytes();
    await store.finish(
      exitStatus: 0,
      rowsPath: rowsPath,
      attemptsPath: attemptsPath,
      finalIdentity: _identity(),
    );
    expect(await File(path).readAsBytes(), terminalBytes);
    expect(
      () => store.finish(
        exitStatus: 1,
        rowsPath: rowsPath,
        attemptsPath: attemptsPath,
        finalIdentity: _identity(),
      ),
      throwsA(isA<EvidenceException>()),
    );
  });

  test(
    'records failed measurements even when evidence files are absent',
    () async {
      final directory = await Directory.systemTemp.createTemp('m0-failure-');
      addTearDown(() => directory.delete(recursive: true));
      final store = EvidenceStore('${directory.path}/bench-shard.json');
      await store.start(_identity());

      await store.finish(
        exitStatus: 17,
        rowsPath: '${directory.path}/missing-rows.json',
        attemptsPath: '${directory.path}/missing-attempts.json',
        finalIdentity: _identity(),
      );

      final envelope = await store.read();
      expect(envelope.state, EvidenceState.failed);
      expect(envelope.exitStatus, 17);
      expect(envelope.failure, 'benchmark exited with status 17');
      expect(envelope.rows, isEmpty);
      expect(envelope.attempts, isEmpty);
    },
  );

  test('rejects unresolved identity on successful finalization', () async {
    final directory = await Directory.systemTemp.createTemp('m0-unresolved-');
    addTearDown(() => directory.delete(recursive: true));
    final rowsPath = '${directory.path}/rows.json';
    final attemptsPath = '${directory.path}/attempts.json';
    await File(rowsPath).writeAsString('[]');
    await File(attemptsPath).writeAsString('[]');
    final unresolved = SourceIdentity.fromEnvironment(
      shardId: 'standard',
      environment: const {},
      phase: IdentityCapturePhase.running,
    );
    final store = EvidenceStore('${directory.path}/bench-shard.json');
    await store.start(unresolved);

    expect(
      () => store.finish(
        exitStatus: 0,
        rowsPath: rowsPath,
        attemptsPath: attemptsPath,
        finalIdentity: unresolved,
      ),
      throwsA(isA<EvidenceException>()),
    );
  });

  test('package CLI enriches pending fixture identity at finish', () async {
    final directory = await Directory.systemTemp.createTemp('m0-cli-');
    addTearDown(() => directory.delete(recursive: true));
    final workflowEnvironment = _workflowEnvironment();
    final envelopePath = '${directory.path}/bench-shard.json';
    final rowsPath = '${directory.path}/rows.json';
    final attemptsPath = '${directory.path}/attempts.json';
    await File(rowsPath).writeAsString('[]');
    await File(attemptsPath).writeAsString('[]');

    final started = await _runPackageSource([
      'start',
      '--output',
      envelopePath,
      '--shard',
      'standard',
    ], workflowEnvironment);
    expect(started.exitCode, 0);
    final running = await EvidenceStore(envelopePath).read();
    expect(running.state, EvidenceState.running);
    expect(running.identity.fixture.tree, startsWith(pendingIdentityPrefix));
    expect(
      running.deadlineStartedAtUtc,
      DateTime.fromMillisecondsSinceEpoch(
        int.parse(workflowEnvironment[_deadlineStartVariable]!),
        isUtc: true,
      ),
    );
    expect(
      running.deadlineStartedAtMonotonic,
      Duration(
        microseconds: int.parse(workflowEnvironment[_monotonicStartVariable]!),
      ),
    );

    final finished = await _runPackageSource(
      [
        'finish',
        '--output',
        envelopePath,
        '--exit-status',
        '0',
        '--rows',
        rowsPath,
        '--attempts',
        attemptsPath,
      ],
      {...workflowEnvironment, ..._fixtureEnvironment},
    );
    expect(finished.exitCode, 0);
    final envelope = await EvidenceStore(envelopePath).read();
    expect(envelope.state, EvidenceState.succeeded);
    expect(
      envelope.identity.fixture.tree,
      _fixtureEnvironment['POLTERGEIST_M0_FIXTURE_TREE'],
    );
  });

  test(
    'package CLI preserves failure status across idempotent finish',
    () async {
      const exitStatusValueIndex = 4;
      final directory = await Directory.systemTemp.createTemp(
        'm0-cli-failure-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final workflowEnvironment = _workflowEnvironment();
      final envelopePath = '${directory.path}/bench-shard.json';
      final finishArguments = [
        'finish',
        '--output',
        envelopePath,
        '--exit-status',
        '23',
        '--rows',
        '${directory.path}/missing-rows.json',
        '--attempts',
        '${directory.path}/missing-attempts.json',
      ];
      final started = await _runPackageSource([
        'start',
        '--output',
        envelopePath,
        '--shard',
        'standard',
      ], workflowEnvironment);
      expect(started.exitCode, 0);

      final firstFinish = await _runPackageSource(
        finishArguments,
        workflowEnvironment,
      );
      expect(firstFinish.exitCode, 23);
      final terminalBytes = await File(envelopePath).readAsBytes();

      final repeatedFinish = await _runPackageSource(
        finishArguments,
        workflowEnvironment,
      );
      expect(repeatedFinish.exitCode, 23);
      expect(await File(envelopePath).readAsBytes(), terminalBytes);

      final mismatch = await _runPackageSource(
        [...finishArguments]..[exitStatusValueIndex] = '22',
        workflowEnvironment,
      );
      expect(mismatch.exitCode, 65);
      expect(await File(envelopePath).readAsBytes(), terminalBytes);
    },
  );

  test('fails an isolated source beyond its lifecycle deadline', () async {
    final directory = await Directory.systemTemp.createTemp('m0-deadline-');
    addTearDown(() => directory.delete(recursive: true));
    final rowsPath = '${directory.path}/rows.json';
    final attemptsPath = '${directory.path}/attempts.json';
    await File(rowsPath).writeAsString('[]');
    await File(attemptsPath).writeAsString('[]');
    var now = DateTime.utc(2026, 9, 1, 12);
    var monotonicNow = Duration.zero;
    final deadlineStartedAt = now;
    final store = EvidenceStore(
      '${directory.path}/bench-shard.json',
      clock: () => now,
      monotonicClock: () => monotonicNow,
    );
    await store.start(
      _identity(shardId: isolatedSourceSpecs.first.id),
      deadlineStartedAtUtc: deadlineStartedAt,
    );
    now = deadlineStartedAt
        .add(isolatedSourceLifecycleBudget)
        .add(const Duration(microseconds: 1));
    monotonicNow =
        isolatedSourceLifecycleBudget + const Duration(microseconds: 1);

    final status = await store.finish(
      exitStatus: 0,
      rowsPath: rowsPath,
      attemptsPath: attemptsPath,
      finalIdentity: _identity(shardId: isolatedSourceSpecs.first.id),
    );

    final envelope = await store.read();
    expect(status, isolatedSourceDeadlineExitStatus);
    expect(envelope.state, EvidenceState.failed);
    expect(envelope.exitStatus, isolatedSourceDeadlineExitStatus);
    expect(envelope.finishedAtUtc, now);
  });

  test('accepts an isolated source at its exact deadline', () async {
    final directory = await Directory.systemTemp.createTemp(
      'm0-deadline-boundary-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final rowsPath = '${directory.path}/rows.json';
    final attemptsPath = '${directory.path}/attempts.json';
    await File(rowsPath).writeAsString('[]');
    await File(attemptsPath).writeAsString('[]');
    var now = DateTime.utc(2026, 9, 1, 12);
    var monotonicNow = Duration.zero;
    final deadlineStartedAt = now;
    final shardId = isolatedSourceSpecs.first.id;
    final store = EvidenceStore(
      '${directory.path}/bench-shard.json',
      clock: () => now,
      monotonicClock: () => monotonicNow,
    );
    await store.start(
      _identity(shardId: shardId),
      deadlineStartedAtUtc: deadlineStartedAt,
    );
    now = deadlineStartedAt.add(isolatedSourceLifecycleBudget);
    monotonicNow = isolatedSourceLifecycleBudget;

    final status = await store.finish(
      exitStatus: 0,
      rowsPath: rowsPath,
      attemptsPath: attemptsPath,
      finalIdentity: _identity(shardId: shardId),
    );

    expect(status, 0);
    expect((await store.read()).state, EvidenceState.succeeded);
  });

  test('includes terminal persistence in the monotonic deadline', () async {
    final directory = await Directory.systemTemp.createTemp(
      'm0-monotonic-deadline-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final rowsPath = '${directory.path}/rows.json';
    final attemptsPath = '${directory.path}/attempts.json';
    await File(rowsPath).writeAsString('[]');
    await File(attemptsPath).writeAsString('[]');
    final startedAtUtc = DateTime.utc(2026, 9, 1, 12);
    var wallNow = startedAtUtc;
    var monotonicRead = 0;
    final monotonicValues = [
      Duration.zero,
      isolatedSourceLifecycleBudget,
      isolatedSourceLifecycleBudget + const Duration(microseconds: 1),
    ];
    final shardId = isolatedSourceSpecs.first.id;
    final store = EvidenceStore(
      '${directory.path}/bench-shard.json',
      clock: () => wallNow,
      monotonicClock: () => monotonicValues[monotonicRead++],
    );
    await store.start(
      _identity(shardId: shardId),
      deadlineStartedAtUtc: startedAtUtc,
    );

    // A backwards wall-clock jump cannot hide the monotonic overrun.
    wallNow = startedAtUtc.subtract(const Duration(hours: 1));
    final status = await store.finish(
      exitStatus: 0,
      rowsPath: rowsPath,
      attemptsPath: attemptsPath,
      finalIdentity: _identity(shardId: shardId),
    );

    final envelope = await store.read();
    expect(status, isolatedSourceDeadlineExitStatus);
    expect(envelope.state, EvidenceState.failed);
    expect(
      envelope.lifecycleElapsed,
      isolatedSourceLifecycleBudget + const Duration(microseconds: 1),
    );
  });

  test('does not apply the isolated deadline to the standard source', () async {
    final directory = await Directory.systemTemp.createTemp(
      'm0-standard-deadline-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final rowsPath = '${directory.path}/rows.json';
    final attemptsPath = '${directory.path}/attempts.json';
    await File(rowsPath).writeAsString('[]');
    await File(attemptsPath).writeAsString('[]');
    var now = DateTime.utc(2026, 9, 1, 12);
    var monotonicNow = Duration.zero;
    final deadlineStartedAt = now;
    final store = EvidenceStore(
      '${directory.path}/bench-shard.json',
      clock: () => now,
      monotonicClock: () => monotonicNow,
    );
    await store.start(_identity(), deadlineStartedAtUtc: deadlineStartedAt);
    now = deadlineStartedAt.add(const Duration(hours: 6));
    monotonicNow = const Duration(hours: 6);

    final status = await store.finish(
      exitStatus: 0,
      rowsPath: rowsPath,
      attemptsPath: attemptsPath,
      finalIdentity: _identity(),
    );

    expect(status, 0);
    expect((await store.read()).state, EvidenceState.succeeded);
  });
}

Map<String, String> _workflowEnvironment() => {
  'GITHUB_SHA': '0123456789abcdef0123456789abcdef01234567',
  'GITHUB_RUN_ID': '123',
  'GITHUB_RUN_ATTEMPT': '2',
  'GITHUB_JOB': 'm0_bench',
  'RUNNER_NAME': 'runner',
  'RUNNER_ARCH': 'X64',
  'ImageOS': 'ubuntu24',
  'ImageVersion': '20260901.1',
  _deadlineStartVariable: '1788220800000',
  _monotonicStartVariable: '${HostMonotonicClock.read().inMicroseconds}',
};

const _deadlineStartVariable = 'POLTERGEIST_M0_STARTED_AT_EPOCH_MS';
const _monotonicStartVariable = 'POLTERGEIST_M0_STARTED_AT_MONOTONIC_US';

const _fixtureEnvironment = {
  'POLTERGEIST_M0_FIXTURE_TREE': 'fedcba9876543210fedcba9876543210fedcba98',
  'POLTERGEIST_M0_FIXTURE_IMAGE_ID':
      'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  'POLTERGEIST_M0_OPENSSH_CLIENT_VERSION': 'OpenSSH_10.5',
  'POLTERGEIST_M0_OPENSSH_SERVER_VERSION': 'openssh-server-pam-10.5_p1-r1',
};

Future<ProcessResult> _runPackageSource(
  List<String> arguments,
  Map<String, String> environment,
) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/package_source.dart', ...arguments],
  workingDirectory: _packageRoot,
  environment: environment,
  includeParentEnvironment: false,
);

String get _packageRoot {
  final current = Directory.current.path;
  if (File('$current/tool/bench/pubspec.yaml').existsSync()) {
    return '$current/tool/bench';
  }

  return current;
}

SourceIdentity _identity({String shardId = standardSourceId}) => SourceIdentity(
  poltergeistSha: '0123456789abcdef0123456789abcdef01234567',
  workflowRunId: '123',
  workflowRunAttempt: 2,
  shardId: shardId,
  host: 'runner',
  runtime: RuntimeIdentity(
    dartVersion: '3.13.2',
    operatingSystem: 'linux',
    operatingSystemVersion: 'Linux test',
    architecture: 'X64',
    runnerName: 'runner',
    runnerImage: 'ubuntu24',
    runnerImageVersion: '20260901.1',
  ),
  dependencies: DependencyIdentity(
    dartssh2Version: resolvedDartssh2Version,
    seanceRevision: pinnedSeanceRevision,
  ),
  fixture: FixtureIdentity(
    tree: 'fedcba9876543210fedcba9876543210fedcba98',
    imageId:
        'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    openSshClientVersion: 'OpenSSH_10.5',
    openSshServerVersion: 'openssh-server-pam-10.5_p1-r1',
    dataVersion: 2,
  ),
);
