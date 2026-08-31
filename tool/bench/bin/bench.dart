import 'dart:io';

import 'package:args/args.dart';
import 'package:poltergeist_m0_bench/algorithm_audit.dart';
import 'package:poltergeist_m0_bench/config.dart';
import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/isolate_poc.dart';
import 'package:poltergeist_m0_bench/pipeline.dart';
import 'package:poltergeist_m0_bench/result_store.dart';
import 'package:poltergeist_m0_bench/throughput.dart';

enum _Scenario { throughput, algorithms, pipeline, isolate }

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

  final throughputImplementationName = parsed['implementation'] as String?;
  final throughputImplementation = throughputImplementationName == null
      ? null
      : ThroughputImplementation.values.byName(throughputImplementationName);
  if (scenario.single == _Scenario.throughput &&
      throughputImplementation == null) {
    stderr.writeln('--implementation is required for throughput.');
    exitCode = 64;
    return;
  }

  final defaults = BenchConfig.defaults();
  final linkName = parsed['link']! as String;
  final rttMs = _optionalInt(parsed['rtt-ms'] as String?);
  if (linkName != 'lan' && rttMs == null) {
    stderr.writeln('--rtt-ms is required for shaped links.');
    exitCode = 64;
    return;
  }
  final config = BenchConfig(
    endpoint: BenchEndpoint(
      host: parsed['host']! as String,
      port: int.parse(parsed['port']! as String),
      username: parsed['user']! as String,
      password: parsed['password']! as String,
    ),
    remoteRoot: parsed['remote-root']! as String,
    identityFile: parsed['identity'] as String? ?? defaults.identityFile,
    outputFile: parsed['output'] as String? ?? defaults.outputFile,
    linkName: linkName,
    measuredRttMs: rttMs,
  );

  if (parsed['reset'] as bool) {
    final output = File(config.outputFile);
    if (await output.exists()) await output.delete();
  }

  late final List<BenchResult> results;
  try {
    results = await switch (scenario.single) {
      _Scenario.throughput => runThroughput(config, throughputImplementation!),
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
  ..addOption(
    'implementation',
    allowed: ThroughputImplementation.values.map((value) => value.name),
  )
  ..addOption('link', defaultsTo: 'lan')
  ..addOption('rtt-ms');

int? _optionalInt(String? value) => value == null ? null : int.parse(value);
