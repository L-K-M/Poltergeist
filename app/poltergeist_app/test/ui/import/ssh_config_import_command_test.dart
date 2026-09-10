import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/ui/import/ssh_config_import_command.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_ssh_config_source.dart';

const _home = '/home/tester';
const _configPath = '$_home/.ssh/config';
final _fixedNow = DateTime.utc(2026, 9, 8, 12);

/// A config with one key-auth host and one password host.
const _sampleConfig = '''
Host web
  HostName web.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519

Host other
  HostName other.example.com
  User root
''';

/// In-memory [BookmarkRepository]; the widget tree must not touch
/// `dart:io` (the on-disk behavior is covered in bookmark_store_test).
class _FakeBookmarkStore implements BookmarkRepository {
  _FakeBookmarkStore([Iterable<Bookmark> seed = const []]) {
    for (final bookmark in seed) {
      _bookmarks[bookmark.id] = bookmark;
    }
  }

  final _bookmarks = <String, Bookmark>{};

  @override
  Future<List<Bookmark>> load() async => List.unmodifiable(_bookmarks.values);

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {
    for (final bookmark in bookmarks) {
      _bookmarks[bookmark.id] = bookmark;
    }
  }
}

/// A store whose read fails; the command must surface the ARB notice and
/// never render the preview.
class _LoadFailingBookmarkStore implements BookmarkRepository {
  @override
  Future<List<Bookmark>> load() async =>
      throw const FileSystemException('unreadable');

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {}
}

/// A store whose write fails; the command must surface the ARB notice and
/// never report a successful import.
class _SaveFailingBookmarkStore implements BookmarkRepository {
  @override
  Future<List<Bookmark>> load() async => const [];

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async =>
      throw const FileSystemException('read-only');
}

Bookmark _existing(String label, String host, int port, String user) {
  return Bookmark(
    id: 'existing-$label',
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: host,
        port: port,
        username: user,
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/',
    sortKey: 'e-$label',
    createdAt: _fixedNow,
    updatedAt: _fixedNow,
  );
}

SshConfigImportService _service(FakeSshConfigSource source) {
  var next = 0;
  return SshConfigImportService(
    homeDirectory: _home,
    source: source,
    mintId: () => 'row-${next++}',
  );
}

void main() {
  late _FakeBookmarkStore store;

  setUp(() {
    store = _FakeBookmarkStore();
  });

  SshConfigImportSetup setup({
    Map<String, String>? files,
    BookmarkRepository? bookmarks,
  }) {
    return SshConfigImportSetup(
      service: _service(
        FakeSshConfigSource(files ?? {_configPath: _sampleConfig}),
      ),
      bookmarks: bookmarks ?? store,
      configPath: _configPath,
    );
  }

  final commandButton = find.byKey(
    const ValueKey('command.$kSshConfigImportCommandId'),
  );

  Future<void> pumpApp(
    WidgetTester tester, {
    SshConfigImportSetup? wiring,
  }) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(PoltergeistApp(sshConfigImport: wiring));
    await tester.pump();
  }

  testWidgets('the import command renders only when wired', (tester) async {
    await pumpApp(tester);
    expect(commandButton, findsNothing);

    await pumpApp(tester, wiring: setup());
    expect(commandButton, findsOneWidget);
    expect(find.text('Import from ssh config…'), findsOneWidget);
  });

  testWidgets('the command opens the preview and persists the rows', (
    tester,
  ) async {
    await pumpApp(tester, wiring: setup());

    await tester.tap(commandButton);
    await tester.pumpAndSettle();

    expect(find.text('Import servers from ssh config'), findsOneWidget);
    expect(find.text('web'), findsOneWidget);
    expect(find.text('other'), findsOneWidget);
    expect(find.text('Import 2'), findsOneWidget);

    await tester.tap(find.text('Import 2'));
    await tester.pumpAndSettle();

    final persisted = await store.load();
    expect(persisted.map((bookmark) => bookmark.id).toSet(), {
      'row-0',
      'row-1',
    });

    final web = persisted.singleWhere((bookmark) => bookmark.id == 'row-0');
    final identity = web.server!.identity!;
    expect(web.label, 'web');
    // IdentityFile stays reference-style: the path travels verbatim and no
    // key material is read at import time (D22, D18).
    expect(identity.authMethod, AuthMethod.privateKey);
    expect(identity.identityFilePath, '~/.ssh/id_ed25519');
    expect(find.text('Imported 2 favorites'), findsOneWidget);
  });

  testWidgets('an existing host+port+username is flagged and skipped', (
    tester,
  ) async {
    store = _FakeBookmarkStore([
      _existing('Saved web', 'web.example.com', 2222, 'deploy'),
    ]);

    await pumpApp(tester, wiring: setup());
    await tester.tap(commandButton);
    await tester.pumpAndSettle();

    // The preview reflects the persisted store: the matching row is
    // flagged and starts skipped, so only the new host is importable.
    expect(find.text('Duplicate of bookmark “Saved web”'), findsOneWidget);
    expect(find.text('Import 1'), findsOneWidget);

    await tester.tap(find.text('Import 1'));
    await tester.pumpAndSettle();

    final persisted = await store.load();
    expect(persisted.map((bookmark) => bookmark.label).toSet(), {
      'Saved web',
      'other',
    });
  });

  testWidgets('a store with no matches flags nothing', (tester) async {
    await pumpApp(tester, wiring: setup());
    await tester.tap(commandButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('Duplicate of bookmark'), findsNothing);
    expect(find.text('Import 2'), findsOneWidget);
  });

  testWidgets('a missing config file shows the retry surface, not a crash', (
    tester,
  ) async {
    await pumpApp(tester, wiring: setup(files: const {}));

    await tester.tap(commandButton);
    await tester.pumpAndSettle();

    // The import command is registered whenever a home resolves; a
    // missing ~/.ssh/config must land on the dialog's retry surface and
    // persist nothing.
    expect(find.text('Could not read $_configPath.'), findsOneWidget);
    expect(await store.load(), isEmpty);
  });

  testWidgets('a store load failure shows the notice, not the preview', (
    tester,
  ) async {
    await pumpApp(
      tester,
      wiring: setup(bookmarks: _LoadFailingBookmarkStore()),
    );

    await tester.tap(commandButton);
    await tester.pumpAndSettle();

    expect(find.text('Could not read the favorites file.'), findsOneWidget);
    expect(find.text('Import servers from ssh config'), findsNothing);
    // The failure is also reported to the app's default error sink;
    // consume it here so the framework does not treat it as unhandled.
    expect(tester.takeException(), isA<FileSystemException>());
  });

  testWidgets('a store save failure shows the notice, not a success', (
    tester,
  ) async {
    await pumpApp(
      tester,
      wiring: setup(bookmarks: _SaveFailingBookmarkStore()),
    );

    await tester.tap(commandButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 2'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not save the imported favorites.'),
      findsOneWidget,
    );
    expect(find.textContaining('Imported'), findsNothing);
    expect(tester.takeException(), isA<FileSystemException>());
  });
}
