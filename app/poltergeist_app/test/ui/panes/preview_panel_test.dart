import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/preview_session.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/preview_panel.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/preview_harness.dart';

void main() {
  /// Session-driving awaits must run in a REAL async zone — the cache's
  /// prepare/commit shell out to chmod, which the fake-async zone's
  /// timers can never wait on. `runAsync` returns a real-event-loop
  /// block; `tester.pump` afterwards renders the notified state.
  Future<void> drive(WidgetTester tester, Future<void> Function() body) =>
      tester.runAsync(body);

  Future<void> pumpPanel(
    WidgetTester tester,
    PreviewSession session, {
    void Function(PaneController, RemoteFileEntry)? onOpen,
    void Function(BuildContext, PaneController, RemoteFileEntry)?
    onOpenWith,
    void Function(PaneController, RemoteFileEntry)? onOpenInEditor,
  }) {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: PreviewPanel(
              session: session,
              onOpen: onOpen,
              onOpenWith: onOpenWith,
              onOpenInEditor: onOpenInEditor,
              onClose: session.closePanel,
              onEscape: (event) => session.escape()
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('prompt card offers Download and runs it', (tester) async {
    final h = (await tester.runAsync(PreviewHarness.create))!;
    await drive(tester, () async {
      await h.connectRemote([previewEntry('notes.txt', size: 4)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
    });
    await pumpPanel(tester, h.session);
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.download')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview.close')), findsOneWidget);

    // The tap starts a real chmod subprocess through cache.prepare —
    // it must run inside runAsync where the event loop is real.
    await drive(tester, () async {
      await tester.tap(find.byKey(const ValueKey('preview.download')));
      await untilPhase(h.session, PreviewPhase.producing);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.progress')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('preview.produce.cancel')),
      findsOneWidget,
    );
    expect(h.producer.specs, hasLength(1));
  });

  testWidgets('confirm card answers cancel and download', (tester) async {
    final h = (await tester.runAsync(
      () => PreviewHarness.create(thresholdBytes: 8),
    ))!;
    await drive(tester, () async {
      await h.connectRemote([previewEntry('big.txt', size: 100)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
    });
    await pumpPanel(tester, h.session);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('preview.confirm.cancel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('preview.confirm.download')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('preview.confirm.cancel')));
    await tester.pump();
    expect(h.session.phase, PreviewPhase.prompt);

    // Re-arm the confirm and answer Download — the tap launches a
    // production, so it runs inside the real-async block.
    await drive(tester, () async {
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
    });
    await tester.pump();
    await drive(tester, () async {
      await tester.tap(
        find.byKey(const ValueKey('preview.confirm.download')),
      );
      await untilPhase(h.session, PreviewPhase.producing);
    });
    await tester.pump();
    expect(h.producer.specs, hasLength(1));
  });

  testWidgets('gate card keeps downloading', (tester) async {
    final h = (await tester.runAsync(
      () => PreviewHarness.create(thresholdBytes: 8),
    ))!;
    await drive(tester, () async {
      await h.connectRemote([previewEntry('stream.txt')]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      h.producer.specs.single.gate!
          .wrap(const NullByteSink())
          .add(List.filled(16, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);
    });
    await pumpPanel(tester, h.session);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('preview.gate.cancel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('preview.gate.keep')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('preview.gate.keep')));
    await tester.pump();
    expect(h.session.phase, PreviewPhase.producing);
    expect(h.producer.specs.single.gate!.isAwaitingConfirmation, isFalse);
  });

  testWidgets('rendered text shows the preview.text surface',
      (tester) async {
    final h = (await tester.runAsync(PreviewHarness.create))!;
    await drive(tester, () async {
      await h.connectRemote([previewEntry('a.txt', size: 5)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await h.producer.complete(0, utf8.encode('hello'));
      await untilPhase(h.session, PreviewPhase.rendered);
    });
    await pumpPanel(tester, h.session);
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.text')), findsOneWidget);
  });

  testWidgets('metadata refusal card carries Open/Open With', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => PreviewHarness.create(cacheCapacityBytes: 8),
    ))!;
    await drive(tester, () async {
      await h.connectRemote([previewEntry('huge.txt', size: 4096)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
    });
    var opened = 0;
    var openWith = 0;
    await pumpPanel(
      tester,
      h.session,
      onOpen: (_, _) => opened++,
      onOpenWith: (_, _, _) => openWith++,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.open')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview.openWith')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview.open')));
    expect(opened, 1);
    await tester.tap(find.byKey(const ValueKey('preview.openWith')));
    expect(openWith, 1);
  });

  testWidgets('close button hides the panel', (tester) async {
    final h = (await tester.runAsync(PreviewHarness.create))!;
    await drive(tester, () async {
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
    });
    await pumpPanel(tester, h.session);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('preview.close')));
    expect(h.workspace.previewPanelHidden, isTrue);
  });

  testWidgets('Quick Look overlay shows the producing card', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      ),
    ))!;
    await drive(tester, () async {
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Stack(children: [PreviewQuickLookOverlay(session: h.session)]),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('preview.quickLookCard')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('preview.quickLookCard.cancel')),
      findsOneWidget,
    );
  });

  group('commands', () {
    test('file.preview and view.togglePreview register per D21',
        () async {
      final h = await PreviewHarness.create();
      final commands = buildPaneCommands(
        workspace: h.workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
        preview: h.session,
      );
      final preview = commands.firstWhere(
        (c) => c.id == kFilePreviewCommandId,
      );
      final toggle = commands.firstWhere(
        (c) => c.id == kViewTogglePreviewCommandId,
      );

      // Space — documented on every platform (dispatched by the pane's
      // key tier, never the chord layer, per 02 §8.2).
      expect(
        preview.activators!(TargetPlatform.linux),
        contains(
          const SingleActivator(LogicalKeyboardKey.space),
        ),
      );
      // ⌥⌘P on macOS, Ctrl+Alt+P elsewhere.
      expect(
        toggle.activators!(TargetPlatform.macOS).single,
        const SingleActivator(
          LogicalKeyboardKey.keyP,
          meta: true,
          alt: true,
        ),
      );
      expect(
        toggle.activators!(TargetPlatform.linux).single,
        const SingleActivator(
          LogicalKeyboardKey.keyP,
          control: true,
          alt: true,
        ),
      );
    });

    test('view.togglePreview enables only with a session; file.preview '
        'follows row focus', () async {
      final h = await PreviewHarness.create();
      final withoutSession = buildPaneCommands(
        workspace: h.workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
      );
      expect(
        withoutSession
            .firstWhere((c) => c.id == kViewTogglePreviewCommandId)
            .enabled(),
        isFalse,
      );
      expect(
        withoutSession
            .firstWhere((c) => c.id == kFilePreviewCommandId)
            .enabled(),
        isFalse,
      );

      final withSession = buildPaneCommands(
        workspace: h.workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
        preview: h.session,
      );
      final toggle = withSession.firstWhere(
        (c) => c.id == kViewTogglePreviewCommandId,
      );
      expect(toggle.enabled(), isTrue);

      // No focused row yet — file.preview stays disabled.
      final preview = withSession.firstWhere(
        (c) => c.id == kFilePreviewCommandId,
      );
      expect(preview.enabled(), isFalse);

      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      expect(preview.enabled(), isTrue);
    });

    test('file.preview does not stay live just because the Info tab '
        'shows', () async {
      final h = await PreviewHarness.create(infoTabShown: true);
      final preview = buildPaneCommands(
        workspace: h.workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
        preview: h.session,
      ).firstWhere((c) => c.id == kFilePreviewCommandId);
      expect(h.workspace.previewPanelHidden, isFalse);
      // No focused row and no Quick Look open: nothing for Space to do.
      expect(preview.enabled(), isFalse);
    });

    test('file.preview names the surface Space actually opens', () async {
      final h = await PreviewHarness.create();
      final commands = buildPaneCommands(
        workspace: h.workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
        preview: h.session,
      );
      final preview = commands.firstWhere(
        (c) => c.id == kFilePreviewCommandId,
      );
      final l10n = AppLocalizationsEn();

      // Space opens Quick Look on every desktop (D32: the native panel
      // on macOS, the in-app overlay elsewhere); touch platforms show
      // the Info tab, so the label stays neutral there.
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(preview.label(l10n), 'Quick Look', reason: platform.name);
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(preview.label(l10n), 'Preview');
    });
  });
}
