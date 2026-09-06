// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../lib/import_guard.dart';

Future<void> main(List<String> arguments) async {
  try {
    final violations = await checkImports(arguments.single);
    for (final violation in violations) {
      stderr.writeln('error: $violation');
    }
    exitCode = violations.isEmpty ? 0 : 1;
  } catch (error) {
    // Missing or unreadable inputs must never produce a passing CI gate.
    stderr.writeln('error: dependency scan failed: $error');
    exitCode = 2;
  }
}
