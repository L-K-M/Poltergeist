import 'dart:io';

import 'config.dart';
import 'harness.dart';
import 'openssh_baseline.dart';
import 'ssh_driver.dart';

const _payloads = [
  _Payload('1mb', 1_000_000),
  _Payload('100mb', 100_000_000),
  _Payload('1gb', 1_000_000_000),
];

enum HashMode { on, off }

enum ThroughputImplementation { dart, openssh }

Future<List<BenchResult>> runThroughput(
  BenchConfig config,
  ThroughputImplementation implementation,
) async {
  final scratch = await Directory.systemTemp.createTemp('poltergeist-m0-');
  final results = <BenchResult>[];

  try {
    switch (implementation) {
      case ThroughputImplementation.dart:
        await _runDartThroughput(config, scratch, results);
      case ThroughputImplementation.openssh:
        await _runOpenSshThroughput(config, scratch, results);
    }
  } finally {
    await scratch.delete(recursive: true);
  }

  return results;
}

Future<void> _runDartThroughput(
  BenchConfig config,
  Directory scratch,
  List<BenchResult> results,
) async {
  final connection = await openBenchConnection(config.endpoint);
  try {
    for (final payload in _payloads) {
      final localFile = File('${scratch.path}/${payload.label}.bin');
      await _createSparseFile(localFile, payload.bytes);

      for (final hashMode in HashMode.values) {
        results.add(await _download(config, connection, payload, hashMode));
        results.add(
          await _upload(config, connection, payload, localFile, hashMode),
        );
      }
    }
  } finally {
    connection.close();
  }
}

Future<void> _runOpenSshThroughput(
  BenchConfig config,
  Directory scratch,
  List<BenchResult> results,
) async {
  final baseline = await OpenSshBaseline.connect(
    endpoint: config.endpoint,
    identityFile: config.identityFile,
  );
  try {
    for (final payload in _payloads) {
      final localFile = File('${scratch.path}/${payload.label}.bin');
      await _createSparseFile(localFile, payload.bytes);

      results.add(await _baselineDownload(config, baseline, payload));
      results.add(await _baselineUpload(config, baseline, payload, localFile));
    }
  } finally {
    await baseline.close();
  }
}

Future<BenchResult> _download(
  BenchConfig config,
  BenchSshConnection connection,
  _Payload payload,
  HashMode hashMode,
) async {
  final sink = File('/dev/null').openWrite();
  final stopwatch = Stopwatch()..start();
  try {
    final entry = await connection.remoteFileSystem.download(
      '${config.remoteRoot}/fixtures/payload-${payload.label}.bin',
      sink,
      computeHash: hashMode == HashMode.on,
    );
    stopwatch.stop();

    _verifyEntry(entry.size, entry.contentSha256, payload, hashMode);
    return BenchResult.capture(
      scenario:
          'dart-download-${payload.label}-${config.linkName}-hash-${hashMode.name}',
      bytes: payload.bytes,
      elapsed: stopwatch.elapsed,
      note: entry.contentSha256 ?? 'hash disabled',
      rttMs: config.measuredRttMs,
    );
  } finally {
    stopwatch.stop();
    await sink.close();
  }
}

Future<BenchResult> _upload(
  BenchConfig config,
  BenchSshConnection connection,
  _Payload payload,
  File localFile,
  HashMode hashMode,
) async {
  final remotePath =
      '${config.remoteRoot}/uploads/dart-${payload.label}-${hashMode.name}.bin';
  final stopwatch = Stopwatch()..start();
  final entry = await connection.remoteFileSystem.upload(
    remotePath,
    localFile.openRead(),
    length: payload.bytes,
    overwrite: true,
    computeHash: hashMode == HashMode.on,
  );
  stopwatch.stop();

  _verifyEntry(entry.size, entry.contentSha256, payload, hashMode);
  await connection.remoteFileSystem.delete(entry);
  return BenchResult.capture(
    scenario:
        'dart-upload-${payload.label}-${config.linkName}-hash-${hashMode.name}',
    bytes: payload.bytes,
    elapsed: stopwatch.elapsed,
    note: entry.contentSha256 ?? 'hash disabled',
    rttMs: config.measuredRttMs,
  );
}

Future<BenchResult> _baselineDownload(
  BenchConfig config,
  OpenSshBaseline baseline,
  _Payload payload,
) async {
  final elapsed = await baseline.download(
    '${config.remoteRoot}/fixtures/payload-${payload.label}.bin',
  );
  return BenchResult.capture(
    scenario: 'openssh-download-${payload.label}-${config.linkName}',
    bytes: payload.bytes,
    elapsed: elapsed,
    note: 'persistent OpenSSH sftp session',
    rttMs: config.measuredRttMs,
  );
}

Future<BenchResult> _baselineUpload(
  BenchConfig config,
  OpenSshBaseline baseline,
  _Payload payload,
  File localFile,
) async {
  final remotePath =
      '${config.remoteRoot}/uploads/openssh-${payload.label}.bin';
  final elapsed = await baseline.upload(localFile.path, remotePath);
  await baseline.remove(remotePath);
  return BenchResult.capture(
    scenario: 'openssh-upload-${payload.label}-${config.linkName}',
    bytes: payload.bytes,
    elapsed: elapsed,
    note: 'persistent OpenSSH sftp session',
    rttMs: config.measuredRttMs,
  );
}

Future<void> _createSparseFile(File file, int bytes) async {
  final handle = await file.open(mode: FileMode.write);
  try {
    await handle.truncate(bytes);
  } finally {
    await handle.close();
  }
}

void _verifyEntry(
  int? actualBytes,
  String? digest,
  _Payload payload,
  HashMode hashMode,
) {
  if (actualBytes != payload.bytes) {
    throw StateError(
      '${payload.label}: $actualBytes != ${payload.bytes} bytes.',
    );
  }
  if (hashMode == HashMode.on && digest == null) {
    throw StateError('${payload.label}: hashing produced no digest.');
  }
  if (hashMode == HashMode.off && digest != null) {
    throw StateError('${payload.label}: hashing-off produced $digest.');
  }
}

class _Payload {
  final String label;
  final int bytes;

  const _Payload(this.label, this.bytes);
}
