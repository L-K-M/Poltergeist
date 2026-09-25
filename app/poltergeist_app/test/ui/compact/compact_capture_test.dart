import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/compact/compact_posture.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'compact_harness.dart';

/// Real-font captures of D32 §9's compact posture on a 390 × 844 phone,
/// light and dark: Home (with live server states, at fourteen servers
/// and searching, and empty), a local and a remote browser, selection mode,
/// the row sheet, the ⋮ menus, the inspector sheet over a running
/// transfer with its pill, the second pane, the filter, and the rename
/// dialog. The widget-test default font renders hollow boxes, so the
/// capture loads Inter (standing in for Android's Roboto) when the host
/// provides it — set POLTERGEIST_CAPTURE_FONT_DIR, or rely on the Debian
/// path — plus the Material icon font from the SDK. PNGs land in
/// POLTERGEIST_CAPTURE_DIR (default tasks/d32-android/captures/ at the
/// repo root), and POLTERGEIST_CAPTURE=1 gates every artifact write so
/// an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/d32-android/captures';

final _captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.sublistView(File(path).readAsBytesSync());

/// Registers Inter under Roboto (the family the Android type ramp asks
/// for) and the Material icon font.
Future<void> _loadRealFonts() async {
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(_fontBytes(icons.path))).load();
  }
  final dir =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '/usr/share/fonts/opentype/inter';
  final faces = [
    for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      File('$dir/Inter-$face.otf'),
  ].where((file) => file.existsSync()).toList();
  if (faces.isEmpty) return; // boxes are still a usable capture
  final loader = FontLoader('Roboto');
  for (final face in faces) {
    loader.addFont(_fontBytes(face.path));
  }
  await loader.load();
}

const _boundary = ValueKey('capture.compact');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_captureOn) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  final bytes = (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
  final outDir = Directory(_captureDir)..createSync(recursive: true);
  final file = File('${outDir.path}/$name.png');
  // ignore: avoid_print
  print('capture: ${file.absolute.path}');
  file.writeAsBytesSync(bytes);
}

final _stamp = DateTime.utc(2026, 9, 20, 9, 30);

/// A saved server for the Home scenes: the endpoint line, the mark, and
/// the group vary per row.
Bookmark _server(
  String id, {
  required String label,
  String? host,
  int port = 22,
  String username = 'deploy',
  ServerColor? color,
  ServerIcon? icon,
  String? group,
}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: label,
  group: group,
  color: color,
  icon: icon,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: host ?? '$id.example.com',
      port: port,
      username: username,
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/',
  sortKey: id.replaceAll(RegExp('[^a-z]'), 'x'),
  createdAt: _stamp,
  updatedAt: _stamp,
);

/// Home with every kind of row it draws: a coloured favorite, a saved
/// sync across a server, and servers connected, connecting, failed, on
/// a custom port, with a long name, and in a group.
List<Bookmark> _homeStates() => [
  folderFavorite('docs', '/home/deploy/Documents', label: 'Documents'),
  Bookmark(
    id: 'photos',
    kind: BookmarkKind.localFolder,
    label: 'Photos',
    color: ServerColor.amber,
    localPath: '/home/deploy/Pictures/2026',
    sortKey: 'photos',
    createdAt: _stamp,
    updatedAt: _stamp,
  ),
  Bookmark(
    id: 'mirror',
    kind: BookmarkKind.savedSync,
    label: 'Mirror site',
    sync: SavedSyncSpec(
      source: const BookmarkLocation(path: '/home/deploy/site'),
      destination: BookmarkLocation(
        server: serverBookmark('demo').server,
        path: '/srv/www',
      ),
    ),
    sortKey: 'qmirror',
    createdAt: _stamp,
    updatedAt: _stamp,
  ),
  _server('demo', label: 'demo'),
  _server('backup', label: 'backup box'),
  _server('staging', label: 'staging', color: ServerColor.violet),
  _server(
    'proddb',
    label: 'production-database-primary-eu-west-1.internal',
    host: 'db1.eu-west-1.internal',
    port: 2222,
    username: 'postgres',
    color: ServerColor.blue,
    icon: ServerIcon.database,
  ),
  _server(
    'pi',
    label: 'Raspberry Pi',
    host: '192.168.1.40',
    username: 'pi',
    color: ServerColor.green,
    icon: ServerIcon.device,
    group: 'Home lab',
  ),
];

/// Fourteen servers: past the rail's filter threshold, so the search
/// bar earns its place.
List<Bookmark> _manyServers() => [
  folderFavorite('docs', '/home/deploy/Documents', label: 'Documents'),
  for (final (i, name) in [
    'api',
    'auth',
    'billing',
    'cache',
    'cdn',
    'db-primary',
    'db-replica',
    'logs',
    'mail',
    'metrics',
    'queue',
    'search',
    'web-1',
    'web-2',
  ].indexed)
    _server(
      'srv$i',
      label: name,
      host: '$name.example.com',
      group: i < 3 ? 'Clients' : null,
    ),
];

Future<void> _withCaptureChrome(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  if (_captureOn) await tester.runAsync(_loadRealFonts);
  // Real elevation: the test binding otherwise paints every shadow as a
  // solid outline, which a capture must not show.
  debugDisableShadows = !_captureOn;
  try {
    await body();
  } finally {
    // Restored inside the body: the binding checks painting debug
    // variables before any tear-down runs.
    debugDisableShadows = true;
  }
}

void main() {
  for (final brightness in Brightness.values) {
    final tone = brightness.name;
    testWidgets('captures the compact posture ($tone)', (tester) async {
      await _withCaptureChrome(
        tester,
        () => _runScenes(tester, tone, brightness),
      );
    });

    testWidgets('captures Home with live states ($tone)', (tester) async {
      await _withCaptureChrome(tester, () async {
        final harness = CompactHarness(bookmarks: _homeStates());
        await _pumpHome(tester, harness, brightness);
        final states = harness.engine.statesControllers;
        states['demo']?.add(
          const ServerStatus(ServerConnectionState.connected),
        );
        states['staging']?.add(
          const ServerStatus(ServerConnectionState.connecting),
        );
        states['backup']?.add(
          const ServerStatus(
            ServerConnectionState.disconnected,
            detail: 'Connection refused',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await _capture(tester, 'compact-$tone-home-states');

        // The rest of the list, and the grouped server.
        await tester.drag(
          find.byKey(const ValueKey('sidebar.home.list')),
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();
        await _capture(tester, 'compact-$tone-home-states-end');

        // A server row's ⋮: the same verbs as the long-press.
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('sidebar.favorite.pi')),
            matching: find.byIcon(Icons.more_vert),
          ),
        );
        await tester.pumpAndSettle();
        await _capture(tester, 'compact-$tone-home-row-sheet');
      });
    });

    testWidgets('captures Home at fourteen servers ($tone)', (tester) async {
      await _withCaptureChrome(tester, () async {
        final harness = CompactHarness(bookmarks: _manyServers());
        await _pumpHome(tester, harness, brightness);
        await _capture(tester, 'compact-$tone-home-many');

        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('sidebar.home.search')),
            matching: find.byType(TextField),
          ),
          'db',
        );
        await tester.pumpAndSettle();
        await _capture(tester, 'compact-$tone-home-search');
      });
    });

    testWidgets('captures an empty Home ($tone)', (tester) async {
      await _withCaptureChrome(tester, () async {
        final harness = CompactHarness(bookmarks: const []);
        await _pumpHome(tester, harness, brightness);
        await _capture(tester, 'compact-$tone-home-empty');
      });
    });
  }
}

Future<void> _pumpHome(
  WidgetTester tester,
  CompactHarness harness,
  Brightness brightness,
) => harness.pump(
  tester,
  brightness: brightness,
  systemInsets: true,
  serverEditor: true,
  sshConfigImport: true,
  wrap: (app) => RepaintBoundary(key: _boundary, child: app),
);

Future<void> _runScenes(
  WidgetTester tester,
  String tone,
  Brightness brightness,
) async {
  final harness = CompactHarness();
  await _pumpHome(tester, harness, brightness);

  // Home: the full-screen sidebar.
  await _capture(tester, 'compact-$tone-home');

  // The FAB's add sheet.
  await tester.tap(find.byKey(const ValueKey('sidebar.home.add')));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-home-add');
  await harness.systemBack(tester);

  // The local browser (This device → pane A's home).
  await tester.tap(find.text('This device'));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-browser-local');

  // Selection: two rows, the contextual bar, the bottom bar.
  await tester.longPress(compactRow('/home/deploy/photo.jpg'));
  await tester.pumpAndSettle();
  await tester.tap(compactRow('/home/deploy/report.pdf'));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-selection');
  await harness.systemBack(tester);

  // The row's action sheet.
  await tester.tap(
    find.byKey(const ValueKey((CompactKey.rowMore, '/home/deploy/notes.txt'))),
  );
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-row-sheet');
  await harness.systemBack(tester);

  // ⋮: the registry's menus.
  await tester.tap(find.byKey(const ValueKey(CompactKey.browserMore)));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-command-sheet');
  await harness.systemBack(tester);

  // The filter field.
  await tester.tap(find.byKey(const ValueKey(CompactKey.browserFilter)));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey(CompactKey.filterField)),
    'o',
  );
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-filter');
  await harness.systemBack(tester);

  // Quick Select through the registry, mid-session.
  final host = menuHost(tester);
  unawaited(
    host.onRun(
      host.commands.firstWhere((c) => c.id == 'selection.quickSelect'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey(CompactKey.quickSelectField)),
    '*.pdf',
  );
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-quick-select');
  await harness.systemBack(tester);

  // Pane B through the switcher.
  await tester.tap(find.byKey(const ValueKey(CompactKey.paneSwitcher)));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-pane-b');
  await tester.tap(find.byKey(const ValueKey(CompactKey.paneSwitcher)));
  await tester.pumpAndSettle();

  // A running transfer: the pill, then the sheet on Transfers.
  harness.queue.addTask(
    state: TransferTaskState.running,
    rootPaths: const ['/home/deploy/site.tar.gz'],
    totalFiles: 1,
    transferredBytes: 54000000,
    totalBytes: 120000000,
  );
  harness.queue.addTask(
    state: TransferTaskState.queued,
    rootPaths: const ['/home/deploy/photo.jpg'],
  );
  harness.queue.emitRefresh();
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-pill');
  await tester.tap(find.byKey(const ValueKey(CompactKey.progressPill)));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-sheet-transfers');
  await tester.tap(
    find.byKey(const ValueKey((CompactKey.inspectorTab, InspectorTab.alerts))),
  );
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-sheet-alerts');
  await harness.systemBack(tester);

  // Rename through the row sheet.
  await tester.tap(
    find.byKey(const ValueKey((CompactKey.rowMore, '/home/deploy/notes.txt'))),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('pane.context.file.rename')));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-rename');
  await harness.systemBack(tester);

  // Back to Home (through whatever folder history the flow built),
  // then a server.
  for (var i = 0; i < 6 && harness.compact(tester).browsing; i++) {
    await harness.systemBack(tester);
  }
  await tester.tap(find.byKey(const ValueKey('sidebar.favorite.demo')));
  await tester.pumpAndSettle();
  await _capture(tester, 'compact-$tone-browser-remote');
}
