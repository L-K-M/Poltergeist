import 'dart:io';

import 'package:args/args.dart';
import 'package:poltergeist_m0_bench/evidence.dart';
import 'package:poltergeist_m0_bench/evidence_store.dart';
import 'package:poltergeist_m0_bench/result_manifest.dart';

const _usageExitCode = 64;
const _dataExitCode = 65;
const _ioExitCode = 74;
const _deadlineStartVariable = 'POLTERGEIST_M0_STARTED_AT_EPOCH_MS';
const _monotonicStartVariable = 'POLTERGEIST_M0_STARTED_AT_MONOTONIC_US';

enum _Command { start, finish }

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
  if (parsed.rest.length != 1) {
    _fail(_usage(parser), _usageExitCode);
    return;
  }
  final commands = _Command.values.where(
    (command) => command.name == parsed.rest.single,
  );
  if (commands.isEmpty) {
    _fail(
      'Unknown command: ${parsed.rest.single}.\n${_usage(parser)}',
      _usageExitCode,
    );
    return;
  }
  final output = parsed['output'] as String?;
  if (output == null) {
    _fail('--output is required.', _usageExitCode);
    return;
  }

  try {
    switch (commands.single) {
      case _Command.start:
        await _start(parsed, output);
      case _Command.finish:
        await _finish(parsed, output);
    }
  } on EvidenceException catch (error) {
    _fail('$error', _dataExitCode);
  } on FormatException catch (error) {
    _fail(error.message, _dataExitCode);
  } on FileSystemException catch (error) {
    _fail(error.message, _ioExitCode);
  }
}

Future<void> _start(ArgResults parsed, String output) async {
  final shard = parsed['shard'] as String?;
  if (shard == null) {
    throw const EvidenceException('start requires --shard.');
  }
  if (sourceSpecForId(shard) == null) {
    throw EvidenceException('Unknown M0 source shard: $shard.');
  }
  await EvidenceStore(output).start(
    SourceIdentity.fromEnvironment(
      shardId: shard,
      phase: IdentityCapturePhase.running,
    ),
    deadlineStartedAtUtc: _deadlineStartedAtUtc(),
    deadlineStartedAtMonotonic: _deadlineStartedAtMonotonic(),
  );
  stdout.writeln(output);
}

Future<void> _finish(ArgResults parsed, String output) async {
  final statusText = parsed['exit-status'] as String?;
  final rows = parsed['rows'] as String?;
  final attempts = parsed['attempts'] as String?;
  if (statusText == null || rows == null || attempts == null) {
    throw const EvidenceException(
      'finish requires --exit-status, --rows, and --attempts.',
    );
  }
  final status = int.tryParse(statusText);
  if (status == null || status < 0 || status > 255) {
    throw EvidenceException('Invalid exit status: $statusText.');
  }
  final effectiveStatus = await EvidenceStore(output).finish(
    exitStatus: status,
    rowsPath: rows,
    attemptsPath: attempts,
    failureMessage: parsed['failure'] as String?,
  );
  stdout.writeln(output);
  exitCode = effectiveStatus;
}

DateTime? _deadlineStartedAtUtc() {
  final value = Platform.environment[_deadlineStartVariable];
  if (value == null) return null;
  final milliseconds = int.tryParse(value);
  if (milliseconds == null || milliseconds <= 0) {
    throw EvidenceException('$_deadlineStartVariable must be epoch ms.');
  }

  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
}

Duration? _deadlineStartedAtMonotonic() {
  final value = Platform.environment[_monotonicStartVariable];
  if (value == null) return null;
  final microseconds = int.tryParse(value);
  if (microseconds == null || microseconds <= 0) {
    throw EvidenceException('$_monotonicStartVariable must be positive µs.');
  }

  return Duration(microseconds: microseconds);
}

ArgParser _parser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('output')
  ..addOption('shard')
  ..addOption('exit-status')
  ..addOption('rows')
  ..addOption('attempts')
  ..addOption('failure');

String _usage(ArgParser parser) =>
    'Usage:\n'
    '  dart run bin/package_source.dart start --output <path> --shard <id>\n'
    '  dart run bin/package_source.dart finish --output <path> '
    '--exit-status <code> --rows <path> --attempts <path>\n'
    '${parser.usage}';

void _fail(String message, int code) {
  stderr.writeln(message);
  exitCode = code;
}
