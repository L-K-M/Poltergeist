import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
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
}
