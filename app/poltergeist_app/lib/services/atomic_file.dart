// Ported from Séance app/seance_app/lib/services/atomic_file.dart @ e11206a; see docs/PORTS.md.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_permissions.dart';
import 'uuid.dart';

enum AtomicFilePrivacy { processDefault, ownerOnly }

/// Replaces [target] without exposing partially written contents.
Future<void> writeStringAtomically(
  File target,
  String contents, {
  AtomicFilePrivacy privacy = AtomicFilePrivacy.processDefault,
}) async {
  await target.parent.create(recursive: true);
  final temporaryPath = p.join(
    target.parent.path,
    '.poltergeist-${uuidV4()}.tmp',
  );
  final temporaryFile = File(temporaryPath);

  try {
    // Restrict an empty file before sensitive contents become visible.
    await temporaryFile.create();
    if (privacy == AtomicFilePrivacy.ownerOnly) {
      restrictFileToOwner(temporaryFile);
    }
    await temporaryFile.writeAsString(contents, flush: true);
    await temporaryFile.rename(target.path);
  } on Object {
    // Cleanup is best-effort so it cannot hide the persistence failure.
    try {
      if (await temporaryFile.exists()) await temporaryFile.delete();
    } on Object {
      // The original write or rename failure is the actionable error.
    }
    rethrow;
  }
}
