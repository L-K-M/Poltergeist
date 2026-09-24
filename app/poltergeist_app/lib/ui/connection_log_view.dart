// Ported from Séance app/seance_app/lib/ui/connection_log_view.dart @
// 035b0d8 (tag v0.9.1); see docs/PORTS.md.
// Divergence: strings localize through ARB (D20); the copy failure is
// reported through ApplicationErrorReporter rather than dart:developer.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/application_error_reporter.dart';
import 'top_toast.dart';

/// A collapsible view of a raw SSH connection transcript, with a copy button.
///
/// Takes the text rather than a session so both places that show a transcript
/// — a failed terminal tab and the server editor's connection test — read the
/// same, including the "(no log captured)" placeholder and the copy affordance
/// people reach for when they are about to paste it into a bug report.
///
/// Redaction is the producer's contract, not this widget's: [text] is copied
/// and rendered verbatim, so anything a person typed into an auth prompt — a
/// password, a key passphrase, a keyboard-interactive answer — must never
/// have reached it. `SshConnectionLog` is where that is enforced, at capture
/// rather than at render, precisely so every view of a transcript inherits it
/// without knowing to.
class ConnectionLogView extends StatelessWidget {
  final String text;
  const ConnectionLogView({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(l10n.connectionLogTitle),
        childrenPadding: EdgeInsets.zero,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: text.isEmpty
                  ? null
                  // Awaited, and the toast is gated on the result landing
                  // while this is still on screen: saying "copied" for a write
                  // that failed sends someone to paste an empty bug report.
                  : () async {
                      // The write can fail — no clipboard on the platform, a
                      // plugin that is not there — and an unhandled async
                      // error is not a report of that.
                      var copied = true;
                      try {
                        await Clipboard.setData(ClipboardData(text: text));
                      } catch (error, stackTrace) {
                        // The toast says it failed; this says why, for the
                        // report that follows it.
                        ApplicationErrorReporter().report(error, stackTrace);
                        copied = false;
                      }
                      if (context.mounted) {
                        showTopToastIn(
                          context,
                          message: copied
                              ? l10n.connectionLogCopied
                              : l10n.connectionLogCopyFailed,
                        );
                      }
                    },
              icon: const Icon(Icons.copy, size: 16),
              label: Text(l10n.connectionLogCopy),
            ),
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              // Horizontally too: a transcript carries long unbreakable runs
              // (algorithm lists, base64 key material) that soft-wrap nowhere,
              // and on a narrow layout their tails painted past the card with
              // no way to reach them — the part a bug report needs.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  text.isEmpty ? l10n.connectionLogEmpty : text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    // `monospace` is a real family on Android and Linux only.
                    // Elsewhere the bare name falls back to the proportional
                    // system font, and a transcript whose columns do not line
                    // up is the thing this view exists to avoid.
                    fontFamilyFallback: ['Menlo', 'Consolas', 'Courier New'],
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
