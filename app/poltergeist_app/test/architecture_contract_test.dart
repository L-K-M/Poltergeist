import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _fileSystemDeclaration = RegExp(
  r'\b(?:abstract\s+)?(?:interface\s+)?class\s+\w*FileSystem\b',
);
const _packageDeclaration = 'name: poltergeist_app';

void main() {
  test('declares no app-local filesystem abstraction', () {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync() ||
        !pubspec.readAsStringSync().contains(_packageDeclaration)) {
      fail('Run this suite from app/poltergeist_app so lib/ can be scanned.');
    }

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
