/// The previewable sync engine for Poltergeist (docs/plan/05-SYNC.md).
///
/// Pure Dart over the one filesystem abstraction — Séance's
/// RemoteFileSystem, reached through package:poltergeist_core (D3). No
/// Flutter, no dartssh2, no dart:io Process, no rsync (05 §2/§11).
library;

export 'src/compare.dart';
export 'src/executor.dart';
export 'src/ignore.dart';
export 'src/journal.dart';
export 'src/plan.dart';
export 'src/scan.dart';
