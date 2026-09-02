import 'dart:async';
import 'dart:io';

import 'package:poltergeist_app/services/atomic_file.dart';

final class ControlledSettingsWriter {
  bool blockWrites = false;
  bool failWrites = false;
  bool failFirstWrite = false;

  final firstWriteStarted = Completer<void>();
  int writeCount = 0;

  Completer<void>? _release;

  Future<void> call(File target, String contents) async {
    writeCount++;
    final currentWrite = writeCount;
    if (!firstWriteStarted.isCompleted) firstWriteStarted.complete();

    if (blockWrites) {
      _release ??= Completer<void>();
      await _release!.future;
    }

    if (failWrites || (failFirstWrite && currentWrite == 1)) {
      throw StateError('write failed');
    }

    await writeStringAtomically(target, contents);
  }

  void releaseWrites() {
    final release = _release;
    if (release == null || release.isCompleted) return;

    release.complete();
  }
}
