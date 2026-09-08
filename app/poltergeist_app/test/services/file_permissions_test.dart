import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/file_permissions.dart';
import 'package:posix/posix.dart' show PosixException;

void main() {
  test('owner-only restriction reports chmod failure', () {
    final directory = Directory.systemTemp.createTempSync(
      'poltergeist-permissions-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final missingFile = File('${directory.path}/missing');

    expect(
      () => restrictFileToOwner(missingFile),
      throwsA(isA<PosixException>()),
    );
  }, skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);
}
