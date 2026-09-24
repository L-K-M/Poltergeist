import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../panes/quick_connect_view.dart';

/// D32 §4's Connect verb (⌘K): the launcher's quick-connect form as a
/// dialog, so connecting never costs the user the pane they are in.
/// [onConnect] runs after the dialog has popped.
Future<void> showConnectDialog(
  BuildContext context, {
  required void Function(Bookmark bookmark, String? initialPath) onConnect,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ConnectDialog(onConnect: onConnect),
  );
}

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({required this.onConnect});

  final void Function(Bookmark bookmark, String? initialPath) onConnect;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  // Owned by the dialog's state, not the caller: the route's exit
  // transition keeps the field mounted after `showDialog` returns, so
  // the node must live exactly as long as the field does.
  final _focus = FocusNode();

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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const ValueKey('connect.dialog'),
      child: QuickConnectView(
        focusNode: _focus,
        onConnect: (bookmark, initialPath) {
          Navigator.of(context).pop();
          widget.onConnect(bookmark, initialPath);
        },
      ),
    );
  }
}
