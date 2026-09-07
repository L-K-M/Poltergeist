import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/connection_status_panel.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final statesController = StreamController<ServerStatus>.broadcast();
  final logController = StreamController<ConnectionLogEvent>.broadcast();
  int retries = 0;

  @override
  void dispose() {
    statesController.close();
    logController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ConnectionStatusPanel(
          serverId: 's1',
          states: statesController.stream,
          log: logController.stream,
          onRetry: () => retries++,
        ),
      ),
    );
  }
}

/// Opens the collapsed transcript (children build lazily — Séance's
/// `_ConnectionLogView` starts collapsed too) using fixed pumps:
/// `pumpAndSettle` never settles while the connecting/reconnecting
/// spinner animates.
Future<void> _expandLog(WidgetTester tester) async {
  await tester.tap(find.text('Connection log'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connecting renders the live transcript as it arrives', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());

    tester.state<_HostState>(find.byType(_Host)).statesController.add(
          const ServerStatus(ServerConnectionState.connecting),
        );
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Connection log'), findsOneWidget);

    await _expandLog(tester);
    // Collapsed children build lazily: the empty placeholder appears only
    // once the tile is open.
    expect(find.text('(no log captured)'), findsOneWidget);

    final state = tester.state<_HostState>(find.byType(_Host));
    state.logController.add(
      ConnectionLogEvent(serverId: 's1', lines: ['tcp connect', 'kex done']),
    );
    await tester.pump();

    expect(find.textContaining('tcp connect'), findsOneWidget);
    expect(find.textContaining('kex done'), findsOneWidget);
  });

  testWidgets('a failure keeps the transcript and shows the one-liner', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));

    state.statesController.add(
      const ServerStatus(ServerConnectionState.connecting),
    );
    state.logController.add(
      ConnectionLogEvent(serverId: 's1', lines: ['tcp connect']),
    );
    await tester.pump();

    state.statesController.add(
      const ServerStatus(
        ServerConnectionState.disconnected,
        detail: 'Connection refused.',
      ),
    );
    await tester.pump();

    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Connection refused.'), findsOneWidget);

    await _expandLog(tester);
    // The transcript stays visible on failure (07 §3.3).
    expect(find.textContaining('tcp connect'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(state.retries, 1);
  });

  testWidgets('a block shows the alarming heading and its reason', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    tester
        .state<_HostState>(find.byType(_Host))
        .statesController
        .add(const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key for example.com:22 has changed.',
        ));
    await tester.pump();

    expect(find.text('Connection blocked'), findsOneWidget);
    expect(find.textContaining('has changed'), findsOneWidget);
    // Blocked has no retry: the review happens at the next connect prompt.
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('reconnecting says so', (tester) async {
    await tester.pumpWidget(const _Host());
    tester
        .state<_HostState>(find.byType(_Host))
        .statesController
        .add(const ServerStatus(ServerConnectionState.reconnecting));
    await tester.pump();

    expect(find.text('Reconnecting…'), findsOneWidget);
  });

  testWidgets('connected renders nothing', (tester) async {
    await tester.pumpWidget(const _Host());
    tester
        .state<_HostState>(find.byType(_Host))
        .statesController
        .add(const ServerStatus(ServerConnectionState.connected));
    await tester.pump();

    expect(find.byType(ConnectionStatusPanel), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Connection failed'), findsNothing);
  });

  testWidgets('copy writes the transcript to the clipboard', (tester) async {
    // flutter_tester answers no platform-channel clipboard call: mock both
    // directions and verify the widget wrote what it copied.
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (message) async {
        switch (message.method) {
          case 'Clipboard.setData':
            clipboardText = message.arguments['text'] as String?;
          case 'Clipboard.getData':
            return clipboardText == null ? null : {'text': clipboardText};
        }
        return null;
      },
    );

    await tester.pumpWidget(const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));

    state.statesController.add(
      const ServerStatus(ServerConnectionState.disconnected),
    );
    state.logController.add(
      ConnectionLogEvent(serverId: 's1', lines: ['line 1', 'line 2']),
    );
    await tester.pump();

    await _expandLog(tester);
    await tester.tap(find.text('Copy'));
    await tester.pump();

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    expect(data?.text, 'line 1\nline 2');
  });

  testWidgets('transcript lines from other servers are ignored', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));

    state.statesController.add(
      const ServerStatus(ServerConnectionState.connecting),
    );
    state.logController.add(
      ConnectionLogEvent(serverId: 's2', lines: ['other server']),
    );
    await tester.pump();

    await _expandLog(tester);
    expect(find.textContaining('other server'), findsNothing);
  });

  testWidgets('the retained transcript is bounded, dropping the oldest', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));

    state.statesController.add(
      const ServerStatus(ServerConnectionState.connecting),
    );
    state.logController.add(
      ConnectionLogEvent(
        serverId: 's1',
        lines: [for (var i = 0; i < 500; i++) 'line $i'],
      ),
    );
    await tester.pump();
    await _expandLog(tester);

    expect(find.textContaining('line 0'), findsNothing);
    expect(find.textContaining('line 99'), findsNothing);
    expect(find.textContaining('line 100'), findsOneWidget);
    expect(find.textContaining('line 499'), findsOneWidget);
  });
}
