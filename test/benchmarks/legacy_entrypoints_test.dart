import 'dart:io';

import 'package:test/test.dart';

/// Contract tests for the M3 bench-harness relocation (07 §3.4).
///
/// The harness lives at `packages/poltergeist_bench`; `tool/bench` is a thin
/// compatibility entrypoint. These tests prove the legacy invocations forward
/// to the relocated package with equivalent behavior, without Docker or SFTP
/// (the run.sh env-driver hooks replace the fixture-backed commands).
void main() {
  test('legacy bench entrypoint forwards help and error contracts', () async {
    final canonical = await _runBench(
      ['--help'],
      workingDirectory: _benchPackageDir,
      entrypoint: _canonicalEntrypoint,
    );
    final legacy = await _runBench(
      ['--help'],
      workingDirectory: _legacyDir,
      entrypoint: _legacyEntrypoint,
    );

    expect(canonical.exitCode, 0, reason: canonical.stderr);
    expect(legacy.exitCode, canonical.exitCode);
    // The forwarded entrypoint prints the canonical usage text verbatim,
    // pointing at the relocated benchmark/bench.dart.
    expect(legacy.stdout, canonical.stdout);

    final canonicalUnknown = await _runBench(
      ['nosuchscenario'],
      workingDirectory: _benchPackageDir,
      entrypoint: _canonicalEntrypoint,
    );
    final legacyUnknown = await _runBench(
      ['nosuchscenario'],
      workingDirectory: _legacyDir,
      entrypoint: _legacyEntrypoint,
    );

    expect(canonicalUnknown.exitCode, 64);
    expect(legacyUnknown.exitCode, canonicalUnknown.exitCode);
    expect(legacyUnknown.stderr, canonicalUnknown.stderr);
  });

  test(
    'legacy aggregate entrypoint forwards help and error contracts',
    () async {
      final canonical = await _runAggregate(
        ['--help'],
        workingDirectory: _benchPackageDir,
        entrypoint: _canonicalAggregateEntrypoint,
      );
      final legacy = await _runAggregate(
        ['--help'],
        workingDirectory: _legacyDir,
        entrypoint: _legacyAggregateEntrypoint,
      );

      expect(canonical.exitCode, 0, reason: canonical.stderr);
      expect(canonical.stdout, contains('--input-root'));
      expect(legacy.exitCode, canonical.exitCode);
      // The forwarded entrypoint prints the canonical usage text verbatim.
      expect(legacy.stdout, canonical.stdout);

      final canonicalUnknown = await _runAggregate(
        ['--no-such-option'],
        workingDirectory: _benchPackageDir,
        entrypoint: _canonicalAggregateEntrypoint,
      );
      final legacyUnknown = await _runAggregate(
        ['--no-such-option'],
        workingDirectory: _legacyDir,
        entrypoint: _legacyAggregateEntrypoint,
      );

      expect(canonicalUnknown.exitCode, 64);
      expect(legacyUnknown.exitCode, canonicalUnknown.exitCode);
      expect(legacyUnknown.stderr, canonicalUnknown.stderr);
    },
  );

  test(
    'legacy run.sh forwards shards with identical routing',
    // run.sh needs a POSIX shell and chmod; CI runs this suite on Ubuntu.
    skip: Platform.isWindows ? 'run.sh requires a POSIX shell' : false,
    () async {
      final canonicalLog = await _routeShardThrough(_canonicalRunShard);
      final legacyLog = await _routeShardThrough(_legacyRunShard);

      expect(canonicalLog.exitCode, 0, reason: canonicalLog.stderr);
      expect(legacyLog.exitCode, 0, reason: legacyLog.stderr);
      expect(
        legacyLog.commands,
        canonicalLog.commands,
        reason: 'shard routing',
      );
      expect(legacyLog.commands, contains(contains('bench throughput')));
    },
  );
}

const _legacyDir = 'tool/bench';
const _benchPackageDir = 'packages/poltergeist_bench';
const _legacyEntrypoint = 'bin/bench.dart';
const _canonicalEntrypoint = 'benchmark/bench.dart';
const _legacyAggregateEntrypoint = 'bin/aggregate.dart';
const _canonicalAggregateEntrypoint = 'benchmark/aggregate.dart';
const _commandLogVariable = 'POLTERGEIST_M0_COMMAND_LOG';
const _sourceFileVariable = 'POLTERGEIST_M0_SOURCE_FILE';

String get _canonicalRunShard => '$_benchPackageDir/run.sh';
String get _legacyRunShard => '$_legacyDir/run.sh';

class _BenchRun {
  final int exitCode;
  final String stdout;
  final String stderr;

  const _BenchRun(this.exitCode, this.stdout, this.stderr);
}

Future<_BenchRun> _runBench(
  List<String> arguments, {
  required String workingDirectory,
  required String entrypoint,
}) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    entrypoint,
    ...arguments,
  ], workingDirectory: workingDirectory);

  return _BenchRun(
    result.exitCode,
    result.stdout as String,
    result.stderr as String,
  );
}

Future<_BenchRun> _runAggregate(
  List<String> arguments, {
  required String workingDirectory,
  required String entrypoint,
}) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    entrypoint,
    ...arguments,
  ], workingDirectory: workingDirectory);

  return _BenchRun(
    result.exitCode,
    result.stdout as String,
    result.stderr as String,
  );
}

class _ShardRouting {
  final int exitCode;
  final String stderr;
  final List<String> commands;

  const _ShardRouting(this.exitCode, this.stderr, this.commands);
}

/// Routes one shard through [runShard] with every fixture-backed command
/// replaced by a logging stub, returning the exact routed command sequence.
Future<_ShardRouting> _routeShardThrough(String runShard) async {
  final directory = await Directory.systemTemp.createTemp(
    'poltergeist-bench-forwarding-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final commandLog = File('${directory.path}/commands.log');
  final sourceFile = File('${directory.path}/bench-shard.json');

  // A pre-started envelope keeps both routings on the same skipped-start path.
  await sourceFile.writeAsString('{}');
  final profileScript = await _writeExecutable(
    directory,
    'profile.sh',
    _fakeProfileScript,
  );
  final benchCommand = await _writeExecutable(
    directory,
    'bench.sh',
    _fakeBenchCommand,
  );
  final packageCommand = await _writeExecutable(
    directory,
    'package.sh',
    _fakePackageCommand,
  );

  final result = await Process.run(
    runShard,
    ['standard'],
    environment: {
      _commandLogVariable: commandLog.path,
      _sourceFileVariable: sourceFile.path,
      'POLTERGEIST_M0_PROFILE_SCRIPT': profileScript,
      'POLTERGEIST_M0_BENCH_COMMAND': benchCommand,
      'POLTERGEIST_M0_PACKAGE_COMMAND': packageCommand,
    },
  );

  return _ShardRouting(
    result.exitCode,
    result.stderr as String,
    // Normalize the per-call temp dir so two routings compare equal.
    (await commandLog.readAsLines())
        .map((line) => line.replaceAll(directory.path, '<temp>'))
        .toList(),
  );
}

const _measuredRttJson =
    '{"samplesUs":[99000,100000,101000,101000,102000,103000,104000],'
    '"medianMs":101,"capturedAtUtc":"2026-09-01T00:00:00.000Z"}';

const _fakeProfileScript =
    '''
#!/bin/sh
set -eu
printf 'profile %s\\n' "\$*" >> "\$$_commandLogVariable"
if [ "\${1:-}" = 'measure-rtt-json' ]; then
  printf '%s\\n' '$_measuredRttJson'
fi
''';

const _fakeBenchCommand =
    '''
#!/bin/sh
set -eu
printf 'bench %s\\n' "\$*" >> "\$$_commandLogVariable"
''';

const _fakePackageCommand =
    '''
#!/bin/sh
set -eu
printf 'package %s\\n' "\$*" >> "\$$_commandLogVariable"
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

Future<String> _writeExecutable(
  Directory directory,
  String name,
  String contents,
) async {
  final file = File('${directory.path}/$name');
  await file.writeAsString(contents);
  final chmod = await Process.run('chmod', ['700', file.path]);
  if (chmod.exitCode != 0) {
    throw StateError('chmod failed: ${chmod.stderr}');
  }

  return file.path;
}
