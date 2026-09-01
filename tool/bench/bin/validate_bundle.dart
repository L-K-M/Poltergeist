import 'dart:io';

import 'package:args/args.dart';
import 'package:poltergeist_m0_bench/bundle_validator.dart';

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
  final bundle = parsed['bundle'] as String?;
  final report = parsed['report'] as String?;
  final repository = parsed['repo'] as String?;
  if (bundle == null || report == null || repository == null) {
    _fail(_usage(parser), _usageExitCode);
    return;
  }

  try {
    final outcome = await validateCommittedEvidence(
      bundleDirectory: bundle,
      reportPath: report,
      repositoryRoot: repository,
    );
    stdout.writeln(
      outcome == BundleValidationOutcome.neutral
          ? 'M0 evidence absent; validation is neutral.'
          : 'M0 evidence valid.',
    );
  } on BundleValidationException catch (error) {
    _fail('$error', _dataExitCode);
  } on FileSystemException catch (error) {
    _fail(error.message, _ioExitCode);
  }
}

ArgParser _parser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('bundle')
  ..addOption('report')
  ..addOption('repo');

String _usage(ArgParser parser) =>
    'Usage: dart run bin/validate_bundle.dart --bundle <path> '
    '--report <path> --repo <path>\n${parser.usage}';

void _fail(String message, int code) {
  stderr.writeln(message);
  exitCode = code;
}
