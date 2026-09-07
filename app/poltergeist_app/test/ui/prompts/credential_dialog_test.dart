import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/identity_file_reader.dart';
import 'package:poltergeist_app/ui/prompts/credential_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

class _Harness extends StatefulWidget {
  final CredentialPromptData data;
  final Future<String> Function(String path)? readKeyFile;
  final bool vaultUnavailable;


  const _Harness(this.data, {this.readKeyFile, this.vaultUnavailable = false});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  CredentialDialogResult? result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) {
              final result = this.result;
              return result == null
                  ? FilledButton(
                      onPressed: () async {
                        this.result = await showCredentialDialog(
                          context,
                          widget.data,
                          readKeyFile:
                              widget.readKeyFile ?? (path) async => 'PEM',
                          vaultUnavailable: widget.vaultUnavailable,
                        );
                        setState(() {});
                      },
                      child: const Text('open'),
                    )
                  : Text(
                      'result:'
                      '${result.password ?? '-'};'
                      '${result.privateKeyPem ?? '-'};'
                      '${result.keyPassphrase ?? '-'};'
                      '${result.saveToVault}',
                    );
            },
          ),
        ),
      ),
    );
  }
}

Future<void> _open(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(harness);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

const _passwordData = CredentialPromptData(
  host: 'example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.password,
);

void main() {
  testWidgets('password auth: endpoint, one field, no save offer', (
    tester,
  ) async {
    await _open(tester, _Harness(_passwordData));

    expect(find.textContaining('deploy@example.com:2222'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Key file'), findsNothing);
    expect(find.text('Save in vault'), findsNothing);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('password auth: answers the typed password', (tester) async {
    await _open(tester, _Harness(_passwordData));

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('result:pw;-;-;false'), findsOneWidget);
  });

  testWidgets('a secretRef offers saving, unchecked by default', (tester) async {
    await _open(
      tester,
      _Harness(
        const CredentialPromptData(
          host: 'example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.password,
          secretRef: 'secret-7',
        ),
      ),
    );

    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.value, isFalse);

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('result:pw;-;-;true'), findsOneWidget);
  });

  testWidgets('private-key auth prefills the identity file path', (
    tester,
  ) async {
    await _open(
      tester,
      _Harness(
        const CredentialPromptData(
          host: 'example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.privateKey,
          identityFilePath: '~/.ssh/id_ed25519',
        ),
      ),
    );

    expect(find.text('Key file'), findsOneWidget);
    expect(find.text('Passphrase'), findsOneWidget);
    expect(find.text('Password'), findsNothing);
    expect(
      tester.widget<TextField>(find.widgetWithText(TextField, 'Key file'))
          .controller!
          .text,
        '~/.ssh/id_ed25519');

    await tester.enterText(
      find.widgetWithText(TextField, 'Passphrase'),
      'phrase',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('result:-;PEM;phrase;false'), findsOneWidget);
  });

  testWidgets('a failing key read shows an inline error and stays open', (
    tester,
  ) async {
    await _open(
      tester,
      _Harness(
        const CredentialPromptData(
          host: 'example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.privateKey,
          identityFilePath: '~/.ssh/missing',
        ),
        readKeyFile: (path) async {
          throw IdentityFileReadException(
            path,
            FileSystemException('No such file', path),
          );
        },
      ),
    );

    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();

    // The ARB sentence wraps the OS detail; the dialog stays up for retry.
    expect(
      find.textContaining('Could not read the key file'),
      findsOneWidget,
    );
    expect(find.text('Connect'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('cancel answers null — the resolution fails without a secret', (
    tester,
  ) async {
    await _open(tester, _Harness(_passwordData));

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('result:'), findsNothing);
  });

  testWidgets('an unavailable vault explains itself before the fields', (
    tester,
  ) async {
    await _open(
      tester,
      _Harness(_passwordData, vaultUnavailable: true),
    );

    expect(
      find.textContaining('the OS keyring is locked or missing'),
      findsOneWidget,
    );
    // The banner never blocks manual entry.
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
  });

  testWidgets('an empty key-file path does not attempt a read', (
    tester,
  ) async {
    var reads = 0;
    await _open(
      tester,
      _Harness(
        const CredentialPromptData(
          host: 'example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.privateKey,
        ),
        readKeyFile: (path) async {
          reads++;
          return 'PEM';
        },
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, 'Key file'), '   ');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(reads, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
