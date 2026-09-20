// Ported from Séance's app/seance_app/test/external_editor_test.dart @
// 2e6d1f1 — the registry validation/normalization matrix — extended for
// Poltergeist's 06 §4.1 divergences: the whole `poltergeist.` prefix is
// reserved (no BBEdit legacy migration exists), per-extension
// `extensionDefaults` bind ahead of the global default, and persistence
// rides the shared settings.json through EditorRegistryController.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/editor_registry_controller.dart';
import 'package:poltergeist_app/services/external_file_opener.dart';
import 'package:poltergeist_app/services/settings_store.dart';

ExternalEditorDefinition _editor({
  String id = 'editor.test',
  String displayName = 'Test Editor',
  EditorHostPlatform? platform,
  String launchTarget = '/test/editor',
  List<String> acceptedExtensions = const [],
}) => ExternalEditorDefinition(
  id: id,
  displayName: displayName,
  platform: platform ?? currentEditorHostPlatform!,
  launchTarget: launchTarget,
  acceptedExtensions: acceptedExtensions,
);

void main() {
  group('EditorRegistry (ported)', () {
    test('normalizes extension filters and matches compound extensions', () {
      final extensions = normalizeEditorExtensions([
        ' .DART ',
        '*.tar.gz',
        'json',
        '.dart',
      ]);
      final editor = _editor(acceptedExtensions: extensions);

      expect(extensions, ['dart', 'json', 'tar.gz']);
      expect(editor.acceptsPath('/tmp/FILE.DART'), isTrue);
      expect(editor.acceptsPath('/tmp/archive.TAR.GZ'), isTrue);
      expect(editor.acceptsPath('/tmp/no-extension'), isFalse);
    });

    test('empty extension filters accept every file', () {
      final editor = _editor(id: 'editor.all');

      expect(editor.acceptsPath('/tmp/.bashrc'), isTrue);
      expect(editor.acceptsPath('/tmp/no-extension'), isTrue);
    });

    test('registry round-trips and filters incompatible defaults', () {
      final editor = _editor(acceptedExtensions: const ['txt']);
      final registry = EditorRegistry(
        defaultEditorId: editor.id,
        editors: [editor],
      );

      final restored = EditorRegistry.fromJson(registry.toJson());

      expect(restored.defaultEditorId, editor.id);
      expect(restored.effectiveDefaultFor('/tmp/readme.txt'), editor.id);
      expect(
        restored.effectiveDefaultFor('/tmp/image.png'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('malformed editor entries do not discard valid entries', () {
      final registry = EditorRegistry.fromJson({
        'version': 1,
        'defaultEditorId': 'valid.editor',
        'editors': [
          {'id': 4},
          {
            'id': 'valid.editor',
            'displayName': 'Valid',
            'platform': currentEditorHostPlatform!.name,
            'launchTarget': '/test/editor',
            'acceptedExtensions': ['txt'],
          },
        ],
      });

      expect(registry.editors.single.id, 'valid.editor');
      expect(registry.defaultEditorId, 'valid.editor');
    });

    test('invalid extension syntax is rejected', () {
      expect(
        () => normalizeEditorExtensions(['txt', '../sh']),
        throwsFormatException,
      );
    });

    test('registry rejects editor values that cannot round-trip', () {
      final registry = EditorRegistry();
      expect(
        () => registry.put(
          _editor(displayName: List.filled(101, 'x').join()),
        ),
        throwsFormatException,
      );
    });
  });

  group('reserved ids (06 §4.1)', () {
    test('the reserved selectors cannot be registered', () {
      for (final id in [
        EditorRegistry.builtInId,
        EditorRegistry.systemDefaultId,
      ]) {
        expect(
          () => EditorRegistry().put(_editor(id: id)),
          throwsFormatException,
        );
      }
    });

    test('the whole poltergeist. prefix is rejected — a synced or '
        'hand-edited definition must not shadow the selectors', () {
      expect(
        () => EditorRegistry().put(_editor(id: 'poltergeist.notepad')),
        throwsFormatException,
      );
      // …and a persisted one is dropped at load, not honored.
      final registry = EditorRegistry.fromJson({
        'editors': [
          {
            'id': 'poltergeist.shadow',
            'displayName': 'Shadow',
            'platform': currentEditorHostPlatform!.name,
            'launchTarget': '/test/editor',
          },
        ],
      });
      expect(registry.editors, isEmpty);
    });

    test('a persisted reserved-prefix default repairs to system', () {
      final registry = EditorRegistry.fromJson({
        'defaultEditorId': 'poltergeist.anything',
      });
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
    });
  });

  group('per-extension bindings (06 §4.1)', () {
    test('a binding resolves ahead of the global default', () {
      final editor = _editor(acceptedExtensions: const ['txt']);
      final registry = EditorRegistry(editors: [editor])
        ..setDefaultForExtension('txt', editor.id);

      expect(registry.effectiveDefaultFor('/tmp/readme.txt'), editor.id);
      expect(
        registry.effectiveDefaultFor('/tmp/other.md'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('the longest matching binding wins — tar.gz beats gz', () {
      final gzip = _editor(id: 'editor.gz', acceptedExtensions: ['gz']);
      final tar = _editor(id: 'editor.tar', acceptedExtensions: ['tar.gz']);
      final registry = EditorRegistry(editors: [gzip, tar])
        ..setDefaultForExtension('gz', gzip.id)
        ..setDefaultForExtension('tar.gz', tar.id);

      expect(
        registry.effectiveDefaultFor('/tmp/archive.tar.gz'),
        tar.id,
      );
      expect(registry.effectiveDefaultFor('/tmp/blob.gz'), gzip.id);
    });

    test('binding to an unknown editor refuses rather than dangling', () {
      expect(
        () => EditorRegistry().setDefaultForExtension('txt', 'editor.missing'),
        throwsFormatException,
      );
    });

    test('bindings normalize like registry input', () {
      final editor = _editor();
      final registry = EditorRegistry(editors: [editor])
        ..setDefaultForExtension(' .TXT ', editor.id);
      expect(registry.extensionDefaults, {'txt': editor.id});
      expect(registry.effectiveDefaultFor('/tmp/A.TXT'), editor.id);
    });

    test('reserved selectors are legal binding targets', () {
      final registry = EditorRegistry()
        ..setDefaultForExtension('txt', EditorRegistry.builtInId);
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.builtInId,
      );
    });

    test('removing an editor strips its bindings and resets a default',
        () {
      final editor = _editor(acceptedExtensions: const ['txt']);
      final registry = EditorRegistry(
        defaultEditorId: editor.id,
        editors: [editor],
      )..setDefaultForExtension('txt', editor.id);

      registry.remove(editor.id);

      expect(registry.defaultEditorId, EditorRegistry.systemDefaultId);
      expect(registry.extensionDefaults, isEmpty);
    });

    test('editing an editor’s extensions strips bindings it disclaimed',
        () {
      final editor = _editor(acceptedExtensions: const ['txt', 'md']);
      final registry = EditorRegistry(editors: [editor])
        ..setDefaultForExtension('txt', editor.id)
        ..setDefaultForExtension('md', editor.id);

      registry.put(editor.copyWith(acceptedExtensions: const ['md']));

      expect(registry.extensionDefaults, {'md': editor.id});
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('a stale persisted binding drops at load instead of dangling', () {
      final registry = EditorRegistry.fromJson({
        'extensionDefaults': {'txt': 'editor.gone'},
        'editors': const [],
      });
      expect(registry.extensionDefaults, isEmpty);
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
    });

    test('a binding to an other-platform editor falls back, and a '
        'persisted one still decodes for its own platform', () {
      final other = currentEditorHostPlatform == EditorHostPlatform.linux
          ? EditorHostPlatform.windows
          : EditorHostPlatform.linux;
      final target = other == EditorHostPlatform.windows
          ? 'C:\\Tools\\editor.exe'
          : '/test/editor';
      final registry = EditorRegistry.fromJson({
        'extensionDefaults': {'txt': 'editor.other'},
        'editors': [
          {
            'id': 'editor.other',
            'displayName': 'Other OS',
            'platform': other.name,
            'launchTarget': target,
            'acceptedExtensions': ['txt'],
          },
        ],
      });
      // The binding decodes (the row exists for its platform), but
      // resolution here falls back — an unavailable editor never wins.
      expect(registry.extensionDefaults, {'txt': 'editor.other'});
      expect(
        registry.effectiveDefaultFor('/tmp/a.txt'),
        EditorRegistry.systemDefaultId,
      );
      expect(registry.compatibleEditors('/tmp/a.txt'), isEmpty);
    });
  });

  group('caps', () {
    test('at most 64 editors register', () {
      final registry = EditorRegistry(
        editors: [for (var i = 0; i < 64; i++) _editor(id: 'editor.$i')],
      );
      expect(
        () => registry.put(_editor(id: 'editor.65')),
        throwsStateError,
      );
      // Replacing an existing id is not an add — still allowed at cap.
      registry.put(_editor(id: 'editor.0', displayName: 'Renamed'));
      expect(registry.editors, hasLength(64));
    });

    test('at most 64 extensions normalize', () {
      expect(
        () => normalizeEditorExtensions([
          for (var i = 0; i < 65; i++) 'e$i',
        ]),
        throwsFormatException,
      );
    });
  });

  group('compatibleEditors', () {
    test('filters by platform availability and declared extensions', () {
      final other = currentEditorHostPlatform == EditorHostPlatform.linux
          ? EditorHostPlatform.windows
          : EditorHostPlatform.linux;
      final registry = EditorRegistry(
        editors: [
          _editor(id: 'editor.txt', acceptedExtensions: ['txt']),
          _editor(id: 'editor.all'),
          _editor(id: 'editor.md', acceptedExtensions: ['md']),
          _editor(
            id: 'editor.other',
            platform: other,
            launchTarget: other == EditorHostPlatform.windows
                ? 'C:\\Tools\\editor.exe'
                : '/test/editor',
          ),
        ],
      );

      expect(
        registry.compatibleEditors('/tmp/a.txt').map((e) => e.id),
        ['editor.txt', 'editor.all'],
      );
    });
  });

  group('EditorRegistryController persistence (06 §4.1)', () {
    late Directory tempDir;
    late SettingsStore store;
    late EditorRegistryController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pg-editors-');
      store = SettingsStore(path: p.join(tempDir.path, 'settings.json'));
      controller = EditorRegistryController(store: store);
      await controller.load();
    });

    tearDown(() async {
      await store.flush();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('a picked editor and a remember-choice binding survive a '
        'fresh load', () async {
      final picked = _editor(
        id: 'editor.picked',
        displayName: 'Picked',
        launchTarget: '/usr/bin/picked',
      );
      await controller.register(picked);
      await controller.setExtensionDefault('txt', picked.id);
      await store.flush();

      final reloaded = EditorRegistryController(store: store);
      await reloaded.load();

      expect(reloaded.registry.byId('editor.picked'), isNotNull);
      expect(
        reloaded.registry.effectiveDefaultFor('/tmp/a.txt'),
        'editor.picked',
      );
      // The document lives under its own settings.json key — the same
      // file every other settings slice shares, never a second file.
      expect(
        File(p.join(tempDir.path, 'settings.json')).readAsStringSync(),
        contains('editorRegistry'),
      );
    });

    test('a malformed persisted document boots the default registry', () {
      expect(
        EditorRegistry.fromJson('not a map').defaultEditorId,
        EditorRegistry.systemDefaultId,
      );
      expect(EditorRegistry.fromJson(42).editors, isEmpty);
    });

    test('a failed settings write restores the pre-mutation registry',
        () async {
      final failing = SettingsStore(
        path: p.join(tempDir.path, 'other.json'),
        atomicWriter: (target, contents, {restrictToOwner = false}) =>
            Future.error(StateError('disk full')),
      );
      final failingController = EditorRegistryController(store: failing);
      await failingController.load();

      await expectLater(
        failingController.register(_editor(id: 'editor.lost')),
        throwsStateError,
      );
      // The in-memory registry rolled back with the write — no surface
      // resolves a default the disk does not hold (06 §8's discipline).
      expect(failingController.registry.byId('editor.lost'), isNull);
    });

    test('removing an editor persists the stripped bindings', () async {
      final editor = _editor(id: 'editor.gone', acceptedExtensions: ['txt']);
      await controller.register(editor);
      await controller.setExtensionDefault('txt', editor.id);
      await controller.remove(editor.id);
      await store.flush();

      final reloaded = EditorRegistryController(store: store);
      await reloaded.load();

      expect(reloaded.registry.editors, isEmpty);
      expect(reloaded.registry.extensionDefaults, isEmpty);
    });
  });
}
