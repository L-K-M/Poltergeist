import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/quit_guard.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

/// Real-font capture of the quit-guard dialog (02 §10) raised through
/// [QuitGuard.confirmClose] over a scripted queue. The widget-test
/// default font renders hollow boxes, so the capture loads a real face
/// when the host provides one — set POLTERGEIST_CAPTURE_FONT_DIR or rely
/// on the DejaVu fallback. The PNG lands in tasks/run3-task72/captures/
/// at the repo root (or POLTERGEIST_CAPTURE_DIR), and
/// POLTERGEIST_CAPTURE=1 gates every artifact write so an ordinary suite
/// run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task72/captures';

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
  testWidgets('captures the quit-with-transfers dialog', (tester) async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadRealFonts);
    }

    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final queue = FakeAppTransferQueue();
    addTearDown(queue.close);
    final guard = QuitGuard(navigatorKey: navigatorKey);

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('quit.capture'),
        child: PoltergeistApp(
          navigatorKey: navigatorKey,
          transferQueue: queue,
          quitGuard: guard,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A running upload at 40%, a queued task, and a finished row the
    // count must exclude — the §10 warning surface in one frame.
    queue.addTask(
      state: TransferTaskState.running,
      rootPaths: const ['/home/tester/site'],
      totalFiles: 4,
      completedFiles: 1,
      transferredBytes: 800 * 1000,
      totalBytes: 2 * 1000 * 1000,
    );
    queue.addTask(
      state: TransferTaskState.queued,
      rootPaths: const ['/home/tester/backup.tar'],
    );
    queue.addTask(
      state: TransferTaskState.completed,
      rootPaths: const ['/home/tester/notes.txt'],
    );

    unawaited(guard.confirmClose());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);
    expect(find.textContaining('2 transfers are running'), findsOneWidget);

    final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    if (captureOn) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('quit.capture')),
      );
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
      final outDir = Directory(_captureDir)..createSync(recursive: true);
      final file = File('${outDir.path}/quit-confirm-dialog.png');
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }

    // Veto the close so no pending dialog outlives the test.
    await tester.tap(find.byKey(const ValueKey('quit.keepTransferring')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quit.dialog')), findsNothing);
  });
}
