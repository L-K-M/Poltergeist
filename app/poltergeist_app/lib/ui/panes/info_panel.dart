import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/folder_size.dart';
import '../../services/pane_controller.dart';
import 'pane_format.dart';

/// The inspector's width — Transmit's inspector is a fixed-width rail,
/// not a resizable split, so the listing underneath keeps its layout.
const _infoPanelWidth = 280.0;

/// 02 §2.6's Get Info inspector: a non-modal panel sliding over the
/// pane's right edge. It is a Stack sibling of the listing — never a
/// route, never a dialog — so the pane stays interactive beneath it,
/// and it retargets on every [PaneController] change as the selection
/// moves.
///
/// The slice renders display-only metadata (name, kind, size, dates,
/// permissions, owner/group, path) plus the on-demand folder-size
/// measure. The D28 permissions editor and owner editing are later
/// work; nothing here fakes editability.
class InfoPanel extends StatelessWidget {
  const InfoPanel({
    super.key,
    required this.controller,
    required this.clock,
    required this.onClose,
    required this.onEscape,
  });

  /// The active tab's browsing controller — the panel's data source and
  /// the folder-size session's owner.
  final PaneController controller;

  /// Injectable clock for deterministic date rendering (the pane's
  /// same seam).
  final DateTime Function() clock;

  /// The ✕ affordance — the strip's [PaneTabsController.closeInfoPanel]
  /// routed through the pane view.
  final VoidCallback onClose;

  /// The pane's shared Esc-tier dispatch (02 §8.2): when a control
  /// inside the panel holds focus, Esc still runs the full ordered
  /// chain — a higher surface (an in-flight navigation) wins over the
  /// panel's own close slot.
  final KeyEventResult Function(KeyEvent event) onEscape;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final target = controller.infoTarget;
    return Focus(
      // The panel never takes focus itself — its controls do — but Esc
      // pressed while one of them holds it still runs the pane's tier
      // order, mirroring the field strips' pattern.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        return onEscape(event);
      },
      child: TweenAnimationBuilder<Offset>(
        // The slide-in over the right edge (02 §2.6); a close unmounts
        // the panel, so the tween only ever plays the entrance.
        tween: Tween(begin: const Offset(1, 0), end: Offset.zero),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, offset, child) => FractionalTranslation(
          translation: offset,
          child: child,
        ),
        child: Semantics(
          container: true,
          label: l10n.infoPanelLabel,
          child: Material(
            elevation: 8,
            color: colors.surfaceContainerHigh,
            shape: BorderDirectional(
              start: BorderSide(color: colors.outlineVariant),
            ),
            child: SizedBox(
              width: _infoPanelWidth,
              height: double.infinity,
              child: SingleChildScrollView(
                padding: const EdgeInsetsDirectional.only(
                  start: 14,
                  end: 10,
                  top: 8,
                  bottom: 14,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(context, l10n, target),
                    if (target != null) ...[
                      const SizedBox(height: 4),
                      if (controller.selectedCount > 1)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            l10n.infoPanelSelectedCount(
                              controller.selectedCount,
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      _detailRows(context, l10n, target),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Text(
                          l10n.infoPanelEmpty,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant),
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

  Widget _header(
    BuildContext context,
    AppLocalizations l10n,
    RemoteFileEntry? target,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: ExcludeSemantics(
            child: Icon(
              switch (target?.type) {
                RemoteFileType.directory => Icons.folder_outlined,
                RemoteFileType.symbolicLink => Icons.shortcut_outlined,
                _ => Icons.insert_drive_file_outlined,
              },
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
              target?.name ?? '',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              // A long name wraps rather than ellipsizing — the panel
              // exists to show the name in full.
              softWrap: true,
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('infoPanel.close'),
          tooltip: l10n.infoPanelClose,
          onPressed: onClose,
          icon: const Icon(Icons.close, size: 18),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _detailRows(
    BuildContext context,
    AppLocalizations l10n,
    RemoteFileEntry target,
  ) {
    final localeName = l10n.localeName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 16),
        _InfoRow(
          label: l10n.infoPanelKind,
          value: switch (target.type) {
            RemoteFileType.file => l10n.paneRowKindFile,
            RemoteFileType.directory => l10n.paneRowKindDirectory,
            RemoteFileType.symbolicLink => l10n.paneRowKindSymbolicLink,
            RemoteFileType.other => l10n.paneRowKindOther,
          },
        ),
        _sizeSection(context, l10n, target),
        _InfoRow(
          label: l10n.infoPanelModified,
          value: formatPaneModified(
            target.modifiedAt,
            now: clock(),
            localeName: localeName,
            today: l10n.paneDateToday,
            yesterday: l10n.paneDateYesterday,
          ),
        ),
        _InfoRow(
          label: l10n.infoPanelAccessed,
          value: formatPaneModified(
            target.accessedAt,
            now: clock(),
            localeName: localeName,
            today: l10n.paneDateToday,
            yesterday: l10n.paneDateYesterday,
          ),
        ),
        _InfoRow(
          label: l10n.infoPanelPermissions,
          value: target.mode == null
              ? paneUnevaluated
              : l10n.infoPanelPermissionsValue(
                  formatPosixModeSymbolic(target.mode!),
                  formatPosixModeOctal(target.mode!),
                ),
        ),
        _InfoRow(
          label: l10n.infoPanelOwner,
          value: target.uid?.toString() ?? paneUnevaluated,
        ),
        _InfoRow(
          label: l10n.infoPanelGroup,
          value: target.gid?.toString() ?? paneUnevaluated,
        ),
        _PathRow(
          label: l10n.infoPanelPath,
          path: target.path,
          copyTooltip: l10n.infoPanelCopyPath,
          onCopied: controller.notePathCopied,
        ),
      ],
    );
  }

  /// The Size row: files render their listing size directly; a folder's
  /// is measured on demand (02 §2.6) — the Calculate affordance, live
  /// progress with Cancel, or the settled total. The session is matched
  /// by target path, so a retargeted panel never displays a measure
  /// started for another folder.
  Widget _sizeSection(
    BuildContext context,
    AppLocalizations l10n,
    RemoteFileEntry target,
  ) {
    final platform = Theme.of(context).platform;
    if (!target.isDirectory) {
      return _InfoRow(
        label: l10n.infoPanelSize,
        value: formatPaneSize(target.size, platform: platform),
      );
    }
    final session = controller.folderSize;
    if (session == null || session.targetPath != target.path) {
      return _InfoRow(
        label: l10n.infoPanelSize,
        value: paneUnevaluated,
        trailing: TextButton(
          key: const ValueKey('infoPanel.calculateSize'),
          onPressed: controller.startFolderSize,
          child: Text(l10n.infoPanelCalculateSize),
        ),
      );
    }
    return switch (session.status) {
      FolderSizeStatus.running => _InfoRow(
          label: l10n.infoPanelSize,
          value: l10n.infoPanelSizeProgress(
            formatPaneSize(session.bytes, platform: platform),
            session.entries,
          ),
          trailing: TextButton(
            key: const ValueKey('infoPanel.cancelSize'),
            onPressed: controller.cancelFolderSize,
            child: Text(l10n.infoPanelCancelSize),
          ),
        ),
      FolderSizeStatus.done => _InfoRow(
          label: l10n.infoPanelSize,
          value: l10n.infoPanelSizeResult(
            formatPaneSize(session.bytes, platform: platform),
            session.entries,
          ),
          detail: session.unmeasured + session.unreadable > 0
              ? l10n.infoPanelSizePartial(
                  session.unmeasured + session.unreadable,
                )
              : null,
        ),
      FolderSizeStatus.failed => _InfoRow(
          label: l10n.infoPanelSize,
          value: l10n.infoPanelSizeFailed,
          trailing: TextButton(
            key: const ValueKey('infoPanel.retrySize'),
            onPressed: controller.startFolderSize,
            child: Text(l10n.infoPanelCalculateSize),
          ),
        ),
      // The controller clears a cancelled session outright, so the
      // panel never observes this state — the Calculate affordance is
      // its rendering.
      FolderSizeStatus.cancelled => _InfoRow(
          label: l10n.infoPanelSize,
          value: paneUnevaluated,
          trailing: TextButton(
            key: const ValueKey('infoPanel.calculateSize'),
            onPressed: controller.startFolderSize,
            child: Text(l10n.infoPanelCalculateSize),
          ),
        ),
    };
  }
}

/// One label/value line of the inspector. The label column is fixed so
/// values align down the rail; [trailing] carries the folder-size row's
/// Calculate/Cancel affordance and [detail] a partial-total note.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.trailing,
    this.detail,
  });

  final String label;
  final String value;
  final Widget? trailing;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: 86, child: Text(label, style: labelStyle)),
              Expanded(
                child: SelectableText(
                  value,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              ?trailing,
            ],
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 86),
              child: Text(
                detail!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The full-path row: the selectable path text plus the copy affordance
/// (02 §2.6's "full path with copy").
class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.label,
    required this.path,
    required this.copyTooltip,
    required this.onCopied,
  });

  final String label;
  final String path;
  final String copyTooltip;
  final VoidCallback onCopied;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: labelStyle),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  path,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                key: const ValueKey('infoPanel.copyPath'),
                tooltip: copyTooltip,
                onPressed: () {
                  unawaited(Clipboard.setData(ClipboardData(text: path)));
                  onCopied();
                },
                icon: const Icon(Icons.copy_outlined, size: 16),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
