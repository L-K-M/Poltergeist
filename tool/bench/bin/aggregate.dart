import 'dart:io';

import 'package:args/args.dart';
import 'package:poltergeist_m0_bench/result_aggregator.dart';

const _usageExitCode = 64;
const _dataExitCode = 65;
const _ioExitCode = 74;

Future<void> main(List<String> arguments) async {
  final parser = _parser();
  late final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (error) {
    _fail('${error.message}\n${_usage(parser)}', _usageExitCode);
    return;
  }
  if (parsed['help'] as bool) {
    stdout.writeln(_usage(parser));
    return;
  }
  final inputRoot = parsed['input-root'] as String?;
  final outputDirectory = parsed['output-dir'] as String?;
  final runId = parsed['run-id'] as String?;
  final runAttemptText = parsed['run-attempt'] as String?;
  final gitSha = parsed['git-sha'] as String?;
  final runAttempt = int.tryParse(runAttemptText ?? '');
  if (inputRoot == null ||
      outputDirectory == null ||
      runId == null ||
      runAttempt == null ||
      gitSha == null) {
    _fail(_usage(parser), _usageExitCode);
    return;
  }

  try {
    await aggregateEvidenceDirectory(
      inputRoot: inputRoot,
      outputDirectory: outputDirectory,
      expectedRunId: runId,
      expectedRunAttempt: runAttempt,
      expectedGitSha: gitSha,
    );
  } on ResultAggregationException catch (error) {
    _fail('$error', _dataExitCode);
    return;
  } on FormatException catch (error) {
    _fail(error.message, _dataExitCode);
    return;
  } on FileSystemException catch (error) {
    _fail(error.message, _ioExitCode);
    return;
  }

  stdout.writeln(outputDirectory);
}

ArgParser _parser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('input-root')
  ..addOption('output-dir')
  ..addOption('run-id')
  ..addOption('run-attempt')
  ..addOption('git-sha');

String _usage(ArgParser parser) =>
    'Usage: dart run bin/aggregate.dart --input-root <path> '
    '--output-dir <path> --run-id <id> --run-attempt <number> '
    '--git-sha <sha>\n${parser.usage}';

void _fail(String message, int code) {
  stderr.writeln(message);
  exitCode = code;
}
