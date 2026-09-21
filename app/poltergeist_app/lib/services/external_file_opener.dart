// Ported from Séance app/seance_app/lib/services/external_file_opener.dart
// @ 2e6d1f1; see docs/PORTS.md.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'uuid.dart';

// Ported from Séance
// app/seance_app/lib/services/external_file_opener.dart @ 2e6d1f1 —
// EditorHostPlatform, ExternalEditorDefinition, EditorRegistry, and the
// channel/detached-process launcher. Poltergeist divergences (06 §4.1):
// the reserved ids are `poltergeist.system` / `poltergeist.builtin` and
// the WHOLE `poltergeist.` prefix is rejected (bookmark-backup sync can
// ship a hand-edited definition — it must never shadow the reserved
// selectors); `extensionDefaults` adds the per-extension bindings
// `effectiveDefaultFor` resolves ahead of the global default, with
// put()/remove() stripping bindings an edit or delete orphans (06 §8);
// `pickEditor` takes its dialog title from the caller (D20 — the file
// carries no UI copy) and forwards it to the macOS channel; the BBEdit
// settings migration is dropped (no legacy settings exist); and
// `openSystemDefault` delegates to the engine's LocalFileOpener rather
// than the open_file plugin — same `open`/`xdg-open`/`explorer.exe`
// hand-off, typed RemoteFileException errors, one fewer plugin.
// See docs/PORTS.md.

enum EditorHostPlatform { macos, linux, windows }

class ExternalEditorDefinition {
  final String id;
  final String displayName;
  final EditorHostPlatform platform;

  /// Bundle identifier on macOS; absolute executable path elsewhere.
  final String launchTarget;
  final List<String> acceptedExtensions;

  const ExternalEditorDefinition({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.launchTarget,
    this.acceptedExtensions = const [],
  });

  factory ExternalEditorDefinition.fromJson(Map<String, dynamic> json) {
    final platformName = json['platform'];
    final platform = EditorHostPlatform.values.where(
      (value) => value.name == platformName,
    );
    if (platform.isEmpty) {
      throw const FormatException('Unknown editor platform');
    }
    final parsedPlatform = platform.first;
    return ExternalEditorDefinition(
      id: _validatedId(json['id']),
      displayName: validateEditorDisplayName(json['displayName']),
      platform: parsedPlatform,
      launchTarget: _validatedTarget(json['launchTarget'], parsedPlatform),
      acceptedExtensions: normalizeEditorExtensions(
        json['acceptedExtensions'] is List
            ? (json['acceptedExtensions'] as List).whereType<String>()
            : const [],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'platform': platform.name,
    'launchTarget': launchTarget,
    'acceptedExtensions': acceptedExtensions,
  };

  ExternalEditorDefinition copyWith({
    String? displayName,
    List<String>? acceptedExtensions,
  }) => ExternalEditorDefinition(
    id: id,
    displayName: validateEditorDisplayName(displayName ?? this.displayName),
    platform: platform,
    launchTarget: launchTarget,
    acceptedExtensions: acceptedExtensions ?? this.acceptedExtensions,
  );

  bool acceptsPath(String path) {
    if (acceptedExtensions.isEmpty) return true;
    final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
    return acceptedExtensions.any((extension) => name.endsWith('.$extension'));
  }

  bool get isAvailableOnCurrentPlatform =>
      platform == currentEditorHostPlatform;
}

class EditorRegistry {
  static const systemDefaultId = 'poltergeist.system';
  static const builtInId = 'poltergeist.builtin';

  /// The reserved-id namespace (06 §4.1): `poltergeist.system`,
  /// `poltergeist.builtin`, and every other `poltergeist.*` id a synced
  /// or hand-edited definition might try to claim — rejecting the whole
  /// prefix keeps a registry entry from shadowing the reserved selectors'
  /// §4.2 semantics.
  static const reservedIdPrefix = 'poltergeist.';

  String defaultEditorId;
  final List<ExternalEditorDefinition> editors;

  /// Per-extension bindings (06 §4.1): normalized extension (`txt`, or a
  /// compound `tar.gz`) → an editor id or a reserved selector. Populated
  /// by the Open With ▸ "always use" flow; a binding resolves in
  /// [effectiveDefaultFor] only while its target still exists, is
  /// platform-available, and still accepts the extension — a stale one
  /// falls back to the global default and [put]/[remove] strip it
  /// outright (06 §8: no dangling editor id survives either path).
  final Map<String, String> extensionDefaults;

  EditorRegistry({
    this.defaultEditorId = systemDefaultId,
    Iterable<ExternalEditorDefinition> editors = const [],
    Map<String, String> extensionDefaults = const {},
  }) : editors = List.of(editors),
       extensionDefaults = Map.of(extensionDefaults) {
    _repairDefault();
  }

  factory EditorRegistry.fromJson(Object? value) {
    if (value is! Map) return EditorRegistry();
    final json = value.cast<Object?, Object?>();
    final editors = <ExternalEditorDefinition>[];
    final ids = <String>{};
    final entries = json['editors'];
    if (entries is List) {
      for (final entry in entries) {
        if (editors.length >= 64) break;
        if (entry is! Map) continue;
        try {
          final editor = ExternalEditorDefinition.fromJson(
            entry.cast<String, dynamic>(),
          );
          if (_isReservedEditorId(editor.id)) continue;
          if (ids.add(editor.id)) editors.add(editor);
        } catch (_) {
          // Keep other valid entries when one persisted app is malformed.
        }
      }
    }
    // Tolerant decode: keys normalize like any extension input, values
    // must resolve to a loaded editor or a reserved selector — a binding
    // whose target vanished between writes drops rather than dangles.
    final extensionDefaults = <String, String>{};
    final storedDefaults = json['extensionDefaults'];
    if (storedDefaults is Map) {
      for (final entry in storedDefaults.entries) {
        if (entry.key is! String || entry.value is! String) continue;
        final target = entry.value as String;
        if (!_isReservedSelector(target) && !ids.contains(target)) continue;
        final List<String> normalized;
        try {
          normalized = normalizeEditorExtensions([entry.key as String]);
        } on FormatException {
          // A malformed persisted key drops rather than failing load.
          continue;
        }
        if (normalized.isEmpty) continue;
        extensionDefaults[normalized.single] = target;
      }
    }
    return EditorRegistry(
      defaultEditorId: json['defaultEditorId'] is String
          ? json['defaultEditorId'] as String
          : systemDefaultId,
      editors: editors,
      extensionDefaults: extensionDefaults,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'defaultEditorId': defaultEditorId,
    'extensionDefaults': extensionDefaults,
    'editors': editors.map((editor) => editor.toJson()).toList(),
  };

  ExternalEditorDefinition? byId(String id) {
    for (final editor in editors) {
      if (editor.id == id) return editor;
    }
    return null;
  }

  List<ExternalEditorDefinition> compatibleEditors(String path) => [
    for (final editor in editors)
      if (editor.isAvailableOnCurrentPlatform && editor.acceptsPath(path))
        editor,
  ];

  /// Binds [extension] to [editorId] — an editor id or a reserved
  /// selector. The extension normalizes like registry input (`.TXT`,
  /// `*.txt`, `txt` are one binding); an input that normalizes to
  /// nothing clears instead. Binding to a missing editor refuses rather
  /// than persisting a dangling id (06 §8's rule, applied at write).
  void setDefaultForExtension(String extension, String editorId) {
    final normalized = normalizeEditorExtensions([extension]);
    if (normalized.isEmpty) {
      extensionDefaults.remove(extension.trim().toLowerCase());
      return;
    }
    if (!_isReservedSelector(editorId) && byId(editorId) == null) {
      throw FormatException('Unknown editor id: $editorId');
    }
    extensionDefaults[normalized.single] = editorId;
  }

  void clearDefaultForExtension(String extension) {
    final normalized = normalizeEditorExtensions([extension]);
    if (normalized.isEmpty) return;
    extensionDefaults.remove(normalized.single);
  }

  /// Resolves the editor id the Open verb launches for [path] (06
  /// §4.2): the per-extension binding first — validated at read so a
  /// binding whose editor vanished or disclaimed the extension falls
  /// through — then the global default, then the platform fallback.
  /// Local Open bypasses this entirely (§4.2's deliberate divergence);
  /// it binds the checkout chains only.
  String effectiveDefaultFor(String path) {
    final bound = _extensionDefaultFor(path);
    if (bound != null) return bound;
    return _resolvedSelectorFor(path, defaultEditorId);
  }

  /// The longest matching binding wins (`tar.gz` beats `gz` — matching
  /// acceptsPath's compound-extension semantics at the same boundary).
  String? _extensionDefaultFor(String path) {
    if (extensionDefaults.isEmpty) return null;
    final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
    String? match;
    var matchLength = 0;
    for (final extension in extensionDefaults.keys) {
      if (extension.length <= matchLength) continue;
      if (!name.endsWith('.$extension')) continue;
      match = extension;
      matchLength = extension.length;
    }
    if (match == null) return null;
    final target = extensionDefaults[match]!;
    if (_isReservedSelector(target)) return target;
    final editor = byId(target);
    if (editor == null ||
        !editor.isAvailableOnCurrentPlatform ||
        !editor.acceptsPath(path)) {
      return null;
    }
    return target;
  }

  String _resolvedSelectorFor(String path, String selected) {
    if (selected == builtInId) return selected;
    // Mobile open/share APIs generally hand another app a copy rather
    // than an in-place editable checkout. Keep remote editing reliable
    // there.
    if (selected == systemDefaultId) {
      return currentEditorHostPlatform == null
          ? builtInId
          : systemDefaultId;
    }
    final editor = byId(selected);
    if (editor == null ||
        !editor.isAvailableOnCurrentPlatform ||
        !editor.acceptsPath(path)) {
      return currentEditorHostPlatform == null
          ? builtInId
          : systemDefaultId;
    }
    return editor.id;
  }

  void put(ExternalEditorDefinition editor) {
    _validatedId(editor.id);
    if (_isReservedEditorId(editor.id)) {
      throw const FormatException('Editor id is reserved');
    }
    validateEditorDisplayName(editor.displayName);
    _validatedTarget(editor.launchTarget, editor.platform);
    // Store the normalized form: acceptsPath suffix-matches lowercase,
    // so an unnormalized list ('.TXT', '*.txt') would never match and
    // the §8 strip below would drop the editor's valid bindings. The
    // copy is skipped when the list is already normalized so put()
    // preserves identity for callers holding the definition.
    final normalizedExtensions = normalizeEditorExtensions(
      editor.acceptedExtensions,
    );
    if (!listEquals(normalizedExtensions, editor.acceptedExtensions)) {
      editor = editor.copyWith(acceptedExtensions: normalizedExtensions);
    }
    final index = editors.indexWhere((item) => item.id == editor.id);
    if (index < 0) {
      if (editors.length >= 64) {
        throw StateError('At most 64 external editors can be configured.');
      }
      editors.add(editor);
    } else {
      editors[index] = editor;
    }
    // 06 §8: editing an editor's accepted extensions strips the
    // per-extension bindings it no longer honors — effectiveDefaultFor
    // falls back to the global default for those extensions rather than
    // keeping a binding the editor disclaimed.
    extensionDefaults.removeWhere(
      (extension, target) =>
          target == editor.id && !editor.acceptsPath('file.$extension'),
    );
  }

  void remove(String id) {
    editors.removeWhere((editor) => editor.id == id);
    if (defaultEditorId == id) defaultEditorId = systemDefaultId;
    // Same §8 strip on the remove path: no binding may point at an
    // editor that no longer exists.
    extensionDefaults.removeWhere((_, target) => target == id);
  }

  void _repairDefault() {
    if (_isReservedSelector(defaultEditorId)) return;
    if (byId(defaultEditorId) == null) defaultEditorId = systemDefaultId;
  }
}

/// A reserved selector — the reserved ids themselves, not the whole
/// rejected prefix (a persisted `poltergeist.anything` default is
/// repaired to system rather than honored).
bool _isReservedSelector(String id) =>
    id == EditorRegistry.systemDefaultId || id == EditorRegistry.builtInId;

bool _isReservedEditorId(String id) =>
    _isReservedSelector(id) || id.startsWith(EditorRegistry.reservedIdPrefix);

EditorHostPlatform? get currentEditorHostPlatform {
  if (Platform.isMacOS) return EditorHostPlatform.macos;
  if (Platform.isLinux) return EditorHostPlatform.linux;
  if (Platform.isWindows) return EditorHostPlatform.windows;
  return null;
}

List<String> normalizeEditorExtensions(Iterable<String> values) {
  final result = <String>{};
  for (var value in values) {
    value = value.trim().toLowerCase();
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.startsWith('*')) value = value.substring(1);
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.isEmpty) continue;
    if (value.length > 32 || RegExp(r'[/\\*?\x00-\x1f\x7f]').hasMatch(value)) {
      throw FormatException('Invalid file extension: $value');
    }
    result.add(value);
    if (result.length > 64) {
      throw const FormatException('At most 64 extensions can be configured.');
    }
  }
  return result.toList()..sort();
}

/// Opens managed checkouts without ever constructing a shell command.
final class ExternalFileOpener {
  static const channel = MethodChannel('poltergeist/files');

  const ExternalFileOpener({
    this.systemOpener,
    this.processStarter,
    this.executablePicker,
  });

  /// The OS-default launch seam — the engine's LocalFileOpener (typed
  /// RemoteFileException errors, no shell) rather than Séance's
  /// open_file plugin: same hand-off, one fewer plugin (PORTS-noted).
  final LocalFileOpener? systemOpener;
  final Future<Process> Function(String executable, List<String> arguments)?
  processStarter;
  final Future<String?> Function(
    EditorHostPlatform platform,
    String dialogTitle,
  )?
  executablePicker;

  Future<void> openSystemDefault(String path) =>
      (systemOpener ?? LocalFileOpener.platform()).open(path);

  Future<void> openWith(String path, ExternalEditorDefinition editor) async {
    if (!editor.isAvailableOnCurrentPlatform) {
      throw UnsupportedError(
        '${editor.displayName} is configured for another platform.',
      );
    }
    if (editor.platform == EditorHostPlatform.macos) {
      await channel.invokeMethod<void>('openWithApplication', {
        'path': path,
        'bundleIdentifier': editor.launchTarget,
      });
      return;
    }
    final executable = File(editor.launchTarget);
    final type = await FileSystemEntity.type(editor.launchTarget);
    if (!executable.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError(
        '${editor.displayName} is no longer installed at '
        '${editor.launchTarget}.',
      );
    }
    if (editor.platform == EditorHostPlatform.linux &&
        ((await executable.stat()).mode & 0x49) == 0) {
      throw StateError('${editor.displayName} is not executable.');
    }
    await (processStarter ?? _startDetached)(
      editor.launchTarget,
      [path],
    );
  }

  static Future<Process> _startDetached(
    String executable,
    List<String> arguments,
  ) => Process.start(
    executable,
    arguments,
    runInShell: false,
    mode: ProcessStartMode.detached,
  );

  /// Picks an application and returns its definition — null on
  /// cancellation. [dialogTitle] is the caller's ARB string (D20): the
  /// native executable picker takes it verbatim, and it crosses the
  /// macOS channel as the panel's prompt.
  Future<ExternalEditorDefinition?> pickEditor({
    required String dialogTitle,
  }) async {
    final platform = currentEditorHostPlatform;
    if (platform == null) return null;
    if (platform == EditorHostPlatform.macos) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'pickApplication',
        {'title': dialogTitle},
      );
      if (result == null) return null;
      final bundleIdentifier = result['bundleIdentifier'] as String?;
      if (bundleIdentifier == null || bundleIdentifier.isEmpty) {
        throw StateError('The selected application has no bundle identifier.');
      }
      return ExternalEditorDefinition(
        id: uuidV4(),
        displayName: validateEditorDisplayName(result['displayName']),
        platform: platform,
        launchTarget: bundleIdentifier,
      );
    }
    final path = await (executablePicker ?? _defaultPickExecutable)(
      platform,
      dialogTitle,
    );
    if (path == null) return null;
    final file = File(path);
    final type = await FileSystemEntity.type(path);
    if (!file.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError('Choose a regular executable file.');
    }
    if (platform == EditorHostPlatform.windows &&
        !path.toLowerCase().endsWith('.exe')) {
      throw StateError('Windows editors must be .exe applications.');
    }
    if (platform == EditorHostPlatform.linux &&
        ((await file.stat()).mode & 0x49) == 0) {
      throw StateError('The selected file is not executable.');
    }
    final name = path.split(Platform.pathSeparator).last;
    return ExternalEditorDefinition(
      id: uuidV4(),
      displayName: validateEditorDisplayName(
        platform == EditorHostPlatform.windows &&
                name.toLowerCase().endsWith('.exe')
            ? name.substring(0, name.length - 4)
            : name,
      ),
      platform: platform,
      launchTarget: path,
    );
  }

  static Future<String?> _defaultPickExecutable(
    EditorHostPlatform platform,
    String dialogTitle,
  ) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      allowMultiple: false,
      type: platform == EditorHostPlatform.windows
          ? FileType.custom
          : FileType.any,
      allowedExtensions: platform == EditorHostPlatform.windows
          ? const ['exe']
          : null,
      lockParentWindow: platform == EditorHostPlatform.windows,
    );
    return result?.files.single.path;
  }
}

String _validatedId(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value)) {
    throw const FormatException('Invalid editor id');
  }
  return value;
}

String validateEditorDisplayName(Object? value) {
  if (value is! String) throw const FormatException('Invalid editor name');
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 100 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
    throw const FormatException('Invalid editor name');
  }
  return name;
}

String _validatedTarget(Object? value, EditorHostPlatform platform) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 4096 ||
      value.contains('\u0000')) {
    throw const FormatException('Invalid editor target');
  }
  // Absoluteness is judged on the DEFINITION's platform, not the host's:
  // a synced or hand-edited registry can carry an other-platform editor
  // (06 §8 renders it disabled), and File.isAbsolute would reject a
  // Windows path everywhere but Windows — making the entry unloadable
  // rather than merely unlaunchable (a Poltergeist divergence from the
  // Seance original, which shares the host-aware check).
  final absolute = switch (platform) {
    EditorHostPlatform.macos => true, // bundle identifier, not a path
    EditorHostPlatform.windows =>
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
          value.startsWith('\\\\'),
    EditorHostPlatform.linux => value.startsWith('/'),
  };
  if (!absolute) {
    throw const FormatException('Editor executable paths must be absolute');
  }
  if (platform == EditorHostPlatform.windows &&
      !value.toLowerCase().endsWith('.exe')) {
    throw const FormatException('Windows editors must be .exe applications');
  }
  return value;
}
