import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/shell/header_toolbar.dart';
import 'package:poltergeist_app/ui/shell/macos_toolbar_band.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_app/ui/top_toast.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/shell_commands.dart';

/// On macOS the empty unified toolbar claims every mouse-down in
/// its 52 pt band for window drag and zoom; only the shell header's
/// MacosToolbarPassthrough views hand clicks back to Flutter. Every
/// other surface (pushed routes like the built-in editor, dialogs, top
/// toasts) must therefore keep its controls below the band, while the
/// shell keeps drawing its header under it.
void main() {
  late session_test.FakeAppEngine engine;

  setUp(() {
    engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
      session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
    ]);
  });

  Future<GlobalKey<NavigatorState>> pumpApp(
    WidgetTester tester,
    TargetPlatform platform, {
    Size size = const Size(1400, 900),
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-band-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final bookmarks = FakeBookmarkStore();
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: bookmarks,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);
    await tester.pumpWidget(
      PoltergeistApp(
        bookmarks: bookmarks,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pumpAndSettle();
    return navigatorKey;
  }

  Future<void> pushEditorLikeRoute(
    WidgetTester tester,
    GlobalKey<NavigatorState> navigator,
  ) async {
    // The built-in editor's shape: a MaterialPageRoute whose Scaffold
    // AppBar carries the implied back button and trailing actions.
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('notes.txt'),
            actions: [
              IconButton(
                key: const ValueKey('band.test.save'),
                onPressed: () {},
                icon: const Icon(Icons.save_outlined),
              ),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('macOS: a pushed route keeps its app bar below the band', (
    tester,
  ) async {
    try {
      final navigator = await pumpApp(tester, TargetPlatform.macOS);
      await pushEditorLikeRoute(tester, navigator);

      final back = tester.getRect(find.byType(BackButton));
      final save = tester.getRect(find.byKey(const ValueKey('band.test.save')));
      expect(back.top, greaterThanOrEqualTo(macosToolbarBandHeight));
      expect(save.top, greaterThanOrEqualTo(macosToolbarBandHeight));

      // The back button still works from its new place.
      await tester.tapAt(back.center);
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS: dialogs and top toasts start below the band', (
    tester,
  ) async {
    try {
      await pumpApp(tester, TargetPlatform.macOS);
      // Raised from inside the shell, as its commands do.
      final context = tester.element(find.byType(HeaderToolbar));

      showTopToastIn(context, message: 'Moved to Trash', actionLabel: 'Undo');
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('Moved to Trash')).top,
        greaterThanOrEqualTo(macosToolbarBandHeight),
      );
      expect(
        tester.getRect(find.text('Undo')).top,
        greaterThanOrEqualTo(macosToolbarBandHeight),
      );

      showDialog<void>(
        context: context,
        builder: (_) => const Dialog(
          child: SizedBox(
            key: ValueKey('band.test.dialog'),
            width: 300,
            height: 5000,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('band.test.dialog'))).top,
        greaterThanOrEqualTo(macosToolbarBandHeight),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS: the shell still draws its header under the band', (
    tester,
  ) async {
    try {
      await pumpApp(tester, TargetPlatform.macOS);
      expect(tester.getRect(find.byType(HeaderToolbar)).top, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS: the narrow-window sidebar drawer starts below the band', (
    tester,
  ) async {
    try {
      // 722 px cannot fit the 232 px sidebar inline beside two panes, so
      // the sidebar mounts in the Scaffold drawer (D32 §3.2).
      await pumpApp(tester, TargetPlatform.macOS, size: const Size(722, 700));
      expect(find.byKey(const ValueKey('sidebar.region')), findsNothing);

      await runShellCommand(tester, kViewToggleSidebarCommandId);
      expect(find.byType(Drawer), findsOneWidget);
      expect(
        tester.getRect(find.byType(SidebarView)).top,
        greaterThanOrEqualTo(macosToolbarBandHeight),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS: the sidebar splitter passes band clicks through', (
    tester,
  ) async {
    try {
      await pumpApp(tester, TargetPlatform.macOS);
      final splitter = find.byKey(const ValueKey('sidebar.splitter'));
      // Full height, so its top segment lies inside the band: without a
      // passthrough view a drag there moves the window instead.
      expect(tester.getRect(splitter).top, 0);
      expect(
        find.descendant(
          of: splitter,
          matching: find.byType(MacosToolbarPassthrough),
        ),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Linux: no band is reserved above pushed routes', (tester) async {
    try {
      final navigator = await pumpApp(tester, TargetPlatform.linux);
      await pushEditorLikeRoute(tester, navigator);
      expect(
        tester.getRect(find.byType(BackButton)).top,
        lessThan(macosToolbarBandHeight),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
