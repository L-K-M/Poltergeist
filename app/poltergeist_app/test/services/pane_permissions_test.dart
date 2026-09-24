import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_permissions.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_pane_channel.dart';
import '../support/test_panes.dart';
import 'pane_controller_test.dart' show FakePaneLanes;

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  int? mode,
  String root = '/home/tester',
}) {
  return RemoteFileEntry(
    path: '$root/$name',
    name: name,
    type: type,
    size: size,
    mode: mode,
  );
}

/// Binds a controller to a scripted local channel listing [entries].
Future<(PaneController, FakePaneChannel)> _browsedPane(
  List<RemoteFileEntry> entries, {
  void Function(Object, StackTrace)? onError,
}) async {
  final lanes = FakePaneLanes();
  final channel = FakePaneChannel('/home/tester');
  channel.listings['/home/tester'] = entries;
  lanes.nextLocalChannel = channel;
  final controller = PaneController(
    paneTabId: 'pane.left',
    lanes: lanes,
    onError: onError,
  );
  await controller.openLocalHome();
  await _settle();
  return (controller, channel);
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Puts the cursor on the row named [name] — the listing's sort order
/// (directories first, then name) is not the fixture's write order.
void _cursorTo(PaneController controller, String name) {
  final index = controller.entries.indexWhere((e) => e.name == name);
  expect(index, isNonNegative, reason: 'fixture row missing: $name');
  controller.setCursorIndex(index);
}

void main() {
  group('octal parse/format (D28)', () {
    test('parses exactly four octal digits, special bits included', () {
      expect(parsePermissionsOctal('0000'), 0);
      expect(parsePermissionsOctal('0644'), 0x1A4);
      expect(parsePermissionsOctal('0755'), 0x1ED);
      expect(parsePermissionsOctal('4755'), 0x9ED); // setuid survives
      expect(parsePermissionsOctal('7777'), 0xFFF);
    });

    test('rejects anything that is not four octal digits', () {
      for (final text in [
        '',
        '755',
        '07555',
        '8888',
        'abcd',
        '-644',
        ' 644',
        '064 ',
      ]) {
        expect(parsePermissionsOctal(text), isNull, reason: '"$text"');
      }
    });

    test('octalTextFor spells four digits and masks the file-type bits',
        () {
      expect(PermissionsEditSession.octalTextFor(0x1ED), '0755');
      expect(PermissionsEditSession.octalTextFor(0x81A4), '0644');
      expect(PermissionsEditSession.octalTextFor(0x9ED), '4755');
      expect(PermissionsEditSession.octalTextFor(0), '0000');
    });

    test('nameIsFlagged keys on U+FFFD only', () {
      expect(nameIsFlagged('a\uFFFDb.txt'), isTrue);
      expect(nameIsFlagged('notes.txt'), isFalse);
      expect(nameIsFlagged(''), isFalse);
    });
  });

  group('countEnclosedApplyItems (D28)', () {
    test('counts changeable items; flagged names and links bucket '
        'separately', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('a.txt', root: '/home/tester/docs'),
          _entry('bad\uFFFDname', root: '/home/tester/docs'),
          _entry(
            'link',
            type: RemoteFileType.symbolicLink,
            root: '/home/tester/docs',
          ),
          _entry(
            'sub',
            type: RemoteFileType.directory,
            root: '/home/tester/docs',
          ),
        ]
        ..listings['/home/tester/docs/sub'] = [
          _entry('deep.txt', root: '/home/tester/docs/sub'),
        ];

      final count = await countEnclosedApplyItems(
        channel,
        '/home/tester/docs',
        cancellation: RemoteTransferCancellation(),
      );
      // a.txt + sub + deep.txt — the flagged name and the link are
      // excluded from the changeable count.
      expect(count.items, 3);
      expect(count.flagged, 1);
      expect(count.links, 1);
      expect(count.clean, isTrue);
      expect(count.cancelled, isFalse);
    });

    test('a nested listing refusal keeps counting and marks the pass '
        'incomplete', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('a.txt', root: '/home/tester/docs'),
          _entry(
            'locked',
            type: RemoteFileType.directory,
            root: '/home/tester/docs',
          ),
          _entry('b.txt', root: '/home/tester/docs'),
        ];
      // 'locked' has no scripted listing — the fake answers the typed
      // notFound refusal.

      final count = await countEnclosedApplyItems(
        channel,
        '/home/tester/docs',
        cancellation: RemoteTransferCancellation(),
      );
      expect(count.items, 3); // a.txt + locked + b.txt
      expect(count.clean, isFalse);
    });

    test('the root listing\'s refusal propagates typed', () async {
      final channel = FakePaneChannel('/home/tester');
      await expectLater(
        countEnclosedApplyItems(
          channel,
          '/home/tester/gone',
          cancellation: RemoteTransferCancellation(),
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.notFound,
          ),
        ),
      );
    });

    test('cancellation answers the cancelled snapshot', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('a.txt', root: '/home/tester/docs'),
        ];
      final cancellation = RemoteTransferCancellation()..cancel();
      final count = await countEnclosedApplyItems(
        channel,
        '/home/tester/docs',
        cancellation: cancellation,
      );
      expect(count.cancelled, isTrue);
    });
  });

  group('applyModeToEnclosed (D28)', () {
    test('writes every changeable entry and chmods directories '
        'post-order — children before the target', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('a.txt', root: '/home/tester/docs'),
          _entry(
            'sub',
            type: RemoteFileType.directory,
            root: '/home/tester/docs',
          ),
        ]
        ..listings['/home/tester/docs/sub'] = [
          _entry('deep.txt', root: '/home/tester/docs/sub'),
        ];

      final result = await applyModeToEnclosed(
        channel,
        '/home/tester/docs',
        targetName: 'docs',
        mode: 0x1C0, // 0700
        cancellation: RemoteTransferCancellation(),
      );

      expect(result.stage, EnclosedApplyStage.done);
      expect(result.applied, 4);
      // Every write carries the exact mode; files write during the
      // scan and the post-order pass lands the sub directory before
      // the target itself.
      expect(channel.permissionsCalls, [
        ('/home/tester/docs/a.txt', 0x1C0),
        ('/home/tester/docs/sub/deep.txt', 0x1C0),
        ('/home/tester/docs/sub', 0x1C0),
        ('/home/tester/docs', 0x1C0),
      ]);
    });

    test('skips flagged names and symbolic links without a wire call',
        () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('bad\uFFFDname', root: '/home/tester/docs'),
          _entry(
            'link',
            type: RemoteFileType.symbolicLink,
            root: '/home/tester/docs',
          ),
          _entry('ok.txt', root: '/home/tester/docs'),
        ];

      final result = await applyModeToEnclosed(
        channel,
        '/home/tester/docs',
        targetName: 'docs',
        mode: 0x1A4,
        cancellation: RemoteTransferCancellation(),
      );

      expect(result.stage, EnclosedApplyStage.done);
      expect(result.applied, 2); // ok.txt + the target directory
      expect(result.skippedUndecodable, 1);
      expect(result.linksSkipped, 1);
      expect(
        channel.permissionsCalls,
        [('/home/tester/docs/ok.txt', 0x1A4), ('/home/tester/docs', 0x1A4)],
      );
    });

    test('a nested listing refusal counts unreadable and continues; a '
        'chmod refusal counts failed and continues', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('a.txt', root: '/home/tester/docs'),
          _entry(
            'locked',
            type: RemoteFileType.directory,
            root: '/home/tester/docs',
          ),
          _entry('denied.txt', root: '/home/tester/docs'),
          _entry('b.txt', root: '/home/tester/docs'),
        ]
        ..permissionsFailures['/home/tester/docs/denied.txt'] =
            const RemoteFileException(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'setMode',
          message: 'denied',
        );

      final result = await applyModeToEnclosed(
        channel,
        '/home/tester/docs',
        targetName: 'docs',
        mode: 0x1A4,
        cancellation: RemoteTransferCancellation(),
      );

      expect(result.stage, EnclosedApplyStage.done);
      expect(result.unreadable, 1); // locked's listing refused
      expect(result.failed, 1); // denied.txt's chmod refused
      // a.txt + b.txt + locked + the target itself.
      expect(result.applied, 4);
    });

    test('the target\'s own chmod refusal ends the run failed', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('a.txt', root: '/home/tester/docs'),
        ]
        ..permissionsFailures['/home/tester/docs'] =
            const RemoteFileException(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'setMode',
          message: 'denied',
        );

      final result = await applyModeToEnclosed(
        channel,
        '/home/tester/docs',
        targetName: 'docs',
        mode: 0x1A4,
        cancellation: RemoteTransferCancellation(),
      );

      expect(result.stage, EnclosedApplyStage.failed);
      expect(result.error, isA<RemoteFileException>());
    });

    test('cancellation returns the cancelled stage with the partial '
        'tally intact', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('a.txt', root: '/home/tester/docs'),
          _entry('b.txt', root: '/home/tester/docs'),
        ];
      final held = Completer<void>();
      channel.heldPermissions = held;
      final cancellation = RemoteTransferCancellation();

      final walk = applyModeToEnclosed(
        channel,
        '/home/tester/docs',
        targetName: 'docs',
        mode: 0x1A4,
        cancellation: cancellation,
      );
      await _settle();
      // The first chmod is parked; cancel and release it — the landed
      // write still counts.
      cancellation.cancel();
      held.complete();
      final result = await walk;

      expect(result.stage, EnclosedApplyStage.cancelled);
      expect(result.applied, 1);
    });
  });

  group('permissions edit session (02 §2.6, D28)', () {
    test('mints a draft for a chmod-able target and none for a '
        'mode-less, flagged, or symlink target', () async {
      final (controller, _) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
        _entry('nomode.txt'),
        _entry('bad\uFFFDname', mode: 0x81A4),
        _entry(
          'link',
          type: RemoteFileType.symbolicLink,
          mode: 0xA1FF,
        ),
      ]);
      addTearDown(controller.dispose);

      _cursorTo(controller, 'plain.txt');
      final session = controller.permissionsEdit;
      expect(session, isNotNull);
      expect(session!.originalMode, 0x81A4);
      expect(session.octalText, '0644');
      expect(controller.permissionsReadOnly, isNull);

      _cursorTo(controller, 'nomode.txt');
      expect(controller.permissionsEdit, isNull);
      expect(controller.permissionsReadOnly, isNull);

      _cursorTo(controller, 'bad\uFFFDname');
      expect(controller.permissionsEdit, isNull);
      expect(
        controller.permissionsReadOnly,
        PermissionsReadOnly.flaggedName,
      );

      _cursorTo(controller, 'link');
      expect(controller.permissionsEdit, isNull);
      expect(
        controller.permissionsReadOnly,
        PermissionsReadOnly.symbolicLink,
      );
    });

    test('octal edits move the draft; checkbox edits re-seed the text',
        () async {
      final (controller, _) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);

      // Typing a valid value moves the mode — the grid reads it.
      controller.editPermissionsOctal('0600');
      var session = controller.permissionsEdit!;
      expect(session.mode, 0x180);
      expect(session.octalInvalid, isFalse);
      expect(session.dirty, isTrue);

      // A checkbox toggle moves the mode and re-seeds the field.
      controller.setPermissionBit(permissionOtherRead, true);
      session = controller.permissionsEdit!;
      expect(session.mode, 0x184);
      expect(session.octalText, '0604');
      expect(session.octalRevision, greaterThan(0));

      // The leading digit carries setuid: a typed special-bits value
      // is preserved verbatim.
      controller.editPermissionsOctal('4755');
      session = controller.permissionsEdit!;
      expect(session.mode, 0x9ED);
      expect(session.mode & 0x800, isNonZero);
    });

    test('invalid octal flags the field and leaves the mode untouched',
        () async {
      final (controller, _) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);

      controller.editPermissionsOctal('8888');
      var session = controller.permissionsEdit!;
      expect(session.octalInvalid, isTrue);
      expect(session.mode, 0x81A4);
      expect(session.octalText, '8888'); // verbatim for correction

      // The rejection is inline only — no chmod leaves the pane.
      await controller.applyPermissions();
      expect(session.applyError, isNull);

      // A partial value stays invalid until the fourth digit lands.
      controller.editPermissionsOctal('060');
      session = controller.permissionsEdit!;
      expect(session.octalInvalid, isTrue);
      controller.editPermissionsOctal('0600');
      session = controller.permissionsEdit!;
      expect(session.octalInvalid, isFalse);
      expect(session.mode, 0x180);
    });

    test('Esc revert restores the applied baseline', () async {
      final (controller, _) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);

      controller.editPermissionsOctal('0600');
      controller.revertPermissionsEdit();
      final session = controller.permissionsEdit!;
      expect(session.mode, 0x81A4);
      expect(session.octalText, '0644');
      expect(session.dirty, isFalse);
    });

    test('apply writes the exact mode and rebaselines the draft',
        () async {
      final (controller, channel) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);
      final listsBefore = channel.listCalls.length;

      controller.editPermissionsOctal('0600');
      await controller.applyPermissions();

      expect(
        channel.permissionsCalls,
        [('/home/tester/plain.txt', 0x180)],
      );
      final session = controller.permissionsEdit!;
      expect(session.applying, isFalse);
      expect(session.applyError, isNull);
      expect(channel.listCalls.length, greaterThan(listsBefore));
    });

    test('a typed refusal lands inline, never modal', () async {
      final (controller, channel) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);
      channel.permissionsFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'setMode',
        message: 'denied',
      );

      controller.editPermissionsOctal('0600');
      await controller.applyPermissions();

      final session = controller.permissionsEdit!;
      expect(session.applying, isFalse);
      expect(session.applyError?.kind, RemoteFileErrorKind.permissionDenied);
    });

    test('an unchanged draft never issues a chmod', () async {
      final (controller, channel) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);

      await controller.applyPermissions();
      expect(channel.permissionsCalls, isEmpty);
    });

    test('a mid-flight draft edit stays dirty against the written '
        'baseline', () async {
      final (controller, channel) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);

      controller.editPermissionsOctal('0700');
      final held = Completer<void>();
      channel.heldPermissions = held;
      unawaited(controller.applyPermissions());
      await _settle();
      final session = controller.permissionsEdit!;
      expect(session.applying, isTrue);

      // The draft drifts while the 0700 write is in flight.
      controller.editPermissionsOctal('0640');
      held.complete();
      await _settle();

      // The baseline records what was written — never the later draft.
      expect(session.originalMode, 0x1C0);
      expect(session.mode, 0x1A0);
      expect(session.dirty, isTrue);
    });

    test('a refusal answering after a retarget reports through the pane '
        'error path, not a dead session', () async {
      final errors = <Object>[];
      final (controller, channel) = await _browsedPane(
        [
          _entry('a.txt', mode: 0x81A4),
          _entry('b.txt', mode: 0x81A4),
        ],
        onError: (error, _) => errors.add(error),
      );
      addTearDown(controller.dispose);
      _cursorTo(controller, 'a.txt');

      controller.editPermissionsOctal('0700');
      final held = Completer<void>();
      channel.heldPermissions = held;
      unawaited(controller.applyPermissions());
      await _settle();

      // The inspector retargets while the write is in flight; its
      // completion is stale and reports like any untyped-adjacent
      // refusal — never landing on b.txt's fresh session.
      _cursorTo(controller, 'b.txt');
      channel.permissionsFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'setMode',
        message: 'denied',
      );
      held.complete();
      await _settle();

      expect(errors.single, isA<RemoteFileException>());
      expect(controller.permissionsEdit!.applyError, isNull);
    });

    test('a stale completion releases the in-flight flag — the '
        're-adopted session can apply again', () async {
      final errors = <Object>[];
      final (controller, channel) = await _browsedPane(
        [_entry('plain.txt', mode: 0x81A4)],
        onError: (error, _) => errors.add(error),
      );
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);

      controller.editPermissionsOctal('0700');
      final held = Completer<void>();
      channel.heldPermissions = held;
      unawaited(controller.applyPermissions());
      await _settle();
      expect(controller.permissionsEdit?.applying, isTrue);

      // A refresh mid-flight retires the write; the identical listing
      // re-adopts the cached session object, so a latched `applying`
      // would dead Apply permanently without the release.
      controller.refresh();
      await _settle();
      channel.permissionsFailure = StateError('gone');
      held.complete();
      await _settle();

      expect(errors.single, isA<StateError>());
      final session = controller.permissionsEdit!;
      expect(session.applying, isFalse);
      expect(session.dirty, isTrue);
    });
  });

  group('apply to enclosed items (02 §2.6, D28)', () {
    test('counts, confirms, then writes every reachable entry plus the '
        'target itself', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', root: '/home/tester/docs', mode: 0x81A4),
        _entry(
          'sub',
          type: RemoteFileType.directory,
          root: '/home/tester/docs',
          mode: 0x41ED,
        ),
      ];
      channel.listings['/home/tester/docs/sub'] = [
        _entry('deep.txt', root: '/home/tester/docs/sub', mode: 0x81A4),
      ];

      _cursorTo(controller, 'docs');
      controller.editPermissionsOctal('0700');
      await controller.requestApplyToEnclosed(confirm: () async => true);

      final session = controller.enclosedApply!;
      expect(session.stage, EnclosedApplyStage.done);
      expect(session.applied, 4);
      expect(
        channel.permissionsCalls,
        containsAll([
          ('/home/tester/docs/a.txt', 0x1C0),
          ('/home/tester/docs/sub/deep.txt', 0x1C0),
          ('/home/tester/docs/sub', 0x1C0),
          ('/home/tester/docs', 0x1C0),
        ]),
      );
      expect(controller.applyToEnclosedInFlight, isFalse);
    });

    test('the confirmation observes the counted quantification', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', root: '/home/tester/docs', mode: 0x81A4),
        _entry('b.txt', root: '/home/tester/docs', mode: 0x81A4),
      ];
      _cursorTo(controller, 'docs');

      final answer = Completer<bool>();
      final apply = controller.requestApplyToEnclosed(
        confirm: () => answer.future,
      );
      unawaited(apply);
      await _settle();

      // The ask is open on the quantified copy — the count pass saw
      // every reachable item.
      final confirming = controller.enclosedApply!;
      expect(confirming.stage, EnclosedApplyStage.confirming);
      expect(confirming.counted, 2);
      expect(confirming.flagPassComplete, isTrue);
      expect(controller.applyToEnclosedInFlight, isTrue);

      answer.complete(true);
      await _settle();
      expect(controller.enclosedApply?.stage, EnclosedApplyStage.done);
      await apply;
    });

    test('the confirmation hedges when the count pass is incomplete',
        () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', root: '/home/tester/docs', mode: 0x81A4),
        _entry(
          'locked',
          type: RemoteFileType.directory,
          root: '/home/tester/docs',
        ),
      ];
      // 'locked' has no scripted listing — the count pass's nested
      // list refuses, leaving the pass incomplete.
      _cursorTo(controller, 'docs');

      final answer = Completer<bool>();
      final apply = controller.requestApplyToEnclosed(
        confirm: () => answer.future,
      );
      unawaited(apply);
      await _settle();

      final confirming = controller.enclosedApply!;
      expect(confirming.stage, EnclosedApplyStage.confirming);
      expect(confirming.counted, 2);
      expect(confirming.flagPassComplete, isFalse);

      answer.complete(true);
      await _settle();
      expect(controller.enclosedApply?.stage, EnclosedApplyStage.done);
      await apply;
    });

    test('declining touches nothing', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', root: '/home/tester/docs', mode: 0x81A4),
      ];
      _cursorTo(controller, 'docs');

      await controller.requestApplyToEnclosed(confirm: () async => false);
      expect(channel.permissionsCalls, isEmpty);
      expect(controller.enclosedApply, isNull);
      expect(controller.applyToEnclosedInFlight, isFalse);
    });

    test('is inert for a file target, an invalid draft, and a running '
        'operation', () async {
      final (controller, channel) = await _browsedPane([
        _entry('plain.txt', mode: 0x81A4),
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = const [];
      _cursorTo(controller, 'plain.txt'); // a file — nothing enclosed

      await controller.requestApplyToEnclosed(confirm: () async => true);
      expect(controller.enclosedApply, isNull);

      _cursorTo(controller, 'docs');
      controller.editPermissionsOctal('8888');
      await controller.requestApplyToEnclosed(confirm: () async => true);
      expect(controller.enclosedApply, isNull);
      expect(channel.permissionsCalls, isEmpty);

      // A running operation refuses a second request.
      controller.editPermissionsOctal('0700');
      final answer = Completer<bool>();
      final apply = controller.requestApplyToEnclosed(
        confirm: () => answer.future,
      );
      unawaited(apply);
      await _settle();
      expect(controller.enclosedApply?.stage, EnclosedApplyStage.confirming);
      await controller.requestApplyToEnclosed(confirm: () async => true);
      expect(controller.enclosedApply?.stage, EnclosedApplyStage.confirming);
      answer.complete(false);
      // The abandoned operation must settle rather than hang.
      await apply;
    });

    test('cancel mid-walk settles cancelled with the partial tally, and '
        'the guard drops', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', root: '/home/tester/docs', mode: 0x81A4),
        _entry('b.txt', root: '/home/tester/docs', mode: 0x81A4),
      ];
      final held = Completer<void>();
      channel.heldPermissions = held;
      _cursorTo(controller, 'docs');

      unawaited(
        controller.requestApplyToEnclosed(confirm: () async => true),
      );
      await _settle();
      expect(controller.enclosedApply?.stage, EnclosedApplyStage.applying);
      expect(controller.applyToEnclosedInFlight, isTrue);

      controller.cancelEnclosedApply();
      held.complete();
      await _settle();

      final session = controller.enclosedApply!;
      expect(session.stage, EnclosedApplyStage.cancelled);
      expect(session.applied, greaterThan(0));
      expect(controller.applyToEnclosedInFlight, isFalse);
    });

    test('a root listing refusal ends the operation typed-failed before '
        'any chmod', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      controller.setCursorIndex(0);
      // 'docs' has no scripted listing — the count's root list refuses.

      await controller.requestApplyToEnclosed(confirm: () async => true);
      final session = controller.enclosedApply!;
      expect(session.stage, EnclosedApplyStage.failed);
      expect(session.error, isA<RemoteFileException>());
      expect(channel.permissionsCalls, isEmpty);
    });

    test('the tab close guard fires while the operation counts, asks, '
        'or applies', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      var asks = 0;
      addTearDown(controller.dispose);
      final strip = testPaneStrip(
        controller,
        confirmClose: (tab, triggers) async {
          asks++;
          return triggers.contains(TabCloseTrigger.applyToEnclosed);
        },
      );
      channel.listings['/home/tester/docs'] = const [];
      _cursorTo(controller, 'docs');

      final answer = Completer<bool>();
      final apply = controller.requestApplyToEnclosed(
        confirm: () => answer.future,
      );
      unawaited(apply);
      await _settle();
      expect(controller.enclosedApply?.stage, EnclosedApplyStage.confirming);

      final outcome = await strip.requestCloseTab(strip.tabs.first);
      expect(asks, 1);
      expect(outcome, TabCloseOutcome.closed);
      expect(controller.applyToEnclosedInFlight, isFalse);
      expect(controller.enclosedApply, isNull);
      answer.complete(false);
      // The abandoned operation must settle rather than hang.
      await apply;
    });

    test('cancelling ends a pending confirmation untouched', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      testPaneStrip(controller);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', root: '/home/tester/docs', mode: 0x81A4),
      ];
      _cursorTo(controller, 'docs');

      final answer = Completer<bool>();
      final apply = controller.requestApplyToEnclosed(
        confirm: () => answer.future,
      );
      unawaited(apply);
      await _settle();
      expect(controller.enclosedApply?.stage, EnclosedApplyStage.confirming);

      controller.cancelEnclosedApply();
      await _settle();
      expect(controller.enclosedApply, isNull);
      expect(controller.applyToEnclosedInFlight, isFalse);
      expect(channel.permissionsCalls, isEmpty);
      answer.complete(false);
      // The abandoned operation must settle rather than hang.
      await apply;
    });

    test('a location-changing navigation ends the operation at issue '
        'time', () async {
      final (controller, channel) = await _browsedPane([
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
        _entry('other', type: RemoteFileType.directory, mode: 0x41ED),
      ]);
      addTearDown(controller.dispose);
      channel.listings['/home/tester/docs'] = const [];
      channel.listings['/home/tester/other'] = const [];
      _cursorTo(controller, 'docs');

      final answer = Completer<bool>();
      final apply = controller.requestApplyToEnclosed(
        confirm: () => answer.future,
      );
      unawaited(apply);
      await _settle();
      expect(controller.applyToEnclosedInFlight, isTrue);

      _cursorTo(controller, 'other');
      unawaited(controller.openEntry(controller.infoTarget!));
      expect(controller.applyToEnclosedInFlight, isFalse);
      expect(controller.enclosedApply, isNull);
      expect(channel.permissionsCalls, isEmpty);
      answer.complete(false);
      // The abandoned operation must settle rather than hang.
      await apply;
    });
  });
}
