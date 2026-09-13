import 'settings_store.dart';
import 'view_preferences.dart';

/// Device-local folder views over global defaults (02 §2.4).
///
/// Share one instance across panes. Each saved folder holds a complete view;
/// reset removes it so later reads inherit the current defaults. Reads and
/// writes share a queue, including durable LRU touches, so concurrent pane
/// actions cannot overwrite one another. Tab-only hidden overrides never enter
/// this store. Persistence failures reach the caller and leave the queue usable.
/// An absent/null section is fresh state. In versioned state, omitted defaults
/// or locations inherit built-in defaults or an empty cache; malformed present
/// fields fail. Unknown fields are ignored, but unknown versions are rejected.
final class ViewPreferencesStore {
  ViewPreferencesStore({required SettingsStore store})
    // Keep the backing store private to the preference facade.
    // ignore: prefer_initializing_formals
    : _store = store;

  static const locationLimit = 500;

  static const _settingsKey = 'view.preferences';
  static const _versionKey = 'version';
  static const _schemaVersion = 1;
  static const _defaultsKey = 'defaults';
  static const _locationsKey = 'locations';
  static const _locationKey = 'location';
  static const _preferencesKey = 'preferences';

  final SettingsStore _store;
  Future<void> _tail = Future.value();

  Future<ViewPreferences> loadDefaults() =>
      _serialized(() async => (await _read())._defaults);

  /// Changes the fallback without overwriting explicit folder preferences.
  Future<void> saveDefaults(ViewPreferences preferences) =>
      _serialized(() async {
        final state = await _read();
        state._defaults = preferences;
        await _write(state);
      });

  /// Resolves a folder and records access only when it has a saved override.
  /// Visiting an unsaved folder never evicts a customized folder.
  Future<ViewPreferences> load(ViewLocationKey location) =>
      _serialized(() async {
        final state = await _read();
        final preferences = state._locations[location];
        if (preferences == null) return state._defaults;
        if (state._locations.keys.last == location) return preferences;

        state._locations.remove(location);
        state._locations[location] = preferences;
        await _write(state);
        return preferences;
      });

  Future<void> save(
    ViewLocationKey location,
    ViewPreferences preferences,
  ) => _serialized(() async {
    final state = await _read();
    // Remove first: assigning an existing map key does not refresh its order.
    state._locations.remove(location);
    state._locations[location] = preferences;
    _trim(state._locations);
    await _write(state);
  });

  Future<void> reset(ViewLocationKey location) => _serialized(() async {
    final state = await _read();
    if (state._locations.remove(location) == null) return;
    await _write(state);
  });

  /// Bookmark deletion removes its views without touching other identities.
  Future<void> removeServer(String serverId) => _serialized(() async {
    final state = await _read();
    final previousCount = state._locations.length;
    state._locations.removeWhere(
      (location, _) =>
          location.kind == ViewLocationKind.remote &&
          location.identity == serverId,
    );
    if (state._locations.length == previousCount) return;
    await _write(state);
  });

  Future<_ViewPreferencesState> _read() async {
    final stored = await _store.get<Object>(_settingsKey);
    if (stored == null) {
      return _ViewPreferencesState(ViewPreferences(), {});
    }

    // Reject unsupported or damaged schemas before any mutation. SettingsStore
    // owns JSON quarantine; this layer must not overwrite a newer view schema.
    if (stored is! Map ||
        stored[_versionKey] is! int ||
        stored[_versionKey] != _schemaVersion) {
      throw const FormatException('Unsupported view preferences schema');
    }
    final defaults = stored.containsKey(_defaultsKey)
        ? ViewPreferences.fromJson(stored[_defaultsKey])
        : ViewPreferences();
    final records = stored.containsKey(_locationsKey)
        ? stored[_locationsKey]
        : const [];
    if (records is! List) {
      throw const FormatException('Invalid view preference locations');
    }

    final locations = <ViewLocationKey, ViewPreferences>{};
    for (final record in records) {
      if (record is! Map) {
        throw const FormatException('Invalid view preference record');
      }
      final location = ViewLocationKey.fromJson(record[_locationKey]);
      final preferences = ViewPreferences.fromJson(record[_preferencesKey]);
      // Last occurrence wins, including its recency, if a file repeats a key.
      locations.remove(location);
      locations[location] = preferences;
      _trim(locations);
    }
    return _ViewPreferencesState(defaults, locations);
  }

  Future<void> _write(_ViewPreferencesState state) => _store.set(_settingsKey, {
    _versionKey: _schemaVersion,
    _defaultsKey: state._defaults.toJson(),
    _locationsKey: [
      for (final entry in state._locations.entries)
        {
          _locationKey: entry.key.toJson(),
          _preferencesKey: entry.value.toJson(),
        },
    ],
  });

  static void _trim(Map<ViewLocationKey, ViewPreferences> locations) {
    while (locations.length > locationLimit) {
      locations.remove(locations.keys.first);
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final run = _tail.then((_) => operation());
    // Callers observe failures; only the shared tail absorbs them for retry.
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }
}

final class _ViewPreferencesState {
  _ViewPreferencesState(this._defaults, this._locations);

  ViewPreferences _defaults;
  final Map<ViewLocationKey, ViewPreferences> _locations;
}
