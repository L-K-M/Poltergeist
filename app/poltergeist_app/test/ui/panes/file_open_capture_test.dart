import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// Real-font captures of the §2.6 file-open surfaces for visual review:
/// the informational notice strip (remote unavailable, Edit deferred,
/// Transfer deferred) and the launcher failure in the pane's inline
/// error overlay. The widget-test default font renders hollow boxes, so
/// the capture loads a real face when the host provides one — set
/// POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. The PNGs
/// land in tasks/run3-task46/ at the repo root, and only when the run
/// is armed: POLTERGEIST_CAPTURE=1 gates every artifact write so an
/// ordinary `flutter test` never dirties the checkout; the UI
/// assertions run regardless.
const _captureDir = '../../tasks/run3-task46';

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
  String parent = '/home/tester',
}) {
  return RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: size,
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

void main() {
  testWidgets('captures the file-open notices and the inline launch '
      'error', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('notes.txt', size: 640),
      _entry('photo-01.png', size: 40240),
      _entry('photo-02.png', size: 38192),
      _entry('report.txt', size: 2048),
      _entry('résumé.pdf', size: 90112),
      _entry('todo.txt', size: 128),
    ];
    lanes.nextLocalChannel = channel;

    final remoteChannel = controller_test.FakePaneChannel('/srv/home');
    remoteChannel.listings['/srv/home'] = [
      _entry('site.conf', size: 320, parent: '/srv/home'),
      _entry('index.html', size: 9216, parent: '/srv/home'),
    ];
    lanes.nextRemoteChannel = remoteChannel;

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
      MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: RepaintBoundary(
                  key: const ValueKey('capture.pane.left'),
                  child: PaneView(
                    controller: left,
                    pane: leftStrip,
                    workspace: workspace,
                    focusNode: leftNode,
                    onSwapFocus: () => rightNode.requestFocus(),
                    onCancelRecovery: () {},
                  ),
                ),
              ),
              Expanded(
                child: RepaintBoundary(
                  key: const ValueKey('capture.pane.right'),
                  child: PaneView(
                    controller: right,
                    pane: rightStrip,
                    workspace: workspace,
                    focusNode: rightNode,
                    onSwapFocus: () => leftNode.requestFocus(),
                    onCancelRecovery: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final leftBoundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.pane.left')),
    );
    final rightBoundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.pane.right')),
    );
    final captureEnabled =
        Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    final outDir = Directory(_captureDir);
    if (captureEnabled) outDir.createSync(recursive: true);

    Future<void> capture(String name, RenderRepaintBoundary boundary) async {
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

    // Remote Open posts the unavailable notice — nothing launches.
    await right.openEntry(right.entries[1]); // index.html
    await tester.pump();
    expect(right.notice, PaneNotice.openRemoteUnavailable);
    expect(remoteChannel.openCalls, isEmpty);
    await capture('notice-remote-unavailable', rightBoundary);

    // Edit in Poltergeist posts the later-milestone notice (06/M7).
    left.doubleClickAction = DoubleClickAction.edit;
    await left.openEntry(left.entries[4]); // report.txt
    await tester.pump();
    expect(left.notice, PaneNotice.editLater);
    await capture('notice-edit-later', leftBoundary);

    // Transfer to other pane posts its own later-milestone notice (M4).
    left.doubleClickAction = DoubleClickAction.transfer;
    await left.openEntry(left.entries[4]);
    await tester.pump();
    expect(left.notice, PaneNotice.transferLater);
    await capture('notice-transfer-later', leftBoundary);

    // A launcher refusal lands in the pane's inline error overlay with
    // its Retry affordance — never a modal dialog.
    left.doubleClickAction = DoubleClickAction.open;
    channel.openFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'open',
      message: 'No application is registered for this file.',
    );
    await left.openEntry(left.entries[4]);
    await tester.pumpAndSettle();
    expect(left.error, isNotNull);
    expect(find.byType(Dialog), findsNothing);
    await capture('open-error-inline', leftBoundary);

    // Retire the remote pane's outstanding notice timer — the binding
    // fails the run on a pending Timer.
    right.dismissNotice();
  });
}
