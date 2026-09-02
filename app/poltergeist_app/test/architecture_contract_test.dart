import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _fileSystemDeclaration = RegExp(
  r'\b(?:abstract\s+)?(?:interface\s+)?class\s+\w*FileSystem\b',
);

void main() {
  test('declares no app-local filesystem abstraction', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (_fileSystemDeclaration.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }

    // D3 reserves the filesystem interface for seance_core.
    expect(offenders, isEmpty);
  });
}
