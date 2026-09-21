import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/pane_controller.dart';
import '../services/preview_session.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'editor_syntax.dart';
import 'panes/pane_format.dart';

/// The docked preview panel's width — a fixed-width rail like the Get
/// Info inspector (02 §1's fixed rail precedent); the adaptive-layout
/// splitter slice for it is not part of this one.
const previewPanelWidth = 320.0;

/// The §5.2 PDF rasterizer seam: builds the page preview for [file], or
/// null where no rasterizer ships — the card then falls back to the
/// metadata card with its `Open With ▸` affordance (06 §5.2's PDF row).
/// [onOpenExternal] is the truncation bar's Open — routed onto the
/// focused entry's real open, never the cache path.
typedef PreviewPdfBuilder = Widget Function(
  BuildContext context,
  File file, {
  VoidCallback? onOpenExternal,
});

/// 06 §5.2's in-app preview panel: the window-level rightmost rail that
/// tracks the focused pane's focused entry and renders the §5.2 kind
/// table — text on the editor's document+syntax layer, images decoded
/// fit-to-panel, PDFs behind [pdfRenderer], everything else on the
/// metadata card with its `Open` / `Open With ▸` affordances.
///
/// All state lives in [PreviewSession]: the widget is a dumb rendering
/// of its phase machine (idle / prompt / confirm / producing /
/// gateConfirm / rendered). Esc inside a focused control runs the
/// pane's shared tier order through [onEscape]; Space stays the pane's
/// key — focused buttons consume their own activation.
class PreviewPanel extends StatelessWidget {
  const PreviewPanel({
    super.key,
    required this.session,
    this.pdfRenderer,
    this.onOpen,
    this.onOpenWith,
    this.onOpenInEditor,
    required this.onClose,
    required this.onEscape,
  });

  final PreviewSession session;

  /// The §5.2 PDF seam — null mounts the metadata card for .pdf rows.
  final PreviewPdfBuilder? pdfRenderer;

  /// The card's `Open`: routed by the shell onto the focused entry —
  /// remote items take the managed-checkout open, never a shell-launch
  /// of a `preview-cache/` path (06 §5.3's boundary rule).
  final void Function(PaneController pane, RemoteFileEntry entry)? onOpen;

  /// The card's `Open With…`: the shell's chooser + editor dispatch.
  final void Function(
    BuildContext context,
    PaneController pane,
    RemoteFileEntry entry,
  )?
  onOpenWith;

  /// The truncation bar's `Open in editor` and a text row's affordance —
  /// the built-in editor's capped open (06 §4.2).
  final void Function(PaneController pane, RemoteFileEntry entry)?
  onOpenInEditor;

  final VoidCallback onClose;

  /// The pane's Esc-tier dispatch (02 §8.2): a focused control inside
  /// the panel still owes Esc to the shared chain — the preview tier
  /// sits above rename/filter/navigation there.
  final KeyEventResult Function(KeyEvent event) onEscape;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Focus(
      // The panel never takes focus itself — its controls do — but Esc
      // pressed while one of them holds it still runs the pane's tier
      // order, mirroring the inspector's pattern (02 §8.2).
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        return onEscape(event);
      },
      child: Semantics(
        container: true,
        label: l10n.previewPanelLabel,
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: BorderDirectional(
            start: BorderSide(color: colors.outlineVariant),
          ),
          child: SizedBox(
            width: previewPanelWidth,
            height: double.infinity,
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) => _PreviewBody(
                session: session,
                pdfRenderer: pdfRenderer,
                onOpen: onOpen,
                onOpenWith: onOpenWith,
                onOpenInEditor: onOpenInEditor,
                onClose: onClose,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.session,
    required this.pdfRenderer,
    required this.onOpen,
    required this.onOpenWith,
    required this.onOpenInEditor,
    required this.onClose,
  });

  final PreviewSession session;
  final PreviewPdfBuilder? pdfRenderer;
  final void Function(PaneController pane, RemoteFileEntry entry)? onOpen;
  final void Function(
    BuildContext context,
    PaneController pane,
    RemoteFileEntry entry,
  )?
  onOpenWith;
  final void Function(PaneController pane, RemoteFileEntry entry)?
  onOpenInEditor;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, l10n),
        Expanded(
          child: switch (session.phase) {
            PreviewPhase.idle => _empty(context),
            PreviewPhase.prompt ||
            PreviewPhase.confirm ||
            PreviewPhase.producing ||
            PreviewPhase.gateConfirm => _card(context, l10n),
            PreviewPhase.rendered => _content(context, l10n),
          },
        ),
      ],
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n) {
    final colors = Theme.of(context).colorScheme;
    final entry = session.entry;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: 14,
        end: 4,
        top: 8,
        bottom: 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: ExcludeSemantics(
                  child: Icon(
                    _iconFor(session),
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    entry?.name ?? '',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    softWrap: true,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('preview.close'),
                tooltip: l10n.previewPanelClose,
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          // §5.2's multi-selection header: count + summed size of the
          // size-known entries, with unknown sizes explicit.
          if (session.selectionCount > 1)
            Text(
              l10n.previewSelectionSummary(
                session.selectionCount,
                formatPaneSize(
                  session.selectionBytes,
                  platform: Theme.of(context).platform,
                ),
                session.selectionUnknownSizes,
              ),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  IconData _iconFor(PreviewSession session) {
    if (session.entry?.isDirectory ?? false) return Icons.folder_outlined;
    return switch (session.kind) {
      PreviewKind.text => Icons.description_outlined,
      PreviewKind.image => Icons.image_outlined,
      PreviewKind.pdf => Icons.picture_as_pdf_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  Widget _empty(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Text(
        l10n.previewPanelEmpty,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// The card family (06 §5.2's state machine): prompt, the §8
  /// confirmation, in-flight progress, the parked unknown-size gate —
  /// each over the item's metadata card.
  Widget _card(BuildContext context, AppLocalizations l10n) {
    final entry = session.entry;
    return SingleChildScrollView(
      padding: const EdgeInsetsDirectional.only(
        start: 14,
        end: 10,
        bottom: 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entry != null) _metadataRows(context, l10n, entry),
          const Divider(height: 20),
          switch (session.phase) {
            PreviewPhase.prompt => _prompt(context, l10n),
            PreviewPhase.confirm => _confirm(context, l10n),
            PreviewPhase.producing => _progress(context, l10n),
            PreviewPhase.gateConfirm => _gate(context, l10n),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }

  /// The prompt card (§5.3's explicit-action rule): `Press Space to
  /// download a preview` plus its button equivalent — and a failure
  /// note after a failed/cancelled production (§5.2's retry state).
  Widget _prompt(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (session.refusal == PreviewRefusal.failed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.previewDownloadFailed,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Text(
          l10n.previewPressSpace,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            key: const ValueKey('preview.download'),
            onPressed:
                session.canProduce ? () => session.confirmDownload() : null,
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(l10n.previewDownloadLabel),
          ),
        ),
      ],
    );
  }

  /// The §8 up-front confirmation (a known size over the threshold):
  /// Space is a no-op here — the card's buttons or an Esc answer it.
  Widget _confirm(BuildContext context, AppLocalizations l10n) {
    final platform = Theme.of(context).platform;
    final name = session.entry?.name ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.previewDownloadConfirm(
            formatPaneSize(session.confirmBytes, platform: platform),
            name,
          ),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              key: const ValueKey('preview.confirm.cancel'),
              onPressed: session.denyDownload,
              child: Text(l10n.previewCancelLabel),
            ),
            FilledButton(
              key: const ValueKey('preview.confirm.download'),
              onPressed: session.confirmDownload,
              child: Text(l10n.previewDownloadLabel),
            ),
          ],
        ),
      ],
    );
  }

  /// In-flight production: determinate when the listing gave a size,
  /// indeterminate on an unknown-size stream (§5.3) — with Esc and the
  /// button both cancelling through the queue's task cancel.
  Widget _progress(BuildContext context, AppLocalizations l10n) {
    final platform = Theme.of(context).platform;
    final total = session.totalBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: l10n.previewDownloadingLabel,
          value: total == null
              ? formatPaneSize(session.transferred, platform: platform)
              : l10n.previewDownloadProgress(
                  formatPaneSize(session.transferred, platform: platform),
                  formatPaneSize(total, platform: platform),
                ),
          child: LinearProgressIndicator(
            key: const ValueKey('preview.progress'),
            value: total != null && total > 0
                ? (session.transferred / total).clamp(0.0, 1.0)
                : null,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          total == null
              ? formatPaneSize(session.transferred, platform: platform)
              : l10n.previewDownloadProgress(
                  formatPaneSize(session.transferred, platform: platform),
                  formatPaneSize(total, platform: platform),
                ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('preview.produce.cancel'),
            onPressed: session.cancelProduction,
            child: Text(l10n.previewCancelLabel),
          ),
        ),
      ],
    );
  }

  /// The parked unknown-size stream (§5.3): the threshold's own card —
  /// `Cancel` aborts the download, `Keep downloading` releases the gate.
  Widget _gate(BuildContext context, AppLocalizations l10n) {
    final platform = Theme.of(context).platform;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.previewGatePrompt(
            formatPaneSize(session.transferred, platform: platform),
          ),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              key: const ValueKey('preview.gate.cancel'),
              onPressed: session.denyDownload,
              child: Text(l10n.previewCancelLabel),
            ),
            FilledButton(
              key: const ValueKey('preview.gate.keep'),
              onPressed: session.confirmDownload,
              child: Text(l10n.previewKeepDownloadingLabel),
            ),
          ],
        ),
      ],
    );
  }

  /// The rendered leg: content by §5.2's kind table, or the metadata
  /// card for the promptless rows (directories, refusals, everything
  /// else).
  Widget _content(BuildContext context, AppLocalizations l10n) {
    final file = session.file;
    final kind = session.kind;
    if (session.refusal != PreviewRefusal.none || file == null) {
      return _refusalOrMetadata(context, l10n);
    }
    switch (kind) {
      case PreviewKind.text:
        return _textContent(context, l10n);
      case PreviewKind.image:
        return _imageContent(context, l10n, file);
      case PreviewKind.pdf:
        final renderer = pdfRenderer;
        if (renderer == null) return _refusalOrMetadata(context, l10n);
        final entry = session.entry;
        final pane = session.pane;
        return renderer(
          context,
          file,
          onOpenExternal: entry != null && pane != null && onOpen != null
              ? () => onOpen!(pane, entry)
              : null,
        );
      case _:
        return _refusalOrMetadata(context, l10n);
    }
  }

  /// Text on the editor's document+syntax layer (§5.2's text row): a
  /// read-only, syntax-highlighted window of the first 1 MiB with the
  /// truncation bar's `Open in editor` affordance.
  Widget _textContent(BuildContext context, AppLocalizations l10n) {
    final content = session.text;
    if (content == null) return _refusalOrMetadata(context, l10n);
    final entry = session.entry;
    final pane = session.pane;
    final language = syntaxLanguageFor(
      entry?.path ?? '',
      firstLine: content.text.split('\n').firstOrNull,
    );
    final theme = EditorSyntaxTheme.of(Theme.of(context).brightness);
    final tokens = language == null
        ? const <SyntaxToken>[]
        : tokenizeSyntax(content.text, language);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (content.truncated) ...[
          _TruncationBar(
            label: l10n.previewTruncatedLabel,
            actionLabel: l10n.previewOpenInEditorLabel,
            onAction: entry != null &&
                    pane != null &&
                    onOpenInEditor != null
                ? () => onOpenInEditor!(pane, entry)
                : null,
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsetsDirectional.only(
              start: 14,
              end: 10,
              bottom: 14,
            ),
            child: SelectableText.rich(
              key: const ValueKey('preview.text'),
              TextSpan(
                children: buildHighlightedSpans(
                  text: content.text,
                  tokens: tokens,
                  matches: const [],
                  activeMatchIndex: -1,
                  theme: theme,
                ),
                style: poltergeistMonoTextStyle.copyWith(
                  fontSize: 12,
                  height: 1.4,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The image row (§5.2): fit-to-panel decode with a dimensions
  /// caption; a corrupt or undecodable file falls back to the metadata
  /// card via the error builder.
  Widget _imageContent(
    BuildContext context,
    AppLocalizations l10n,
    File file,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              start: 14,
              end: 10,
              bottom: 8,
            ),
            child: Semantics(
              label: l10n.previewImageLabel(session.entry?.name ?? ''),
              image: true,
              child: Image.file(
                file,
                key: const ValueKey('preview.image'),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) =>
                    _refusalOrMetadata(context, l10n),
              ),
            ),
          ),
        ),
        _ImageDimensionsCaption(file: file),
      ],
    );
  }

  /// The promptless card rows (§5.3): directories, metadata kinds, and
  /// every refusal carry name/kind/size/dates plus the Open affordances
  /// — with the refusal reason on top when one exists.
  Widget _refusalOrMetadata(BuildContext context, AppLocalizations l10n) {
    final entry = session.entry;
    final pane = session.pane;
    return SingleChildScrollView(
      padding: const EdgeInsetsDirectional.only(
        start: 14,
        end: 10,
        bottom: 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (session.refusal != PreviewRefusal.none)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                switch (session.refusal) {
                  PreviewRefusal.overCacheCap =>
                    l10n.previewRefusalOverCacheCap,
                  PreviewRefusal.overKindCap =>
                    l10n.previewRefusalOverKindCap,
                  PreviewRefusal.notText => l10n.previewRefusalNotText,
                  PreviewRefusal.failed => l10n.previewDownloadFailed,
                  PreviewRefusal.cancelled =>
                    l10n.previewDownloadCancelled,
                  PreviewRefusal.missing => l10n.previewRefusalMissing,
                  PreviewRefusal.none => '',
                },
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (entry != null) _metadataRows(context, l10n, entry),
          const SizedBox(height: 8),
          if (entry != null && pane != null)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (onOpen != null)
                  OutlinedButton(
                    key: const ValueKey('preview.open'),
                    onPressed: () => onOpen!(pane, entry),
                    child: Text(l10n.previewOpenLabel),
                  ),
                if (onOpenWith != null)
                  OutlinedButton(
                    key: const ValueKey('preview.openWith'),
                    onPressed: () => onOpenWith!(context, pane, entry),
                    child: Text(l10n.previewOpenWithLabel),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _metadataRows(
    BuildContext context,
    AppLocalizations l10n,
    RemoteFileEntry entry,
  ) {
    final platform = Theme.of(context).platform;
    final localeName = l10n.localeName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MetaRow(
          label: l10n.infoPanelKind,
          value: switch (entry.type) {
            RemoteFileType.file => l10n.paneRowKindFile,
            RemoteFileType.directory => l10n.paneRowKindDirectory,
            RemoteFileType.symbolicLink => l10n.paneRowKindSymbolicLink,
            RemoteFileType.other => l10n.paneRowKindOther,
          },
        ),
        _MetaRow(
          label: l10n.infoPanelSize,
          value: formatPaneSize(entry.size, platform: platform),
        ),
        _MetaRow(
          label: l10n.infoPanelModified,
          value: formatPaneModified(
            entry.modifiedAt,
            now: DateTime.now(),
            localeName: localeName,
            today: l10n.paneDateToday,
            yesterday: l10n.paneDateYesterday,
          ),
        ),
      ],
    );
  }
}

/// The dimensions caption under an image preview — resolved from the
/// decoded frame so a file lying about its extension reports the real
/// dimensions.
class _ImageDimensionsCaption extends StatefulWidget {
  const _ImageDimensionsCaption({required this.file});

  final File file;

  @override
  State<_ImageDimensionsCaption> createState() =>
      _ImageDimensionsCaptionState();
}

class _ImageDimensionsCaptionState extends State<_ImageDimensionsCaption> {
  /// The decoded probe frame. A `ui.Image` owns GPU-side memory, so the
  /// decode runs once per file here — not per build like a FutureBuilder
  /// would — and the image is disposed with the state.
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    unawaited(_decode(widget.file));
  }

  @override
  void didUpdateWidget(_ImageDimensionsCaption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _image?.dispose();
      _image = null;
      unawaited(_decode(widget.file));
    }
  }

  Future<void> _decode(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() => _image = frame.image);
      } finally {
        codec.dispose();
      }
    } on Object {
      // An unreadable/undecodable file leaves the caption blank — the
      // image widget's own errorBuilder carries the honest state.
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox(height: 18);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 14, bottom: 10),
      child: Text(
        l10n.previewImageDimensions(image.width, image.height),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The `Preview truncated` bar — the §5.2 truncation affordance (text
/// gets "Open in editor", the PDF row's page cap gets the external
/// "Open" — §5.2's PDF truncation mirrors the metadata card's Open).
class _TruncationBar extends StatelessWidget {
  const _TruncationBar({
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          if (onAction != null)
            TextButton(
              key: const ValueKey('preview.truncated.open'),
              onPressed: onAction,
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }
}

/// The Quick Look surface's in-window card (06 §5.1): the native
/// `QLPreviewPanel` cannot host Flutter content and a modal over it is
/// forbidden, so the production's progress, the §8 confirmation, and
/// the refusal render as a non-blocking card near the top of the panes
/// region. Arrow keys keep stepping the native panel while it shows.
class PreviewQuickLookOverlay extends StatelessWidget {
  const PreviewQuickLookOverlay({super.key, required this.session});

  final PreviewSession session;

  @override
  Widget build(BuildContext context) {
    // The card's visibility and contents ride the session's notify —
    // the parent Stack mounts this once and never rebuilds it.
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => _card(context),
    );
  }

  Widget _card(BuildContext context) {
    if (!session.quickLookCardVisible) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final platform = Theme.of(context).platform;
    final name = session.entry?.name ?? '';
    return Positioned(
      top: 12,
      left: 24,
      right: 24,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            key: const ValueKey('preview.quickLookCard'),
            elevation: 6,
            color: colors.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: switch (session.quickLookCard) {
                QuickLookCardKind.confirm => _cardColumn(
                  context,
                  l10n.previewDownloadConfirm(
                    formatPaneSize(
                      session.confirmBytes,
                      platform: platform,
                    ),
                    name,
                  ),
                  cancel: session.quickLookDeny,
                  confirm: session.quickLookConfirm,
                  confirmLabel: l10n.previewDownloadLabel,
                  l10n: l10n,
                ),
                QuickLookCardKind.gateConfirm => _cardColumn(
                  context,
                  l10n.previewGatePrompt(
                    formatPaneSize(
                      session.transferred,
                      platform: platform,
                    ),
                  ),
                  cancel: session.quickLookDeny,
                  confirm: session.quickLookKeepDownloading,
                  confirmLabel: l10n.previewKeepDownloadingLabel,
                  l10n: l10n,
                ),
                QuickLookCardKind.producing => _cardColumn(
                  context,
                  session.totalBytes == null
                      ? l10n.previewDownloadingNamed(
                          name,
                          formatPaneSize(
                            session.transferred,
                            platform: platform,
                          ),
                        )
                      : l10n.previewDownloadingNamed(
                          name,
                          l10n.previewDownloadProgress(
                            formatPaneSize(
                              session.transferred,
                              platform: platform,
                            ),
                            formatPaneSize(
                              session.totalBytes!,
                              platform: platform,
                            ),
                          ),
                        ),
                  cancel: session.cancelProduction,
                  confirm: null,
                  confirmLabel: null,
                  l10n: l10n,
                ),
                QuickLookCardKind.refused => _cardColumn(
                  context,
                  switch (session.refusal) {
                    PreviewRefusal.overCacheCap =>
                      l10n.previewRefusalOverCacheCap,
                    PreviewRefusal.overKindCap =>
                      l10n.previewRefusalOverKindCap,
                    PreviewRefusal.notText => l10n.previewRefusalNotText,
                    PreviewRefusal.missing => l10n.previewRefusalMissing,
                    PreviewRefusal.cancelled =>
                      l10n.previewDownloadCancelled,
                    _ => l10n.previewDownloadFailed,
                  },
                  cancel: session.quickLookDeny,
                  confirm: null,
                  confirmLabel: null,
                  cancelLabel: l10n.previewDismissLabel,
                  l10n: l10n,
                ),
                QuickLookCardKind.none => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardColumn(
    BuildContext context,
    String message, {
    required VoidCallback? cancel,
    required VoidCallback? confirm,
    required String? confirmLabel,
    String? cancelLabel,
    required AppLocalizations l10n,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (cancel != null)
              TextButton(
                key: const ValueKey('preview.quickLookCard.cancel'),
                onPressed: cancel,
                child: Text(cancelLabel ?? l10n.previewCancelLabel),
              ),
            if (confirm != null && confirmLabel != null) ...[
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('preview.quickLookCard.confirm'),
                onPressed: confirm,
                child: Text(confirmLabel),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall,
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}
