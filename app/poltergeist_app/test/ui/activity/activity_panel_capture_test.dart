import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/activity_panel_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/activity/activity_panel.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_app_transfer_queue.dart';

/// Real-font captures of 02 §6's activity panel: live task rows over a
/// parked conflict, the conflict chooser dialog, and the History tab.
/// The widget-test default font renders hollow boxes, so the capture
/// loads a real face when the host provides one — set
/// POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. PNGs
/// land in tasks/run3-task68/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR), and POLTERGEIST_CAPTURE=1 gates every
/// artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task68/captures';

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

void main() {
  testWidgets('captures the active panel, the conflict dialog, and '
      'history', (tester) async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadRealFonts);
    }

    final queue = FakeAppTransferQueue();
    addTearDown(queue.close);
    final controller = ActivityPanelController(queue: queue);
    // Disposed explicitly at the test's end — a linger timer armed by
    // the scripted completed row must die inside the fake-async zone,
    // not in a teardown that runs after the binding's timer check.

    tester.view.physicalSize = const Size(1200, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // A running upload expanded to its files, a queued task, a
    // lingering completed row, and one parked conflict — the §6
    // surface in one frame.
    final running = queue.addTask(
      state: TransferTaskState.running,
      rootPaths: const ['/home/tester/site'],
      totalFiles: 4,
      completedFiles: 1,
      transferredBytes: 512 * 1000,
      totalBytes: 2 * 1000 * 1000,
    );
    queue.addItem(
      running,
      name: 'index.html',
      size: 20 * 1000,
      state: TransferItemState.completed,
    );
    queue.addItem(
      running,
      name: 'app.js',
      size: 800 * 1000,
      transferredBytes: 300 * 1000,
      state: TransferItemState.active,
    );
    final parked = queue.addItem(running, name: 'logo.png');
    queue.addTask(
      state: TransferTaskState.queued,
      rootPaths: const ['/home/tester/backup.tar'],
    );
    queue.addTask(
      state: TransferTaskState.completed,
      rootPaths: const ['/home/tester/notes.txt'],
      totalFiles: 1,
      completedFiles: 1,
      transferredBytes: 1024,
      totalBytes: 1024,
    );
    queue.addConflict(running, parked);

    final navigatorKey = GlobalKey<NavigatorState>();
    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.panel'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates:
              AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                SizedBox(
                  height: 420,
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => ActivityPanel(
                      controller: controller,
                      onClose: () {},
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.panel')),
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
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }

    // Expand the running task so its sub-rows show.
    await tester.tap(find.byTooltip('Show files'));
    await tester.pumpAndSettle();
    expect(find.text('index.html'), findsOneWidget);
    expect(find.text('app.js'), findsOneWidget);
    await capture('activity-panel-active');

    // The conflict chooser over the parked item.
    await tester.tap(
      find.byKey(ValueKey('activity.conflictResolve.${parked.id}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('conflict.verb.replace')),
      findsOneWidget,
    );
    await capture('activity-conflict-dialog');
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    // The History tab with two persisted rows.
    queue.addHistory();
    queue.addHistory(
      taskId: 'done-2',
      rootPaths: const ['/home/tester/vm.iso'],
      operation: TransferOperation.move,
      outcome: TransferTaskState.failed,
      transferredBytes: 3 * 1000 * 1000,
      totalBytes: 8 * 1000 * 1000,
      error: 'connection lost',
    );
    await tester.tap(find.byKey(const ValueKey('activity.tab.history')));
    await tester.pumpAndSettle();
    expect(find.textContaining('report.pdf'), findsWidgets);
    await capture('activity-panel-history');

    // The scripted completed row armed the linger timer — dispose now
    // so no timer outlives the test's fake-async zone.
    controller.dispose();
  });
}
