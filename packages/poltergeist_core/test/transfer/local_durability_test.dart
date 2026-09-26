@TestOn('vm')
library;

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

final class _RecordingIo extends TransferJournalIo {
  final List<String> operations = [];
  String? failingOperation;

  @override
  Future<void> fsyncFile(File file) async {
    operations.add('file');
    if (failingOperation == 'file') throw StateError('file flush failed');
  }

  @override
  Future<void> fsyncDirectory(Directory directory) async {
    operations.add('directory');
    if (failingOperation == 'directory') {
      throw StateError('directory flush failed');
    }
  }
}

void main() {
  test('a local copy flushes its data before its parent entry', () async {
    final io = _RecordingIo();

    await io.flushLocalFile('copy.txt');

    expect(io.operations, ['file', 'directory']);
  });

  test('a file flush failure never reaches the directory barrier', () async {
    final io = _RecordingIo()..failingOperation = 'file';

    await expectLater(io.flushLocalFile('copy.txt'), throwsStateError);

    expect(io.operations, ['file']);
  });

  test('a reported directory flush failure propagates', () async {
    final io = _RecordingIo()..failingOperation = 'directory';

    await expectLater(io.flushLocalFile('copy.txt'), throwsStateError);

    expect(io.operations, ['file', 'directory']);
  });
}
