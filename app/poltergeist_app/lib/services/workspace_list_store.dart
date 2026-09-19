import 'settings_store.dart';
import 'workspace_state.dart';

/// The workspace detail document's persistence layer (02 §3): one
/// versioned JSON document inside `settings.json`, behind the prefs
/// layer — the same generic [SettingsStore] the session document and
/// the other prefs use, so workspace writes ride the existing atomic
/// serialized writer for free.
///
/// This is deliberately a SEPARATE key from `session.state`: the
/// safe-point writer rewrites the auto-session on every state change,
/// and a named workspace's detail must never be displaced by it. At M5
/// the workspace's synced half became the `BookmarkKind.workspace`
/// favorite (04 §2.1); this document is what stays device-local — the
/// full tab-set snapshot keyed by the favorite's id (04 §2.3).
///
/// Schema posture matches [SessionStateStore]: decode is strict, a newer
/// schema fails closed, and [save] re-reads the stored value first so a
/// document this build could not decode is never silently overwritten.
final class WorkspaceListStore {
  WorkspaceListStore({required SettingsStore store})
    // Keep the backing store private to the workspace seam.
    // ignore: prefer_initializing_formals
    : _store = store;

  static const _settingsKey = 'workspaces.saved';

  final SettingsStore _store;
  Future<void> _tail = Future<void>.value();

  /// The stored workspace list, or null when none was persisted yet.
  /// Throws [FormatException] when the document is malformed or carries
  /// a schema this build does not understand — callers report and start
  /// with an empty list; the document is never partially trusted.
  Future<WorkspaceListDocument?> load() => _serialized(() async {
    final stored = await _store.get<Object>(_settingsKey);
    if (stored == null) return null;
    return WorkspaceListDocument.fromJson(stored);
  });

  /// Persists [document] atomically. Fails closed when the stored
  /// document carries a schema this build cannot decode — overwriting a
  /// newer Poltergeist's workspace list would lose its data.
  Future<void> save(WorkspaceListDocument document) => _serialized(() async {
    // Never persist a document this build would itself refuse to decode.
    WorkspaceListDocument.fromJson(document.toJson());
    final stored = await _store.get<Object>(_settingsKey);
    if (stored != null) {
      // Validates the stored schema; throws before touching the file
      // when a newer or corrupt document sits there.
      WorkspaceListDocument.fromJson(stored);
    }
    await _store.set(_settingsKey, document.toJson());
  });

  /// Serialize store operations so a save can never interleave with a
  /// load (or another save) mid-flight — the same read-then-write
  /// pairing [SessionStateStore] serializes.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then((_) {}, onError: (_, _) {});
    return result;
  }
}
