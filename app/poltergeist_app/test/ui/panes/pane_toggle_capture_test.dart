import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/adaptive_shell.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

/// Real-font captures of 02 §3's one/two-pane toggle in the production
/// shell: the remembered two-pane layout, the one-pane layout after
/// `view.toggleSecondPane`, and the restored layout after re-showing —
/// pane B's strip and listing return whole. The widget-test default font
/// renders hollow boxes, so the capture loads a real face when the host
/// provides one — set POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu
/// fallback. The PNGs land in tasks/run3-task53/captures/ at the repo
/// root (or POLTERGEIST_CAPTURE_DIR when set), and POLTERGEIST_CAPTURE=1
/// gates every artifact write so an ordinary suite run produces no
/// files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task53/captures';

Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.sublistView(bytes);
}

Future<void> _loadRealFonts() async {
  final home = Platform.environment['HOME'];
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home == null ? '' : '$home/.local/share/fonts');
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

RemoteFileEntry _entry(String name) => RemoteFileEntry(
  path: '/home/tester/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

void main() {
  testWidgets('captures the one-pane and restored two-pane layouts', (
    tester,
  ) async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadRealFonts);
    }

    final engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [
          _entry('left-docs.txt'),
          _entry('left-notes.txt'),
        ],
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [
          _entry('right-photos.txt'),
          _entry('right-music.txt'),
        ],
    ]);
    addTearDown(engine.close);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-toggle-');
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

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.shell'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorKey: navigatorKey,
          home: WorkspaceShell(
            bookmarks: bookmarks,
            engineSession: session,
          ),
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

    // Baseline: both panes browsing their scripted homes.
    expect(find.text('left-docs.txt'), findsOneWidget);
    expect(find.text('right-photos.txt'), findsOneWidget);
    await capture('pane-toggle-two-pane');

    // The toggle hides pane B whole: the layout collapses to pane A at
    // full width while the strip and per-tab state live on.
    await tester.tap(
      find.byKey(const ValueKey('command.view.toggleSecondPane')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(AdaptiveShell.secondaryPaneKey),
      findsNothing,
    );
    expect(find.text('right-photos.txt'), findsNothing);
    await capture('pane-toggle-one-pane');

    // Re-showing restores the remembered pane exactly — same strip,
    // same listing, no re-list.
    await tester.tap(
      find.byKey(const ValueKey('command.view.toggleSecondPane')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(AdaptiveShell.secondaryPaneKey),
      findsOneWidget,
    );
    expect(find.text('right-photos.txt'), findsOneWidget);
    expect(engine.localChannels[1].listCalls, ['/home/tester']);
    await capture('pane-toggle-restored');
  });
}
