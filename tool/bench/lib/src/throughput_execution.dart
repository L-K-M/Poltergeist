import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../config.dart';
import '../result_store.dart';
import '../ssh_driver.dart';
import '../throughput_attempt.dart';

const _cleanupTimeout = Duration(minutes: 5);
const _hostUploadDirectory = 'host';

typedef ThroughputExecutionTimeout = Duration Function();

/// Package-internal payload identity used by every throughput driver.
class ThroughputExecutionPayload {
  final String label;
  final int bytes;
  final String digest;

  const ThroughputExecutionPayload({
    required this.label,
    required this.bytes,
    required this.digest,
  });
}

/// Package-internal driver boundary shared by Dart and OpenSSH execution.
abstract interface class ThroughputExecutionDriver {
  ThroughputVariant get variant;

  Future<ThroughputTransferResult> download({
    required String remoteSource,
    required File localDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  });

  Future<ThroughputTransferResult> upload({
    required File localSource,
    required String remoteDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  });

  Future<void> deleteRemote(String path, {required Duration timeout});

  Future<void> close();
}

/// Executes the same prime, transfer, and verification path for every driver.
class ThroughputExecutionRuntime {
  final BenchConfig _config;
  final Directory _scratch;
  final ThroughputAttemptStore _store;
  final _ReferenceFactory _references = _ReferenceFactory();
  final Map<String, ThroughputAttempt> _primes = {};

  factory ThroughputExecutionRuntime({
    required BenchConfig config,
    required Directory scratch,
    required ThroughputAttemptStore store,
  }) => ThroughputExecutionRuntime._(config, scratch, store);

  ThroughputExecutionRuntime._(this._config, this._scratch, this._store);

  Future<ThroughputAttempt> prime(
    ThroughputLeg direction,
    ThroughputExecutionPayload payload,
  ) async {
    final key = '${direction.name}:${payload.label}';
    final existing = _primes[key];
    if (existing != null) return existing;

    // The bind-mounted download fixture and runner upload file share this
    // host path, so priming never sends payload bytes over the shaped link.
    final source = _fixtureFile(payload);
    final scenario =
        '${direction.name}-${payload.label}-${_config.linkName}-source-prime';
    final reference = _references.next(scenario, ThroughputAttemptPhase.prime);
    final running = ThroughputAttempt(
      reference: reference,
      scenario: scenario,
      direction: direction,
      variant: null,
      replicate: null,
      ordinal: null,
      phase: ThroughputAttemptPhase.prime,
      payloadBytes: payload.bytes,
      status: ThroughputAttemptStatus.running,
      startedAtUtc: DateTime.now().toUtc(),
      endedAtUtc: null,
      elapsed: null,
      primeReference: null,
      warmupReference: null,
      rttEvidence: _config.rttEvidence,
      integrity: ThroughputIntegrityEvidence(
        status: ThroughputIntegrityStatus.pending,
        expectedBytes: payload.bytes,
        expectedSha256: payload.digest,
        destination: source.path,
      ),
    );
    await _store.checkpoint(running);

    final stopwatch = Stopwatch()..start();
    final integrity = await inspectThroughputFile(
      source,
      expectedBytes: payload.bytes,
      expectedDigest: payload.digest,
    );
    stopwatch.stop();
    final status = integrity.isVerified
        ? ThroughputAttemptStatus.success
        : ThroughputAttemptStatus.failure;
    final completed = running.finish(
      status: status,
      endedAtUtc: DateTime.now().toUtc(),
      elapsed: stopwatch.elapsed,
      integrity: integrity,
      error: integrity.isVerified ? null : integrity.detail,
    );
    await _store.checkpoint(completed);
    if (!integrity.isVerified) {
      throw StateError('Source prime failed: ${integrity.detail}');
    }

    _primes[key] = completed;
    return completed;
  }

  Future<ThroughputTrialEvidence> runTrial({
    required ThroughputExecutionDriver driver,
    required String scenario,
    required ThroughputLeg direction,
    required ThroughputExecutionPayload payload,
    required ThroughputExecutionPayload warmupPayload,
    required int? ordinal,
    required ThroughputReplicate? replicate,
    required ThroughputExecutionTimeout warmupTimeout,
    required ThroughputExecutionTimeout trialTimeout,
  }) async {
    final sourcePrime = await prime(direction, payload);
    final warmupSourcePrime = await prime(direction, warmupPayload);
    final warmup = await _runTransfer(
      driver: driver,
      scenario: scenario,
      direction: direction,
      payload: warmupPayload,
      phase: ThroughputAttemptPhase.warmup,
      ordinal: ordinal,
      replicate: replicate,
      primeReference: warmupSourcePrime.reference,
      warmupReference: null,
      timeout: warmupTimeout,
    );
    final trial = await _runTransfer(
      driver: driver,
      scenario: scenario,
      direction: direction,
      payload: payload,
      phase: ThroughputAttemptPhase.trial,
      ordinal: ordinal,
      replicate: replicate,
      primeReference: sourcePrime.reference,
      warmupReference: warmup.reference,
      timeout: trialTimeout,
    );

    return ThroughputTrialEvidence(
      sourcePrime: sourcePrime,
      warmupSourcePrime: warmupSourcePrime,
      warmup: warmup,
      trial: trial,
    );
  }

  Future<ThroughputAttempt> _runTransfer({
    required ThroughputExecutionDriver driver,
    required String scenario,
    required ThroughputLeg direction,
    required ThroughputExecutionPayload payload,
    required ThroughputAttemptPhase phase,
    required int? ordinal,
    required ThroughputReplicate? replicate,
    required String primeReference,
    required String? warmupReference,
    required ThroughputExecutionTimeout timeout,
  }) async {
    final reference = _references.next(scenario, phase);
    final basename = '$reference.bin';
    final localSource = _fixtureFile(payload);
    final localDestination = direction == ThroughputLeg.download
        ? File('${_scratch.path}/$basename')
        : File('${_config.uploadRoot}/$basename');
    final remoteSource =
        '${_config.remoteRoot}/fixtures/payload-${payload.label}.bin';
    final remoteDestination =
        '${_config.remoteRoot}/uploads/$_hostUploadDirectory/$basename';
    final startedAtUtc = DateTime.now().toUtc();
    final running = ThroughputAttempt(
      reference: reference,
      scenario: scenario,
      direction: direction,
      variant: driver.variant,
      replicate: replicate,
      ordinal: ordinal,
      phase: phase,
      payloadBytes: payload.bytes,
      status: ThroughputAttemptStatus.running,
      startedAtUtc: startedAtUtc,
      endedAtUtc: null,
      elapsed: null,
      primeReference: primeReference,
      warmupReference: warmupReference,
      rttEvidence: _config.rttEvidence,
      integrity: ThroughputIntegrityEvidence(
        status: ThroughputIntegrityStatus.pending,
        expectedBytes: payload.bytes,
        expectedSha256: payload.digest,
        destination: localDestination.path,
      ),
    );
    await _store.checkpoint(running);

    ThroughputTransferResult? transfer;
    ThroughputIntegrityEvidence? checkedIntegrity;
    var successCheckpointed = false;
    final failureClock = Stopwatch()..start();
    try {
      final transferTimeout = timeout();
      if (await localDestination.exists()) {
        throw StateError(
          'Destination already exists: ${localDestination.path}',
        );
      }
      transfer = direction == ThroughputLeg.download
          ? await driver.download(
              remoteSource: remoteSource,
              localDestination: localDestination,
              payload: payload,
              timeout: transferTimeout,
            )
          : await driver.upload(
              localSource: localSource,
              remoteDestination: remoteDestination,
              payload: payload,
              timeout: transferTimeout,
            );
      failureClock.stop();
      _validateDriverResult(driver.variant, transfer, payload);

      // Destination hashing is outside the driver-reported transfer time.
      checkedIntegrity = await inspectThroughputFile(
        localDestination,
        expectedBytes: payload.bytes,
        expectedDigest: payload.digest,
      );
      if (!checkedIntegrity.isVerified) {
        throw StateError(
          checkedIntegrity.detail ?? 'Integrity verification failed.',
        );
      }

      final success = running.finish(
        status: ThroughputAttemptStatus.success,
        endedAtUtc: DateTime.now().toUtc(),
        elapsed: transfer.elapsed,
        integrity: checkedIntegrity,
      );
      await _store.checkpoint(success);
      successCheckpointed = true;

      if (direction == ThroughputLeg.download) {
        await localDestination.delete();
      } else {
        await driver.deleteRemote(remoteDestination, timeout: _cleanupTimeout);
      }
      return success;
    } catch (error) {
      if (successCheckpointed) rethrow;

      failureClock.stop();
      final integrity =
          checkedIntegrity ??
          await inspectThroughputFile(
            localDestination,
            expectedBytes: payload.bytes,
            expectedDigest: payload.digest,
          );
      final status = error is TimeoutException
          ? ThroughputAttemptStatus.timeout
          : ThroughputAttemptStatus.failure;
      final failed = running.finish(
        status: status,
        endedAtUtc: DateTime.now().toUtc(),
        elapsed: transfer?.elapsed ?? failureClock.elapsed,
        integrity: integrity,
        error: '${error.runtimeType}: $error',
      );
      await _store.checkpoint(failed);
      rethrow;
    }
  }

  File _fixtureFile(ThroughputExecutionPayload payload) =>
      File('${_config.fixtureRoot}/payload-${payload.label}.bin');
}

Future<ThroughputIntegrityEvidence> inspectThroughputFile(
  File file, {
  required int expectedBytes,
  required String expectedDigest,
}) async {
  try {
    if (!await file.exists()) {
      return ThroughputIntegrityEvidence(
        status: ThroughputIntegrityStatus.failed,
        expectedBytes: expectedBytes,
        expectedSha256: expectedDigest,
        destination: file.path,
        detail: 'Destination is absent.',
      );
    }

    final actualBytes = await file.length();
    final actualDigest = (await sha256.bind(file.openRead()).first).toString();
    final verified =
        actualBytes == expectedBytes && actualDigest == expectedDigest;
    return ThroughputIntegrityEvidence(
      status: verified
          ? ThroughputIntegrityStatus.verified
          : ThroughputIntegrityStatus.failed,
      expectedBytes: expectedBytes,
      actualBytes: actualBytes,
      expectedSha256: expectedDigest,
      actualSha256: actualDigest,
      destination: file.path,
      detail: verified
          ? null
          : '$actualBytes bytes/$actualDigest, expected '
                '$expectedBytes bytes/$expectedDigest.',
    );
  } catch (error) {
    return ThroughputIntegrityEvidence(
      status: ThroughputIntegrityStatus.failed,
      expectedBytes: expectedBytes,
      expectedSha256: expectedDigest,
      destination: file.path,
      detail: '${error.runtimeType}: $error',
    );
  }
}

void _validateDriverResult(
  ThroughputVariant variant,
  ThroughputTransferResult result,
  ThroughputExecutionPayload payload,
) {
  if (variant == ThroughputVariant.openssh) return;
  if (result.bytes != payload.bytes) {
    throw StateError('${result.bytes} != ${payload.bytes} bytes.');
  }
  if (variant == ThroughputVariant.dartHashOn &&
      result.digest != payload.digest) {
    throw StateError(
      'hashing produced ${result.digest}, expected ${payload.digest}.',
    );
  }
  if (variant == ThroughputVariant.dartHashOff && result.digest != null) {
    throw StateError('hashing-off produced ${result.digest}.');
  }
}

class _ReferenceFactory {
  var _sequence = 0;

  String next(String scenario, ThroughputAttemptPhase phase) {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '$scenario-${phase.name}-$timestamp-${_sequence++}';
  }
}
