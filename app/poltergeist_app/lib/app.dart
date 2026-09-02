import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:macos_window_utils/widgets/titlebar_safe_area.dart';

import 'l10n/app_localizations.dart';
import 'services/content_size_reporter.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/workspace_shell.dart';

class PoltergeistApp extends StatelessWidget {
  const PoltergeistApp({
    super.key,
    this.initialPaneRatio = 0.5,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
    this.onContentSizeChanged,
  });

  final double initialPaneRatio;
  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;
  final ValueChanged<Size>? onContentSizeChanged;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
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
      home: TitlebarSafeArea(child: _buildWorkspace()),
    );
  }

  Widget _buildWorkspace() {
    final workspace = WorkspaceShell(
      initialPaneRatio: initialPaneRatio,
      onPaneRatioChanged: onPaneRatioChanged,
      onPaneRatioSaveError: onPaneRatioSaveError,
    );
    final callback = onContentSizeChanged;
    if (callback == null) return workspace;

    // The desktop minimum includes native chrome around this content box.
    return ContentSizeReporter(onSize: callback, child: workspace);
  }
}
