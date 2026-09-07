// Ported from Séance app/seance_app/lib/ui/keyboard_interactive_dialog.dart @ a9add15; see docs/PORTS.md.
// Divergence: strings localize through ARB (D20) and the payload is the
// engine protocol's KeyboardInteractivePromptData (03 §5).
import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';

/// Prompts for keyboard-interactive auth (e.g. a 2FA/TOTP code). Returns one
/// answer per prompt, in order. An empty list cancels the attempt.
Future<List<String>> showKeyboardInteractiveDialog(
  BuildContext context,
  KeyboardInteractivePromptData data, {
  GlobalKey? dialogKey,
}) async {
  final result = await showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _KeyboardInteractiveDialog(key: dialogKey, data: data),
  );
  return result ?? const <String>[];
}

class _KeyboardInteractiveDialog extends StatefulWidget {
  const _KeyboardInteractiveDialog({required this.data, super.key});

  final KeyboardInteractivePromptData data;

  @override
  State<_KeyboardInteractiveDialog> createState() =>
      _KeyboardInteractiveDialogState();
}

class _KeyboardInteractiveDialogState
    extends State<_KeyboardInteractiveDialog> {
  // Owns the prompt controllers in its [State] so they are disposed in
  // [State.dispose] — after the route's exit animation, once the fields are
  // truly unmounted. Disposing right after `await showDialog(...)` is too
  // early: the fields stay mounted through the reverse transition and the
  // framework can still write to a controller (e.g. `clearComposing()` when
  // the focused field loses focus) — a use-after-dispose that throws in
  // debug builds whenever an IME composing region is active. Same lifecycle
  // as Séance's snippet placeholder dialog (regression there:
  // test/placeholder_dialog_test.dart; pinned here by
  // keyboard_interactive_dialog_test.dart).
  late final List<TextEditingController> _controllers = [
    for (final _ in widget.data.prompts) TextEditingController(),
  ];

  final Set<int> _revealed = {};

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _close(List<String> answers) {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.pop(context, answers);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      // Long challenges must remain reachable above the software keyboard.
      scrollable: true,
      title: Text(
        widget.data.name.isEmpty ? l10n.keyboardAuthTitle : widget.data.name,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.data.instruction.isNotEmpty) ...[
            Text(widget.data.instruction),
            const SizedBox(height: 12),
          ],
          for (var i = 0; i < widget.data.prompts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _controllers[i],
                autofocus: i == 0,
                keyboardType: TextInputType.visiblePassword,
                // Echo metadata is absent; reveal only on explicit request.
                obscureText: !_revealed.contains(i),
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: widget.data.prompts[i],
                  suffixIcon: IconButton(
                    tooltip: _revealed.contains(i)
                        ? l10n.keyboardHideAnswer
                        : l10n.keyboardShowAnswer,
                    icon: Icon(
                      _revealed.contains(i)
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(() {
                      if (!_revealed.remove(i)) _revealed.add(i);
                    }),
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _close(const <String>[]),
          child: Text(l10n.keyboardCancel),
        ),
        FilledButton(
          onPressed: () =>
              _close([for (final controller in _controllers) controller.text]),
          child: Text(l10n.keyboardSubmit),
        ),
      ],
    );
  }
}
