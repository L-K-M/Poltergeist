import 'dart:io';

import 'package:args/args.dart';
import 'package:poltergeist_m0_bench/result_aggregator.dart';

const _usageExitCode = 64;
const _dataExitCode = 65;
const _ioExitCode = 74;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('standard')
    ..addOption('slow')
    ..addOption('output');
  late final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (error) {
    _fail('${error.message}\n${parser.usage}', _usageExitCode);
    return;
  }

  if (parsed['help'] as bool) {
    stdout.writeln(_usage(parser));
    return;
  }
  final standardPath = parsed['standard'] as String?;
  final slowPath = parsed['slow'] as String?;
  final outputPath = parsed['output'] as String?;
  if (standardPath == null || slowPath == null || outputPath == null) {
    _fail(_usage(parser), _usageExitCode);
    return;
  }

  try {
    await aggregateResultFiles(
      standardPath: standardPath,
      slowPath: slowPath,
      outputPath: outputPath,
    );
  } on ResultAggregationException catch (error) {
    _fail('$error', _dataExitCode);
    return;
  } on FileSystemException catch (error) {
    _fail(error.message, _ioExitCode);
    return;
  }

  stdout.writeln(outputPath);
}

String _usage(ArgParser parser) =>
    'Usage: dart run bin/aggregate.dart '
    '--standard <path> --slow <path> --output <path>\n${parser.usage}';

void _fail(String message, int code) {
  stderr.writeln(message);
  exitCode = code;
}
