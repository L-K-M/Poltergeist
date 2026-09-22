// §9's local pair-state files — `<app-support>/sync_state/<pairId>.json`.
// The schema lives in the pure sync package (SyncPairState); this is the
// file IO 05 §11 keeps out of it, wrapped in the app's atomic-write
// helper so a kill never exposes a torn state document.
import 'dart:io';

import 'package:poltergeist_sync/poltergeist_sync.dart';

import 'atomic_file.dart';

/// The `sync_state/` directory name under app support (05 §9).
const String kSyncStateDirectoryName = 'sync_state';

/// Reads and writes [SyncPairState] documents keyed by canonical
/// `pairId` (05 §9 — the endpoint-derived id, never a bookmark id).
abstract interface class SyncStateStore {
  /// The pair's recorded state, or a fresh default when no document
  /// exists (or the file cannot decode — the model treats corruption as
  /// an empty cache).
  Future<SyncPairState> load(String pairId);

  /// Persists [state] atomically.
  Future<void> save(String pairId, SyncPairState state);
}

/// The file-backed store over [directory].
final class FileSyncStateStore implements SyncStateStore {
  FileSyncStateStore(this.directory);

  final Directory directory;

  File _fileFor(String pairId) {
    validateSyncPairId(pairId);
    return File('${directory.path}${Platform.pathSeparator}$pairId.json');
  }

  @override
  Future<SyncPairState> load(String pairId) async {
    final file = _fileFor(pairId);
    if (!await file.exists()) return SyncPairState();
    return syncPairStateFromJsonText(await file.readAsString());
  }

  @override
  Future<void> save(String pairId, SyncPairState state) =>
      writeStringAtomically(_fileFor(pairId), syncPairStateToJsonText(state));
}

/// A memory store for tests — the same interface, no IO.
final class MemorySyncStateStore implements SyncStateStore {
  final _states = <String, SyncPairState>{};

  @override
  Future<SyncPairState> load(String pairId) async =>
      _states[pairId] ?? SyncPairState();

  @override
  Future<void> save(String pairId, SyncPairState state) async {
    _states[pairId] = state;
  }
}
