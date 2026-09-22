// The `app.settings` surface's first slice (02 §10's five-tab Settings
// screen lands later; until then each section mounts as a bounded
// dialog like Settings → Backup). The General tab's first row is D19's
// update-check opt-out — a switch writing through the shell's
// persist-first sink, reverting on a failed write.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../top_toast.dart';

/// The live value and write sink the General section needs — assembled
/// by the shell so the dialog reads fresh state at open and never
/// captures a stale controller. [onCheckForUpdatesChanged] must throw
/// on persist failure so the switch can revert (the immediate-persist
/// idiom 06 §8 cross-references).
final class GeneralSettings {
  const GeneralSettings({
    required this.checkForUpdates,
    required this.onCheckForUpdatesChanged,
  });

  /// Live D19 update-check opt-out state (ON = the check may run).
  final bool checkForUpdates;

  /// Applies + persists a new toggle value. Throws on persist failure.
  final Future<void> Function(bool enabled) onCheckForUpdatesChanged;
}

/// The bounded `app.settings` dialog: today the General section alone;
/// the remaining 02 §10 tabs join this surface as their slices land.
Future<void> showGeneralSettingsDialog(
  BuildContext context, {
  required GeneralSettings settings,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) {
    final l10n = AppLocalizations.of(dialogContext);
    return AlertDialog(
      key: const ValueKey('general.settings.dialog'),
      title: Text(l10n.settingsTitle),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: GeneralSection(settings: settings),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('general.settings.close'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.editorSettingsClose),
        ),
      ],
    );
  },
);

/// The 02 §10 General tab's rows. Each field commits through its sink
/// immediately; a failed write reverts the field and reports the error
/// rather than leaving the UI ahead of the store.
class GeneralSection extends StatefulWidget {
  const GeneralSection({super.key, required this.settings});

  final GeneralSettings settings;

  @override
  State<GeneralSection> createState() => _GeneralSectionState();
}

class _GeneralSectionState extends State<GeneralSection> {
  late bool _checkForUpdates = widget.settings.checkForUpdates;

  Future<void> _commitCheckForUpdates(bool value) async {
    setState(() => _checkForUpdates = value);
    try {
      await widget.settings.onCheckForUpdatesChanged(value);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (!mounted) return;
      setState(() => _checkForUpdates = !value);
      showTopToastIn(context, message: error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.settingsGeneralSection,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SwitchListTile(
          key: const ValueKey('updates.checkEnabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.updateCheckEnabledLabel),
          subtitle: Text(l10n.updateCheckEnabledSubtitle),
          value: _checkForUpdates,
          onChanged: (value) =>
              unawaited(_commitCheckForUpdates(value)),
        ),
      ],
    );
  }
}
