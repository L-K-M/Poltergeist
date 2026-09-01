import 'dart:io';

import 'config.dart';
import 'fixture_data.dart';
import 'harness.dart';
import 'openssh_baseline.dart';
import 'ssh_driver.dart';

const _warmupPayload = _Payload(
  '1mb',
  fixturePayload1MbBytes,
  fixturePayload1MbSha256,
);
const _payloads = [
  _warmupPayload,
  _Payload('100mb', fixturePayload100MbBytes, fixturePayload100MbSha256),
  _Payload('1gb', fixturePayload1GbBytes, fixturePayload1GbSha256),
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
    'samples=2; aggregate=median; pathPrimed=true; '
    'variantWarmup=1mb-per-trial; order=ABCCBA';

enum ThroughputVariant { dartHashOn, dartHashOff, openssh }

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

Future<List<BenchResult>> runThroughput(BenchConfig config) async {
  final scratch = await Directory.systemTemp.createTemp('poltergeist-m0-');
  final results = <BenchResult>[];

  try {
    final dart = await _DartVariantConnections.open(config.endpoint);
    try {
      final openssh = await OpenSshBaseline.connect(
        endpoint: config.endpoint,
        identityFile: config.identityFile,
      );
      try {
        final warmupFile = File('${scratch.path}/variant-warmup.bin');
        await _createSparseFile(warmupFile, _warmupPayload.bytes);

        for (final payload in _payloads) {
          final localFile = File('${scratch.path}/${payload.label}.bin');
          await _createSparseFile(localFile, payload.bytes);

          await _primeRemotePath(config, payload);
          final downloads = await collectCounterbalancedSamples(
            (variant) => _download(
              config: config,
              dart: dart,
              openssh: openssh,
              payload: payload,
              variant: variant,
            ),
            warmup: (variant) => _download(
              config: config,
              dart: dart,
              openssh: openssh,
              payload: _warmupPayload,
              variant: variant,
            ),
          );
          results.addAll(
            _captureSamples(
              config: config,
              direction: 'download',
              payload: payload,
              samples: downloads,
            ),
          );

          await localFile.openRead().drain<void>();
          final uploads = await collectCounterbalancedSamples(
            (variant) => _upload(
              config: config,
              dart: dart,
              openssh: openssh,
              payload: payload,
              localFile: localFile,
              variant: variant,
            ),
            warmup: (variant) => _upload(
              config: config,
              dart: dart,
              openssh: openssh,
              payload: _warmupPayload,
              localFile: warmupFile,
              variant: variant,
            ),
          );
          results.addAll(
            _captureSamples(
              config: config,
              direction: 'upload',
              payload: payload,
              samples: uploads,
            ),
          );
        }
      } finally {
        await openssh.close();
      }
    } finally {
      dart.close();
    }
  } finally {
    await scratch.delete(recursive: true);
  }

  return results;
}

Future<void> _primeRemotePath(BenchConfig config, _Payload payload) async {
  final connection = await openBenchConnection(config.endpoint);
  try {
    final read = await connection.download(
      path: '${config.remoteRoot}/fixtures/payload-${payload.label}.bin',
      digestMode: DigestMode.disabled,
    );
    if (read.bytes != payload.bytes) {
      throw StateError(
        '${payload.label}: primed ${read.bytes} != ${payload.bytes} bytes.',
      );
    }
  } finally {
    connection.close();
  }
}

Future<Duration> _download({
  required BenchConfig config,
  required _DartVariantConnections dart,
  required OpenSshBaseline openssh,
  required _Payload payload,
  required ThroughputVariant variant,
}) async {
  final remotePath =
      '${config.remoteRoot}/fixtures/payload-${payload.label}.bin';
  if (variant == ThroughputVariant.openssh) {
    return openssh.download(remotePath);
  }

  final hashMode = _hashMode(variant);
  final sink = File('/dev/null').openWrite();
  final stopwatch = Stopwatch()..start();
  try {
    final entry = await dart
        .connectionFor(variant)
        .remoteFileSystem
        .download(remotePath, sink, computeHash: hashMode == HashMode.on);
    stopwatch.stop();
    validateThroughputEntry(
      actualBytes: entry.size,
      digest: entry.contentSha256,
      expectedBytes: payload.bytes,
      expectedDigest: payload.digest,
      hashMode: hashMode,
    );
    return stopwatch.elapsed;
  } finally {
    stopwatch.stop();
    await sink.close();
  }
}

Future<Duration> _upload({
  required BenchConfig config,
  required _DartVariantConnections dart,
  required OpenSshBaseline openssh,
  required _Payload payload,
  required File localFile,
  required ThroughputVariant variant,
}) async {
  final suffix = _variantName(variant);
  final remotePath =
      '${config.remoteRoot}/uploads/$suffix-${payload.label}.bin';
  if (variant == ThroughputVariant.openssh) {
    final elapsed = await openssh.upload(localFile.path, remotePath);
    await openssh.remove(remotePath);
    return elapsed;
  }

  final hashMode = _hashMode(variant);
  final stopwatch = Stopwatch()..start();
  final connection = dart.connectionFor(variant);
  final entry = await connection.remoteFileSystem.upload(
    remotePath,
    localFile.openRead(),
    length: payload.bytes,
    overwrite: true,
    computeHash: hashMode == HashMode.on,
  );
  stopwatch.stop();

  validateThroughputEntry(
    actualBytes: entry.size,
    digest: entry.contentSha256,
    expectedBytes: payload.bytes,
    expectedDigest: payload.digest,
    hashMode: hashMode,
  );
  await connection.remoteFileSystem.delete(entry);
  return stopwatch.elapsed;
}

Iterable<BenchResult> _captureSamples({
  required BenchConfig config,
  required String direction,
  required _Payload payload,
  required CounterbalancedSamples samples,
}) sync* {
  for (final variant in ThroughputVariant.values) {
    final openssh = variant == ThroughputVariant.openssh;
    final note = openssh
        ? '$_sampleNote; completion=batch-echo-drain'
        : _dartSampleNote(variant, payload);
    yield BenchResult.capture(
      scenario:
          '${_variantName(variant)}-$direction-${payload.label}-${config.linkName}',
      bytes: payload.bytes,
      elapsed: samples.medianFor(variant),
      note: note,
      rttMs: config.measuredRttMs,
    );
  }
}

enum HashMode { on, off }

String _dartSampleNote(ThroughputVariant variant, _Payload payload) {
  final hashMode = _hashMode(variant);
  final digest = hashMode == HashMode.on ? '; sha256=${payload.digest}' : '';
  return '$_sampleNote; hash=${hashMode.name}$digest';
}

HashMode _hashMode(ThroughputVariant variant) {
  if (variant == ThroughputVariant.dartHashOn) return HashMode.on;
  if (variant == ThroughputVariant.dartHashOff) return HashMode.off;

  throw ArgumentError.value(variant, 'variant', 'OpenSSH has no hash mode');
}

String _variantName(ThroughputVariant variant) {
  if (variant == ThroughputVariant.dartHashOn) return 'dart-hash-on';
  if (variant == ThroughputVariant.dartHashOff) return 'dart-hash-off';
  return 'openssh';
}

Future<void> _createSparseFile(File file, int bytes) async {
  final handle = await file.open(mode: FileMode.write);
  try {
    await handle.truncate(bytes);
  } finally {
    await handle.close();
  }
}

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

class _Payload {
  final String label;
  final int bytes;
  final String digest;

  const _Payload(this.label, this.bytes, this.digest);
}

class _DartVariantConnections {
  final BenchSshConnection _hashOn;
  final BenchSshConnection _hashOff;

  const _DartVariantConnections._(this._hashOn, this._hashOff);

  static Future<_DartVariantConnections> open(BenchEndpoint endpoint) async {
    final hashOn = await openBenchConnection(endpoint);
    try {
      final hashOff = await openBenchConnection(endpoint);
      return _DartVariantConnections._(hashOn, hashOff);
    } catch (_) {
      hashOn.close();
      rethrow;
    }
  }

  BenchSshConnection connectionFor(ThroughputVariant variant) {
    if (variant == ThroughputVariant.dartHashOn) return _hashOn;
    if (variant == ThroughputVariant.dartHashOff) return _hashOff;

    throw ArgumentError.value(variant, 'variant', 'OpenSSH has no Dart link');
  }

  void close() {
    _hashOn.close();
    _hashOff.close();
  }
}
