import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'application_error_reporter.dart';
import 'external_file_opener.dart';
import 'settings_store.dart';

/// The app-wide [EditorRegistry] owner (06 §4.1): loads the persisted
/// registry from the shared settings.json document once at startup and
/// serializes every mutation through the same store — never a second
/// file. The Open With ▸ submenu reads it live through the listenable
/// so a picked or removed editor shows (or leaves) the next render.
///
/// Mutations persist first and publish second — the WorkspaceLibrary
/// discipline: a store write that fails restores the pre-mutation
/// registry, so no surface resolves a default the disk does not hold.
final class EditorRegistryController extends ChangeNotifier {
  EditorRegistryController({
    required SettingsStore store,
    ApplicationErrorReporter? errors,
  }) : // Keep the store and reporter private.
       // ignore: prefer_initializing_formals
       _store = store,
       // ignore: prefer_initializing_formals
       _errors = errors ?? ApplicationErrorReporter();

  static const _settingsKey = 'editorRegistry';

  final SettingsStore _store;
  final ApplicationErrorReporter _errors;

  EditorRegistry _registry = EditorRegistry();

  /// The live registry — menus resolve through it on every render.
  EditorRegistry get registry => _registry;

  /// Startup read: a malformed or absent document decodes through the
  /// tolerant `fromJson` — never a startup failure.
  Future<void> load() async {
    _registry = EditorRegistry.fromJson(
      await _store.get<Object>(_settingsKey),
    );
    notifyListeners();
  }

  /// Registers (or replaces) an editor definition — the Open With ▸
  /// `Other…` pick lands here.
  Future<void> register(ExternalEditorDefinition editor) =>
      _mutate(() => _registry.put(editor));

  Future<void> remove(String id) => _mutate(() => _registry.remove(id));

  /// The global default editor — `poltergeist.system`,
  /// `poltergeist.builtin`, or a registered editor id (06 §8's
  /// Default-editor dropdown writes here). Refuses an unresolvable id
  /// at write time, matching [setExtensionDefault]'s rule — a dangling
  /// default would sit in settings.json until the next load's repair.
  Future<void> setDefault(String id) => _mutate(() {
    if (id != EditorRegistry.systemDefaultId &&
        id != EditorRegistry.builtInId &&
        _registry.byId(id) == null) {
      throw FormatException('Unknown editor id: $id');
    }
    _registry.defaultEditorId = id;
  });

  /// The remember-choice write (06 §4.1): binds one extension to an
  /// editor id or a reserved selector.
  Future<void> setExtensionDefault(String extension, String editorId) =>
      _mutate(() => _registry.setDefaultForExtension(extension, editorId));

  Future<void> clearExtensionDefault(String extension) =>
      _mutate(() => _registry.clearDefaultForExtension(extension));

  Future<void> _mutate(void Function() apply) async {
    final before = _registry.toJson();
    apply();
    final after = _registry.toJson();
    try {
      await _store.set(_settingsKey, after);
    } on Object catch (error, stackTrace) {
      // Roll back only this mutation: a newer one may have applied on
      // top while the write was in flight, and blindly restoring
      // `before` would clobber it — the registry mutates in place, so
      // compare snapshots, not identity.
      if (jsonEncode(_registry.toJson()) == jsonEncode(after)) {
        _registry = EditorRegistry.fromJson(before);
      }
      _errors.report(error, stackTrace);
      // Listeners may have read the mutated registry while the write
      // was in flight — publish the rollback so they re-render.
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }
}
