import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/quick_connect_address.dart';
import '../../services/uuid.dart';

/// The launcher's Quick Connect form (02 §2.7): the address field with
/// its visible parse interpretations, and the Connect action.
///
/// This slice lands Quick Connect as the launcher's initial content —
/// the Servers and Recent tabs ride M5's sidebar/favorites work, so no
/// tab scaffolding is built here.
///
/// Connect mints an ephemeral `adhoc:<uuid>` bookmark (03 §3.5) and
/// hands it to [onConnect], which binds a fresh tab through the existing
/// remote-connect seam (prompts, errors, and banner behavior stay owned
/// by the connect flow). The field is a real [TextField], so 02 §8.2's
/// suppression seams apply untouched: while it holds primary focus the
/// pane's single keys and the command chords stay inert, and Enter
/// submits.
class QuickConnectView extends StatefulWidget {
  const QuickConnectView({
    super.key,
    required this.onConnect,
    required this.focusNode,
  });

  /// Binds [bookmark] on a fresh tab; [initialPath] overrides the
  /// landing directory. Fire-and-forget safe: the connect flow owns all
  /// failure surfaces.
  final void Function(Bookmark bookmark, String? initialPath) onConnect;

  /// The address field's focus node, owned by the launcher: the launcher
  /// focuses the field (not the pane node) on mount when its pane is
  /// active, and an inactive pane's field never steals focus.
  final FocusNode focusNode;

  @override
  State<QuickConnectView> createState() => _QuickConnectViewState();
}

class _QuickConnectViewState extends State<QuickConnectView> {
  final _field = TextEditingController();
  QuickConnectParse _parse = parseQuickConnectAddress('');

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    var parse = parseQuickConnectAddress(value);
    final sanitized = parse.sanitizedInput;
    if (sanitized != null && sanitized != value) {
      // A pasted password: echo the stripped address, never the secret
      // (02 §2.7). Re-parsing the stripped form is stable — it carries
      // no password, so no second rewrite follows.
      _field.value = TextEditingValue(
        text: sanitized,
        selection: TextSelection.collapsed(offset: sanitized.length),
      );
      parse = parseQuickConnectAddress(sanitized);
    }
    setState(() {
      _parse = parse;
    });
  }

  void _submit() {
    final target = _parse.target;
    if (target == null) return;
    widget.onConnect(_adhocBookmark(target), target.remotePath);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final parse = _parse;
    final target = parse.target;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.quickConnectTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('quickConnect.field'),
                controller: _field,
                focusNode: widget.focusNode,
                // An address is not prose: no autocorrect, no
                // suggestions, and the URL keyboard where one exists.
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: l10n.quickConnectAddressLabel,
                  hintText: l10n.quickConnectAddressHint,
                  // The rejection hints carry an example; let them wrap
                  // instead of truncating it away.
                  errorMaxLines: 3,
                  errorText: _errorText(l10n, parse),
                ),
                textInputAction: TextInputAction.done,
                onChanged: _onChanged,
                onSubmitted: (_) => _submit(),
              ),
              for (final hint in _hintTexts(l10n, parse))
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 6),
                  child: Text(
                    hint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  key: const ValueKey('quickConnect.connect'),
                  onPressed: target == null ? null : _submit,
                  child: Text(l10n.quickConnectConnect),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rejecting issues rendered as the field error; at most one shows —
/// empty input reports nothing until the user types.
String? _errorText(AppLocalizations l10n, QuickConnectParse parse) {
  if (parse.ok) return null;
  final issues = parse.issues;
  if (issues.contains(QuickConnectIssue.ipv6NeedsBrackets)) {
    return l10n.quickConnectHintIpv6;
  }
  if (issues.contains(QuickConnectIssue.invalidPort)) {
    return l10n.quickConnectInvalidPortError;
  }
  if (issues.contains(QuickConnectIssue.unsupportedScheme)) {
    return l10n.quickConnectUnsupportedSchemeError;
  }
  if (issues.contains(QuickConnectIssue.missingHost)) {
    return l10n.quickConnectMissingHostError;
  }
  return null;
}

/// The visible interpretations rendered under the field: the port/path
/// assumptions and the password-strip notice.
List<String> _hintTexts(AppLocalizations l10n, QuickConnectParse parse) {
  final target = parse.target;
  final hints = <String>[];
  if (target != null &&
      parse.issues.contains(QuickConnectIssue.portAssumed)) {
    hints.add(
      l10n.quickConnectHintPort('${target.port}', target.host),
    );
  }
  if (target != null &&
      parse.issues.contains(QuickConnectIssue.pathAssumed)) {
    hints.add(
      l10n.quickConnectHintPath(target.remotePath ?? ''),
    );
  }
  if (parse.issues.contains(QuickConnectIssue.passwordStripped)) {
    hints.add(l10n.quickConnectPasswordStripped);
  }
  return hints;
}

/// Mints the ephemeral bookmark for [target] (03 §3.5's `adhoc:<uuid>`
/// serverId). Username may be empty — the credential prompt resolves it
/// at connect time, like an imported row without a `User`.
Bookmark _adhocBookmark(QuickConnectTarget target) {
  final id = '$quickConnectAdhocIdPrefix${uuidV4()}';
  final now = DateTime.now();
  final username = target.username;
  final label = username.isEmpty
      ? _hostLabel(target)
      : '$username@${_hostLabel(target)}';
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: target.host,
        port: target.port,
        username: username,
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: target.remotePath,
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}

String _hostLabel(QuickConnectTarget target) => target.port == 22
    ? target.host
    : '${target.host}:${target.port}';
