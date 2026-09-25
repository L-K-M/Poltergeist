import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/folder_size.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_permissions.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/info_panel.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// Real-font captures of the Get Info inspector (02 §2.6) for visual
/// review — over a local pane and over a remote pane, plus the
/// folder-size states. The widget-test default font renders hollow
/// boxes, so the capture loads a real face when the host provides one —
/// set POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. The
/// PNGs land in tasks/run3-task59/ at the repo root, and only when the
/// run is armed: POLTERGEIST_CAPTURE=1 gates every artifact write so an
/// ordinary `flutter test` never dirties the checkout; the UI
/// assertions run regardless. POLTERGEIST_CAPTURE_DIR overrides the
/// output root — the default only resolves at the repo root when the
/// test is launched from the app package directory.
final _captureDir = Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task59';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

/// Registers a readable face under the names the theme resolves: the
/// default family name for body text plus the mono fallback chain the
/// row metrics style reaches for.
Future<void> _loadRealFonts() async {
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '${Platform.environment['HOME']}/.local/share/fonts';
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  if (!sans.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader('DejaVu Sans')
    ..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
    // The widget-test resolver does not walk fontFamilyFallback to a
    // dynamically loaded family, so register the face under the theme's
    // primary mono name too — otherwise editor text rasterizes as tofu.
    final primaryMono = FontLoader('JetBrains Mono')
      ..addFont(_fontBytes(mono.path));
    await primaryMono.load();
  }
  // Kind glyphs are MaterialIcons codepoints: without the icon font they
  // rasterize as tofu boxes. It ships inside the Flutter SDK.
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
}

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  int? uid,
  int? gid,
  int? mode,
  DateTime? modified,
  DateTime? accessed,
  String root = '/home/tester',
}) {
  return RemoteFileEntry(
    path: '$root/$name',
    name: name,
    type: type,
    size: size,
    uid: uid,
    gid: gid,
    mode: mode,
    accessedAt: accessed,
    modifiedAt: modified,
  );
}

Bookmark _remoteBookmark() {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: 'srv-1',
    kind: BookmarkKind.remotePath,
    label: 'web.example.com',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'tester',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/home',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

DateTime _fixedClock() => DateTime(2026, 9, 15, 10);

void main() {
  testWidgets('captures the Get Info inspector over local and remote '
      'panes', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final lanes = controller_test.FakePaneLanes();
    final local = controller_test.FakePaneChannel('/home/tester');
    local.listings['/home/tester'] = [
      _entry(
        'docs',
        type: RemoteFileType.directory,
        mode: 0x41ED,
        modified: DateTime(2026, 9, 10, 14, 32),
        accessed: DateTime(2026, 9, 14, 18, 40),
      ),
      _entry(
        'notes.txt',
        size: 640,
        mode: 0x81A4,
        modified: DateTime(2026, 9, 11, 9, 5),
      ),
      _entry('photo-01.png', size: 40240, mode: 0x81A4),
      _entry('report.txt', size: 2048, mode: 0x81A4),
      _entry('résumé.pdf', size: 90112, mode: 0x81A4),
      _entry('todo.txt', size: 128, mode: 0x81A4),
    ];
    local.listings['/home/tester/docs'] = [
      _entry('draft.md', size: 1200, root: '/home/tester/docs'),
      _entry('images', type: RemoteFileType.directory,
          root: '/home/tester/docs'),
    ];
    local.listings['/home/tester/docs/images'] = [
      _entry('hero.png', size: 80240, root: '/home/tester/docs/images'),
      _entry('thumb.png', size: 9120, root: '/home/tester/docs/images'),
    ];
    lanes.nextLocalChannel = local;

    final remote = controller_test.FakePaneChannel('/srv/home');
    remote.listings['/srv/home'] = [
      _entry(
        'deploy.sh',
        size: 512,
        uid: 0,
        gid: 0,
        mode: 0x81ED,
        modified: DateTime(2026, 9, 10, 8, 15),
        accessed: DateTime(2026, 9, 15, 9, 59),
        root: '/srv/home',
      ),
      _entry(
        'logs',
        type: RemoteFileType.directory,
        uid: 33,
        gid: 33,
        mode: 0x41C0,
        modified: DateTime(2026, 9, 12, 22, 1),
        root: '/srv/home',
      ),
      _entry(
        'public',
        type: RemoteFileType.directory,
        uid: 33,
        gid: 33,
        mode: 0x41ED,
        modified: DateTime(2026, 9, 8),
        root: '/srv/home',
      ),
    ];
    remote.listings['/srv/home/logs'] = [
      _entry('access.log', size: 240512, root: '/srv/home/logs'),
      _entry('error.log', size: 1122, root: '/srv/home/logs'),
    ];
    lanes.nextRemoteChannel = remote;

    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);
    final leftNode = FocusNode();
    final rightNode = FocusNode();
    addTearDown(leftNode.dispose);
    addTearDown(rightNode.dispose);

    await left.openLocalHome();
    await right.connectRemote(_remoteBookmark());

    tester.view.physicalSize = const Size(1400, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme:
          base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
    );
    await tester.pumpWidget(
      // The shell-level boundary wraps the MaterialApp so a capture can
      // include the navigator overlay — the enclosed-apply dialog rides
      // a route above the Scaffold.
      RepaintBoundary(
        key: const ValueKey('capture.shell'),
        child: MaterialApp(
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: RepaintBoundary(
                    key: const ValueKey('capture.paneLeft'),
                    child: PaneView(
                      controller: left,
                      pane: leftStrip,
                      workspace: workspace,
                      focusNode: leftNode,
                      onSwapFocus: () => rightNode.requestFocus(),
                      onCancelRecovery: () {},
                      clock: _fixedClock,
                    ),
                  ),
                ),
                Expanded(
                  child: RepaintBoundary(
                    key: const ValueKey('capture.paneRight'),
                    child: PaneView(
                      controller: right,
                      pane: rightStrip,
                      workspace: workspace,
                      focusNode: rightNode,
                      onSwapFocus: () => leftNode.requestFocus(),
                      onCancelRecovery: () {},
                      clock: _fixedClock,
                    ),
                  ),
                ),
                // D32's inspector column: the Info panel follows the
                // active pane's tab, as InspectorView mounts it.
                SizedBox(
                  width: 280,
                  child: RepaintBoundary(
                    key: const ValueKey('capture.info'),
                    child: ColoredBox(
                      color: theme
                          .extension<PoltergeistChrome>()!
                          .inspectorBackground,
                      child: ListenableBuilder(
                        listenable: workspace,
                        builder: (context, _) {
                          final controller = workspace.activeTabController;
                          if (controller == null) {
                            return const SizedBox.shrink();
                          }
                          return ListenableBuilder(
                            listenable: controller,
                            builder: (context, _) => SingleChildScrollView(
                              padding: const EdgeInsetsDirectional.fromSTEB(
                                14,
                                12,
                                12,
                                16,
                              ),
                              child: InfoPanel(
                                controller: controller,
                                clock: _fixedClock,
                                onEscape: (_) => KeyEventResult.ignored,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    leftNode.requestFocus();
    await tester.pump();

    final shellBoundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.shell')),
    );
    RenderRepaintBoundary infoBoundary() =>
        tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture.info')),
        );
    final captureEnabled =
        Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    final outDir = Directory(_captureDir);
    if (captureEnabled) outDir.createSync(recursive: true);

    Future<void> capture(
      RenderRepaintBoundary boundary,
      String name,
    ) async {
      if (!captureEnabled) return;
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
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes);
    }

    // The local pane's inspector on a file: full metadata rendered
    // plus the D28 permissions editor (octal field + rwx grid).
    left.setCursorIndex(3); // report.txt
    await tester.pumpAndSettle();
    await capture(infoBoundary(), 'info-local-file');

    // The editor mid-draft: an edited octal value the listing hasn't
    // applied yet — the grid, Apply, and the enclosed affordance.
    left.setCursorIndex(0); // docs
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('infoPanel.octalField')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('infoPanel.octalField')),
      '0700',
    );
    // pumpAndSettle would hang on the focused field's cursor blink, so
    // drop focus and then let every animation finish.
    leftNode.requestFocus();
    await tester.pumpAndSettle();
    // The octal edit must have re-driven the whole grid: owner bits
    // set, group and others cleared (0755 → 0700).
    for (final cell in const [
      ('owner', 'read', true),
      ('owner', 'write', true),
      ('owner', 'execute', true),
      ('group', 'read', false),
      ('group', 'write', false),
      ('group', 'execute', false),
      ('others', 'read', false),
      ('others', 'write', false),
      ('others', 'execute', false),
    ]) {
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(
                ValueKey('infoPanel.permCell.${cell.$1}.${cell.$2}'),
              ),
            )
            .value,
        cell.$3,
        reason: 'permCell.${cell.$1}.${cell.$2}',
      );
    }
    await capture(infoBoundary(), 'info-local-permissions-draft');

    // The recursive apply's real confirmation dialog — counted copy —
    // over the shell it guards. The dialog rides the root navigator,
    // so the capture uses a shell-level boundary.
    await tester.ensureVisible(
      find.byKey(const ValueKey('infoPanel.applyEnclosed')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('infoPanel.applyEnclosed')));
    await tester.pumpAndSettle();
    expect(left.enclosedApply?.stage, EnclosedApplyStage.confirming);
    await capture(shellBoundary, 'info-enclosed-confirm');
    await tester.tap(find.byKey(const ValueKey('infoPanel.enclosedConfirm')));
    await tester.pumpAndSettle();
    // The walk settles on the fake channel — the panel's terminal
    // tally is the post-apply render.
    expect(left.enclosedApply?.stage, EnclosedApplyStage.done);
    await tester.pump();
    await capture(infoBoundary(), 'info-local-permissions-enclosed-done');

    // The folder target's on-demand measure: Calculate, then the
    // settled total. The panel still sits where the enclosed-apply
    // capture left it scrolled — ensureVisible before the tap so the
    // button is on-screen under any font metrics.
    left.setCursorIndex(0); // docs
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('infoPanel.calculateSize')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('infoPanel.calculateSize')));
    await tester.pumpAndSettle();
    // The capture must show the SETTLED total, never a mid-walk
    // progress line that survived a regression.
    expect(left.folderSizeInFlight, isFalse);
    expect(left.folderSize?.status, FolderSizeStatus.done);
    await capture(infoBoundary(), 'info-local-folder-size');

    // The remote pane's inspector on a file: server-side uid/gid/mode
    // shown. The sorted listing puts directories first — deploy.sh is
    // the last row.
    workspace.setActivePane(rightStrip);
    right.setCursorIndex(2); // deploy.sh
    await tester.pumpAndSettle();
    await capture(infoBoundary(), 'info-remote-file');

    // A remote folder mid-inspection — the Calculate affordance.
    // pumpAndSettle so the retarget's checkbox transitions finish.
    right.setCursorIndex(0); // logs
    await tester.pumpAndSettle();
    await capture(infoBoundary(), 'info-remote-folder');
  });
}
