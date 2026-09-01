// This executable and its tests stay under tool/ so the audit never ships.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../lib/seance_pin_audit.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runSeancePinAudit(arguments);
}
