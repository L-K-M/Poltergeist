import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/pane_controller.dart';

import 'pane_controller_test.dart'
    show FakePaneLanes, FakePaneChannel;

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
}) {
  return RemoteFileEntry(path: '/home/tester/$name', name: name, type: type);
}

void main() {
  /// Binds a local listing inside the fake clock: the fake channel's
  /// futures resolve on microtasks, so a flush settles the open.
  PaneController openBrowsing(
    FakeAsync async,
    FakePaneLanes lanes,
    List<RemoteFileEntry> entries,
  ) {
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = entries;
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    unawaited(controller.openLocalHome());
    async.flushMicrotasks();
    expect(controller.phase, PanePhase.browsing);
    return controller;
  }

  test('printable characters accumulate and prefix-match the first row', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('docs', type: RemoteFileType.directory),
        _entry('readme.md'),
        _entry('report.txt'),
        _entry('zebra.png'),
      ]);

      controller.typeAhead('r');
      expect(controller.typeAheadBuffer, 'r');
      expect(controller.typeAheadActive, isTrue);
      expect(
        controller.entries[controller.cursorIndex!].name,
        'readme.md',
        reason: 'first match wins, not the best match',
      );

      controller.typeAhead('e');
      controller.typeAhead('p');
      expect(controller.typeAheadBuffer, 'rep');
      expect(controller.entries[controller.cursorIndex!].name, 'report.txt');

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('the buffer resets after exactly one second of inactivity', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('readme.md'),
        _entry('report.txt'),
      ]);

      controller.typeAhead('r');
      async.elapse(const Duration(milliseconds: 999));
      expect(controller.typeAheadBuffer, 'r',
          reason: 'the reset is inactivity-gated, not a fixed deadline');
      async.elapse(const Duration(milliseconds: 2));
      expect(controller.typeAheadBuffer, '');
      expect(controller.typeAheadActive, isFalse);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('each keystroke re-arms the one-second reset', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('readme.md'),
        _entry('report.txt'),
      ]);

      controller.typeAhead('r');
      async.elapse(const Duration(milliseconds: 900));
      controller.typeAhead('e');
      async.elapse(const Duration(milliseconds: 900));
      expect(
        controller.typeAheadBuffer,
        're',
        reason: 'a keystroke inside the window keeps the buffer alive',
      );
      async.elapse(const Duration(milliseconds: 200));
      expect(controller.typeAheadBuffer, '');

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('matching is case- and diacritic-insensitive, prefix-only', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('cliche.txt'),
        _entry('Étude.doc'),
        _entry('settings.json'),
      ]);

      // Diacritics fold: 'e' reaches the precomposed É, and a typed
      // accented prefix reaches the plain-ASCII row.
      controller.typeAhead('e');
      expect(controller.entries[controller.cursorIndex!].name, 'Étude.doc');

      controller.clearTypeAhead();
      controller.typeAhead('E');
      expect(controller.entries[controller.cursorIndex!].name, 'Étude.doc',
          reason: 'an uppercase keystroke folds and still matches');

      controller.clearTypeAhead();
      controller.typeAhead('é');
      controller.typeAhead('t');
      expect(controller.entries[controller.cursorIndex!].name, 'Étude.doc',
          reason: 'ét folds to et and still prefixes Étude');

      // Prefix-only: 'tt' does not reach settings.json's infix.
      controller.clearTypeAhead();
      controller.typeAhead('t');
      controller.typeAhead('t');
      expect(
        controller.entries[controller.cursorIndex!].name,
        'Étude.doc',
        reason: 'no match is a no-op — the cursor stays on the last hit',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('no match leaves the cursor and selection untouched', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.setCursorIndex(1);

      controller.typeAhead('z');
      expect(controller.typeAheadBuffer, 'z');
      expect(controller.cursorIndex, 1);
      expect(controller.isRowSelected(1), isTrue);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('flagged names are never matched but stay selectable', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      // The U+FFFD stand-in for an undecodable name (STATUS item 13's
      // caller-side flag until real flag metadata lands).
      final controller = openBrowsing(async, lanes, [
        _entry('apple.txt'),
        _entry('fl\u{FFFD}ag.bin'),
      ]);
      controller.setCursorIndex(0);

      controller.typeAhead('f');
      controller.typeAhead('l');
      expect(
        controller.entries[controller.cursorIndex!].name,
        'apple.txt',
        reason: 'the flagged row is ineligible for by-name matching — '
            'no match keeps the cursor where it was',
      );

      // Selectability is untouched: arrows and clicks still reach it.
      controller.setCursorIndex(1);
      expect(controller.cursorIndex, 1);
      expect(controller.isRowSelected(1), isTrue);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('the hidden-file policy runs before matching', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('.hidden-cache'),
        _entry('visible.txt'),
      ]);

      expect(controller.entries.map((e) => e.name), ['visible.txt'],
          reason: 'dotfiles are filtered at listing accept — they never '
              'reach the matcher');
      controller.typeAhead('h');
      expect(controller.cursorIndex, isNull);
      controller.clearTypeAhead();
      controller.typeAhead('v');
      expect(controller.entries[controller.cursorIndex!].name, 'visible.txt');

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('matching is basename-only — directory paths never match', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      // Entry names carry the basename; the path's parent segments must
      // not be reachable through type-ahead ('home' would hit every row).
      final controller = openBrowsing(async, lanes, [
        _entry('readme.md'),
      ]);

      controller.typeAhead('h');
      controller.typeAhead('o');
      expect(controller.cursorIndex, isNull);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('a listing replacement clears the pending buffer', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('subdir', type: RemoteFileType.directory),
        _entry('readme.md'),
      ];
      channel.listings['/home/tester/subdir'] = [_entry('nested.txt')];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
      unawaited(controller.openLocalHome());
      async.flushMicrotasks();

      controller.typeAhead('r');
      expect(controller.typeAheadActive, isTrue);

      controller.openEntry(controller.entries[0]);
      async.flushMicrotasks();
      expect(
        controller.typeAheadBuffer,
        '',
        reason: 'the accepted listing replaced the rows the buffer '
            'was matched against',
      );

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('clearTypeAhead empties the buffer without touching the cursor', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);

      controller.typeAhead('b');
      expect(controller.entries[controller.cursorIndex!].name, 'beta.txt');

      controller.clearTypeAhead();
      expect(controller.typeAheadBuffer, '');
      expect(controller.entries[controller.cursorIndex!].name, 'beta.txt',
          reason: 'Esc clears the pending buffer, not the jumped cursor');

      // The cleared buffer leaves no pending reset timer.
      expect(async.pendingTimers, isEmpty,
          reason: 'clearTypeAhead cancels the pending reset');
      async.elapse(const Duration(seconds: 2));
      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('a marks-only buffer shows the badge but never jumps', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.setCursorIndex(1);

      // A lone dead-key press delivers a combining mark; it folds to
      // nothing and must not slam the cursor onto the first row.
      controller.typeAhead('\u{301}');
      expect(controller.typeAheadActive, isTrue);
      expect(controller.cursorIndex, 1);

      controller.dispose();
      async.flushMicrotasks();
    });
  });

  test('an empty pane accumulates nothing', () {
    fakeAsync((async) {
      final lanes = FakePaneLanes();
      final controller = openBrowsing(async, lanes, []);

      controller.typeAhead('x');
      expect(controller.typeAheadBuffer, '');
      expect(controller.typeAheadActive, isFalse);

      controller.dispose();
      async.flushMicrotasks();
    });
  });
}
