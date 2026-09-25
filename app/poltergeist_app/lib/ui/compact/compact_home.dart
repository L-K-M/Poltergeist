import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../../theme/app_theme.dart';
import '../settings/app_settings_command.dart' show kAppSettingsCommandId;
import 'compact_command_sheet.dart';
import 'compact_posture.dart';

/// D32 §9's Home: the sidebar, full screen, under an app bar with the
/// product name, the rows' density switch (D33), Settings, and ⋮.
/// [sidebar] is the shared sidebar in its home presentation (search bar,
/// the three sections, the "+" FAB); this widget adds only the app-level
/// chrome around it.
///
/// Home's ⋮ renders the registry's APP-scoped commands: a pane or
/// selection verb has nothing to act on from here (the panes are one
/// screen away), and offering it would act on a pane the user cannot
/// see.
class CompactHome extends StatelessWidget {
  const CompactHome({
    super.key,
    required this.sidebar,
    required this.commands,
    required this.onRunCommand,
    this.densitySwitch,
  });

  final Widget sidebar;

  /// The sidebar's density switch, drawn before Settings; null draws
  /// none (no sidebar controller to set).
  final Widget? densitySwitch;
  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRunCommand;

  RegisteredCommand? _command(String id) {
    for (final command in commands) {
      if (command.id == id) return command;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final settings = _command(kAppSettingsCommandId);
    final appCommands = [
      for (final command in commands)
        if (command.scope == CommandScope.app) command,
    ];
    // The page surface, like the browser Home pushes: the two screens
    // read as one app rather than a sidebar and a pane.
    return Scaffold(
      key: const ValueKey(CompactKey.home),
      backgroundColor: chrome.paneBackground,
      appBar: AppBar(
        backgroundColor: chrome.paneBackground,
        // Flat under a scrolled list: the search bar below is part of the
        // header, and a tint on the bar alone would split the two.
        scrolledUnderElevation: 0,
        title: Text(l10n.appTitle),
        actions: [
          if (densitySwitch case final densitySwitch?)
            Padding(
              key: const ValueKey(CompactKey.homeDensity),
              padding: const EdgeInsetsDirectional.only(end: 4),
              child: Center(child: densitySwitch),
            ),
          if (settings != null)
            IconButton(
              key: const ValueKey(CompactKey.homeSettings),
              tooltip: settings.label(l10n),
              onPressed: settings.enabled()
                  ? () => unawaited(onRunCommand(settings))
                  : null,
              icon: const Icon(Icons.settings_outlined),
            ),
          IconButton(
            key: const ValueKey(CompactKey.homeMore),
            tooltip: l10n.compactMoreOptions,
            onPressed: () => unawaited(
              showCompactCommandSheet(
                context,
                title: l10n.appTitle,
                commands: appCommands,
                onRun: onRunCommand,
              ),
            ),
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: sidebar,
    );
  }
}
