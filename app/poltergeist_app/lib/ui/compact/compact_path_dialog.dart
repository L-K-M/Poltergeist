import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_controller.dart';
import 'compact_posture.dart';

/// The compact posture's rendering of 02 §2.1's path field (`go.editPath`
/// and `go.toFolder`): the controller owns the session and resolves the
/// input exactly as it does for the desktop's in-header field; this
/// dialog is only its touch surface. Submitting navigates (an
/// unresolvable path lands on the pane's inline error); dismissing it
/// closes the session.
Future<void> showCompactPathDialog(
  BuildContext context, {
  required PaneController controller,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _CompactPathDialog(controller: controller),
  );
  if (controller.pathFieldOpen) controller.closePathField();
}

class _CompactPathDialog extends StatefulWidget {
  const _CompactPathDialog({required this.controller});

  final PaneController controller;

  @override
  State<_CompactPathDialog> createState() => _CompactPathDialogState();
}

class _CompactPathDialogState extends State<_CompactPathDialog> {
  late final TextEditingController _text;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // Seeded selected whole, so a keystroke replaces it (02 §2.1).
    final seed = widget.controller.pathFieldSeed;
    _text = TextEditingController(text: seed)
      ..selection = TextSelection(baseOffset: 0, extentOffset: seed.length);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _text.dispose();
    super.dispose();
  }

  /// The session closed elsewhere (a navigation, a rebind): so does the
  /// dialog — once, and only while it is still the current route.
  void _onControllerChanged() {
    if (!mounted || widget.controller.pathFieldOpen) return;
    _close();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop();
    }
  }

  void _submit() => widget.controller.submitPathField(_text.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      key: const ValueKey(CompactKey.pathDialog),
      title: Text(l10n.compactGoToFolderTitle),
      content: TextField(
        key: const ValueKey(CompactKey.pathField),
        controller: _text,
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        decoration: InputDecoration(
          hintText: l10n.panePathFieldHint,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: _close, child: Text(l10n.compactCancel)),
        FilledButton(
          key: const ValueKey(CompactKey.pathGo),
          onPressed: _submit,
          child: Text(l10n.compactGo),
        ),
      ],
    );
  }
}
