import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/prompts/host_key_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

const _firstUse = HostKeyPromptData(
  host: 'example.com',
  port: 2222,
  keyType: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:presented',
);

const _changed = HostKeyPromptData(
  host: 'example.com',
  port: 2222,
  keyType: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:changed',
  pinnedFingerprintSha256: 'SHA256:original',
);

class _Harness extends StatefulWidget {
  final HostKeyPromptData data;

  const _Harness(this.data);

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool? result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(
            // The dialog needs a context *below* MaterialApp for
            // Localizations; the State's own context sits above it.
            builder:
                (context) =>
                    result == null
                        ? FilledButton(
                          onPressed: () async {
                            result = await showHostKeyDialog(
                              context,
                              widget.data,
                            );
                            if (mounted) setState(() {});
                          },
                          child: const Text('open'),
                        )
                        : Text('result:$result'),
          ),
        ),
      ),
    );
  }
}

Future<void> _open(WidgetTester tester, HostKeyPromptData data) async {
  // Reset the tree first so a reused harness state (same widget type)
  // cannot carry a stale result between openings.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(_Harness(data));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<bool> _settleResult(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final text = tester.widget<Text>(find.textContaining('result:')).data!;
  return text == 'result:true';
}

void main() {
  testWidgets('first use shows the fingerprint with trust verbs', (
    tester,
  ) async {
    await _open(tester, _firstUse);

    expect(find.text('Unknown host key'), findsOneWidget);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
      isTrue,
    );
    expect(find.text('example.com:2222'), findsOneWidget);
    expect(find.text('Fingerprint'), findsOneWidget);
    // The key type and fingerprint render as selectable monospace data.
    expect(
      find.textContaining('SHA256:presented'),
      findsOneWidget,
      reason: 'the presented fingerprint must be inspectable',
    );
    expect(find.text('Trust and connect'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    // A first-use prompt is not alarming: no warning banner.
    expect(find.textContaining('man-in-the-middle'), findsNothing);
  });

  testWidgets('first use trust returns true, cancel returns false', (
    tester,
  ) async {
    await _open(tester, _firstUse);
    await tester.tap(find.text('Trust and connect'));
    expect(await _settleResult(tester), isTrue);

    await _open(tester, _firstUse);
    await tester.tap(find.text('Cancel'));
    expect(await _settleResult(tester), isFalse);
  });

  testWidgets('a changed key is a hard, alarming block with both prints', (
    tester,
  ) async {
    await _open(tester, _changed);

    expect(find.text('HOST KEY CHANGED'), findsOneWidget);
    expect(find.textContaining('man-in-the-middle'), findsOneWidget);
    expect(find.text('New key'), findsOneWidget);
    expect(find.text('Previously trusted'), findsOneWidget);
    expect(find.textContaining('SHA256:changed'), findsOneWidget);
    expect(find.textContaining('SHA256:original'), findsOneWidget);
    expect(find.text('Trust the new key'), findsOneWidget);

    await tester.tap(find.text('Trust the new key'));
    expect(await _settleResult(tester), isTrue);
  });

  testWidgets('the dialog cannot be dismissed by tapping outside', (
    tester,
  ) async {
    await _open(tester, _firstUse);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('Unknown host key'), findsOneWidget);
  });

  testWidgets('Esc leaves the hard block up — only explicit verbs answer', (
    tester,
  ) async {
    await _open(tester, _changed);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // A changed-key review is never dismissed implicitly: the barrier is
    // not dismissible and Esc pops nothing, so trust can only come from
    // the explicit button (Séance-identical dialog semantics).
    expect(find.text('HOST KEY CHANGED'), findsOneWidget);
    expect(find.textContaining('result:'), findsNothing);
  });
}
