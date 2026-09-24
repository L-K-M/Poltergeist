import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../middle_ellipsis_text.dart';
import '../panes/quick_connect_view.dart';

/// How many saved servers the Connect dialog lists above Quick Connect.
const connectDialogServerLimit = 6;

/// One saved server the Connect dialog offers as a one-click row: what
/// it shows, and the open the shell runs for it (the sidebar's own).
@immutable
final class ConnectServerChoice {
  const ConnectServerChoice({
    required this.id,
    required this.label,
    required this.detail,
    required this.mark,
    required this.open,
  });

  final String id;
  final String label;

  /// `user@host` (the port when it is not 22), shown trailing.
  final String detail;

  /// The server's 18 px mark, as the sidebar draws it.
  final Widget mark;

  /// Binds the server the way the sidebar's new-tab open does.
  final VoidCallback open;
}

/// Orders the Connect dialog's servers (10 §4: "recent servers + Quick
/// Connect"): the ones used most recently first — [recentServerIds] is
/// newest first and may repeat or name servers that no longer exist —
/// then the rest alphabetically, capped at [connectDialogServerLimit].
List<ConnectServerChoice> orderConnectChoices(
  List<ConnectServerChoice> choices,
  List<String> recentServerIds,
) {
  final rank = <String, int>{};
  for (final id in recentServerIds) {
    rank.putIfAbsent(id, () => rank.length);
  }
  final ordered = [...choices]
    ..sort((a, b) {
      final ra = rank[a.id];
      final rb = rank[b.id];
      if (ra != null || rb != null) {
        if (ra == null) return 1;
        if (rb == null) return -1;
        return ra.compareTo(rb);
      }
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
  return ordered.take(connectDialogServerLimit).toList();
}

/// D32 §4's Connect verb (⌘K): saved servers as one-click rows above the
/// launcher's Quick Connect form, so connecting never costs the user the
/// pane they are in. The address field has focus on open; ↑/↓ move a
/// highlight through the servers and Return opens the highlighted one
/// (with no highlight, Return submits the address). [onConnect] and a
/// choice's [ConnectServerChoice.open] run after the dialog has popped.
Future<void> showConnectDialog(
  BuildContext context, {
  List<ConnectServerChoice> servers = const [],
  required void Function(Bookmark bookmark, String? initialPath) onConnect,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _ConnectDialog(servers: servers, onConnect: onConnect),
  );
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.servers, required this.onConnect});

  final List<ConnectServerChoice> servers;
  final void Function(Bookmark bookmark, String? initialPath) onConnect;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  // Owned by the dialog's state, not the caller: the route's exit
  // transition keeps the field mounted after `showDialog` returns, so
  // the node must live exactly as long as the field does.
  final _focus = FocusNode();

  /// The keyboard highlight among the server rows; null means Return
  /// belongs to the address field.
  int? _highlight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _open(ConnectServerChoice choice) {
    Navigator.of(context).pop();
    choice.open();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final servers = widget.servers;
    if (servers.isEmpty) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      final current = _highlight;
      setState(() {
        // Past the last row the highlight hands Return back to the field.
        _highlight = current == null
            ? 0
            : (current + 1 < servers.length ? current + 1 : null);
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      final current = _highlight;
      setState(() {
        _highlight = current == null
            ? servers.length - 1
            : (current > 0 ? current - 1 : null);
      });
      return KeyEventResult.handled;
    }
    final highlight = _highlight;
    if (highlight != null &&
        event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      _open(servers[highlight]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final servers = widget.servers;
    return Dialog(
      key: const ValueKey('connect.dialog'),
      child: Focus(
        // Sees ↑/↓/Return before the field's own text shortcuts; never
        // takes focus itself.
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (servers.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(24, 18, 24, 6),
                  child: Text(
                    l10n.connectDialogServers,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: chrome.secondaryText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (var i = 0; i < servers.length; i++)
                  _ServerRow(
                    choice: servers[i],
                    highlighted: i == _highlight,
                    onTap: () => _open(servers[i]),
                  ),
                const SizedBox(height: 6),
                Divider(height: 1, color: chrome.separator),
              ],
              QuickConnectView(
                focusNode: _focus,
                layout: QuickConnectLayout.inline,
                onEdited: () {
                  if (_highlight != null) setState(() => _highlight = null);
                },
                onConnect: (bookmark, initialPath) {
                  Navigator.of(context).pop();
                  widget.onConnect(bookmark, initialPath);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.choice,
    required this.highlighted,
    required this.onTap,
  });

  final ConnectServerChoice choice;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final foreground = highlighted ? chrome.onSelection : null;
    return Semantics(
      button: true,
      selected: highlighted,
      label: '${choice.label}, ${choice.detail}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Material(
          color: highlighted ? chrome.selectionFill : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            key: ValueKey('connect.server.${choice.id}'),
            borderRadius: BorderRadius.circular(6),
            hoverColor: chrome.hoverFill,
            onTap: onTap,
            child: SizedBox(
              height: MediaQuery.textScalerOf(context).scale(30),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    SizedBox.square(dimension: 18, child: choice.mark),
                    const SizedBox(width: 8),
                    Expanded(
                      child: MiddleEllipsisText(
                        choice.label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        choice.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: highlighted
                              ? chrome.onSelection.withValues(alpha: 0.8)
                              : chrome.secondaryText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
