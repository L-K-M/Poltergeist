import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

/// Real-font captures of the tab strip (02 §3): a mixed strip (local,
/// remote-badged, launcher, in-flight), the guarded-close confirmation,
/// and the launcher after the last tab closes. The widget-test default
/// font renders hollow boxes, so the capture loads a real face when the
/// host provides one — set POLTERGEIST_CAPTURE_FONT_DIR or rely on the
/// DejaVu fallback. The PNGs land in tasks/run3-task38/ at the repo root
/// (or POLTERGEIST_CAPTURE_DIR when set), and POLTERGEIST_CAPTURE=1 gates
/// every artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task38';

Future<ByteData> _fontBytes(String path) async {
  // sublistView, not ByteData.view: correct even if the read ever
  // returns a sublist view into a pooled buffer (offset ≠ 0).
  final bytes = File(path).readAsBytesSync();
  return ByteData.sublistView(bytes);
}

Future<void> _loadRealFonts() async {
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '${Platform.environment['HOME']}/.local/share/fonts';
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
  if (!sans.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader('DejaVu Sans')
    ..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
  }
}

RemoteFileEntry _entry(
  String name, {
  String parent = '/home/tester',
  RemoteFileType type = RemoteFileType.file,
}) {
  return RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: 10,
  );
}

/// A channel whose next listing never answers — the in-flight-navigation
/// close-guard trigger (02 §3).
class _HeldListingChannel extends session_test.FakeAppBrowseChannel {
  _HeldListingChannel({super.homePath = '/home/tester'});

  final held = Completer<List<RemoteFileEntry>>();

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    listCalls.add(path);
    return held.future;
  }
}

Bookmark _remoteBookmark() => Bookmark(
  id: 'srv-teal',
  kind: BookmarkKind.remotePath,
  label: 'srv-teal.example.com',
  color: ServerColor.teal,
  icon: ServerIcon.server,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'srv-teal.example.com',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/srv/home',
  sortKey: 'srv-teal',
  createdAt: DateTime.utc(2026, 9, 15),
  updatedAt: DateTime.utc(2026, 9, 15),
);

void main() {
  testWidgets('captures the multi-tab strip, the guarded close, and the '
      'post-last-close launcher', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final engine = session_test.FakeAppEngine();
    // Channel order matches open order: the left and right initial
    // `home` tabs, then the ⌘T duplicate of the left home tab.
    for (final names in [
      ['left.txt', 'docs'],
      ['right.txt'],
      ['left.txt', 'docs'],
    ]) {
      engine.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester'] = [
            for (final name in names) _entry(name),
          ],
      );
    }
    final held = _HeldListingChannel(homePath: '/srv/data');
    engine.localChannels.add(held);
    engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv/home')
      ..listings['/srv/home'] = [
        _entry('remote.txt', parent: '/srv/home'),
      ];

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(engine.close);
    final supportDir = Directory.systemTemp.createTempSync('pg-tabs-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: FakeBookmarkStore(),
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme:
          base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
    );
    await tester.pumpWidget(
      // The boundary wraps the app, not the shell: the guarded-close
      // dialog renders on the Navigator's overlay — a SIBLING of `home`
      // — so a boundary inside the app would capture no dialog.
      RepaintBoundary(
        key: const ValueKey('capture.shell'),
        child: MaterialApp(
          // Whole-app captures include the overlay; the debug banner
          // is test chrome, not product chrome — keep it out.
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorKey: navigatorKey,
          home: WorkspaceShell(engineSession: session),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.shell')),
    );
    final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    final outDir = Directory(_captureDir);

    Future<void> capture(String name) async {
      if (!captureOn) return;
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          return data!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      outDir.createSync(recursive: true);
      final file = File('${outDir.path}/$name.png');
      // The default dir is relative to the test runner's CWD; print
      // where the PNG actually landed so a run launched from another
      // directory is obvious instead of silently writing elsewhere.
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }

    PaneTabsController leftStrip() => tester
        .widgetList<PaneTabsView>(find.byType(PaneTabsView))
        .first
        .tabs;

    // The initial left tab browsed home; grow the strip through the
    // production operations: ⌘T honors the duplicate default, then a
    // launcher tab binds remote and another stays on the launcher.
    final strip = leftStrip();
    expect(strip.tabs.length, 1);

    strip.newTab(); // NewTabTarget.duplicate default
    final remote = strip.newTab(target: NewTabTarget.launcher);
    unawaited(remote.controller.connectRemote(_remoteBookmark()));
    strip.newTab(target: NewTabTarget.launcher);
    final navigating = strip.newTab(target: NewTabTarget.launcher);
    unawaited(navigating.controller.openLocalAt('/srv/data'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(strip.tabs.length, 5);
    expect(navigating.controller.loading, isTrue);
    expect(
      strip.closeTriggers(navigating),
      [TabCloseTrigger.navigation],
    );

    // Activate the remote tab for the strip capture: its chip carries
    // the teal badge and the connected dot beside the folder tabs.
    strip.activateTab(remote);
    await tester.pump();
    await capture('strip-multi');

    // Middle-click close on the navigating tab routes through the same
    // guarded operation — the confirmation is the shell's real dialog.
    unawaited(strip.requestCloseTab(navigating));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsOneWidget);
    await capture('close-confirm');

    // Decline: the tab and its in-flight navigation survive.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AlertDialog), findsNothing);
    expect(strip.tabs, contains(navigating));

    // Close every left tab: the last one lands the pane on the
    // launcher — never blank, never auto-reopened.
    held.held.complete(const []);
    for (final tab in List.of(strip.tabs)) {
      unawaited(strip.requestCloseTab(tab));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(AlertDialog).evaluate().isNotEmpty) {
        await tester.tap(find.text('Close'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(strip.tabs, isEmpty);
    expect(strip.activeTab, isNull);
    expect(strip.canReopen, isTrue);
    await capture('launcher-after-last-close');
  });
}
