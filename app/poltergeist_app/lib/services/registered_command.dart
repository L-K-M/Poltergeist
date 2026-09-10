import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

/// Which surface a command acts on (02 §8.1).
enum CommandScope { app, pane, selection, editor }

/// One registered user action (D21: every user action is a registered
/// command; menus, shortcuts, and toolbar buttons are renderings of the
/// registry).
///
/// This is the M2 debug subset of the 02 §8.1 command model: id, scope,
/// an ARB label, enablement, an optional per-platform shortcut, and the
/// run action with its invoking [BuildContext] resolved at invocation
/// time, never captured. The M3 command registry adds CommandContext
/// resolution, menu/palette renderings, and the keyboard-completeness
/// invariant, and replaces this shape together with the debug-only
/// surface that consumes it.
class RegisteredCommand {
  const RegisteredCommand({
    required this.id,
    required this.scope,
    required this.label,
    this.enabled = _alwaysEnabled,
    required this.run,
    this.activators,
  });

  /// Dotted lowerCamel, grouped by noun (`connect.*`, `pane.*`, 02 §8.1).
  final String id;

  final CommandScope scope;

  /// The ARB-sourced label (D20); commands carry no hard-coded copy.
  final String Function(AppLocalizations) label;

  final bool Function() enabled;

  static bool _alwaysEnabled() => true;

  /// Per-platform shortcut chords; null when the command has none.
  /// The returned list is freshly built (or const) per call and must be
  /// treated as immutable — callers copy before mutating.
  final List<ShortcutActivator> Function(TargetPlatform)? activators;

  /// Executes the command with the invoking surface's [context].
  /// Implementations must not capture [context] and must re-check
  /// `context.mounted` after any `await` before using it again.
  final Future<void> Function(BuildContext context) run;
}
