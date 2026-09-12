import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Only the POSIX utility/mode cases skip Windows, never a whole VFS suite.
void testWithPosixTools(String description, FutureOr<void> Function() body) {
  test(
    description,
    body,
    skip: Platform.isWindows ? 'requires POSIX utilities and mode bits' : false,
  );
}

/// Probe privilege before registering link-dependent cases on Windows.
void testWithSymbolicLinks(String description, FutureOr<void> Function() body) {
  test(description, body, skip: _symbolicLinkSkip);
}

final Object _symbolicLinkSkip = _probeSymbolicLinks();

Object _probeSymbolicLinks() {
  if (!Platform.isWindows) return false;

  const accessDenied = 5; // Win32 ERROR_ACCESS_DENIED.
  const notSupported = 50; // Win32 ERROR_NOT_SUPPORTED.
  const privilegeNotHeld = 1314; // Win32 ERROR_PRIVILEGE_NOT_HELD.
  final root = Directory.systemTemp.createTempSync('pg-link-probe');
  // Cleanup owns partial setup too; unexpected filesystem errors still fail.
  try {
    final target = File(p.join(root.path, 'target'))..writeAsStringSync('x');
    try {
      Link(p.join(root.path, 'link')).createSync(target.path);
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code != accessDenied &&
          code != notSupported &&
          code != privilegeNotHeld) {
        rethrow;
      }
      return 'Windows link creation unavailable (Win32 $code): '
          'requires link support and Developer Mode or administrator privileges';
    }
    return false;
  } finally {
    root.deleteSync(recursive: true);
  }
}
