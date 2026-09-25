import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' show FakePaneLanes;
import '../support/fake_pane_channel.dart';

/// The inline error's Cancel (02 §2.8): Retry alone is no way out of a
/// failure that will not heal, so every error the overlay shows either
/// backs the pane out on its own or names the binding exit the shell
/// runs.

const _denied = RemoteFileException(
  kind: RemoteFileErrorKind.permissionDenied,
  operation: 'list',
  path: '/root',
  message: 'Could not list "/root": Permission denied',
);

RemoteFileEntry _entry(
  String name, {
  String parent = '/home/tester',
  RemoteFileType type = RemoteFileType.file,
}) => RemoteFileEntry(path: '$parent/$name', name: name, type: type);

Bookmark _bookmark({String remotePath = '/'}) {
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
    remotePath: remotePath,
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakePaneLanes lanes;
  late PaneController controller;

  setUp(() {
    lanes = FakePaneLanes();
    controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
  });

  tearDown(() => controller.dispose());

  test(
    'Cancel on a denied folder returns to the folder the user left',
    () async {
      final channel = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [_entry('notes.txt', parent: '/srv/home')]
        ..listingFailures['/root'] = _denied;
      lanes.nextRemoteChannel = channel;
      await controller.connectRemote(_bookmark());
      await _settle();

      controller.navigate('/root');
      await _settle();
      expect(controller.error?.kind, RemoteFileErrorKind.permissionDenied);
      expect(controller.errorExit, PaneErrorExit.pane);

      // Retry cannot get out: the folder refuses the same way every time.
      await controller.retry();
      await _settle();
      expect(controller.error?.kind, RemoteFileErrorKind.permissionDenied);

      controller.cancelError();

      expect(controller.error, isNull);
      expect(
        controller.location,
        const RemotePaneLocation('srv-1', '/srv/home'),
      );
      expect(controller.entries.single.name, 'notes.txt');
      expect(controller.staleRows, isFalse);
      expect(controller.verbsEnabled, isTrue);
      expect(controller.errorExit, PaneErrorExit.none);
      // The rows under the error were the committed listing: no re-list.
      expect(channel.listCalls, ['/srv/home', '/root', '/root']);
      // The attempt survives as Forward history, like an Esc-cancel.
      expect(controller.canGoBack, isFalse);
      expect(controller.canGoForward, isTrue);

      // The restored rows are live again.
      controller.moveCursorBy(1);
      expect(controller.cursorIndex, 0);
    },
  );

  test(
    'Cancel re-lists a restored local folder so its watch re-arms',
    () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('here.txt')]
        ..listingFailures['/root'] = _denied;
      lanes.nextLocalChannel = channel;
      await controller.openLocalHome();
      await _settle();
      expect(channel.watchCalls, ['/home/tester']);

      controller.navigate('/root');
      await _settle();
      expect(controller.error, isNotNull);

      controller.cancelError();
      await _settle();

      expect(controller.error, isNull);
      expect(controller.location, const LocalPaneLocation('/home/tester'));
      expect(controller.entries.single.name, 'here.txt');
      // Nothing watched home while the pane stood on /root.
      expect(channel.listCalls.last, '/home/tester');
      expect(channel.watchCalls.last, '/home/tester');
      expect(controller.loading, isFalse);
    },
  );

  test('Cancel retires a navigation still in flight under the error',
      () async {
    // Remote, so no directory watch re-lists over a wrongly accepted
    // answer and hides it.
    final channel = FakePaneChannel('/srv/home')
      ..listings['/srv/home'] = [_entry('here.txt', parent: '/srv/home')]
      ..listings['/srv/home/slow'] = [
        _entry('slow.txt', parent: '/srv/home/slow'),
      ];
    lanes.nextRemoteChannel = channel;
    await controller.connectRemote(_bookmark());
    await _settle();

    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.navigate('/srv/home/slow');
    await _settle();
    // A rejected typed path lands its error over the pending load.
    controller.editPath();
    controller.submitPathField('~root/docs');
    expect(controller.error, isA<PaneFaultException>());

    controller.cancelError();
    expect(controller.loading, isFalse);
    hold.complete();
    await _settle();

    expect(controller.location, const RemotePaneLocation('srv-1', '/srv/home'));
    expect(controller.entries.single.name, 'here.txt');
    expect(controller.error, isNull);
  });

  test('Cancel on a failed file Open only drops the error', () async {
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('report.txt')]
      ..openFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'open',
        message: 'No application can open this file',
      );
    lanes.nextLocalChannel = channel;
    await controller.openLocalHome();
    await _settle();

    await controller.openEntry(controller.entries.single);
    expect(controller.error, isA<OpenEntryError>());
    expect(controller.errorExit, PaneErrorExit.pane);

    controller.cancelError();

    expect(controller.error, isNull);
    expect(controller.location, const LocalPaneLocation('/home/tester'));
    expect(channel.listCalls, ['/home/tester']);
    expect(controller.verbsEnabled, isTrue);
  });

  test('Cancel on a rejected typed path keeps the folder as it was', () async {
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('here.txt')];
    lanes.nextLocalChannel = channel;
    await controller.openLocalHome();
    await _settle();

    controller.editPath();
    controller.submitPathField('~root/docs');
    expect(controller.error, isA<PaneFaultException>());

    controller.cancelError();

    expect(controller.error, isNull);
    expect(controller.entries.single.name, 'here.txt');
    expect(channel.listCalls, ['/home/tester']);
  });

  test('a folder that fails its own re-list is left for its parent', () async {
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [
        _entry('docs', type: RemoteFileType.directory),
      ]
      ..listings['/home/tester/docs'] = [
        _entry('a.txt', parent: '/home/tester/docs'),
      ];
    lanes.nextLocalChannel = channel;
    await controller.openLocalHome();
    await _settle();
    controller.navigate('/home/tester/docs');
    await _settle();

    // The folder vanishes under the pane: its refresh fails, and its
    // own rows are all the pane has.
    channel.listings.remove('/home/tester/docs');
    controller.refresh();
    await _settle();
    expect(controller.error?.kind, RemoteFileErrorKind.notFound);
    expect(controller.errorExit, PaneErrorExit.pane);

    controller.cancelError();
    await _settle();

    expect(controller.error, isNull);
    expect(controller.location, const LocalPaneLocation('/home/tester'));
    expect(controller.entries.single.name, 'docs');
  });

  test('a first listing that never landed is left for its parent', () async {
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('here.txt')];
    lanes.nextLocalChannel = channel;
    await controller.openLocalAt('/home/tester/gone');
    await _settle();
    expect(controller.committedLocation, isNull);
    expect(controller.error?.kind, RemoteFileErrorKind.notFound);

    controller.cancelError();
    await _settle();

    expect(controller.error, isNull);
    expect(controller.location, const LocalPaneLocation('/home/tester'));
    expect(controller.entries.single.name, 'here.txt');
  });

  test('a root that fails its own re-list falls back to home', () async {
    final channel = FakePaneChannel('/srv/home')
      ..listings['/srv/home'] = [_entry('notes.txt', parent: '/srv/home')]
      ..listings['/'] = [
        _entry('srv', parent: '', type: RemoteFileType.directory),
      ];
    lanes.nextRemoteChannel = channel;
    await controller.connectRemote(_bookmark());
    await _settle();
    controller.navigate('/');
    await _settle();
    expect(
      controller.committedLocation,
      const RemotePaneLocation('srv-1', '/'),
    );

    // The root refuses its refresh: it is its own parent, so home is
    // the only folder left to fall back to.
    channel.listingFailures['/'] = _denied;
    controller.refresh();
    await _settle();
    expect(controller.errorExit, PaneErrorExit.pane);

    controller.cancelError();
    await _settle();

    expect(controller.error, isNull);
    expect(controller.location, const RemotePaneLocation('srv-1', '/srv/home'));
    expect(controller.entries.single.name, 'notes.txt');
  });

  test(
    'a remote pane with nothing to fall back to leaves the binding',
    () async {
      final channel = FakePaneChannel('/')..listingFailures['/'] = _denied;
      lanes.nextRemoteChannel = channel;
      await controller.connectRemote(_bookmark());
      await _settle();

      expect(controller.error?.kind, RemoteFileErrorKind.permissionDenied);
      expect(controller.errorExit, PaneErrorExit.unbind);
      controller.cancelError();
      expect(
        controller.error,
        isNotNull,
        reason: 'the binding exit is the shell\'s to run',
      );
    },
  );

  test('a local pane with nothing to fall back to offers no Cancel', () async {
    final channel = FakePaneChannel('/')..listingFailures['/'] = _denied;
    lanes.nextLocalChannel = channel;
    await controller.openLocalHome();
    await _settle();

    expect(controller.error, isNotNull);
    expect(controller.errorExit, PaneErrorExit.none);
  });

  test('a failed connect leaves through the binding exit', () async {
    lanes.remoteOpenFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'connect',
      message: 'Authentication failed for tester@web.example.com:22',
    );
    await controller.connectRemote(_bookmark());

    expect(controller.phase, PanePhase.connectingRemote);
    expect(controller.errorExit, PaneErrorExit.unbind);
  });

  test('no error, no Cancel', () async {
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('here.txt')];
    lanes.nextLocalChannel = channel;
    await controller.openLocalHome();
    await _settle();

    expect(controller.errorExit, PaneErrorExit.none);
    controller.cancelError();
    expect(controller.location, const LocalPaneLocation('/home/tester'));
    expect(channel.listCalls, ['/home/tester']);
  });
}
