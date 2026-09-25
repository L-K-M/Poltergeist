// The desktop Settings window's whole app. Its engine starts the same `main`
// as the app's with [settingsWindowArgument], and `main` hands over to this
// instead of starting a second Poltergeist: no stores, no engine session, no
// window lifecycle — only the Settings sections over the app's models,
// reached through the link (services/settings_window/).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_localizations.dart';
import 'services/settings_window/remote_settings.dart';
import 'services/settings_window/settings_window_link.dart';
import 'theme/app_theme.dart';
import 'ui/selected_tab_view.dart';
import 'ui/settings/backup_settings.dart';
import 'ui/settings/editor_settings.dart';
import 'ui/settings/general_settings.dart';
import 'ui/settings/preview_settings.dart';

Future<void> runSettingsWindow() async {
  RemoteSettings? remote;
  try {
    remote = await RemoteSettings.connect();
  } on Object catch (error, stackTrace) {
    // Started without the app to answer; the window says so. Reported too,
    // so a broken handshake is told apart from a window started by hand.
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stackTrace),
    );
  }
  runApp(SettingsWindowApp(remote: remote));
}

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key, required this.remote});

  /// Null when the app did not answer.
  final RemoteSettings? remote;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  /// Hands a request to quit the application to the app's isolate, whose
  /// quit guard and exit flush decide it: see
  /// [RemoteSettings.requestAppExit].
  AppLifecycleListener? _exitRequests;

  @override
  void initState() {
    super.initState();
    final remote = widget.remote;
    if (remote != null) {
      _exitRequests = AppLifecycleListener(
        onExitRequested: remote.requestAppExit,
      );
    }
  }

  @override
  void dispose() {
    _exitRequests?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.remote;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => AppLocalizations.of(context).settingsTitle,
      theme: buildPoltergeistTheme(Brightness.light),
      darkTheme: buildPoltergeistTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: remote == null
          ? const _Message(unreachable: true)
          : ListenableBuilder(
              listenable: Listenable.merge([remote, remote.page]),
              builder: (context, _) {
                final page = remote.page.value;
                if (remote.lost) return const _Message(unreachable: true);
                return page == null
                    // Hidden: no screen, so nothing typed into it outlives
                    // the window being closed.
                    ? const Scaffold()
                    : SettingsWindowScreen(
                        key: ValueKey(page.generation),
                        remote: remote,
                        initialTab: page.tab,
                      );
              },
            ),
    );
  }
}

/// The Settings sections as tabs: those the app has, in
/// [SettingsWindowTab] order.
class SettingsWindowScreen extends StatefulWidget {
  const SettingsWindowScreen({
    super.key,
    required this.remote,
    required this.initialTab,
  });

  final RemoteSettings remote;
  final SettingsWindowTab initialTab;

  @override
  State<SettingsWindowScreen> createState() => _SettingsWindowScreenState();
}

class _SettingsWindowScreenState extends State<SettingsWindowScreen>
    with SingleTickerProviderStateMixin {
  /// Which tabs exist is fixed for the app's run: each follows a seam the
  /// app either has or has not.
  late final List<SettingsWindowTab> _tabs = [
    if (widget.remote.general != null) SettingsWindowTab.general,
    if (widget.remote.editors != null || widget.remote.previewDownloads != null)
      SettingsWindowTab.editing,
    if (widget.remote.backup != null) SettingsWindowTab.sync,
  ];

  late final TabController _controller = TabController(
    length: _tabs.length,
    initialIndex: _indexOf(widget.initialTab),
    vsync: this,
  );
  StreamSubscription<SettingsWindowTab>? _tabRequests;

  int _indexOf(SettingsWindowTab tab) {
    final index = _tabs.indexOf(tab);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _tabRequests = widget.remote.tabRequests.listen(
      (tab) => _controller.animateTo(_indexOf(tab)),
    );
  }

  @override
  void dispose() {
    unawaited(_tabRequests?.cancel());
    _controller.dispose();
    super.dispose();
  }

  String _label(AppLocalizations l10n, SettingsWindowTab tab) => switch (tab) {
    SettingsWindowTab.general => l10n.settingsGeneralTab,
    SettingsWindowTab.editing => l10n.settingsEditingTab,
    SettingsWindowTab.sync => l10n.settingsSyncTab,
  };

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) return const _Message(unreachable: false);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 0,
        bottom: TabBar(
          controller: _controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final tab in _tabs) Tab(text: _label(l10n, tab))],
        ),
      ),
      body: ListenableBuilder(
        listenable: widget.remote,
        builder: (context, _) => SelectedTabView(
          controller: _controller,
          children: [for (final tab in _tabs) _page(tab)],
        ),
      ),
    );
  }

  Widget _page(SettingsWindowTab tab) {
    final remote = widget.remote;
    final List<Widget> children;
    switch (tab) {
      case SettingsWindowTab.general:
        children = [GeneralSection(settings: remote.general!)];
      case SettingsWindowTab.editing:
        final editors = remote.editors;
        final preview = remote.previewDownloads;
        children = [
          if (editors != null)
            EditorsSettingsSection(
              controller: editors,
              picker: remote.pickEditor,
            ),
          if (editors != null && preview != null) const SizedBox(height: 20),
          if (preview != null) PreviewDownloadsSection(settings: preview),
        ];
      case SettingsWindowTab.sync:
        children = [
          BackupSettingsSection(service: remote.backup!, gate: remote.gate),
        ];
    }
    // The dialogs' 560 px column, centred in a window the user may widen.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          key: PageStorageKey(tab),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: children,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.unreachable});

  final bool unreachable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            unreachable
                ? l10n.settingsWindowUnreachable
                : l10n.settingsWindowEmpty,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
