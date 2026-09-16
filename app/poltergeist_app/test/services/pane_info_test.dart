import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/folder_size.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_pane_channel.dart';
import '../support/test_panes.dart';
import 'pane_controller_test.dart' show FakePaneLanes;

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) {
  return RemoteFileEntry(
    path: '/home/tester/$name',
    name: name,
    type: type,
    size: size,
  );
}

/// Binds a controller to a scripted local channel listing [entries].
Future<(PaneController, FakePaneChannel)> _browsedPane(
  List<RemoteFileEntry> entries,
) async {
  final lanes = FakePaneLanes();
  final channel = FakePaneChannel('/home/tester');
  channel.listings['/home/tester'] = entries;
  lanes.nextLocalChannel = channel;
  final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
  await controller.openLocalHome();
  await Future<void>.delayed(Duration.zero);
  return (controller, channel);
}

void main() {
  group('infoTarget (02 §2.6)', () {
    test('is null with no selection and follows the cursor row', () async {
      final (controller, _) = await _browsedPane([
        _entry('a.txt'),
        _entry('b.txt'),
      ]);
      addTearDown(controller.dispose);

      expect(controller.infoTarget, isNull);
      controller.setCursorIndex(1);
      expect(controller.infoTarget?.name, 'b.txt');
      controller.setCursorIndex(0);
      expect(controller.infoTarget?.name, 'a.txt');
    });

    test('falls back to the first selected row in listing order when '
        'no cursor is set', () async {
      final (controller, _) = await _browsedPane([
        _entry('a.txt'),
        _entry('b.txt'),
        _entry('c.txt'),
      ]);
      addTearDown(controller.dispose);

      // selectAll with no cursor leaves every row selected and the
      // cursor unset — the target is the first selected row.
      controller.selectAll();
      expect(controller.cursorIndex, isNull);
      expect(controller.infoTarget?.name, 'a.txt');
    });

    test('a pruned selection moves the target with it', () async {
      final (controller, channel) = await _browsedPane([
        _entry('a.txt'),
        _entry('b.txt'),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);
      controller.setCursorIndex(1, update: SelectionUpdate.range);
      expect(controller.infoTarget?.name, 'b.txt');

      // The refreshed listing dropped the cursor's row — the cursor is
      // pruned and the target falls back to the surviving selected row,
      // never pointing at a stale row.
      channel.listings['/home/tester'] = [_entry('a.txt')];
      controller.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(controller.infoTarget?.name, 'a.txt');

      // Pruning the last selected row empties the target outright.
      channel.listings['/home/tester'] = [_entry('c.txt')];
      controller.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(controller.infoTarget, isNull);
    });
  });

  group('folder-size session (02 §2.6)', () {
    test('is inert for a file target and for no target', () async {
      final (controller, channel) = await _browsedPane([
        _entry('a.txt', size: 4),
      ]);
      addTearDown(controller.dispose);

      controller.startFolderSize();
      expect(controller.folderSize, isNull);

      controller.setCursorIndex(0);
      controller.startFolderSize();
      expect(controller.folderSize, isNull);
      expect(channel.listCalls, ['/home/tester']);
    });

    test('measures the folder target, publishing progress then the '
        'settled total', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        RemoteFileEntry(
          path: '/home/tester/docs/inner.txt',
          name: 'inner.txt',
          type: RemoteFileType.file,
          size: 12,
        ),
      ];

      controller.setCursorIndex(0);
      controller.startFolderSize();
      expect(controller.folderSizeInFlight, isTrue);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final settled = controller.folderSize;
      expect(settled?.status, FolderSizeStatus.done);
      expect(settled?.targetPath, '/home/tester/docs');
      expect(settled?.bytes, 12);
      expect(settled?.entries, 1);
      expect(controller.folderSizeInFlight, isFalse);
      expect(
        channel.listCalls,
        contains('/home/tester/docs'),
      );
    });

    test('cancel clears the session so the panel offers Calculate again',
        () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory),
      ]);
      addTearDown(controller.dispose);
      // Hold the walk's first listing so the cancel lands mid-flight.
      final held = Completer<void>();
      channel.holdNext = held;
      channel.listings['/home/tester/docs'] = const [];

      controller.setCursorIndex(0);
      controller.startFolderSize();
      expect(controller.folderSizeInFlight, isTrue);

      controller.cancelFolderSize();
      expect(controller.folderSize, isNull);
      expect(controller.folderSizeInFlight, isFalse);

      // Release the held answer — a real late result, not a vacuous
      // settle — and give it a nonzero total so a resurrected session
      // would be observable.
      channel.listings['/home/tester/docs'] = [
        RemoteFileEntry(
          path: '/home/tester/docs/late.txt',
          name: 'late.txt',
          type: RemoteFileType.file,
          size: 9,
        ),
      ];
      held.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.folderSize, isNull);
    });

    test('a location-changing navigation ends the walk at issue time',
        () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory),
        _entry('other', type: RemoteFileType.directory),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = const [];
      channel.listings['/home/tester/other'] = const [];

      controller.setCursorIndex(0);
      controller.startFolderSize();
      expect(controller.folderSizeInFlight, isTrue);

      // Navigate away mid-walk: the session dies with the location that
      // spawned it.
      controller.setCursorIndex(1);
      unawaited(controller.openEntry(controller.entries[1]));
      expect(controller.folderSizeInFlight, isFalse);
      expect(controller.folderSize, isNull);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.folderSize, isNull);
    });

    test('a restart retires the previous walk — the stale result drops',
        () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        RemoteFileEntry(
          path: '/home/tester/docs/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 7,
        ),
      ];
      controller.setCursorIndex(0);

      // First walk parks on a held listing; the restart supersedes it.
      final held = Completer<void>();
      channel.holdNext = held;
      controller.startFolderSize();
      final first = controller.folderSize;
      expect(first?.status, FolderSizeStatus.running);

      controller.startFolderSize();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final settled = controller.folderSize;
      expect(settled?.status, FolderSizeStatus.done);
      expect(settled?.bytes, 7);

      // Release the superseded walk's held listing with a DIFFERENT
      // total — the channel reads listings after the hold, so the late
      // answer is observably stale (99 B, not the fresh walk's 7 B).
      channel.listings['/home/tester/docs'] = [
        RemoteFileEntry(
          path: '/home/tester/docs/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 99,
        ),
      ];
      held.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.folderSize?.bytes, 7,
          reason: 'the superseded walk\'s late result must be dropped');
    });
  });

  group('strip panel state (02 §2.6)', () {
    test('toggleInfoPanel opens and closes; the flag reports false '
        'with no active tab', () async {
      final (controller, _) = await _browsedPane([_entry('a.txt')]);
      final strip = testPaneStrip(controller);
      addTearDown(controller.dispose);

      expect(strip.infoPanelOpen, isFalse);
      strip.toggleInfoPanel();
      expect(strip.infoPanelOpen, isTrue);
      strip.toggleInfoPanel();
      expect(strip.infoPanelOpen, isFalse);

      // An empty strip reports closed regardless of the latch.
      strip.toggleInfoPanel();
      expect(strip.infoPanelOpen, isTrue);
      await strip.requestCloseTab(strip.tabs.first);
      expect(strip.infoPanelOpen, isFalse);
    });

    test('closing the panel cancels every tab\'s in-flight walk',
        () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory),
      ]);
      final strip = testPaneStrip(controller);
      addTearDown(controller.dispose);
      channel.holdNext = Completer<void>();
      channel.listings['/home/tester/docs'] = const [];

      controller.setCursorIndex(0);
      strip.toggleInfoPanel();
      controller.startFolderSize();
      expect(controller.folderSizeInFlight, isTrue);

      strip.closeInfoPanel();
      expect(strip.infoPanelOpen, isFalse);
      expect(controller.folderSizeInFlight, isFalse);
    });

    test('the tab close guard fires while a walk is in flight', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory),
      ]);
      var asks = 0;
      final strip = testPaneStrip(
        controller,
        confirmClose: (tab, triggers) async {
          asks++;
          return triggers.contains(TabCloseTrigger.folderSize);
        },
      );
      addTearDown(controller.dispose);
      channel.holdNext = Completer<void>();
      channel.listings['/home/tester/docs'] = const [];

      controller.setCursorIndex(0);
      controller.startFolderSize();

      // Closing the tab mid-walk asks; confirming lands the close and
      // the walk dies with its controller.
      final outcome = await strip.requestCloseTab(strip.tabs.first);
      expect(asks, 1);
      expect(outcome, TabCloseOutcome.closed);
      expect(controller.folderSizeInFlight, isFalse);
    });
  });
}
