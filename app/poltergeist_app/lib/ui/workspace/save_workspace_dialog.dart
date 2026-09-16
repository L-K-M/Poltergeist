import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// `workspace.save`'s name prompt (02 §3): a small dialog asking for the
/// workspace's label. The Save action stays disabled while the trimmed
/// field is empty — no validation error string needed.
class SaveWorkspaceDialog extends StatefulWidget {
  const SaveWorkspaceDialog({super.key});

  @override
  State<SaveWorkspaceDialog> createState() => _SaveWorkspaceDialogState();
}

class _SaveWorkspaceDialogState extends State<SaveWorkspaceDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _field.text.trim();
    if (label.isEmpty) return;
    Navigator.of(context).pop(label);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.workspaceSaveTitle),
      content: TextField(
        key: const Key('workspaceSave.name'),
        controller: _field,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.workspaceNameField),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.workspaceSaveCancel),
        ),
        ListenableBuilder(
          listenable: _field,
          builder: (context, _) => FilledButton(
            onPressed: _field.text.trim().isEmpty ? null : _submit,
            child: Text(l10n.workspaceSaveAction),
          ),
        ),
      ],
    );
  }
}
