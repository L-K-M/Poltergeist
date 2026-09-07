import 'dart:io';

import 'package:posix/posix.dart' as posix;

const _ownerReadWriteMode = 0x180; // POSIX 0600: owner read + write only.

/// Applies owner-only mode bits where desktop files are not sandboxed.
///
/// Windows and mobile rely on their per-user/application storage ACLs.
void restrictFileToOwner(File file) {
  if (!Platform.isLinux && !Platform.isMacOS) return;

  posix.chmodWithMode(file.path, _ownerReadWriteMode);
}
