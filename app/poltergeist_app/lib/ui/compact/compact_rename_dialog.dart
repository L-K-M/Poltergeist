import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_controller.dart';
import 'compact_pane_messages.dart';
import 'compact_posture.dart';

/// The compact posture's rendering of 02 §2.6's rename session: the
/// controller owns the session exactly as it does for the desktop's
/// inline editor (validation, the commit, a failure re-opening the
/// session with its typed error); this dialog is only its touch surface.
/// It closes itself when the session ends, and dismissing it cancels an
/// open session once the route is gone — a dialog can never strand a
/// live edit.
Future<void> showCompactRenameDialog(
  BuildContext context, {
  required PaneController controller,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _CompactRenameDialog(controller: controller),
  );
  // Back, the barrier, or Cancel: an edit the user walked away from must
  // not stay open behind the listing (the close guard would hold the tab
  // for it). A landed commit already ended the session.
  if (controller.renameTarget != null) controller.cancelRename();
}

class _CompactRenameDialog extends StatefulWidget {
  const _CompactRenameDialog({required this.controller});

  final PaneController controller;

  @override
  State<_CompactRenameDialog> createState() => _CompactRenameDialogState();
}

class _CompactRenameDialogState extends State<_CompactRenameDialog> {
  final _text = TextEditingController();
  bool _closing = false;

  PaneController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The desktop editor's seed rule: the stem pre-selected so a typed
    // replacement keeps the extension; dotfiles select whole.
    final name = _controller.renameSeed;
    final dot = name.lastIndexOf('.');
    _text.value = TextEditingValue(
      text: name,
      selection: dot > 0
          ? TextSelection(baseOffset: 0, extentOffset: dot)
          : TextSelection(baseOffset: 0, extentOffset: name.length),
    );
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _text.dispose();
    super.dispose();
  }

  /// The session ended (a commit landed, a navigation dropped it): the
  /// surface goes with it. A commit in flight keeps the dialog up — a
  /// refused commit re-opens the session here with its error.
  void _onControllerChanged() {
    if (!mounted) return;
    if (_controller.renameTarget == null && !_controller.inlineRenameActive) {
      _close();
      return;
    }
    setState(() {});
  }

  /// Pops THIS dialog, once. A back or barrier dismissal already popped
  /// the route (and the session cancel that follows notifies here while
  /// the exit animation runs) — popping again would take the route
  /// under the dialog with it.
  void _close() {
    if (_closing) return;
    _closing = true;
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop();
    }
  }

  void _submit() {
    if (_controller.renameTarget == null) return;
    unawaited(_controller.submitRename(_text.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _controller.renameError;
    final committing =
        _controller.inlineRenameActive && _controller.renameTarget == null;
    return AlertDialog(
      key: const ValueKey(CompactKey.renameDialog),
      title: Text(l10n.fileRenameLabel),
      content: TextField(
        key: const ValueKey(CompactKey.renameField),
        controller: _text,
        autofocus: true,
        enabled: !committing,
        textInputAction: TextInputAction.done,
        // The dialog's title names the field; a floating label would
        // only repeat it.
        decoration: InputDecoration(
          errorText: error == null ? null : compactRenameErrorText(l10n, error),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          key: const ValueKey(CompactKey.renameCancel),
          onPressed: committing ? null : _close,
          child: Text(l10n.compactCancel),
        ),
        FilledButton(
          key: const ValueKey(CompactKey.renameConfirm),
          onPressed: committing ? null : _submit,
          child: committing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.fileRenameLabel),
        ),
      ],
    );
  }
}
