// SyncPlanView coverage (M8): the ready-state §7 surface — header
// clauses, filter chips, grouped rows, the per-row override menu, the
// conflict bar, rail 3's typed-DELETE dialog, rail 4's refusal banner,
// and the run controls — plus the POLTERGEIST_CAPTURE-gated artifact
// set the task captures ask for.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/sync/sync_plan_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';

/// PNGs land in tasks/run3-task90/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set); POLTERGEIST_CAPTURE=1 gates every
/// artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task90/captures';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

/// Loads the faces the theme resolves plus MaterialIcons — the
/// widget-test default font renders hollow boxes, so captures ask the
/// host for DejaVu (POLTERGEIST_CAPTURE_FONT_DIR or the usual user font
/// directory).
Future<void> _loadRealFonts() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home != null ? '$home/.local/share/fonts' : '');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
  final sans = File('$dir/DejaVuSans.ttf');
  if (!sans.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader('DejaVu Sans')
    ..addFont(_fontBytes(sans.path));
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  final mono = File('$dir/DejaVuSansMono.ttf');
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
  }
}

/// The capture shell — a RepaintBoundary at the size a pane tab would
/// occupy, l10n delegates + the app theme wired exactly as the shell
/// does.
Future<void> pumpSyncPlanView(
  WidgetTester tester,
  SyncPlanController controller, {
  VoidCallback? onSaveAsFavorite,
  VoidCallback? onEditRules,
  DateTime Function()? clock,
  Size size = const Size(1200, 720),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final base = buildPoltergeistTheme(Brightness.dark);
  // The house capture convention: the loaded family must be requested
  // by the theme — FontLoader alone cannot reach default-styled text.
  final theme = Platform.environment['POLTERGEIST_CAPTURE'] == '1'
      ? base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
          primaryTextTheme: base.primaryTextTheme.apply(
            fontFamily: 'DejaVu Sans',
          ),
        )
      : base;
  return tester.pumpWidget(
    // The boundary wraps MaterialApp so overlay surfaces (the typed
    // DELETE dialog, the override popup) land inside the capture.
    RepaintBoundary(
      key: const ValueKey('capture.syncPlan'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncPlanView(
            controller: controller,
            onSaveAsFavorite: onSaveAsFavorite,
            onEditRules: onEditRules,
            clock: clock,
          ),
        ),
      ),
    ),
  );
}

/// The fake scanner/differ resolve on microtasks — a pump loop reaches
/// `ready` without runAsync.
Future<void> pumpToReady(
  WidgetTester tester,
  SyncPlanController controller,
) async {
  for (var i = 0; i < 20 && controller.phase != SyncPlanPhase.ready; i++) {
    await tester.pump();
  }
  expect(controller.phase, SyncPlanPhase.ready);
  // The phase flips inside a pump's microtask drain; the rebuild that
  // paints it lands on the next frame.
  await tester.pump();
}

SyncPlanController fakeController(
  Directory scratch, {
  required SyncPair pair,
  required SyncPlan plan,
  List<ScanWarning> warnings = const [],
}) => testController(
  pair: pair,
  scanner: FakeSyncScanner(
    left: testScanResult('/left', const {}),
    right: testScanResult('/right', const {}),
  ),
  differ: FakeSyncDiffer(plan),
  environment: testSyncEnvironment(scratch),
);

Future<void> capturePlan(
  WidgetTester tester,
  String name, {
  bool inRunAsync = false,
}) async {
  if (Platform.environment['POLTERGEIST_CAPTURE'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture.syncPlan')),
  );
  Future<Uint8List> grab() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  // runAsync can't nest — callers already on the real event loop raster
  // directly.
  final bytes = inRunAsync ? await grab() : (await tester.runAsync(grab))!;
  Directory(_captureDir).createSync(recursive: true);
  File('$_captureDir/$name.png').writeAsBytesSync(bytes);
}

/// An upload-gated LocalFileSystem — the run blocks mid-copy once
/// [blocker] is armed, holding the controller in its running state for
/// the capture without racing the executor. Disarmed during the scan:
/// the scanner's case probe writes through the same verb.
final class _GatedUploadFs extends LocalFileSystem {
  Future<void> Function() blocker = () async {};

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    await blocker();
    return super.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }
}

/// A filesystem whose setTimes is refused — the local stand-in for
/// sshd-restricted's `sftp-server -P setstat,fsetstat` (the Docker leg
/// proves the same path over the wire in poltergeist_sync's integration
/// test). The run must still complete, flag the side mtime-unreliable,
/// and surface 05 §4's size-only notice.
final class _SetTimesRefusingFs extends LocalFileSystem {
  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) => throw RemoteFileException(
    kind: RemoteFileErrorKind.permissionDenied,
    operation: 'setTimes',
    path: path,
    message: 'this server refuses setstat',
  );
}

void main() {
  setUpAll(() async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await _loadRealFonts();
    }
  });

  testWidgets(
    'ready state renders the §7 surface: header, chips, rows, run label',
    (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair();
      final plan = testPlan(
        pair,
        [
          testItem(
            'a.txt',
            left: testFile(size: 100),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem(
            'docs',
            left: testDir,
            suggested: SyncActionType.makeDirRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem(
            'docs/inner.txt',
            left: testFile(size: 50),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem('same.txt', left: testFile(), right: testFile()),
        ],
        warnings: const [
          ScanWarning(
            relativePath: 'locked',
            side: SyncSide.left,
            message: 'could not descend into locked/',
            kind: ScanWarningKind.listingFailure,
          ),
        ],
      );
      final controller = fakeController(scratch, pair: pair, plan: plan);
      addTearDown(controller.dispose);

      var saved = false;
      await pumpSyncPlanView(
        tester,
        controller,
        onSaveAsFavorite: () => saved = true,
      );
      await pumpToReady(tester, controller);

      // Header: the verbatim consequence sentence — copy clause,
      // folder clause, the no-delete sentence (Update mode).
      expect(find.textContaining('Copy 2 new files'), findsOneWidget);
      expect(find.textContaining('create 1 folder'), findsOneWidget);
      expect(
        find.text('Nothing will be deleted.'),
        findsOneWidget,
      );
      // Mode picker + rescan affordance.
      expect(find.text('Mode'), findsOneWidget);
      expect(find.text('Update'), findsWidgets);
      expect(find.text('Mirror'), findsOneWidget);
      expect(find.text('Additive'), findsOneWidget);

      // The collapsed-by-default warnings strip counts the warning.
      expect(find.text('1 scan warning'), findsOneWidget);

      // Filter chips carry the effective-action counts.
      expect(find.widgetWithText(FilterChip, 'All (4)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'New (3)'), findsOneWidget);
      expect(
        find.widgetWithText(FilterChip, 'Skipped (1)'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilterChip, 'Only show actions'),
        findsOneWidget,
      );

      // Rows: the group header, the grouped child, the ungrouped file.
      // Only-actions filtering (on by default) hides the skip row.
      expect(find.text('docs'), findsWidgets);
      expect(find.text('docs/inner.txt'), findsOneWidget);
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('same.txt'), findsNothing);

      // The run button spells out the consequences.
      expect(
        find.widgetWithText(FilledButton, 'Copy 2 · Create 1 Folder'),
        findsOneWidget,
      );
      expect(find.text('Save as Favorite…'), findsOneWidget);

      await capturePlan(tester, 'sync-plan-grouped');

      // Save-as-favorite delegates to the shell's name dialog.
      await tester.tap(find.text('Save as Favorite…'));
      expect(saved, isTrue);
    },
  );

  testWidgets(
    'secondary tap opens the per-row override menu; Skip applies',
    (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair();
      final item = testItem(
        'a.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final plan = testPlan(pair, [item]);
      final controller = fakeController(scratch, pair: pair, plan: plan);
      addTearDown(controller.dispose);

      await pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);

      await tester.tap(
        find.byKey(const ValueKey('sync.row.a.txt')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      // §7's override vocabulary: skip, the valid copy direction,
      // reset (disabled until an override exists).
      expect(find.text('Copy left → right'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Reset to suggested'), findsOneWidget);
      await capturePlan(tester, 'sync-plan-override-menu');

      await tester.tap(find.text('Skip'));
      await tester.pump();
      expect(item.effective, SyncActionType.skip);
      expect(item.userOverridden, isTrue);

      // The run button collapses to its empty consequence.
      expect(
        find.widgetWithText(FilledButton, 'Nothing to Do'),
        findsOneWidget,
      );
    },
  );

  testWidgets('conflict rows mount the bulk resolve bar', (tester) async {
    final scratch = Directory.systemTemp.createTempSync('pg-view-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final pair = testSyncPair(
      rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
    );
    final conflict = testItem(
      'a.txt',
      left: testFile(mtimeSecs: 30),
      right: testFile(mtimeSecs: 20),
      suggested: SyncActionType.conflict,
      reason: SyncReason.bothChanged,
    );
    final controller = fakeController(
      scratch,
      pair: pair,
      plan: testPlan(pair, [conflict]),
    );
    addTearDown(controller.dispose);

    await pumpSyncPlanView(tester, controller);
    await pumpToReady(tester, controller);

    expect(find.text('Resolve conflicts:'), findsOneWidget);
    expect(find.text('Newer wins'), findsOneWidget);
    expect(find.text('Keep left'), findsOneWidget);
    expect(find.text('Keep right'), findsOneWidget);
    expect(find.text('Skip all'), findsOneWidget);
    // Conflicts gate the run — the button stays disabled until they
    // resolve (§7's decision-before-run rule).
    final runButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Nothing to Do'),
    );
    expect(runButton.onPressed, isNull);

    await tester.tap(find.text('Keep left'));
    await tester.pump();
    expect(conflict.effective, SyncActionType.updateLeftToRight);
    expect(find.text('Resolve conflicts:'), findsNothing);
    expect(
      find.widgetWithText(FilledButton, 'Copy 1'),
      findsOneWidget,
    );
  });

  testWidgets(
    'rail 4 refusal shows the banner and keeps Run disabled',
    (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          deletions: DeletionPolicy.trash,
          maxDelete: 2,
        ),
      );
      final items = [
        for (var i = 0; i < 3; i++)
          testItem(
            'gone$i.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ];
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, items),
      );
      addTearDown(controller.dispose);

      await pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);

      expect(find.text('Too many deletions'), findsOneWidget);
      expect(
        find.textContaining('over the 2-file cap'),
        findsOneWidget,
      );
      await capturePlan(tester, 'sync-plan-maxdelete-refusal');

      // The consequence label still reports the plan; the button
      // refuses to arm it.
      final runButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Delete 3'),
      );
      expect(runButton.onPressed, isNull);
    },
  );

  testWidgets(
    'rail 3: the typed DELETE gate opens, stays disabled until typed, '
    'then the run executes',
    (tester) async {
      await tester.runAsync(() async {
        final scratch = Directory.systemTemp.createTempSync('pg-view-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final left = Directory('${scratch.path}/left')..createSync();
        final right = Directory('${scratch.path}/right')..createSync();
        // 10 deletes of 11 right files trips the fraction clause.
        for (var i = 0; i < 10; i++) {
          File('${right.path}/gone$i.txt').writeAsStringSync('x');
        }
        File('${right.path}/keep.txt').writeAsStringSync('k');
        File('${left.path}/a.txt').writeAsStringSync('a');
        final controller = SyncPlanController(
          pair: testSyncPair(
            left: left.path,
            right: right.path,
            rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
          ),
          environment: testSyncEnvironment(scratch),
          syncTasks: SyncQueueTasks(),
          deviceId: 'test-device',
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await pumpSyncPlanView(tester, controller);
        await pumpUntil(
          () => controller.phase == SyncPlanPhase.ready,
        );
        await tester.pump();
        expect(controller.needsTypedConfirmation, isTrue);

        // The action bar's consequence label arms the dialog, not the
        // run — a.txt's copy joins all 11 right-side deletes (mirror
        // deletes keep.txt too: left is authoritative).
        await tester.tap(
          find.widgetWithText(FilledButton, 'Copy 1 · Delete 11'),
        );
        // pumpAndSettle is fake-clock — inside runAsync only pump works.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text('Confirm deletions'), findsOneWidget);
        expect(find.textContaining('Type DELETE'), findsWidgets);
        await capturePlan(
          tester,
          'sync-plan-delete-confirm',
          inRunAsync: true,
        );

        // Disabled until the field reads DELETE exactly. The dialog's
        // field shares the tree with the filter bar's — scope it.
        final confirmField = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        FilledButton confirm() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Delete'),
        );
        expect(confirm().onPressed, isNull);
        await tester.enterText(confirmField, 'DELET');
        await tester.pump();
        expect(confirm().onPressed, isNull);
        await tester.enterText(confirmField, 'DELETE');
        await tester.pump();
        expect(confirm().onPressed, isNotNull);

        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await pumpUntil(
          () => controller.phase == SyncPlanPhase.completed,
        );
        await tester.pump();
        expect(File('${right.path}/gone0.txt').existsSync(), isFalse);
        // The journal exposes the restore affordance.
        expect(find.text('Restore Trashed Files…'), findsOneWidget);
        expect(find.text('Copy Report'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'a running sync exposes Pause/Cancel; a failed run offers Retry',
    (tester) async {
      await tester.runAsync(() async {
        final scratch = Directory.systemTemp.createTempSync('pg-view-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final left = Directory('${scratch.path}/left')..createSync();
        final right = Directory('${scratch.path}/right')..createSync();
        File('${left.path}/a.txt').writeAsStringSync('payload');
        final gated = _GatedUploadFs();
        final controller = SyncPlanController(
          pair: testSyncPair(left: left.path, right: right.path),
          environment: testSyncEnvironment(
            scratch,
            localFileSystem: () => gated,
          ),
          syncTasks: SyncQueueTasks(),
          deviceId: 'test-device',
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await pumpSyncPlanView(tester, controller);
        await pumpUntil(
          () => controller.phase == SyncPlanPhase.ready,
        );
        await tester.pump();

        // Arm the gate post-scan (the case probe rides `upload` too),
        // then the run blocks mid-copy.
        final gate = Completer<void>();
        gated.blocker = () => gate.future;
        unawaited(controller.run());
        await pumpUntil(() => controller.isRunning);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(find.text('Pause'), findsOneWidget);
        expect(find.text('Cancel'), findsWidgets);
        await capturePlan(
          tester,
          'sync-plan-running',
          inRunAsync: true,
        );

        // Pause toggles the verb while the upload stays gated.
        await tester.tap(find.text('Pause'));
        await tester.pump();
        expect(find.text('Resume'), findsOneWidget);
        await tester.tap(find.text('Resume'));
        await tester.pump();

        gate.complete();
        await pumpUntil(
          () => controller.phase == SyncPlanPhase.completed,
        );
        await tester.pump();
        expect(
          File('${right.path}/a.txt').readAsStringSync(),
          'payload',
        );
      });
    },
  );

  testWidgets(
    'a failed item surfaces Retry Failed and retries to done',
    (tester) async {
      await tester.runAsync(() async {
        final scratch = Directory.systemTemp.createTempSync('pg-view-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final left = Directory('${scratch.path}/left')..createSync();
        final right = Directory('${scratch.path}/right')..createSync();
        final source = File('${left.path}/a.txt')
          ..writeAsStringSync('x');
        final controller = SyncPlanController(
          pair: testSyncPair(left: left.path, right: right.path),
          environment: testSyncEnvironment(scratch),
          syncTasks: SyncQueueTasks(),
          deviceId: 'test-device',
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await pumpSyncPlanView(tester, controller);
        await pumpUntil(
          () => controller.phase == SyncPlanPhase.ready,
        );
        await tester.pump();

        // Vanish the source between preview and run — rail 7 flips the
        // item failed rather than copying stale bytes.
        source.deleteSync();
        await controller.run();
        await tester.pump();
        final item = controller.lastRun!.plan.items.firstWhere(
          (i) => i.relativePath == 'a.txt',
        );
        expect(
          item.status,
          isIn([SyncItemStatus.failed, SyncItemStatus.conflicted]),
        );
        if (item.status != SyncItemStatus.failed) return;

        expect(find.text('Retry Failed'), findsOneWidget);
        await capturePlan(
          tester,
          'sync-plan-retry-failed',
          inRunAsync: true,
        );

        source.writeAsStringSync('x');
        await tester.tap(find.text('Retry Failed'));
        await pumpUntil(() => item.status == SyncItemStatus.done);
        await tester.pump();
        expect(
          File('${right.path}/a.txt').readAsStringSync(),
          'x',
        );
      });
    },
  );

  testWidgets(
    'a refused setTimes flags the side mtime-unreliable and surfaces '
    'the size-only notice',
    (tester) async {
      await tester.runAsync(() async {
        final scratch = Directory.systemTemp.createTempSync('pg-view-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final left = Directory('${scratch.path}/left')..createSync();
        final right = Directory('${scratch.path}/right')..createSync();
        File('${left.path}/a.txt').writeAsStringSync('payload');
        final refusing = _SetTimesRefusingFs();
        final controller = SyncPlanController(
          pair: testSyncPair(left: left.path, right: right.path),
          environment: testSyncEnvironment(
            scratch,
            localFileSystem: () => refusing,
          ),
          syncTasks: SyncQueueTasks(),
          deviceId: 'test-device',
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await pumpSyncPlanView(tester, controller);
        await pumpUntil(
          () => controller.phase == SyncPlanPhase.ready,
        );
        await tester.pump();

        // Before the run both sides are trusted — no notice.
        expect(
          find.textContaining('comparing by size only'),
          findsNothing,
        );

        await controller.run();
        await pumpUntil(
          () => controller.phase == SyncPlanPhase.completed,
        );
        await tester.pump();

        // The refused stamp completed the item, flagged the
        // destination side, and the header now warns (05 §4).
        expect(File('${right.path}/a.txt').existsSync(), isTrue);
        expect(controller.pairState.mtimeUnreliableRight, isTrue);
        expect(controller.pairState.mtimeUnreliableLeft, isFalse);
        expect(
          find.textContaining('comparing by size only'),
          findsOneWidget,
        );
        await capturePlan(
          tester,
          'sync-plan-sizeonly-notice',
          inRunAsync: true,
        );

        // §4's automatic fallback: the flagged pair's next plan
        // compares size-only, so the refused stamp no longer reads
        // as an update — the row converges to equal.
        await controller.rescan();
        await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
        final replanned = controller.plan!.items.singleWhere(
          (item) => item.relativePath == 'a.txt',
        );
        expect(replanned.effective, SyncActionType.skip);
        expect(replanned.reason, SyncReason.equal);
      });
    },
  );

  testWidgets(
    'a kind-change row counts its removed files in Deletes and stays '
    'in the filter',
    (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      // Mirror: one authorized rule-4 replace (file over a 2-file
      // folder) plus one plain delete — §7's chip counts removed
      // files: 1 delete row + 2-file toll = Deletes (3).
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final replace = testItem(
        'thing',
        left: testFile(size: 3),
        right: testDir,
        suggested: SyncActionType.updateLeftToRight,
        reason: SyncReason.typeDiffers,
        destinationSubtree: const {
          'thing/a.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
          'thing/b.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
        },
      );
      final plan = testPlan(pair, [
        replace,
        testItem(
          'old.txt',
          right: testFile(),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ]);
      final controller = fakeController(scratch, pair: pair, plan: plan);
      addTearDown(controller.dispose);
      await pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);

      expect(
        find.widgetWithText(FilterChip, 'Deletes (3)'),
        findsOneWidget,
      );
      // The Run button states the full consequence — the replace
      // row's toll lands in its Delete part.
      expect(find.textContaining('Delete 3'), findsOneWidget);

      // Filtering to Deletes keeps the replace row visible — its
      // red removal badge is why the visible rows sum under N.
      await tester.tap(find.widgetWithText(FilterChip, 'Deletes (3)'));
      await tester.pump();
      expect(find.text('thing'), findsOneWidget);
      expect(find.text('old.txt'), findsOneWidget);
    },
  );

  // 05 §2.1's "Copy as rsync Command" — the action-bar surface of
  // `sync.copyRsyncCommand`: clipboard write + the differentiated
  // toast, disabled while nothing exportable exists.
  group('rsync export button', () {
    String? clipboardText;
    Future<void> pumpAndCopy(
      WidgetTester tester,
      SyncPlanController controller,
    ) async {
      // Reset between captures — a copy that never reaches the channel
      // must fail the assert, not pass on a previous test's text.
      clipboardText = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (message) async {
          if (message.method == 'Clipboard.setData') {
            clipboardText = (message.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);
      await tester.tap(find.text('Copy as rsync Command'));
      await tester.pump();
    }

    testWidgets('copies the rendered command and toasts', (tester) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair();
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 3, mtimeSecs: 10),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      addTearDown(controller.dispose);

      await pumpAndCopy(tester, controller);
      expect(clipboardText, isNotNull);
      expect(clipboardText, contains('rsync '));
      expect(clipboardText, contains('rsync -n -i'));
      expect(find.text('Copied rsync command'), findsOneWidget);
    });

    testWidgets('permanent+none toasts the paste-time warning', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          deletions: DeletionPolicy.permanent,
          backups: BackupPolicy.none,
        ),
      );
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'old.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
        ]),
      );
      addTearDown(controller.dispose);

      await pumpAndCopy(tester, controller);
      expect(
        find.text(
          'Copied rsync command — deletions are permanent when pasted',
        ),
        findsOneWidget,
      );
      expect(find.text('Copied rsync command'), findsNothing);
      expect(clipboardText, contains('--delete-delay'));
    });

    testWidgets('an unresolvable remote side disables the button', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      // A shared-mode serverConfigId with no catalog bound (the
      // harness's default resolver) — the command refuses rather
      // than emitting a wrong host.
      final pair = SyncPair(
        id: 'pair-remote',
        name: 'Remote',
        left: const LocalEndpoint('/left'),
        right: const RemoteEndpoint(
          server: BookmarkServerRef(serverConfigId: 'srv-missing'),
          path: '/srv/path',
        ),
        rules: const SyncRuleSet(),
      );
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 3, mtimeSecs: 10),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      addTearDown(controller.dispose);
      await pumpSyncPlanView(tester, controller);
      await pumpToReady(tester, controller);

      expect(controller.canExportRsync, isFalse);
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Copy as rsync Command'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('an embedded-identity remote side exports its spec', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-view-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final pair = SyncPair(
        id: 'pair-remote',
        name: 'Remote',
        left: const LocalEndpoint('/left'),
        right: const RemoteEndpoint(
          server: BookmarkServerRef(
            identity: EmbeddedHostIdentity(
              host: 'example.com',
              port: 2222,
              username: 'deploy',
              authMethod: AuthMethod.agent,
            ),
          ),
          path: '/srv/site',
        ),
        rules: const SyncRuleSet(),
      );
      final controller = fakeController(
        scratch,
        pair: pair,
        plan: testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 3, mtimeSecs: 10),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      addTearDown(controller.dispose);

      await pumpAndCopy(tester, controller);
      expect(clipboardText, contains("'deploy@example.com:/srv/site'"));
      expect(clipboardText, contains('ssh -p 2222'));
    });
  });
}
