import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';

/// A one-field name prompt (rename, new group, Save to Servers…). The
/// field owns its controller through the pop animation — an external
/// controller disposed at `await` return would be torn down under the
/// still-animating route. Returns the trimmed name, or null when
/// cancelled.
Future<String?> showNamePrompt(
  BuildContext context, {
  required String title,
  required String fieldLabel,
  required Key fieldKey,
  required Key saveKey,
  String initial = '',
}) {
  final l10n = AppLocalizations.of(context);
  var text = initial;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      var canSave = text.trim().isNotEmpty;
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: TextFormField(
            key: fieldKey,
            initialValue: initial,
            autofocus: true,
            decoration: InputDecoration(labelText: fieldLabel),
            onChanged: (value) {
              text = value;
              setState(() => canSave = text.trim().isNotEmpty);
            },
            onFieldSubmitted: (_) {
              if (canSave) Navigator.of(dialogContext).pop(text.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.tabCloseConfirmCancel),
            ),
            FilledButton(
              key: saveKey,
              onPressed: canSave
                  ? () => Navigator.of(dialogContext).pop(text.trim())
                  : null,
              child: Text(l10n.saveFavoriteSave),
            ),
          ],
        ),
      );
    },
  );
}

/// `user@host` (with a non-default port) from a live identity, or the
/// bookmark's label when it carries none — never the raw Quick Connect
/// input, which may have carried a stripped password.
String sessionEndpointLabel(Bookmark bookmark) {
  final identity = bookmark.server?.identity;
  if (identity == null) return bookmark.label;
  final host = identity.port == 22
      ? identity.host
      : '${identity.host}:${identity.port}';
  return identity.username.isEmpty ? host : '${identity.username}@$host';
}

/// The endpoint a saved server and a live session are matched on
/// (`user@host:port`, host case-folded): once a stored server carries a
/// session's endpoint, that session counts as saved — the sidebar's
/// italic row retires and the pane's "Not saved" banner leaves.
String? sessionEndpointKey(Bookmark bookmark) {
  final identity = bookmark.server?.identity;
  if (identity == null) return null;
  return '${identity.username}@${identity.host.toLowerCase()}:'
      '${identity.port}';
}

/// "Save to Servers…" for a live Quick Connect session (10 §5): the
/// sidebar's italic row and the pane's "Not saved" banner run this one
/// flow — the name prompt, prefilled with the live endpoint. Returns the
/// chosen name, or null when cancelled; the caller saves it.
Future<String?> promptSaveToServers(
  BuildContext context,
  Bookmark live, {
  required Key fieldKey,
  required Key saveKey,
}) {
  final l10n = AppLocalizations.of(context);
  return showNamePrompt(
    context,
    title: l10n.sidebarSaveToServersTitle,
    fieldLabel: l10n.saveFavoriteNameLabel,
    fieldKey: fieldKey,
    saveKey: saveKey,
    initial: sessionEndpointLabel(live),
  );
}
