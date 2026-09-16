import 'package:flutter/foundation.dart';

import 'uuid.dart';
import 'workspace_list_store.dart';
import 'workspace_state.dart';

/// The app's saved-workspace list (02 §3's "Save Workspace…" / "Open
/// Workspace"): an in-memory view of the versioned [WorkspaceListStore]
/// document that the menu commands render and mutate.
///
/// The list is kept newest-first — the position IS the order (saves and
/// opens move their record to the front), so menu ordering never depends
/// on timestamp resolution or ties. `savedAt`/`lastOpenedAt` stay on the
/// record for the M5 migration into the favorites store.
///
/// Mutations persist first and publish second: a store write that fails
/// (or fails closed over a newer schema) leaves the in-memory list
/// untouched, so a surface never renders a workspace the disk does not
/// hold.
final class WorkspaceLibrary extends ChangeNotifier {
  WorkspaceLibrary({
    required WorkspaceListStore store,
    DateTime Function()? now,
  }) : // Keep the store seam private to the library.
       // ignore: prefer_initializing_formals
       _store = store,
       _now = now ?? DateTime.now;

  final WorkspaceListStore _store;
  final DateTime Function() _now;

  List<SavedWorkspace> _workspaces = const [];
  bool _disposed = false;

  /// The saved workspaces, newest activity first.
  List<SavedWorkspace> get workspaces => List.unmodifiable(_workspaces);

  /// Loads the persisted document. A malformed or newer-schema document
  /// throws [FormatException] — the caller reports and boots an empty
  /// library; the file is never partially trusted or overwritten
  /// unread (the store's read-before-write keeps it intact).
  Future<void> load() async {
    final document = await _store.load();
    _workspaces = document?.workspaces ?? const [];
    notifyListeners();
  }

  /// Saves [snapshot] under [label]. Saving over an existing label
  /// replaces that workspace's snapshot in place — one named workspace
  /// per name, the standard save-over behavior — keeping its id so a
  /// re-saved workspace is recognizably the same record. The record
  /// moves to the front (it is the workspace the user just touched).
  ///
  /// Returns the record as persisted. A store failure propagates and
  /// leaves the in-memory list untouched.
  Future<SavedWorkspace> save({
    required String label,
    required WorkspaceSnapshot snapshot,
  }) async {
    assert(!_disposed, 'save on a disposed WorkspaceLibrary');
    final now = _now().toUtc();
    final existing = _workspaces
        .where(
          (workspace) => workspace.label.toLowerCase() == label.toLowerCase(),
        )
        .firstOrNull;
    final saved = existing == null
        ? SavedWorkspace(
            id: uuidV4(),
            label: label,
            savedAt: now,
            lastOpenedAt: null,
            snapshot: snapshot,
          )
        : existing.copyWith(
            savedAt: now,
            snapshot: snapshot,
            lastOpenedAt: () => null,
          );
    final next = [
      saved,
      for (final workspace in _workspaces)
        if (!identical(workspace, existing)) workspace,
    ];
    await _store.save(WorkspaceListDocument(workspaces: next));
    _workspaces = List.unmodifiable(next);
    notifyListeners();
    return saved;
  }

  /// Records that [id]'s workspace was opened: the record moves to the
  /// front (newest-opened order) and stamps `lastOpenedAt`. A store
  /// failure propagates; a missing id is a no-op.
  Future<void> markOpened(String id) async {
    if (_disposed) return;
    final index = _workspaces.indexWhere((workspace) => workspace.id == id);
    if (index < 0) return;
    final opened = _workspaces[index].copyWith(
      lastOpenedAt: () => _now().toUtc(),
    );
    final next = [
      opened,
      for (final workspace in _workspaces)
        if (workspace.id != id) workspace,
    ];
    await _store.save(WorkspaceListDocument(workspaces: next));
    _workspaces = List.unmodifiable(next);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
