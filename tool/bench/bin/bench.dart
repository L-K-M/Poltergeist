import 'dart:io';

import 'package:args/args.dart';
import 'package:poltergeist_m0_bench/algorithm_audit.dart';
import 'package:poltergeist_m0_bench/config.dart';
import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/isolate_poc.dart';
import 'package:poltergeist_m0_bench/pipeline.dart';
import 'package:poltergeist_m0_bench/result_store.dart';
import 'package:poltergeist_m0_bench/throughput.dart';
import 'package:poltergeist_m0_bench/throughput_attempt.dart';

enum _Scenario { throughput, algorithms, pipeline, isolate }

const _deadlineStartMillisecondsOption = 'deadline-start-ms';
const _deadlineStartMonotonicMicrosecondsOption = 'deadline-start-monotonic-us';

Future<void> main(List<String> arguments) async {
  final parser = _parser();
  late final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (parsed['help'] as bool || parsed.rest.length != 1) {
    stdout.writeln('Usage: dart run bin/bench.dart <scenario> [options]');
    stdout.writeln(
      'Scenarios: ${_Scenario.values.map((value) => value.name).join(', ')}',
    );
    stdout.writeln(parser.usage);
    exitCode = parsed['help'] as bool ? 0 : 64;
    return;
  }

  final scenarioName = parsed.rest.single;
  final scenario = _Scenario.values.where(
    (value) => value.name == scenarioName,
  );
  if (scenario.isEmpty) {
    stderr.writeln('Unknown scenario: $scenarioName');
    exitCode = 64;
    return;
  }

  late final ThroughputSlice throughputSlice;
  late final ThroughputSampleSpec? throughputSample;
  late final RttEvidence? rttEvidence;
  late final DateTime? deadlineStartedAtUtc;
  late final Duration? deadlineStartedAtMonotonic;
  try {
    throughputSlice = ThroughputSlice.parse(
      parsed['throughput-slice']! as String,
    );
    final sampleValue = parsed['throughput-sample'] as String?;
    throughputSample = sampleValue == null
        ? null
        : ThroughputSampleSpec.parse(sampleValue);
    final rttValue = parsed['rtt-evidence'] as String?;
    rttEvidence = rttValue == null ? null : RttEvidence.parse(rttValue);
    deadlineStartedAtUtc = _deadlineStart(
      parsed[_deadlineStartMillisecondsOption] as String?,
    );
    deadlineStartedAtMonotonic = _deadlineStartMonotonic(
      parsed[_deadlineStartMonotonicMicrosecondsOption] as String?,
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }

  final selectedScenario = scenario.single;
  final linkName = parsed['link']! as String;
  if (linkName != 'lan' && rttEvidence == null) {
    stderr.writeln('--rtt-evidence is required for shaped links.');
    exitCode = 64;
    return;
  }
  if (linkName == 'lan' && rttEvidence != null) {
    stderr.writeln('--rtt-evidence is only valid for shaped links.');
    exitCode = 64;
    return;
  }
  if (throughputSample != null && selectedScenario != _Scenario.throughput) {
    stderr.writeln('--throughput-sample requires the throughput scenario.');
    exitCode = 64;
    return;
  }
  if (throughputSample != null &&
      (linkName != 'rtt100' ||
          deadlineStartedAtUtc == null ||
          deadlineStartedAtMonotonic == null)) {
    stderr.writeln(
      '--throughput-sample requires --link=rtt100 and both deadline anchors.',
    );
    exitCode = 64;
    return;
  }
  if (throughputSample == null &&
      (deadlineStartedAtUtc != null || deadlineStartedAtMonotonic != null)) {
    stderr.writeln('Deadline anchors require --throughput-sample.');
    exitCode = 64;
    return;
  }

  final defaults = BenchConfig.defaults();
  final identityFile = parsed['identity'] as String? ?? defaults.identityFile;
  final config = BenchConfig(
    endpoint: BenchEndpoint(
      host: parsed['host']! as String,
      port: int.parse(parsed['port']! as String),
      username: parsed['user']! as String,
      password: parsed['password']! as String,
      identityFile: identityFile,
    ),
    remoteRoot: parsed['remote-root']! as String,
    identityFile: identityFile,
    outputFile: parsed['output'] as String? ?? defaults.outputFile,
    linkName: linkName,
    fixtureRoot: parsed['fixture-root'] as String? ?? defaults.fixtureRoot,
    uploadRoot: parsed['upload-root'] as String? ?? defaults.uploadRoot,
    rttEvidence: rttEvidence,
    deadlineStartedAtUtc: deadlineStartedAtUtc,
    deadlineStartedAtMonotonic: deadlineStartedAtMonotonic,
  );

  if (parsed['reset'] as bool) {
    final output = File(config.outputFile);
    if (await output.exists()) await output.delete();
    final attempts = File(throughputAttemptOutputPath(config.outputFile));
    if (await attempts.exists()) await attempts.delete();
  }

  late final List<BenchResult> results;
  try {
    results = await switch (scenario.single) {
      _Scenario.throughput =>
        throughputSample == null
            ? runThroughput(config, slice: throughputSlice)
            : runThroughputSample(config, throughputSample),
      _Scenario.algorithms => runAlgorithmAudit(config),
      _Scenario.pipeline => runPipeline(config),
      _Scenario.isolate => runIsolatePoc(config),
    };
  } on BenchRunFailure catch (failure) {
    await appendResults(config.outputFile, failure.results);
    stderr.writeln(failure.message);
    exitCode = 1;
    return;
  }
  await appendResults(config.outputFile, results);

  for (final result in results) {
    final rate = result.bytes == 0
        ? ''
        : ' ${result.mbPerSec.toStringAsFixed(2)} MB/s';
    stdout.writeln(
      '${result.scenario}: ${result.elapsed.inMicroseconds}µs$rate',
    );
  }
}

ArgParser _parser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addFlag('reset', negatable: false)
  ..addOption('host', defaultsTo: defaultSshHost)
  ..addOption('port', defaultsTo: '$defaultSshPort')
  ..addOption('user', defaultsTo: defaultSshUser)
  ..addOption('password', defaultsTo: defaultSshPassword)
  ..addOption('remote-root', defaultsTo: defaultRemoteRoot)
  ..addOption('identity')
  ..addOption('output')
  ..addOption('fixture-root')
  ..addOption('upload-root')
  ..addOption('link', defaultsTo: 'lan')
  ..addOption(
    'throughput-slice',
    defaultsTo: ThroughputSlice.full.cliValue,
    allowed: ThroughputSlice.cliValues,
  )
  ..addOption('throughput-sample')
  ..addOption('rtt-evidence')
  ..addOption(_deadlineStartMillisecondsOption)
  ..addOption(_deadlineStartMonotonicMicrosecondsOption);

DateTime? _deadlineStart(String? value) {
  if (value == null) return null;

  final milliseconds = int.tryParse(value);
  if (milliseconds == null || milliseconds <= 0) {
    throw const FormatException('--deadline-start-ms must be positive.');
  }

  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
}

Duration? _deadlineStartMonotonic(String? value) {
  if (value == null) return null;

  final microseconds = int.tryParse(value);
  if (microseconds == null || microseconds <= 0) {
    throw const FormatException(
      '--deadline-start-monotonic-us must be positive.',
    );
  }

  return Duration(microseconds: microseconds);
}
