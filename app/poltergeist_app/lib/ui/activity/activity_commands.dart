import 'package:flutter/material.dart';

import '../../services/activity_panel_controller.dart';
import '../../services/registered_command.dart';

const kQueueTogglePauseCommandId = 'queue.togglePause';

/// The transfer-queue commands (02 §6/§8.1): `queue.togglePause` is the
/// panel header's toggle expressed as a registered command — the §8.1
/// note demands a menu path, so it sits in the Commands menu behind the
/// transfer block's trailing slot (02 §9 lists Pause/Resume Transfers
/// last).
List<RegisteredCommand> buildActivityCommands({
  required ActivityPanelController? activity,
}) {
  return [
    RegisteredCommand(
      id: kQueueTogglePauseCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.queueTogglePauseLabel,
      icon: Icons.pause_circle_outline,
      // No queue seam → nothing to pause; the row stays visible-but-
      // disabled rather than vanishing (a registered command keeps its
      // menu path either way).
      enabled: () => activity?.queue != null,
      disabledReason: (l10n) => l10n.commandDisabledNoQueue,
      run: (_) async {
        activity?.toggleQueuePause();
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.server,
        order: 70,
        group: 4,
      ),
    ),
  ];
}
