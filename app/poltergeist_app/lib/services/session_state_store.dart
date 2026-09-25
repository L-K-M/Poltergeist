import 'session_state.dart';
import 'settings_store.dart';

/// The session-state document's persistence layer (02 §3): one
/// versioned JSON document inside `settings.json`, behind the prefs
/// layer — the same generic [SettingsStore] the other prefs use, so
/// session writes ride the existing atomic serialized writer for free.
///
/// Schema posture matches the sibling versioned stores: decode is
/// strict, a newer schema fails closed, and [save] re-reads the stored
/// value first so a document this build could not decode is never
/// silently overwritten (data loss is a bug, never a migration path —
/// the D12 catalogs' rule).
final class SessionStateStore {
  SessionStateStore({required SettingsStore store})
    // Keep the backing store private to the session seam.
    // ignore: prefer_initializing_formals
    : _store = store;

  static const _settingsKey = 'session.state';
  static const _windowsKey = 'session.windows';

  final SettingsStore _store;
  Future<void> _tail = Future<void>.value();

  /// The stored session, or null when none was persisted yet. Throws
  /// [FormatException] when the document is malformed or carries a
  /// schema this build does not understand — callers report and boot a
  /// default session; the document is never partially trusted.
  Future<SessionState?> load() => _serialized(() async {
    final stored = await _store.get<Object>(_settingsKey);
    if (stored == null) return null;
    return SessionState.fromJson(stored);
  });

  /// Persists [state] atomically. Fails closed when the stored document
  /// carries a schema this build cannot decode — overwriting a newer
  /// Poltergeist's session would lose its data.
  Future<void> save(SessionState state) => _serialized(() async {
    final stored = await _store.get<Object>(_settingsKey);
    if (stored != null) {
      // Validates the stored schema; throws before touching the file
      // when a newer or corrupt document sits there.
      SessionState.fromJson(stored);
    }
    await _store.set(_settingsKey, state.toJson());
  });

  /// The windows the last session had open beside the first (00 D38),
  /// empty when none was persisted. Throws [FormatException] like [load].
  Future<List<SessionState>> loadWindows() => _serialized(() async {
    final stored = await _store.get<Object>(_windowsKey);
    if (stored == null) return const <SessionState>[];
    return SessionWindowsState.fromJson(stored).windows;
  });

  /// Persists every open window at once: [first] as the v1 document and
  /// [others] beside it, in one write, so the two never disagree about
  /// which windows were open. Fails closed like [save] when either stored
  /// document carries a schema this build cannot decode.
  Future<void> saveAll(SessionState first, List<SessionState> others) =>
      _serialized(() async {
        final stored = await _store.get<Object>(_settingsKey);
        if (stored != null) SessionState.fromJson(stored);
        final storedWindows = await _store.get<Object>(_windowsKey);
        if (storedWindows != null) {
          SessionWindowsState.fromJson(storedWindows);
        }
        await _store.setAll({
          _settingsKey: first.toJson(),
          _windowsKey: SessionWindowsState(windows: others).toJson(),
        });
      });

  /// Serialize store operations so a save can never interleave with a
  /// load (or another save) mid-flight — [SettingsStore] already
  /// serializes its writes, but the read-then-write in [save] needs the
  /// whole pair serialized.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then((_) {}, onError: (_, _) {});
    return result;
  }
}
