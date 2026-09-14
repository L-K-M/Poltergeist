import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_m0_bench/config.dart';
import 'package:poltergeist_m0_bench/result_store.dart';
import 'package:poltergeist_m0_bench/src/throughput_execution.dart';
import 'package:poltergeist_m0_bench/ssh_driver.dart';
import 'package:poltergeist_m0_bench/throughput_attempt.dart';
import 'package:test/test.dart';

const _remoteRoot = '/bench';
const _warmupContents = 'w';
const _trialContents = 'trial';
const _transferElapsed = Duration(microseconds: 17);
const _transferTimeout = Duration(seconds: 1);

void main() {
  test(
    'all variants execute direction-correct verified transfer paths',
    () async {
      final fixture = await _ExecutionFixture.create();
      addTearDown(fixture.close);
      final pathsByLeg = <ThroughputLeg, Set<String>>{};

      for (final direction in ThroughputLeg.values) {
        for (final variant in ThroughputVariant.values) {
          final driver = _RecordingDriver(
            variant: variant,
            uploadRoot: fixture.uploads,
          );
          final evidence = await fixture.runtime.runTrial(
            driver: driver,
            scenario: '${variant.cliValue}-${direction.name}',
            direction: direction,
            payload: fixture.trialPayload,
            warmupPayload: fixture.warmupPayload,
            ordinal: 1,
            replicate: ThroughputReplicate.first,
            warmupTimeout: () => _transferTimeout,
            trialTimeout: () => _transferTimeout,
          );

          _expectSourceOnlyPrimes(evidence, fixture, direction);
          _expectVerifiedDestinations(evidence, fixture, direction);
          _expectDirectionPaths(driver.calls, fixture, direction);
          _expectUniqueAbsentDestinations(driver.calls);
          pathsByLeg
              .putIfAbsent(direction, () => <String>{})
              .add(_pathShape(driver.calls));
        }
      }

      final attempts = await fixture.readAttempts();
      final primes = attempts
          .where((attempt) => attempt.phase == ThroughputAttemptPhase.prime)
          .toList();
      expect(primes, hasLength(4));
      expect(primes.every((prime) => prime.variant == null), isTrue);
      expect(
        primes
            .map((prime) => '${prime.direction.name}:${prime.payloadBytes}')
            .toSet(),
        hasLength(4),
      );

      // Dart and OpenSSH must measure the same sources and destination roots.
      for (final shapes in pathsByLeg.values) {
        expect(shapes.toSet(), hasLength(1));
      }
    },
  );

  test('post-timing verification rejects every corrupt destination', () async {
    for (final direction in ThroughputLeg.values) {
      for (final variant in ThroughputVariant.values) {
        final fixture = await _ExecutionFixture.create();
        addTearDown(fixture.close);
        final driver = _RecordingDriver(
          variant: variant,
          uploadRoot: fixture.uploads,
          content: _TransferContent.corruptTrial,
        );

        await expectLater(
          fixture.runtime.runTrial(
            driver: driver,
            scenario: '${variant.cliValue}-${direction.name}',
            direction: direction,
            payload: fixture.trialPayload,
            warmupPayload: fixture.warmupPayload,
            ordinal: 1,
            replicate: ThroughputReplicate.first,
            warmupTimeout: () => _transferTimeout,
            trialTimeout: () => _transferTimeout,
          ),
          throwsStateError,
        );

        final attempts = await fixture.readAttempts();
        final trial = attempts.singleWhere(
          (attempt) => attempt.phase == ThroughputAttemptPhase.trial,
        );
        expect(trial.status, ThroughputAttemptStatus.failure);
        expect(trial.elapsed, _transferElapsed);
        expect(trial.integrity.status, ThroughputIntegrityStatus.failed);
      }
    }
  });
}

void _expectSourceOnlyPrimes(
  ThroughputTrialEvidence evidence,
  _ExecutionFixture fixture,
  ThroughputLeg direction,
) {
  expect(evidence.sourcePrime.direction, direction);
  expect(evidence.sourcePrime.variant, isNull);
  expect(evidence.sourcePrime.phase, ThroughputAttemptPhase.prime);
  expect(evidence.sourcePrime.integrity.destination, fixture.trialFile.path);
  expect(evidence.sourcePrime.integrity.isVerified, isTrue);
  expect(evidence.warmupSourcePrime.direction, direction);
  expect(evidence.warmupSourcePrime.variant, isNull);
  expect(
    evidence.warmupSourcePrime.integrity.destination,
    fixture.warmupFile.path,
  );
  expect(evidence.warmupSourcePrime.integrity.isVerified, isTrue);
  expect(
    evidence.sourcePrime.endedAtUtc!.isAfter(evidence.warmup.startedAtUtc),
    isFalse,
  );
  expect(
    evidence.warmupSourcePrime.endedAtUtc!.isAfter(
      evidence.warmup.startedAtUtc,
    ),
    isFalse,
  );
}

void _expectVerifiedDestinations(
  ThroughputTrialEvidence evidence,
  _ExecutionFixture fixture,
  ThroughputLeg direction,
) {
  final expectedRoot = direction == ThroughputLeg.download
      ? fixture.scratch.path
      : fixture.uploads.path;
  for (final attempt in [evidence.warmup, evidence.trial]) {
    expect(attempt.integrity.destination, startsWith('$expectedRoot/'));
    expect(attempt.integrity.isVerified, isTrue);
    expect(attempt.integrity.actualBytes, attempt.payloadBytes);
    expect(attempt.integrity.actualSha256, attempt.integrity.expectedSha256);
    expect(attempt.elapsed, _transferElapsed);
  }
}

void _expectDirectionPaths(
  List<_TransferCall> calls,
  _ExecutionFixture fixture,
  ThroughputLeg direction,
) {
  if (direction == ThroughputLeg.download) {
    expect(calls.first.source, '$_remoteRoot/fixtures/payload-warmup.bin');
    expect(calls.last.source, '$_remoteRoot/fixtures/payload-trial.bin');
  } else {
    expect(calls.first.source, fixture.warmupFile.path);
    expect(calls.last.source, fixture.trialFile.path);
  }

  for (final call in calls) {
    final expectedDestinationRoot = direction == ThroughputLeg.download
        ? fixture.scratch.path
        : '$_remoteRoot/uploads/host';
    expect(File(call.destination).parent.path, expectedDestinationRoot);
  }
}

void _expectUniqueAbsentDestinations(List<_TransferCall> calls) {
  expect(calls, hasLength(2));
  expect(calls.map((call) => call.destination).toSet(), hasLength(2));
  expect(
    calls.map((call) => call.verificationDestination).toSet(),
    hasLength(2),
  );
  expect(calls.every((call) => !call.destinationExisted), isTrue);
}

class _ExecutionFixture {
  final Directory root;
  final Directory scratch;
  final Directory uploads;
  final File warmupFile;
  final File trialFile;
  final String outputPath;
  final ThroughputExecutionRuntime runtime;
  final ThroughputExecutionPayload warmupPayload;
  final ThroughputExecutionPayload trialPayload;

  const _ExecutionFixture._({
    required this.root,
    required this.scratch,
    required this.uploads,
    required this.warmupFile,
    required this.trialFile,
    required this.outputPath,
    required this.runtime,
    required this.warmupPayload,
    required this.trialPayload,
  });

  static Future<_ExecutionFixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'poltergeist-throughput-execution-',
    );
    final fixtureRoot = Directory('${root.path}/fixtures')
      ..createSync(recursive: true);
    final scratch = Directory('${root.path}/scratch')
      ..createSync(recursive: true);
    final uploads = Directory('${root.path}/uploads')
      ..createSync(recursive: true);
    final warmupPayload = _payload('warmup', _warmupContents);
    final trialPayload = _payload('trial', _trialContents);
    final warmupFile = File(
      '${fixtureRoot.path}/payload-${warmupPayload.label}.bin',
    )..writeAsStringSync(_warmupContents);
    final trialFile = File(
      '${fixtureRoot.path}/payload-${trialPayload.label}.bin',
    )..writeAsStringSync(_trialContents);
    final outputPath = '${root.path}/results.json';
    final config = BenchConfig(
      endpoint: const BenchEndpoint(),
      remoteRoot: _remoteRoot,
      identityFile: 'unused',
      outputFile: outputPath,
      linkName: 'test',
      fixtureRoot: fixtureRoot.path,
      uploadRoot: uploads.path,
      rttEvidence: null,
    );
    final runtime = ThroughputExecutionRuntime(
      config: config,
      scratch: scratch,
      store: ThroughputAttemptStore(throughputAttemptOutputPath(outputPath)),
    );

    return _ExecutionFixture._(
      root: root,
      scratch: scratch,
      uploads: uploads,
      warmupFile: warmupFile,
      trialFile: trialFile,
      outputPath: outputPath,
      runtime: runtime,
      warmupPayload: warmupPayload,
      trialPayload: trialPayload,
    );
  }

  Future<List<ThroughputAttempt>> readAttempts() async {
    final source = await File(
      throughputAttemptOutputPath(outputPath),
    ).readAsString();
    final rows = jsonDecode(source) as List<Object?>;
    return rows
        .map(
          (row) =>
              ThroughputAttempt.fromJson((row! as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<void> close() => root.delete(recursive: true);
}

ThroughputExecutionPayload _payload(String label, String contents) =>
    ThroughputExecutionPayload(
      label: label,
      bytes: utf8.encode(contents).length,
      digest: sha256.convert(utf8.encode(contents)).toString(),
    );

class _RecordingDriver implements ThroughputExecutionDriver {
  @override
  final ThroughputVariant variant;
  final Directory uploadRoot;
  final _TransferContent content;
  final List<_TransferCall> calls = [];

  _RecordingDriver({
    required this.variant,
    required this.uploadRoot,
    this.content = _TransferContent.valid,
  });

  @override
  Future<ThroughputTransferResult> download({
    required String remoteSource,
    required File localDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  }) async {
    final destinationExisted = await localDestination.exists();
    calls.add(
      _TransferCall(
        direction: ThroughputLeg.download,
        source: remoteSource,
        destination: localDestination.path,
        verificationDestination: localDestination.path,
        destinationExisted: destinationExisted,
      ),
    );
    await _writeDestination(localDestination, payload);

    return _result(payload);
  }

  @override
  Future<ThroughputTransferResult> upload({
    required File localSource,
    required String remoteDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  }) async {
    final localDestination = File(
      '${uploadRoot.path}/${File(remoteDestination).uri.pathSegments.last}',
    );
    final destinationExisted = await localDestination.exists();
    calls.add(
      _TransferCall(
        direction: ThroughputLeg.upload,
        source: localSource.path,
        destination: remoteDestination,
        verificationDestination: localDestination.path,
        destinationExisted: destinationExisted,
      ),
    );
    await _writeDestination(localDestination, payload);

    return _result(payload);
  }

  Future<void> _writeDestination(
    File destination,
    ThroughputExecutionPayload payload,
  ) async {
    final corrupt =
        content == _TransferContent.corruptTrial && payload.label == 'trial';
    final contents = payload.label == 'warmup'
        ? _warmupContents
        : _trialContents;
    await destination.writeAsString(corrupt ? 'corrupt' : contents);
  }

  ThroughputTransferResult _result(ThroughputExecutionPayload payload) =>
      ThroughputTransferResult(
        bytes: variant == ThroughputVariant.openssh ? null : payload.bytes,
        digest: variant == ThroughputVariant.dartHashOn ? payload.digest : null,
        elapsed: _transferElapsed,
      );

  @override
  Future<void> deleteRemote(String path, {required Duration timeout}) async {
    final call = calls.lastWhere((candidate) => candidate.destination == path);
    final destination = File(call.verificationDestination);
    if (await destination.exists()) await destination.delete();
  }

  @override
  Future<void> close() async {}
}

enum _TransferContent { valid, corruptTrial }

class _TransferCall {
  final ThroughputLeg direction;
  final String source;
  final String destination;
  final String verificationDestination;
  final bool destinationExisted;

  const _TransferCall({
    required this.direction,
    required this.source,
    required this.destination,
    required this.verificationDestination,
    required this.destinationExisted,
  });
}

String _pathShape(List<_TransferCall> calls) => calls
    .map(
      (call) => [
        call.direction.name,
        call.source,
        File(call.destination).parent.path,
        File(call.verificationDestination).parent.path,
      ].join('|'),
    )
    .join('\n');
