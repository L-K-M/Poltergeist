// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../lib/protocol_guard.dart';

Future<void> main(List<String> arguments) async {
  try {
    final violations = await checkProtocol(arguments.single);
    for (final violation in violations) {
      stderr.writeln('error: $violation');
    }
    exitCode = violations.isEmpty ? 0 : 1;
  } catch (error) {
    // Missing, malformed, or unreadable input must fail the CI gate.
    stderr.writeln('error: protocol scan failed: $error');
    exitCode = 2;
  }
}
