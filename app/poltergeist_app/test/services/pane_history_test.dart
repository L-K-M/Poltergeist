import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' as base;

/// The per-tab navigation trail (02 §2.1): push/back/forward/up
/// semantics, branch truncation, and the boundary rules. History lives
/// on the per-tab [PaneController] and never persists — per-tab
/// isolation and transience are structural consequences tested at the
/// strip level.
void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Binds a fresh local controller whose channel lists [paths] (plus
  /// its own home) and returns it once the first listing has landed.
  Future<(PaneController, base.FakePaneChannel)> boundPane(
    base.FakePaneLanes lanes,
    List<String> paths,
  ) async {
    final channel = base.FakePaneChannel('/home/tester');
    for (final path in ['/home/tester', ...paths]) {
      channel.listings[path] = [
        RemoteFileEntry(
          path: '$path/file.txt',
          name: 'file.txt',
          type: RemoteFileType.file,
        ),
      ];
    }
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();
    return (controller, channel);
  }

  test('navigations push entries; back/forward walk the index', () async {
    final lanes = base.FakePaneLanes();
    final (controller, channel) = await boundPane(lanes, [
      '/home/tester/a',
      '/home/tester/b',
      '/home/tester/c',
    ]);
    addTearDown(controller.dispose);

    // Each hop settles: a hop superseded before its watch arms never
    // reaches the listing seam, and this test counts the hops that do.
    controller.navigate('/home/tester/a');
    await settle();
    controller.navigate('/home/tester/b');
    await settle();
    expect(controller.location?.path, '/home/tester/b');
    expect(controller.canGoBack, isTrue);
    expect(controller.canGoForward, isFalse);

    controller.goBack();
    expect(controller.location?.path, '/home/tester/a');
    await settle();
    controller.goBack();
    expect(controller.location?.path, '/home/tester');
    await settle();
    expect(controller.canGoBack, isFalse);
    expect(controller.canGoForward, isTrue);

    controller.goForward();
    await settle();
    controller.goForward();
    await settle();
    expect(controller.location?.path, '/home/tester/b');
    expect(controller.canGoForward, isFalse);
    // Traversals reissue through the listing seam — every hop hits the
    // channel, never a cached replay.
    expect(
      channel.listCalls,
      equals([
        '/home/tester',
        '/home/tester/a',
        '/home/tester/b',
        '/home/tester/a',
        '/home/tester',
        '/home/tester/a',
        '/home/tester/b',
      ]),
    );
  });

  test('a new navigation drops forward entries (branch truncation)',
      () async {
    final lanes = base.FakePaneLanes();
    final (controller, channel) = await boundPane(lanes, [
      '/home/tester/a',
      '/home/tester/b',
      '/home/tester/d',
    ]);
    addTearDown(controller.dispose);

    controller.navigate('/home/tester/a');
    controller.navigate('/home/tester/b');
    await settle();
    controller.goBack();
    await settle();
    expect(controller.location?.path, '/home/tester/a');
    expect(controller.canGoForward, isTrue);

    controller.navigate('/home/tester/d');
    await settle();
    expect(controller.location?.path, '/home/tester/d');
    // The /b forward entry is gone — Forward is disabled at the end.
    expect(controller.canGoForward, isFalse);

    controller.goBack();
    await settle();
    // Back lands on /a: the truncated branch is unreachable.
    expect(controller.location?.path, '/home/tester/a');
    expect(controller.canGoBack, isTrue); // /home/tester remains
  });

  test('refresh and same-path navigation record nothing', () async {
    final lanes = base.FakePaneLanes();
    final (controller, _) = await boundPane(lanes, ['/home/tester/a']);
    addTearDown(controller.dispose);

    controller.navigate('/home/tester/a');
    await settle();
    expect(controller.canGoBack, isTrue);

    // Re-listing the SAME location is a refresh, not a hop.
    controller.refresh();
    await settle();
    controller.navigate('/home/tester/a');
    await settle();

    controller.goBack();
    await settle();
    expect(controller.location?.path, '/home/tester');
    expect(controller.canGoBack, isFalse);
  });

  test('go.up records the parent like any navigation', () async {
    final lanes = base.FakePaneLanes();
    final (controller, _) = await boundPane(lanes, ['/home/tester/a']);
    addTearDown(controller.dispose);

    controller.navigate('/home/tester/a');
    await settle();
    controller.goUp();
    await settle();
    expect(controller.location?.path, '/home/tester');
    // The climb is a navigation: Back returns to where the user was.
    controller.goBack();
    await settle();
    expect(controller.location?.path, '/home/tester/a');
  });

  test('a failed navigation stays in the trail; Back returns from it',
      () async {
    final lanes = base.FakePaneLanes();
    final (controller, channel) = await boundPane(lanes, [
      '/home/tester/a',
    ]);
    addTearDown(controller.dispose);

    controller.navigate('/home/tester/a');
    await settle();
    // '/gone' is unscripted — the listing fails and the pane lands on
    // the erred location with its inline error (02 §2.7).
    controller.navigate('/gone');
    await settle();
    expect(controller.error, isNotNull);
    expect(controller.location?.path, '/gone');
    expect(controller.canGoBack, isTrue);

    controller.goBack();
    await settle();
    expect(controller.location?.path, '/home/tester/a');
    expect(controller.error, isNull);

    // Forward re-attempts the failed location — browser semantics.
    expect(controller.canGoForward, isTrue);
    channel.listings['/gone'] = [
      RemoteFileEntry(
        path: '/gone/now.txt',
        name: 'now.txt',
        type: RemoteFileType.file,
      ),
    ];
    controller.goForward();
    await settle();
    expect(controller.location?.path, '/gone');
    expect(controller.error, isNull);
    expect(controller.entries.single.name, 'now.txt');
  });

  test('Esc-cancel rejoins the trail; Forward re-attempts the cancelled '
      'navigation', () async {
    final lanes = base.FakePaneLanes();
    final (controller, channel) = await boundPane(lanes, [
      '/home/tester/a',
      '/home/tester/b',
    ]);
    addTearDown(controller.dispose);

    controller.navigate('/home/tester/a');
    await settle();

    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.navigate('/home/tester/b');
    expect(controller.location?.path, '/home/tester/b');

    // Esc restores the quiescent location AND rejoins its trail entry:
    // the cancelled /b survives as a forward record, not a dead end.
    controller.cancelNavigation();
    expect(controller.location?.path, '/home/tester/a');
    expect(controller.canGoForward, isTrue);
    expect(controller.canGoBack, isTrue);

    hold.complete();
    await settle();

    // The held listing resolving after Esc must not resurrect the
    // cancelled navigation — the pane stays on the quiescent restore.
    expect(controller.location?.path, '/home/tester/a');

    controller.goForward();
    await settle();
    expect(controller.location?.path, '/home/tester/b');
    expect(controller.entries.single.name, 'file.txt');
  });

  test('cancelling a back-traversal rejoins the deeper entry', () async {
    final lanes = base.FakePaneLanes();
    final (controller, channel) = await boundPane(lanes, [
      '/home/tester/a',
      '/home/tester/b',
    ]);
    addTearDown(controller.dispose);

    controller.navigate('/home/tester/a');
    controller.navigate('/home/tester/b');
    await settle();

    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.goBack(); // in-flight toward /a
    controller.cancelNavigation();

    // The restore lands on /b — the index rejoins it, so Back is still
    // armed (toward /a) rather than collapsed onto the cancelled target.
    expect(controller.location?.path, '/home/tester/b');
    expect(controller.canGoBack, isTrue);
    expect(controller.canGoForward, isFalse);

    hold.complete();
    await settle();
    controller.goBack();
    await settle();
    expect(controller.location?.path, '/home/tester/a');
  });

  test('a rebound pane starts a fresh trail', () async {
    final lanes = base.FakePaneLanes();
    final (controller, _) = await boundPane(lanes, ['/home/tester/a']);
    addTearDown(controller.dispose);

    controller.navigate('/home/tester/a');
    await settle();
    expect(controller.canGoBack, isTrue);

    final other = base.FakePaneChannel('/home/other');
    other.listings['/home/other'] = [
      RemoteFileEntry(
        path: '/home/other/x.txt',
        name: 'x.txt',
        type: RemoteFileType.file,
      ),
    ];
    lanes.nextLocalChannel = other;
    await controller.openLocalAt('/home/other');
    await settle();

    expect(controller.location?.path, '/home/other');
    expect(controller.canGoBack, isFalse);
    expect(controller.canGoForward, isFalse);
  });

  test('history is per-tab: sibling tabs keep independent trails and a '
      'reopened ghost starts empty', () async {
    final lanes = base.FakePaneLanes();
    final strip = PaneTabsController(
      paneId: 'pane.left',
      lanes: lanes,
    );
    addTearDown(strip.dispose);

    base.FakePaneChannel channelFor(String home, List<String> paths) {
      final channel = base.FakePaneChannel(home);
      for (final path in [home, ...paths]) {
        channel.listings[path] = [
          RemoteFileEntry(
            path: '$path/f.txt',
            name: 'f.txt',
            type: RemoteFileType.file,
          ),
        ];
      }
      lanes.nextLocalChannel = channel;
      return channel;
    }

    // Tab 1 binds and walks a→b.
    final tab1 = strip.newTab(target: NewTabTarget.launcher);
    final controller1 = tab1.controller;
    channelFor('/home/one', ['/home/one/a', '/home/one/b']);
    await controller1.openLocalAt('/home/one');
    await settle();
    controller1.navigate('/home/one/a');
    controller1.navigate('/home/one/b');
    await settle();

    // Tab 2 binds elsewhere — its trail starts empty.
    final tab2 = strip.newTab(target: NewTabTarget.launcher);
    final controller2 = tab2.controller;
    channelFor('/home/two', ['/home/two/z']);
    await controller2.openLocalAt('/home/two');
    await settle();
    controller2.navigate('/home/two/z');
    await settle();

    expect(controller2.canGoBack, isTrue);
    controller2.goBack();
    await settle();
    expect(controller2.location?.path, '/home/two',
        reason: 'tab 2 walks its own trail, never tab 1\'s');

    // Switching back to tab 1 keeps its trail intact (02 §3's per-tab
    // state carries the history with the tab's controller).
    strip.activateTab(strip.tabs.first);
    expect(strip.activeTab, same(tab1));
    expect(controller1.location?.path, '/home/one/b');
    controller1.goBack();
    await settle();
    expect(controller1.location?.path, '/home/one/a');

    // Transience: a closed tab's trail dies with its controller — the
    // ghost reopen binds a fresh one (02 §3's restore covers the
    // listing lenses, never the trail).
    strip.activateTab(strip.tabs.last);
    expect(strip.activeTab, same(tab2));
    await strip.requestCloseTab(tab2);
    channelFor('/home/two', []);
    final reopenedTab = await strip.reopenClosedTab();
    final reopened = reopenedTab!.controller;
    expect(reopenedTab, isNot(same(tab2)));
    await settle();
    expect(reopened.canGoBack, isFalse);
    expect(reopened.canGoForward, isFalse);
  });

  test('back/forward are inert while disabled or unbound', () async {
    final lanes = base.FakePaneLanes();
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    addTearDown(controller.dispose);

    // Unbound: no channel, no trail — the verbs no-op.
    expect(controller.canGoBack, isFalse);
    expect(controller.canGoForward, isFalse);
    controller.goBack();
    controller.goForward();
    expect(controller.location, isNull);

    final (bound, channel) = await boundPane(lanes, ['/home/tester/a']);
    addTearDown(bound.dispose);
    expect(bound.canGoBack, isFalse);
    bound.goBack();
    await settle();
    expect(bound.location?.path, '/home/tester');
    // No stray listing issued for the disabled traversal.
    expect(channel.listCalls, ['/home/tester']);
  });

  // P4-02: returning to a folder puts the user back where they were —
  // the folder they climbed out of, or the row they left selected —
  // instead of an unselected listing at its top (Finder, ForkLift,
  // Transmit).
  group('returning to a folder re-selects where the user was', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    RemoteFileEntry folder(String path) => RemoteFileEntry(
      path: path,
      name: paneLastSegment(path),
      type: RemoteFileType.directory,
    );

    RemoteFileEntry file(String path) => RemoteFileEntry(
      path: path,
      name: paneLastSegment(path),
      type: RemoteFileType.file,
    );

    /// A pane standing in /home/tester, whose parent lists 80 folders
    /// ahead of it.
    Future<(PaneController, base.FakePaneChannel)> homePane() async {
      final lanes = base.FakePaneLanes();
      final channel = base.FakePaneChannel('/home/tester')
        ..listings['/home'] = [
          for (var i = 0; i < 80; i++)
            folder('/home/a${i.toString().padLeft(2, '0')}'),
          folder('/home/tester'),
        ]
        ..listings['/home/tester'] = [
          folder('/home/tester/docs'),
          folder('/home/tester/src'),
          file('/home/tester/notes.txt'),
        ]
        ..listings['/home/tester/docs'] = [file('/home/tester/docs/a.txt')]
        ..listings['/home/tester/src'] = [
          file('/home/tester/src/main.dart'),
          file('/home/tester/src/util.dart'),
        ];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
      addTearDown(controller.dispose);
      await controller.openLocalHome();
      await settle();
      return (controller, channel);
    }

    String? cursorPath(PaneController controller) {
      final cursor = controller.cursorIndex;
      return cursor == null ? null : controller.entries[cursor].path;
    }

    int indexOf(PaneController controller, String path) =>
        controller.entries.indexWhere((entry) => entry.path == path);

    test('go.up selects the folder it came from', () async {
      final (controller, _) = await homePane();

      controller.goUp();
      await settle();
      expect(controller.location?.path, '/home');
      expect(cursorPath(controller), '/home/tester');
      expect(controller.selectedEntries.map((entry) => entry.path), [
        '/home/tester',
      ]);
    });

    test('Back re-selects the row the user left; Forward the one it came '
        'back from', () async {
      final (controller, _) = await homePane();
      controller.setCursorIndex(indexOf(controller, '/home/tester/src'));
      await controller.openEntry(controller.entries[controller.cursorIndex!]);
      await settle();
      expect(controller.location?.path, '/home/tester/src');
      controller.setCursorIndex(1);

      controller.goBack();
      await settle();
      expect(cursorPath(controller), '/home/tester/src');

      controller.goForward();
      await settle();
      expect(cursorPath(controller), '/home/tester/src/util.dart');
    });

    test('Back remembers the row even when it is not the way back', () async {
      final (controller, _) = await homePane();
      controller.setCursorIndex(indexOf(controller, '/home/tester/notes.txt'));
      controller.navigate('/home/tester/docs');
      await settle();

      controller.goBack();
      await settle();
      expect(cursorPath(controller), '/home/tester/notes.txt');
    });

    test('Back to an ancestor with nothing remembered selects the child '
        'on the way', () async {
      final (controller, _) = await homePane();
      // A typed path: nothing was selected when the user left.
      controller.navigate('/home/tester/docs');
      await settle();

      controller.goBack();
      await settle();
      expect(cursorPath(controller), '/home/tester/docs');
    });

    test('the re-select is spent on the listing it arrived with', () async {
      final (controller, _) = await homePane();
      controller.goUp();
      await settle();
      expect(cursorPath(controller), '/home/tester');

      // The user clears it; a refresh must not bring it back.
      controller.clearSelection();
      controller.refresh();
      await settle();
      expect(controller.cursorIndex, isNull);

      // And a row the user picks survives the next re-list.
      controller.setCursorIndex(3);
      controller.refresh();
      await settle();
      expect(controller.cursorIndex, 3);
    });

    test('a re-list issued while the parent is loading keeps the re-select',
        () async {
      final (controller, channel) = await homePane();
      final held = Completer<void>();
      channel.holdNext = held;
      controller.goUp();
      await settle();
      expect(controller.loading, isTrue);

      // A refresh (or a watch re-list) of the same folder supersedes the
      // held answer before anything was accepted.
      controller.refresh();
      await settle();
      expect(cursorPath(controller), '/home/tester');
      held.complete();
      await settle();
      expect(cursorPath(controller), '/home/tester');
    });

    test('an Esc-cancelled climb leaves no re-select pending',
        () async {
      final (controller, channel) = await homePane();
      controller.navigate('/home/tester/docs');
      await settle();
      final held = Completer<void>();
      channel.holdNext = held;
      controller.goUp();
      await settle();
      expect(controller.location?.path, '/home/tester');

      // Esc before the parent answered: the pane stays in docs.
      controller.cancelNavigation();
      held.complete();
      await settle();
      expect(controller.location?.path, '/home/tester/docs');
      // A leaked re-select would ride the next same-folder re-list; a
      // docs listing holding a row by that path makes one observable.
      channel.listings['/home/tester/docs'] = [
        folder('/home/tester/docs'),
      ];
      controller.refresh();
      await settle();
      expect(controller.cursorIndex, isNull);
    });

    test('touch platforms select nothing the user did not pick', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (controller, _) = await homePane();

      controller.goUp();
      await settle();
      expect(controller.location?.path, '/home');
      expect(controller.cursorIndex, isNull);
    });
  });
}
