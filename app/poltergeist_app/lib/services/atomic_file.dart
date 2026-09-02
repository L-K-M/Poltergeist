// Ported from Séance app/seance_app/lib/services/atomic_file.dart @ e11206a; see docs/PORTS.md.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'uuid.dart';

/// Replaces [target] without exposing partially written contents.
Future<void> writeStringAtomically(File target, String contents) async {
  await target.parent.create(recursive: true);
  final temporaryPath = p.join(
    target.parent.path,
    '.poltergeist-${uuidV4()}.tmp',
  );
  final temporaryFile = File(temporaryPath);

  try {
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
