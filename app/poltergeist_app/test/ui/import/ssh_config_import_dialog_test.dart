import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/import/ssh_config_import_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

class _FakeSource implements SshConfigFileSource {
  final Map<String, String> files;
  final Completer<String?>? gate;

  _FakeSource(this.files, {this.gate});

  @override
  Future<String?> readText(String path) async =>
      gate == null ? files[path] : await gate!.future.then((_) => files[path]);

  @override
  Future<List<String>?> listLexical(String directory) async => null;
}

const _home = '/home/tester';
const _configPath = '$_home/.ssh/config';
final _fixedNow = DateTime.utc(2026, 9, 8, 12);

SshConfigImportService _service(_FakeSource source) {
  var next = 0;
  return SshConfigImportService(
    homeDirectory: _home,
    source: source,
    mintId: () => 'id-${next++}',
  );
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

const _sampleConfig = '''
Host web
  HostName web.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519

Host dup
  HostName web.example.com
  Port 2222
  User deploy

Host bad-port
  Port 70000
''';

class _Harness extends StatefulWidget {
  final SshConfigImportService service;
  final String configPath;
  final List<Bookmark> existing;

  const _Harness(this.service, this.configPath, {this.existing = const []});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String? result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) {
              return result == null
                  ? FilledButton(
                      onPressed: () async {
                        final imported = await showSshConfigImportDialog(
                          context,
                          service: widget.service,
                          configPath: widget.configPath,
                          existingBookmarks: widget.existing,
                          clock: () => _fixedNow,
                        );
                        if (!mounted) return;
                        setState(() {
                          result = imported == null
                              ? 'null'
                              : imported
                                    .map(
                                      (b) =>
                                          '${b.label}:'
                                          '${b.server!.identity!.host}:'
                                          '${b.server!.identity!.port}:'
                                          '${b.server!.identity!.username}:'
                                          '${b.server!.identity!.authMethod.name}'
                                          ':${b.server!.identity!.identityFilePath ?? '-'}',
                                    )
                                    .join('|');
                        });
                      },
                      child: const Text('open'),
                    )
                  : Text('result:$result');
            },
          ),
        ),
      ),
    );
  }
}

Future<void> _open(WidgetTester tester, SshConfigImportService service,
    {List<Bookmark> existing = const []}) async {
  await tester.pumpWidget(_Harness(service, _configPath, existing: existing));
  await tester.tap(find.text('open'));
  await tester.pump(); // dialog route opens
  await tester.pumpAndSettle(); // load completes
}

class _ThrowingService extends SshConfigImportService {
  _ThrowingService()
    : super(
        homeDirectory: '/home/tester',
        source: const _NeverSource(),
        mintId: () => 'unused',
      );

  @override
  Future<SshConfigImportPreview> loadPreview({
    required String configPath,
    Iterable<Bookmark> existingBookmarks = const [],
  }) async => throw Exception('importer bug');
}

class _NeverSource implements SshConfigFileSource {
  const _NeverSource();

  @override
  Future<String?> readText(String path) async => null;

  @override
  Future<List<String>?> listLexical(String directory) async => null;
}

void main() {
  testWidgets('renders rows with dedupe and limitation verdicts',
      (tester) async {
    await _open(
      tester,
      _service(_FakeSource({_configPath: _sampleConfig})),
      existing: [_existing('Prod web', 'web.example.com', 2222, 'deploy')],
    );

    expect(find.text('web'), findsOneWidget);
    expect(find.text('web.example.com:2222'), findsNWidgets(2));
    expect(find.text('Key: ~/.ssh/id_ed25519'), findsOneWidget);
    expect(find.text('deploy'), findsNWidgets(2));
    expect(find.text('Password'), findsNWidgets(2));

    // Both rows target the bookmarked endpoint; the existing-bookmark
    // chip outranks the earlier-row chip when both would apply.
    expect(find.text('Duplicate of bookmark “Prod web”'), findsNWidgets(2));
    expect(find.text('Duplicate of “web” in this import'), findsNothing);
    // …and the invalid port chip.
    expect(find.text('Cannot import: port outside 1–65535'), findsOneWidget);

    // Both endpoint rows duplicate the existing bookmark, so every row
    // starts skipped; the invalid-port row can never import at all.
    final boxes = find.byType(Checkbox);
    expect(boxes, findsNWidgets(3));
    expect(tester.widget<Checkbox>(boxes.at(0)).value, isFalse);
    expect(tester.widget<Checkbox>(boxes.at(1)).value, isFalse);
    expect(tester.widget<Checkbox>(boxes.at(2)).value, isFalse);
    // The invalid-port row's checkbox is inert.
    expect(tester.widget<Checkbox>(boxes.at(2)).onChanged, isNull);

    // Nothing selected: the action stays disabled and label-less (the
    // other "Import" text is the table header).
    final disabledButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.descendant(
          of: find.byType(FilledButton),
          matching: find.text('Import'),
        ),
        matching: find.byType(FilledButton),
      ),
    );
    expect(disabledButton.onPressed, isNull);

    // A clean row would start selected…
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(find.text('Import 1'), findsOneWidget);
  });

  testWidgets('match blocks badge every row', (tester) async {
    const config = '''
Match host *.internal
  Port 2222

Host web
  HostName web.example.com
''';
    await _open(tester, _service(_FakeSource({_configPath: config})));

    expect(
      find.text(
        'Won\u2019t behave as in ssh: Match blocks are ignored; '
        'settings may differ',
      ),
      findsOneWidget,
    );
  });

  testWidgets('unresolved include notices are listed', (tester) async {
    await _open(
      tester,
      _service(
        _FakeSource({
          _configPath: 'Include $_home/.ssh/missing.conf\n\nHost web\n',
        }),
      ),
    );

    expect(find.text('Unresolved includes'), findsOneWidget);
    expect(
      find.text('$_home/.ssh/missing.conf: could not be read'),
      findsOneWidget,
    );
  });

  testWidgets('toggling rows updates the count and the imported set',
      (tester) async {
    await _open(
      tester,
      _service(_FakeSource({_configPath: _sampleConfig})),
    );

    // Without existing bookmarks, the second row shows the earlier-row
    // duplicate chip instead.
    expect(find.text('Duplicate of “web” in this import'), findsOneWidget);

    // Select the duplicate row too.
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(find.text('Import 2'), findsOneWidget);

    // Deselect the clean row.
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(find.text('Import 1'), findsOneWidget);

    await tester.tap(find.text('Import 1'));
    await tester.pumpAndSettle();

    // Only `dup` was imported; the reference-style key path travels with
    // key auth rows (none here), and password rows keep password auth.
    expect(
      find.text(
        'result:dup:web.example.com:2222:deploy:password:-',
      ),
      findsOneWidget,
    );
  });

  testWidgets('import maps IdentityFile to reference-style key auth',
      (tester) async {
    await _open(tester, _service(_FakeSource({_configPath: _sampleConfig})));

    await tester.tap(find.text('Import 1'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'result:web:web.example.com:2222:deploy:privateKey:'
        '~/.ssh/id_ed25519',
      ),
      findsOneWidget,
    );
  });

  testWidgets('import is disabled with nothing selected', (tester) async {
    await _open(
      tester,
      _service(
        _FakeSource({_configPath: 'Host web\n  HostName w.example.com\n'}),
      ),
      existing: [_existing('Prod', 'w.example.com', 22, '')],
    );

    // The only row duplicates an existing bookmark, so it starts
    // unselected and the import action is disabled at zero selection.
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Import'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);

    // Selecting the row re-enables it with a count.
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    final enabled = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Import 1'), matching: find.byType(FilledButton)),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('cancel returns null', (tester) async {
    await _open(tester, _service(_FakeSource({_configPath: _sampleConfig})));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('result:null'), findsOneWidget);
  });

  testWidgets('a missing config shows the failure with a working retry',
      (tester) async {
    final files = <String, String>{};
    final service = _service(_FakeSource(files));

    await _open(tester, service);
    expect(find.text('Could not read $_configPath.'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    files[_configPath] = _sampleConfig;
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget);
    expect(find.text('Import 1'), findsOneWidget);
  });

  testWidgets('a config with no host blocks says so', (tester) async {
    await _open(
      tester,
      _service(_FakeSource({_configPath: 'Port 22\n'})),
    );

    expect(
      find.text('No importable hosts were found in $_configPath.'),
      findsOneWidget,
    );
  });

  testWidgets('an unexpected load failure shows the retry UI',
      (tester) async {
    final service = _ThrowingService();

    await tester.pumpWidget(_Harness(service, _configPath));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pumpAndSettle();

    // Not stuck on the spinner: the failure surface offers retry.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Could not read $_configPath.'), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('a late load result never paints after disposal',
      (tester) async {
    final gate = Completer<String?>();
    final service = _service(_FakeSource({_configPath: _sampleConfig}, gate: gate));

    await tester.pumpWidget(_Harness(service, _configPath));
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Dismiss (dispose) the dialog while the load is still in flight…
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Container()),
      ),
    );
    // …then let the load finish: no setState may fire on the dead state.
    gate.complete(_sampleConfig);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('web'), findsNothing);
  });
}
