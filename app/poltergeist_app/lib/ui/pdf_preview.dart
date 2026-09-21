import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../l10n/app_localizations.dart';
import 'preview_panel.dart' show PreviewPdfBuilder;

/// 06 §5.2's PDF row cap: the panel renders the first
/// `min(20, M)` pages, headed `Page 1–N of M`, and the truncation bar
/// appears only when the document actually has more — a 5-page PDF
/// never reads `1–20 of 5`.
const previewPdfPageLimit = 20;

/// The [PreviewPanel.pdfRenderer] production binding (06 §5.2's
/// `PreviewRenderer` seam): pdfrx-backed page rasterization.
/// `PdfDocumentViewBuilder` owns the document lifecycle (autoDispose)
/// and reports open failures through its error builder — a corrupt or
/// password-locked PDF shows the error body, not a crash.
// Typed as the seam itself so the binding is assignability-checked
// against [PreviewPdfBuilder], not just structurally compatible.
// ignore: prefer_function_declarations_over_variables
final PreviewPdfBuilder pdfPreviewBuilder =
    (context, file, {onOpenExternal}) =>
        PdfPreviewView(file: file, onOpenExternal: onOpenExternal);

/// The docked panel's PDF surface: a vertical strip of rasterized
/// pages with the `Page 1–N of M` header and the external-Open
/// truncation bar (the editor refuses binary files, so the affordance
/// launches the real file — never the cache path — through the panel's
/// own open seam).
class PdfPreviewView extends StatelessWidget {
  const PdfPreviewView({
    super.key,
    required this.file,
    this.onOpenExternal,
  });

  final File file;

  /// The truncation bar's `Open` — routed by the panel onto the focused
  /// entry's external open, never a launch of the cache path (06 §5.3's
  /// open-boundary rule).
  final VoidCallback? onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PdfDocumentViewBuilder.file(
      file.path,
      builder: (context, document) {
        if (document == null) {
          // Progressive load — pdfrx reports a null document until the
          // first page's structure is ready.
          return const Center(child: CircularProgressIndicator());
        }
        final total = document.pages.length;
        final shown = total < previewPdfPageLimit
            ? total
            : previewPdfPageLimit;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: 14,
                top: 6,
                bottom: 6,
              ),
              child: Text(
                l10n.previewPdfPageRange(shown, total),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (total > previewPdfPageLimit)
              _PdfTruncationBar(
                label: l10n.previewTruncatedLabel,
                actionLabel: l10n.previewOpenLabel,
                onAction: onOpenExternal,
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsetsDirectional.only(
                  start: 14,
                  end: 10,
                  bottom: 14,
                ),
                itemCount: shown,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => Semantics(
                  label: l10n.previewPdfPageLabel(index + 1, total),
                  image: true,
                  child: AspectRatio(
                    // The page's point size sets the strip's aspect —
                    // an unbounded page would leave the scroll layout
                    // unresolved. Width/height are guesses until the
                    // page loads, which is fine for a preview rail.
                    aspectRatio: document.pages[index].height <= 0
                        ? 1.0
                        : document.pages[index].width /
                            document.pages[index].height,
                    child: PdfPageView(
                      document: document,
                      pageNumber: index + 1,
                      alignment: Alignment.topCenter,
                      // The rail is ~300 px wide; 150 dpi keeps the
                      // raster sharp on 2x displays without the memory
                      // the default 300 dpi would cost per page.
                      maximumDpi: 150,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      errorBuilder: (context, error, stackTrace) => Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          l10n.previewPdfFailed,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

}

class _PdfTruncationBar extends StatelessWidget {
  const _PdfTruncationBar({
    required this.label,
    required this.actionLabel,
    required this.onAction,
  });

  final String label;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      color: colors.surfaceContainerHighest,
      padding: const EdgeInsetsDirectional.only(
        start: 14,
        end: 8,
        top: 6,
        bottom: 6,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (onAction != null)
            TextButton(
              key: const ValueKey('preview.pdf.open'),
              onPressed: onAction,
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }
}
