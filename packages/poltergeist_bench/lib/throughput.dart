import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'fixture_data.dart';
import 'harness.dart';
import 'monotonic_clock.dart';
import 'openssh_baseline.dart';
import 'result_store.dart';
import 'src/throughput_execution.dart';
import 'ssh_driver.dart';
import 'throughput_attempt.dart';

export 'throughput_attempt.dart'
    show
        ThroughputLeg,
        ThroughputReplicate,
        ThroughputSampleSpec,
        ThroughputVariant;

const throughputSampleBudget = Duration(minutes: 315);
const throughputSampleTransferMaximum = Duration(minutes: 240);
const throughputSampleReserve = Duration(minutes: 30);
const _warmupTransferMaximum = Duration(minutes: 10);
const _normalTransferMaximum = throughputSampleTransferMaximum;
const _warmupPayload = ThroughputExecutionPayload(
  label: '1mb',
  bytes: fixturePayload1MbBytes,
  digest: fixturePayload1MbSha256,
);
const _payloads = [
  _warmupPayload,
  ThroughputExecutionPayload(
    label: '100mb',
    bytes: fixturePayload100MbBytes,
    digest: fixturePayload100MbSha256,
  ),
  ThroughputExecutionPayload(
    label: '1gb',
    bytes: fixturePayload1GbBytes,
    digest: fixturePayload1GbSha256,
  ),
];
const _trialOrder = [
  ThroughputVariant.dartHashOn,
  ThroughputVariant.openssh,
  ThroughputVariant.dartHashOff,
  ThroughputVariant.dartHashOff,
  ThroughputVariant.openssh,
  ThroughputVariant.dartHashOn,
];
const _sampleNote =
    'samples=2; aggregate=floor-midpoint; pathPrimed=true; '
    'variantWarmup=1mb-per-trial; order=ABCCBA';

enum ThroughputSlice {
  full('full'),
  withoutShapedOneGigabyte('without-shaped-1gb');

  final String cliValue;

  const ThroughputSlice(this.cliValue);

  static Iterable<String> get cliValues =>
      values.map((slice) => slice.cliValue);

  static ThroughputSlice parse(String value) {
    for (final slice in values) {
      if (slice.cliValue == value) return slice;
    }

    throw FormatException('Unknown throughput slice: $value');
  }

  bool includes(ThroughputLeg leg, int payloadBytes) {
    return switch (this) {
      full => true,
      withoutShapedOneGigabyte => payloadBytes != fixturePayload1GbBytes,
    };
  }
}

class ThroughputSampleDeadline {
  final DateTime startedAtUtc;
  final Duration _startedAtMonotonic;
  final MonotonicClock _monotonicNow;

  factory ThroughputSampleDeadline(
    DateTime startedAtUtc, {
    required Duration startedAtMonotonic,
    MonotonicClock? monotonicNow,
  }) {
    if (!startedAtUtc.isUtc) {
      throw ArgumentError.value(
        startedAtUtc,
        'startedAtUtc',
        'The sample deadline must start in UTC.',
      );
    }
    if (startedAtMonotonic.isNegative) {
      throw ArgumentError.value(
        startedAtMonotonic,
        'startedAtMonotonic',
        'The monotonic deadline anchor cannot be negative.',
      );
    }
    final clock = monotonicNow ?? HostMonotonicClock.read;
    if (clock() < startedAtMonotonic) {
      throw StateError('The monotonic deadline clock moved back.');
    }

    return ThroughputSampleDeadline._(startedAtUtc, startedAtMonotonic, clock);
  }

  const ThroughputSampleDeadline._(
    this.startedAtUtc,
    this._startedAtMonotonic,
    this._monotonicNow,
  );

  DateTime get expiresAtUtc => startedAtUtc.add(throughputSampleBudget);

  Duration get remaining {
    final elapsed = _monotonicNow() - _startedAtMonotonic;
    if (elapsed.isNegative) {
      throw StateError('The monotonic deadline clock moved back.');
    }

    return throughputSampleBudget - elapsed;
  }

  Duration transferLimit() => _limit(maximum: throughputSampleTransferMaximum);

  Duration warmupLimit() => _limit(maximum: _warmupTransferMaximum);

  void ensureReserve() {
    if (remaining >= throughputSampleReserve) return;

    throw StateError(
      'The sample did not retain its ${throughputSampleReserve.inMinutes}-'
      'minute evidence reserve.',
    );
  }

  Duration _limit({required Duration maximum}) {
    final available = remaining - throughputSampleReserve;
    if (available <= Duration.zero) {
      throw StateError(
        'The sample cannot retain its ${throughputSampleReserve.inMinutes}-'
        'minute evidence reserve.',
      );
    }
    if (available < maximum) return available;

    return maximum;
  }
}

typedef ThroughputTrial = Future<Duration> Function(ThroughputVariant variant);

/// Warms immediately before every trial, then records mirrored samples.
Future<CounterbalancedSamples> collectCounterbalancedSamples(
  ThroughputTrial trial, {
  ThroughputTrial? warmup,
}) async {
  final samples = {
    for (final variant in ThroughputVariant.values) variant: <Duration>[],
  };
  for (final variant in _trialOrder) {
    await (warmup ?? trial)(variant);
    samples[variant]!.add(await trial(variant));
  }
  return CounterbalancedSamples._(samples);
}

class CounterbalancedSamples {
  final Map<ThroughputVariant, List<Duration>> _samples;

  const CounterbalancedSamples._(this._samples);

  int get sampleCount => _samples.values.first.length;

  Duration medianFor(ThroughputVariant variant) {
    final ordered = [..._samples[variant]!]..sort();
    final middle = ordered.length ~/ 2;
    if (ordered.length.isOdd) return ordered[middle];

    return Duration(
      microseconds:
          (ordered[middle - 1].inMicroseconds +
              ordered[middle].inMicroseconds) ~/
          2,
    );
  }
}

Future<List<BenchResult>> runThroughput(
  BenchConfig config, {
  ThroughputSlice slice = ThroughputSlice.full,
}) async {
  final scratch = await Directory.systemTemp.createTemp('poltergeist-m0-');
  final store = ThroughputAttemptStore(
    throughputAttemptOutputPath(config.outputFile),
  );
  final runtime = ThroughputExecutionRuntime(
    config: config,
    scratch: scratch,
    store: store,
  );
  final results = <BenchResult>[];
  var succeeded = false;
  final drivers = await _NormalDriverSet.open(config);

  try {
    for (final payload in _payloads) {
      for (final direction in ThroughputLeg.values) {
        if (!slice.includes(direction, payload.bytes)) continue;

        final cellResults = await _runCounterbalancedCell(
          config: config,
          direction: direction,
          payload: payload,
          drivers: drivers,
          runtime: runtime,
        );
        results.addAll(cellResults);
      }
    }
    succeeded = true;
    return results;
  } catch (error) {
    throw BenchRunFailure('Throughput failed: $error', results);
  } finally {
    await drivers.close();
    if (succeeded) await scratch.delete(recursive: true);
  }
}

Future<List<BenchResult>> runThroughputSample(
  BenchConfig config,
  ThroughputSampleSpec spec,
) async {
  final rttEvidence = config.rttEvidence;
  final deadlineStartedAtUtc = config.deadlineStartedAtUtc;
  final deadlineStartedAtMonotonic = config.deadlineStartedAtMonotonic;
  if (config.linkName != 'rtt100' || rttEvidence == null) {
    throw const BenchRunFailure(
      'A shaped throughput sample requires seven-probe RTT evidence.',
      [],
    );
  }
  if (deadlineStartedAtUtc == null || deadlineStartedAtMonotonic == null) {
    throw const BenchRunFailure(
      'A shaped throughput sample requires its fixture-start deadline.',
      [],
    );
  }

  final deadline = ThroughputSampleDeadline(
    deadlineStartedAtUtc,
    startedAtMonotonic: deadlineStartedAtMonotonic,
  );
  final scratch = await Directory.systemTemp.createTemp(
    'poltergeist-m0-sample-',
  );
  final store = ThroughputAttemptStore(
    throughputAttemptOutputPath(config.outputFile),
  );
  final runtime = ThroughputExecutionRuntime(
    config: config,
    scratch: scratch,
    store: store,
  );
  ThroughputExecutionDriver? driver;
  var succeeded = false;

  try {
    // Refuse before hashing 1 GB when the fixture setup spent the reserve.
    deadline.transferLimit();
    await runtime.prime(spec.direction, _payloads.last);
    await runtime.prime(spec.direction, _warmupPayload);
    driver = await _openDriver(config, spec.variant);
    final scenario = _scenario(
      spec.variant,
      spec.direction,
      _payloads.last,
      config.linkName,
    );

    final evidence = await runtime.runTrial(
      driver: driver,
      scenario: scenario,
      direction: spec.direction,
      payload: _payloads.last,
      warmupPayload: _warmupPayload,
      ordinal: null,
      replicate: spec.replicate,
      warmupTimeout: deadline.warmupLimit,
      trialTimeout: deadline.transferLimit,
    );
    deadline.ensureReserve();
    final result = BenchResult.capture(
      scenario: scenario,
      bytes: _payloads.last.bytes,
      elapsed: evidence.trial.elapsed!,
      note:
          'samples=1; aggregate=external-floor-midpoint; pathPrimed=true; '
          'variantWarmup=1mb; replicate=r${spec.replicate.number}',
      rttEvidence: rttEvidence,
      throughputTrials: [evidence],
    );
    succeeded = true;
    return [result];
  } catch (error) {
    throw BenchRunFailure('${spec.cliValue} failed: $error', const []);
  } finally {
    await driver?.close();
    if (succeeded) await scratch.delete(recursive: true);
  }
}

Future<List<BenchResult>> _runCounterbalancedCell({
  required BenchConfig config,
  required ThroughputLeg direction,
  required ThroughputExecutionPayload payload,
  required _NormalDriverSet drivers,
  required ThroughputExecutionRuntime runtime,
}) async {
  final trials = {
    for (final variant in ThroughputVariant.values)
      variant: <ThroughputTrialEvidence>[],
  };
  final replicateCounts = {
    for (final variant in ThroughputVariant.values) variant: 0,
  };

  for (var index = 0; index < _trialOrder.length; index++) {
    final variant = _trialOrder[index];
    final driver = drivers.forVariant(variant);
    final ordinal = index + 1;
    final replicateIndex = replicateCounts[variant]!;
    replicateCounts[variant] = replicateIndex + 1;
    final replicate = ThroughputReplicate.values[replicateIndex];
    final scenario = _scenario(variant, direction, payload, config.linkName);
    final evidence = await runtime.runTrial(
      driver: driver,
      scenario: scenario,
      direction: direction,
      payload: payload,
      warmupPayload: _warmupPayload,
      ordinal: ordinal,
      replicate: replicate,
      warmupTimeout: () => _warmupTransferMaximum,
      trialTimeout: () => _normalTransferMaximum,
    );
    trials[variant]!.add(evidence);
  }

  return [
    for (final variant in ThroughputVariant.values)
      _captureCellResult(
        config: config,
        direction: direction,
        payload: payload,
        variant: variant,
        trials: trials[variant]!,
      ),
  ];
}

Future<ThroughputIntegrityEvidence> inspectLocalFile(
  File file, {
  required int expectedBytes,
  required String expectedDigest,
}) => inspectThroughputFile(
  file,
  expectedBytes: expectedBytes,
  expectedDigest: expectedDigest,
);

BenchResult _captureCellResult({
  required BenchConfig config,
  required ThroughputLeg direction,
  required ThroughputExecutionPayload payload,
  required ThroughputVariant variant,
  required List<ThroughputTrialEvidence> trials,
}) {
  final samples = trials.map((evidence) => evidence.trial.elapsed!).toList()
    ..sort();
  final elapsed = Duration(
    microseconds: (samples[0].inMicroseconds + samples[1].inMicroseconds) ~/ 2,
  );
  final openssh = variant == ThroughputVariant.openssh;
  final note = openssh
      ? '$_sampleNote; completion=batch-echo-drain'
      : _dartSampleNote(variant, payload);
  return BenchResult.capture(
    scenario: _scenario(variant, direction, payload, config.linkName),
    bytes: payload.bytes,
    elapsed: elapsed,
    note: note,
    rttEvidence: config.rttEvidence,
    throughputTrials: trials,
  );
}

enum HashMode { on, off }

String _dartSampleNote(
  ThroughputVariant variant,
  ThroughputExecutionPayload payload,
) {
  final hashMode = _hashMode(variant);
  final digest = hashMode == HashMode.on ? '; sha256=${payload.digest}' : '';
  return '$_sampleNote; hash=${hashMode.name}$digest';
}

HashMode _hashMode(ThroughputVariant variant) {
  if (variant == ThroughputVariant.dartHashOn) return HashMode.on;
  if (variant == ThroughputVariant.dartHashOff) return HashMode.off;

  throw ArgumentError.value(variant, 'variant', 'OpenSSH has no hash mode');
}

String _scenario(
  ThroughputVariant variant,
  ThroughputLeg direction,
  ThroughputExecutionPayload payload,
  String linkName,
) => '${variant.cliValue}-${direction.name}-${payload.label}-$linkName';

void validateThroughputEntry({
  required int? actualBytes,
  required String? digest,
  required int expectedBytes,
  required String expectedDigest,
  required HashMode hashMode,
}) {
  if (actualBytes != expectedBytes) {
    throw StateError('$actualBytes != $expectedBytes bytes.');
  }
  if (hashMode == HashMode.on && digest != expectedDigest) {
    throw StateError('hashing produced $digest, expected $expectedDigest.');
  }
  if (hashMode == HashMode.off && digest != null) {
    throw StateError('hashing-off produced $digest.');
  }
}

class _DartThroughputDriver implements ThroughputExecutionDriver {
  final BenchSshConnection _connection;

  @override
  final ThroughputVariant variant;

  const _DartThroughputDriver(this._connection, this.variant);

  @override
  Future<ThroughputTransferResult> download({
    required String remoteSource,
    required File localDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  }) => _connection.downloadToFile(
    remotePath: remoteSource,
    destination: localDestination,
    digestMode: _digestMode,
    timeout: timeout,
  );

  @override
  Future<ThroughputTransferResult> upload({
    required File localSource,
    required String remoteDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  }) => _connection.uploadFile(
    source: localSource,
    remotePath: remoteDestination,
    bytes: payload.bytes,
    digestMode: _digestMode,
    timeout: timeout,
  );

  DigestMode get _digestMode => _hashMode(variant) == HashMode.on
      ? DigestMode.enabled
      : DigestMode.disabled;

  @override
  Future<void> deleteRemote(String path, {required Duration timeout}) =>
      _connection.deletePath(path).timeout(timeout);

  @override
  Future<void> close() async => _connection.close();
}

class _OpenSshThroughputDriver implements ThroughputExecutionDriver {
  final OpenSshBaseline _baseline;
  var _closed = false;

  _OpenSshThroughputDriver(this._baseline);

  @override
  ThroughputVariant get variant => ThroughputVariant.openssh;

  @override
  Future<ThroughputTransferResult> download({
    required String remoteSource,
    required File localDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  }) => _run(
    () => _baseline.download(
      remoteSource,
      localDestination.path,
      timeout: timeout,
    ),
  );

  @override
  Future<ThroughputTransferResult> upload({
    required File localSource,
    required String remoteDestination,
    required ThroughputExecutionPayload payload,
    required Duration timeout,
  }) => _run(
    () =>
        _baseline.upload(localSource.path, remoteDestination, timeout: timeout),
  );

  Future<ThroughputTransferResult> _run(
    Future<Duration> Function() transfer,
  ) async {
    try {
      final elapsed = await transfer();
      return ThroughputTransferResult(
        bytes: null,
        digest: null,
        elapsed: elapsed,
      );
    } on TimeoutException {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> deleteRemote(String path, {required Duration timeout}) =>
      _baseline.remove(path, timeout: timeout);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _baseline.close();
  }
}

class _NormalDriverSet {
  final Map<ThroughputVariant, ThroughputExecutionDriver> _drivers;

  const _NormalDriverSet._(this._drivers);

  static Future<_NormalDriverSet> open(BenchConfig config) async {
    final drivers = <ThroughputVariant, ThroughputExecutionDriver>{};
    try {
      for (final variant in ThroughputVariant.values) {
        drivers[variant] = await _openDriver(config, variant);
      }
      return _NormalDriverSet._(drivers);
    } catch (_) {
      for (final driver in drivers.values) {
        await driver.close();
      }
      rethrow;
    }
  }

  ThroughputExecutionDriver forVariant(ThroughputVariant variant) =>
      _drivers[variant]!;

  Future<void> close() async {
    Object? firstError;
    for (final driver in _drivers.values) {
      try {
        await driver.close();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) throw firstError;
  }
}

Future<ThroughputExecutionDriver> _openDriver(
  BenchConfig config,
  ThroughputVariant variant,
) async {
  if (variant == ThroughputVariant.openssh) {
    final baseline = await OpenSshBaseline.connect(
      endpoint: config.endpoint,
      identityFile: config.identityFile,
    );
    return _OpenSshThroughputDriver(baseline);
  }

  final connection = await openBenchConnection(config.endpoint);
  return _DartThroughputDriver(connection, variant);
}
