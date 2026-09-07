// Ported from Séance app/seance_app/lib/ui/host_key_dialog.dart @ a9add15; see docs/PORTS.md.
// Divergence: strings localize through ARB (D20) and the decision payload is
// the engine protocol's HostKeyPromptData instead of seance_core's
// HostKeyDecision (prompts cross the isolate as plain data, 03 §5).
import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';

/// Shows the trust-on-first-use prompt. On a *changed* key this is a hard,
/// visually alarming block that requires explicit re-pinning — never a
/// one-click dismiss (D18). Returns true to trust (and pin) the presented
/// key.
Future<bool> showHostKeyDialog(
  BuildContext context,
  HostKeyPromptData data, {
  GlobalKey? dialogKey,
}) async {
  final changed = data.pinnedFingerprintSha256 != null;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      final l10n = AppLocalizations.of(context);
      void close(bool accepted) {
        if (ModalRoute.of(context)?.isCurrent != true) return;
        Navigator.pop(context, accepted);
      }

      return AlertDialog(
        key: dialogKey,
        icon: Icon(
          changed ? Icons.gpp_bad : Icons.verified_user_outlined,
          color: changed ? scheme.error : null,
        ),
        title: Text(
          changed ? l10n.hostKeyChangedTitle : l10n.hostKeyUnknownTitle,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (changed)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.hostKeyChangedWarning(data.host),
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            Text(l10n.hostKeyEndpoint(data.host, data.port)),
            const SizedBox(height: 8),
            _Fingerprint(
              label: changed
                  ? l10n.hostKeyNewLabel
                  : l10n.hostKeyFingerprintLabel,
              type: data.keyType,
              value: data.fingerprintSha256,
            ),
            if (changed) ...[
              const SizedBox(height: 8),
              _Fingerprint(
                label: l10n.hostKeyPreviousLabel,
                type: data.keyType,
                value: data.pinnedFingerprintSha256!,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => close(false),
            child: Text(l10n.hostKeyCancel),
          ),
          FilledButton(
            style: changed
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => close(true),
            child: Text(
              changed ? l10n.hostKeyTrustNewKey : l10n.hostKeyTrustConnect,
            ),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

class _Fingerprint extends StatelessWidget {
  final String label;
  final String type;
  final String value;

  const _Fingerprint({
    required this.label,
    required this.type,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        SelectableText(
          '$type\n$value',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
    );
  }
}
