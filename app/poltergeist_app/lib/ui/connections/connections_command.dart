import 'package:flutter/material.dart';

import '../../services/connection_status_controller.dart';
import '../../services/registered_command.dart';
import 'connections_view.dart';

/// The registered id of the Connections surface. 02 §8.1's `view.*` group:
/// opening a surface is a view action. No default shortcut — the v1 table
/// binds none for it — and M5 replaces the route with the sidebar's permanent
/// Connections section.
const kConnectionsCommandId = 'view.connections';

/// The command that opens the Connections surface (D21: the toolbar renders
/// registered commands, it never hard-codes a button).
RegisteredCommand buildConnectionsCommand({
  required ConnectionStatusController controller,
  required bool Function() enabled,
  void Function(ConnectionServer server)? onReviewBlocked,
  void Function(ConnectionServer server)? onOpenInPane,
}) {
  return RegisteredCommand(
    id: kConnectionsCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.connectionsTitle,
    icon: Icons.lan_outlined,
    enabled: enabled,
    run: (context) => _openConnections(
      context,
      controller,
      onReviewBlocked,
      onOpenInPane,
    ),
  );
}

/// Pushes the surface and stays pending until it pops, so the shell's
/// one-command-session guard covers this route like every other.
Future<void> _openConnections(
  BuildContext context,
  ConnectionStatusController controller,
  void Function(ConnectionServer server)? onReviewBlocked,
  void Function(ConnectionServer server)? onOpenInPane,
) async {
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ConnectionsView(
        controller,
        onReviewBlocked: onReviewBlocked,
        onOpenInPane: onOpenInPane,
      ),
    ),
  );
}
