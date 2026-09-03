// This executable and its library stay outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../lib/release_version_cli.dart';

void main(List<String> arguments) {
  exitCode = runReleaseVersionCommand(arguments);
}
