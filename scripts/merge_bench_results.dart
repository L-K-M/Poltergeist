// Merges per-scenario `poltergeist-d12-results-1` documents into the
// single bench-results.json the D12 bench job hands to
// test/benchmarks/check.dart (08 §6/§8).
//
//   dart scripts/merge_bench_results.dart --output bench-results.json IN...
//
// Each tier-A collector publishes its own document atomically and knows
// nothing about its siblings; this merger is the only writer of the
// combined file. The results schema admits multiple scenarios in one
// `rows` array — `fingerprint.scenarioConfig` is a per-scenario axis,
// never job-wide — so concatenating rows is the whole transform. An
// input with a different schema id or a non-list `rows` member is
// rejected rather than merged: the job must fail loudly instead of
// handing the checker a silently truncated document.
//
// Exit codes mirror check.dart's: 0 success, 64 usage, 65 malformed
// input, 74 I/O.

import 'dart:convert';
import 'dart:io';

const resultsSchemaId = 'poltergeist-d12-results-1';
const usageExitCode = 64;
const dataExitCode = 65;
const ioExitCode = 74;

const _usageText = '''
Usage: dart scripts/merge_bench_results.dart --output <path> <in.json>...
Merges poltergeist-d12-results-1 documents into one results file (08 §6).''';

Future<int> mergeMain(List<String> arguments) async {
  String? output;
  final inputs = <String>[];
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    switch (argument) {
      case '-h' || '--help':
        stdout.writeln(_usageText);
        return 0;
      case '--output':
        if (i + 1 >= arguments.length) {
          stderr.writeln('--output requires a value\n$_usageText');
          return usageExitCode;
        }
        output = arguments[++i];
      default:
        if (argument.startsWith('-')) {
          stderr.writeln('unknown option $argument\n$_usageText');
          return usageExitCode;
        }
        inputs.add(argument);
    }
  }
  if (output == null || output.isEmpty || inputs.isEmpty) {
    stderr.writeln(
      '--output and at least one input file are required\n$_usageText',
    );
    return usageExitCode;
  }

  final rows = <Object?>[];
  final seenInputs = <String>{};
  for (final path in inputs) {
    // Reject a repeated input outright: the same document listed twice
    // (a glob plus an explicit name, say) would double its rows, and the
    // checker would grade the inflated sample with no error anywhere.
    if (!seenInputs.add(File(path).absolute.path)) {
      stderr.writeln('duplicate input file: $path');
      return usageExitCode;
    }
    final Object? document;
    try {
      // Raw bytes first, like check.dart: a genuine I/O failure stays a
      // 74 while a decode failure is malformed input (65) — conflating
      // them would report a missing file as a schema violation.
      document = jsonDecode(utf8.decode(await File(path).readAsBytes()));
    } on FileSystemException catch (error) {
      stderr.writeln('I/O error ($path): ${error.message}');
      return ioExitCode;
    } on FormatException catch (error) {
      stderr.writeln('$path is not valid UTF-8 or JSON: ${error.message}');
      return dataExitCode;
    }
    if (document is! Map<String, Object?>) {
      stderr.writeln('$path: results document is not a JSON object');
      return dataExitCode;
    }
    final schema = document['schema'];
    if (schema != resultsSchemaId) {
      stderr.writeln(
        '$path: unsupported results schema $schema '
        '(expected $resultsSchemaId)',
      );
      return dataExitCode;
    }
    final documentRows = document['rows'];
    if (documentRows is! List) {
      stderr.writeln('$path: results document has no rows list');
      return dataExitCode;
    }
    // Reject non-object rows here, not downstream: once merged into the
    // shared file, a malformed row can no longer be attributed to the
    // per-scenario document that carried it.
    for (final row in documentRows) {
      if (row is! Map<String, Object?>) {
        stderr.writeln('$path: rows contains a non-object entry');
        return dataExitCode;
      }
    }
    rows.addAll(documentRows);
  }

  // Owned temp + rename, the same publication class the collectors and
  // the checker's drift state use: a torn write never leaves a
  // valid-looking bench-results.json behind.
  final target = File(output).absolute;
  final temporary = File(
    '${target.path}.merge-$pid-'
    '${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temporary.create(exclusive: true);
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'schema': resultsSchemaId, 'rows': rows})}\n',
      flush: true,
    );
    await temporary.rename(target.path);
  } on FileSystemException catch (error) {
    stderr.writeln('I/O error writing ${target.path}: ${error.message}');
    try {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    } catch (_) {
      // Best-effort cleanup; the write error above is the reported one.
    }
    return ioExitCode;
  }

  stdout.writeln(
    'merged ${inputs.length} documents (${rows.length} rows) '
    'into ${target.path}',
  );
  return 0;
}

void main(List<String> arguments) async {
  exitCode = await mergeMain(arguments);
}
