import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/connection_status_panel.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Cancellation targets a stub subscription; [emit] still models an
/// already-queued callback from the replaced stream.
class _LateStream<T> extends Stream<T> {
  void Function(T)? _listener;

  void emit(T value) => _listener?.call(value);

  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _listener = onData;
    return StreamController<T>().stream.listen(
      null,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class _LateHost extends StatelessWidget {
  final String serverId;
  final Stream<ServerStatus> states;
  final Stream<ConnectionLogEvent> log;

  const _LateHost({
    required this.serverId,
    required this.states,
    required this.log,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ConnectionStatusPanel(serverId: serverId, states: states, log: log),
    ),
  );
}

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  var serverId = 's1';
  var statesController = StreamController<ServerStatus>.broadcast();
  var logController = StreamController<ConnectionLogEvent>.broadcast();
  final _retiredControllers = <StreamController<Object?>>[];
  int retries = 0;

  void replaceStreams({required String serverId}) {
    _retiredControllers.add(statesController);
    _retiredControllers.add(logController);
    setState(() {
      this.serverId = serverId;
      statesController = StreamController<ServerStatus>.broadcast();
      logController = StreamController<ConnectionLogEvent>.broadcast();
    });
  }

  @override
  void dispose() {
    statesController.close();
    logController.close();
    for (final controller in _retiredControllers) {
      controller.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ConnectionStatusPanel(
          serverId: serverId,
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

  testWidgets('awaiting the first status never flashes a failure', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Connection failed'), findsNothing);
  });

  testWidgets('new stream props replace stale status and transcript', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    state.statesController.add(
      const ServerStatus(ServerConnectionState.connected),
    );
    state.logController.add(
      ConnectionLogEvent(serverId: 's1', lines: ['old transcript']),
    );
    await tester.pump();

    state.replaceStreams(serverId: 's2');
    await tester.pump();
    expect(find.text('Connecting…'), findsOneWidget);

    state.statesController.add(
      const ServerStatus(
        ServerConnectionState.disconnected,
        detail: 'New failure.',
      ),
    );
    state.logController.add(
      ConnectionLogEvent(serverId: 's2', lines: ['new transcript']),
    );
    await tester.pump();

    expect(find.text('New failure.'), findsOneWidget);
    await _expandLog(tester);
    expect(find.textContaining('new transcript'), findsOneWidget);
    expect(find.textContaining('old transcript'), findsNothing);
  });

  testWidgets('late events from replaced streams are ignored', (tester) async {
    final oldStates = _LateStream<ServerStatus>();
    final oldLog = _LateStream<ConnectionLogEvent>();
    await tester.pumpWidget(
      _LateHost(serverId: 's1', states: oldStates, log: oldLog),
    );

    final newStates = _LateStream<ServerStatus>();
    final newLog = _LateStream<ConnectionLogEvent>();
    await tester.pumpWidget(
      _LateHost(serverId: 's2', states: newStates, log: newLog),
    );

    newStates.emit(
      const ServerStatus(
        ServerConnectionState.disconnected,
        detail: 'Current failure.',
      ),
    );
    newLog.emit(
      ConnectionLogEvent(serverId: 's2', lines: ['current transcript']),
    );

    // Model callbacks already queued when cancellation began.
    oldStates.emit(
      const ServerStatus(
        ServerConnectionState.blocked,
        detail: 'Stale failure.',
      ),
    );
    // Deliberately match the new server: only the generation guard rejects it.
    oldLog.emit(
      ConnectionLogEvent(serverId: 's2', lines: ['stale transcript']),
    );
    await tester.pump();

    expect(find.text('Current failure.'), findsOneWidget);
    expect(find.text('Stale failure.'), findsNothing);
    await _expandLog(tester);
    expect(find.textContaining('current transcript'), findsOneWidget);
    expect(find.textContaining('stale transcript'), findsNothing);
  });

  testWidgets('connecting renders the live transcript as it arrives', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());

    tester
        .state<_HostState>(find.byType(_Host))
        .statesController
        .add(const ServerStatus(ServerConnectionState.connecting));
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Connection log'), findsOneWidget);

    await _expandLog(tester);
    // Collapsed children build lazily: the empty placeholder appears only
    // once the tile is open.
    expect(find.text('(no log captured)'), findsOneWidget);
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .reverse,
      isTrue,
    );

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
        .add(
          const ServerStatus(
            ServerConnectionState.blocked,
            detail: 'Host key for example.com:22 has changed.',
          ),
        );
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
            clipboardText = (message.arguments as Map)['text'] as String?;
          case 'Clipboard.getData':
            return clipboardText == null ? null : {'text': clipboardText};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
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
    const totalLines = 500;
    const retainedLines = 400; // Mirrors the panel's transcript cap.
    state.logController.add(
      ConnectionLogEvent(
        serverId: 's1',
        lines: [for (var i = 0; i < totalLines; i++) 'line $i'],
      ),
    );
    await tester.pump();
    await _expandLog(tester);

    expect(find.textContaining('line 0'), findsNothing);
    expect(
      find.textContaining('line ${totalLines - retainedLines - 1}'),
      findsNothing,
    );
    expect(
      find.textContaining('line ${totalLines - retainedLines}'),
      findsOneWidget,
    );
    expect(find.textContaining('line ${totalLines - 1}'), findsOneWidget);
  });
}
