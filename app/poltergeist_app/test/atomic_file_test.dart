// Ported from Séance app/seance_app/test/atomic_file_test.dart @ e11206a; see docs/PORTS.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/atomic_file.dart';

final _temporaryFileName = RegExp(
  r'^\.poltergeist-'
  r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
  r'[0-9a-f]{12}\.tmp$',
);

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_atomic_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('creates the parent directory and round-trips content', () async {
    final target = File(
      p.join(temporaryDirectory.path, 'nested', 'deep', 'data.json'),
    );

    await writeStringAtomically(target, '{"hello":"world"}');

    expect(await target.readAsString(), '{"hello":"world"}');
  });

  test('replaces existing content and leaves no temporary file', () async {
    final target = File(p.join(temporaryDirectory.path, 'data.json'));

    await writeStringAtomically(target, 'first');
    await writeStringAtomically(target, 'second');

    expect(await target.readAsString(), 'second');
    expect(await _temporaryFiles(temporaryDirectory), isEmpty);
  });

  test('removes the temporary sibling after rename fails', () async {
    final target = File(p.join(temporaryDirectory.path, 'data.json'));
    await Directory(target.path).create();

    await expectLater(
      writeStringAtomically(target, 'value'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await _temporaryFiles(temporaryDirectory), isEmpty);
  });
}

Future<List<FileSystemEntity>> _temporaryFiles(Directory directory) async =>
    directory
        .list()
        .where((entry) => _temporaryFileName.hasMatch(p.basename(entry.path)))
        .toList();
