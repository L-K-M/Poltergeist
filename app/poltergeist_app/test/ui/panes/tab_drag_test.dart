import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart';

/// PNGs land in tasks/run3-task54/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set); POLTERGEIST_CAPTURE=1 gates every
/// artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task54/captures';

Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  // Honor the list's window into its buffer — a nonzero offset would
  // otherwise smear the font bytes.
  return ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
}

/// Registers a readable face under the names the theme resolves — the
/// widget-test default font renders hollow boxes in captures.
Future<void> _loadRealFonts() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home != null ? '$home/.local/share/fonts' : '');
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  // The drag affordance glyphs are MaterialIcons codepoints: without the
  // icon font they rasterize as tofu boxes. It ships inside the Flutter
  // SDK, so it loads even when the host has no DejaVu faces.
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

/// 02 §3's "drag tabs between panes" at the widget layer: a chip drag
/// carries the tab to the other pane's strip at the hovered insertion
/// point, a drop anywhere else cancels cleanly, and the strip shows the
/// platform-convention insertion indicator while a foreign tab hovers.
void main() {
  const leftPane = ValueKey('rig.pane.left');
  const rightPane = ValueKey('rig.pane.right');
  const dropIndicator = ValueKey('pane.tabDropIndicator');

  late FakePaneLanes lanes;
  late PaneTabsController left;
  late PaneTabsController right;
  late WorkspaceController workspace;
  late FocusNode leftFocus;
  late FocusNode rightFocus;

  setUp(() {
    lanes = FakePaneLanes();
    left = PaneTabsController(
      paneId: PaneTabsController.leftPaneId,
      lanes: lanes,
    );
    right = PaneTabsController(
      paneId: PaneTabsController.rightPaneId,
      lanes: lanes,
    );
    workspace = WorkspaceController(left: left, right: right);
    addTearDown(workspace.dispose);
    leftFocus = FocusNode(debugLabel: 'pane.left.listing');
    rightFocus = FocusNode(debugLabel: 'pane.right.listing');
    addTearDown(leftFocus.dispose);
    addTearDown(rightFocus.dispose);
  });

  Widget pane(Key key, PaneTabsController strip, FocusNode focus) =>
      Expanded(
        child: KeyedSubtree(
          key: key,
          child: PaneTabsView(
            tabs: strip,
            workspace: workspace,
            focusNode: focus,
            onSwapFocus: () {},
            onCancelRecovery: () {},
          ),
        ),
      );

  Future<void> pumpPanes(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Row(
            children: [
              pane(leftPane, left, leftFocus),
              pane(rightPane, right, rightFocus),
            ],
          ),
        ),
      ),
    );
  }

  /// The tab chip inside [paneKey]'s strip — scoped past the PaneView,
  /// which carries the same ValueKey.
  Finder chipIn(Key paneKey, String tabId) => find.descendant(
    of: find.descendant(
      of: find.byKey(paneKey),
      matching: find.byType(SingleChildScrollView),
    ),
    matching: find.byKey(ValueKey(tabId)),
  );

  /// The insertion indicator while a foreign tab hovers [paneKey]'s
  /// strip.
  Finder indicatorIn(Key paneKey) => find.descendant(
    of: find.byKey(paneKey),
    matching: find.byKey(dropIndicator),
  );

  /// Opens [count] launcher tabs on [strip] — unbound tabs keep the
  /// widget flow engine-free.
  List<PaneTab> launcherTabs(PaneTabsController strip, int count) => [
    for (var i = 0; i < count; i++)
      strip.newTab(target: NewTabTarget.launcher),
  ];

  testWidgets('a chip dragged to the other strip lands there whole', (
    tester,
  ) async {
    lanes.nextLocalChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [
        RemoteFileEntry(
          path: '/home/tester/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 10,
        ),
      ];
    final tab = left.newTab(target: NewTabTarget.home);
    launcherTabs(right, 2);
    await pumpPanes(tester);
    await tester.pump();
    await tester.pump();

    final chip = chipIn(leftPane, tab.id);
    expect(chip, findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);

    final target = tester.getCenter(chipIn(rightPane, right.tabs.first.id));
    await tester.drag(chip, target - tester.getCenter(chip));
    await tester.pump();
    await tester.pump();

    expect(right.tabs, contains(tab));
    expect(left.tabs, isEmpty);
    expect(identical(right.activeTab, tab), isTrue);
    // The moved tab's listing renders in the right pane's view.
    expect(
      find.descendant(
        of: find.byKey(rightPane),
        matching: find.text('a.txt'),
      ),
      findsOneWidget,
    );
    // The source pane sits on the launcher, never blank: the Quick
    // Connect form (02 §2.7's launcher content) renders in its view.
    expect(
      find.descendant(
        of: find.byKey(leftPane),
        matching: find.byKey(const ValueKey('quickConnect.field')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the drop index follows the hovered chip half', (
    tester,
  ) async {
    final moved = left.newTab(target: NewTabTarget.launcher);
    final r = launcherTabs(right, 3);
    await pumpPanes(tester);
    await tester.pump();
    await tester.pump();

    // Leading edge of the first chip inserts at index 0.
    var chip = chipIn(leftPane, moved.id);
    var target = tester.getCenter(chipIn(rightPane, r[0].id));
    var gesture = await tester.startGesture(tester.getCenter(chip));
    await tester.pump();
    await gesture.moveTo(Offset(target.dx - 20, target.dy));
    await tester.pump();
    expect(indicatorIn(rightPane), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(right.tabs.first, same(moved));

    // Between chip centers inserts in the middle.
    final second = left.newTab(target: NewTabTarget.launcher);
    await tester.pump();
    await tester.pump();
    chip = chipIn(leftPane, second.id);
    target = tester.getCenter(chipIn(rightPane, r[1].id));
    gesture = await tester.startGesture(tester.getCenter(chip));
    await tester.pump();
    await gesture.moveTo(Offset(target.dx - 20, target.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    // After the first drop the right order is [moved, r0, r1, r2];
    // landing on r1's left half inserts at r1's index — the middle.
    expect(right.tabs[2], same(second));

    // Dropping on the strip past the last chip appends. The active-tab
    // keep-visible scroll pushed r2's right half offscreen, so the
    // append gesture lands on the strip's trailing space — the `+`
    // button's left edge — rather than the clipped chip.
    final third = left.newTab(target: NewTabTarget.launcher);
    await tester.pump();
    await tester.pump();
    chip = chipIn(leftPane, third.id);
    target = tester.getCenter(
      find.byKey(const ValueKey('pane.right.tab.new')),
    );
    gesture = await tester.startGesture(tester.getCenter(chip));
    await tester.pump();
    await gesture.moveTo(Offset(target.dx - 10, target.dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(right.tabs.last, same(third));
    expect(right.tabs, hasLength(6));
  });

  testWidgets('the indicator follows the hover and clears on drop', (
    tester,
  ) async {
    final moved = left.newTab(target: NewTabTarget.launcher);
    final r = launcherTabs(right, 2);
    await pumpPanes(tester);
    await tester.pump();
    await tester.pump();

    final chip = chipIn(leftPane, moved.id);
    final r0 = tester.getCenter(chipIn(rightPane, r[0].id));
    final r1 = tester.getCenter(chipIn(rightPane, r[1].id));
    final gesture = await tester.startGesture(tester.getCenter(chip));
    await tester.pump();
    await gesture.moveTo(Offset(r0.dx - 20, r0.dy));
    await tester.pump();

    final indicator = indicatorIn(rightPane);
    expect(indicator, findsOneWidget);
    final atStart = tester.getRect(indicator);

    // Hovering later in the strip moves the insertion point right.
    await gesture.moveTo(Offset(r1.dx - 20, r1.dy));
    await tester.pump();
    expect(tester.getRect(indicator).left, greaterThan(atStart.left));

    await gesture.up();
    await tester.pump();
    expect(indicatorIn(rightPane), findsNothing);
    expect(indicatorIn(leftPane), findsNothing);
  });

  testWidgets('a drop outside either strip cancels cleanly', (
    tester,
  ) async {
    final tab = left.newTab(target: NewTabTarget.launcher);
    launcherTabs(right, 1);
    await pumpPanes(tester);
    await tester.pump();
    await tester.pump();

    // Drop on the right pane's BODY — below its strip: no DragTarget
    // accepts the tab, so the drag cancels and the tab stays put.
    final chip = chipIn(leftPane, tab.id);
    final rightBody = tester.getCenter(find.byKey(rightPane));
    await tester.drag(chip, rightBody - tester.getCenter(chip));
    await tester.pump();
    await tester.pump();

    expect(left.tabs, contains(tab));
    expect(right.tabs, hasLength(1));
  });

  testWidgets('a drop back on the source strip cancels — no within-strip '
      'reorder this slice', (tester) async {
    final first = left.newTab(target: NewTabTarget.launcher);
    final second = left.newTab(target: NewTabTarget.launcher);
    await pumpPanes(tester);
    await tester.pump();
    await tester.pump();

    // Dragging the first chip toward its own strip's far edge is a
    // refused drop: order and membership stay untouched.
    final chip = chipIn(leftPane, first.id);
    await tester.drag(chip, const Offset(300, 0));
    await tester.pump();
    await tester.pump();

    expect(left.tabs, [first, second]);
  });

  testWidgets('captures the hover indicator and the dropped state', (
    tester,
  ) async {
    // Real faces matter only when artifacts are written; an ordinary
    // suite run skips the file IO entirely.
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadRealFonts);
    }

    final tab = left.newTab(target: NewTabTarget.launcher);
    final r = launcherTabs(right, 3);

    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The boundary wraps the MaterialApp so the overlay-rendered drag
    // avatar is inside the capture, not clipped out at the Scaffold.
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.tabDrag'),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Row(
              children: [
                pane(leftPane, left, leftFocus),
                pane(rightPane, right, rightFocus),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.tabDrag')),
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
          return data!.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          image.dispose();
        }
      }))!;
      outDir.createSync(recursive: true);
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes);
    }

    // Hovering the middle chip's left half: the avatar follows the
    // pointer and the insertion indicator stands before the chip.
    final chip = chipIn(leftPane, tab.id);
    final target = tester.getCenter(chipIn(rightPane, r[1].id));
    final gesture = await tester.startGesture(tester.getCenter(chip));
    await tester.pump();
    await gesture.moveTo(Offset(target.dx - 20, target.dy));
    await tester.pump();
    expect(indicatorIn(rightPane), findsOneWidget);
    await capture('tab-drag-hover');

    // The drop commits: the moved chip sits mid-strip on the right and
    // the source pane stands on its launcher.
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(right.tabs[1], same(tab));
    await capture('tab-drag-dropped');
  });
}
