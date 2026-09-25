// The Sync sheet's three small follow-up dialogs (D32 §7): the
// favorite's name, the exclude-rules editor (with the engine's
// built-in patterns shown read-only), and the time-offset tolerance.
// Each is stateful so its TextEditingController outlives the exit
// animation — disposing it in `showDialog`'s continuation would leave
// the transition building against a dead controller.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// Asks for the favorite's name; null when cancelled.
Future<String?> showSyncFavoriteNameDialog(
  BuildContext context, {
  required String initialName,
}) => showDialog<String>(
  context: context,
  builder: (_) => _FavoriteNameDialog(initialName: initialName),
);

/// Edits the pair's exclude globs; null when cancelled.
Future<List<String>?> showSyncRulesDialog(
  BuildContext context, {
  required List<String> globs,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => _RulesDialog(globs: globs),
);

/// The time-offset dialog's answer.
typedef SyncTimeOffset = ({int toleranceSecs, bool ignoreHourShift});

/// The one-hour shift 05 §4 names for FAT/DST skew.
const int kSyncHourShiftSecs = 3600;

/// Edits the modification-date tolerance and the 1-hour shift; null
/// when cancelled.
Future<SyncTimeOffset?> showSyncTimeOffsetDialog(
  BuildContext context, {
  required SyncTimeOffset initial,
}) => showDialog<SyncTimeOffset>(
  context: context,
  builder: (_) => _TimeOffsetDialog(initial: initial),
);

class _FavoriteNameDialog extends StatefulWidget {
  const _FavoriteNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_FavoriteNameDialog> createState() => _FavoriteNameDialogState();
}

class _FavoriteNameDialogState extends State<_FavoriteNameDialog> {
  late final _field = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _field.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.syncFavoriteNameTitle),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const ValueKey('sync.favoriteName.field'),
          controller: _field,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.syncEditorNameLabel),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.syncCancel),
        ),
        FilledButton(
          key: const ValueKey('sync.favoriteName.save'),
          onPressed: _field.text.trim().isEmpty ? null : _submit,
          child: Text(l10n.syncEditorSave),
        ),
      ],
    );
  }
}

class _RulesDialog extends StatefulWidget {
  const _RulesDialog({required this.globs});

  final List<String> globs;

  @override
  State<_RulesDialog> createState() => _RulesDialogState();
}

class _RulesDialogState extends State<_RulesDialog> {
  late final _field = TextEditingController(text: widget.globs.join('\n'));

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  List<String> get _globs => [
    for (final line in _field.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    return AlertDialog(
      title: Text(l10n.syncRulesTitle),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('sync.rules.field'),
              controller: _field,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              style: theme.textTheme.bodyMedium?.merge(
                poltergeistMonoTextStyle,
              ),
              decoration: InputDecoration(
                helperText: l10n.syncRulesHint,
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.syncRulesDefaultsTitle,
              style: theme.textTheme.labelMedium?.copyWith(
                color: chrome.secondaryText,
              ),
            ),
            const SizedBox(height: 6),
            // The engine's compiled-in patterns (05 §3) sit after the
            // pair's rules, so no `!` line can re-include them — shown
            // read-only for exactly that reason.
            Wrap(
              key: const ValueKey('sync.rules.defaults'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final pattern in SyncIgnoreRules.appDefaults)
                  Chip(
                    label: Text(pattern),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.syncCancel),
        ),
        FilledButton(
          key: const ValueKey('sync.rules.done'),
          onPressed: () => Navigator.of(context).pop(_globs),
          child: Text(l10n.syncRulesDone),
        ),
      ],
    );
  }
}

class _TimeOffsetDialog extends StatefulWidget {
  const _TimeOffsetDialog({required this.initial});

  final SyncTimeOffset initial;

  @override
  State<_TimeOffsetDialog> createState() => _TimeOffsetDialogState();
}

class _TimeOffsetDialogState extends State<_TimeOffsetDialog> {
  late final _tolerance = TextEditingController(
    text: '${widget.initial.toleranceSecs}',
  );
  late bool _hourShift = widget.initial.ignoreHourShift;

  @override
  void dispose() {
    _tolerance.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((
    toleranceSecs:
        int.tryParse(_tolerance.text.trim()) ?? widget.initial.toleranceSecs,
    ignoreHourShift: _hourShift,
  ));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.syncTimeOffsetTitle),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('sync.timeOffset.tolerance'),
              controller: _tolerance,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l10n.syncTimeOffsetToleranceLabel,
                helperText: l10n.syncTimeOffsetToleranceHelp,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              key: const ValueKey('sync.timeOffset.hourShift'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _hourShift,
              onChanged: (value) => setState(() => _hourShift = value ?? false),
              title: Text(l10n.syncTimeOffsetHourShift),
              subtitle: Text(l10n.syncTimeOffsetHourShiftHelp),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.syncCancel),
        ),
        FilledButton(
          key: const ValueKey('sync.timeOffset.done'),
          onPressed: _submit,
          child: Text(l10n.syncRulesDone),
        ),
      ],
    );
  }
}
