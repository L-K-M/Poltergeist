import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/folder_size.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_permissions.dart';
import '../../theme/app_theme.dart';
import 'kind_glyph.dart';
import 'pane_format.dart';

/// 02 §2.6's Get Info facts, rendered in D32's inspector Info tab (10
/// §3): the window-level inspector owns the chrome — no slide-in, no
/// elevation, no ✕ — and the panel never covers the listing. It
/// retargets on every [PaneController] change as the selection moves.
///
/// The slice renders the metadata rows (name, kind, size, dates,
/// permissions, owner/group, path), the on-demand folder-size measure,
/// and the D28 permissions editor — octal field plus rwx checkboxes,
/// Apply for the target, and "Apply to enclosed items…" for folders.
/// Owner/group stay display-only until the D3 `setOwner` addition ships.
class InfoPanel extends StatelessWidget {
  const InfoPanel({
    super.key,
    required this.controller,
    required this.clock,
    required this.onEscape,
  });

  /// The active tab's browsing controller — the panel's data source and
  /// the folder-size session's owner.
  final PaneController controller;

  /// Injectable clock for deterministic date rendering (the pane's
  /// same seam).
  final DateTime Function() clock;

  /// Esc pressed while a control inside the panel holds focus: the
  /// inspector routes it (an open preview answers first).
  final KeyEventResult Function(KeyEvent event) onEscape;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final target = controller.infoTarget;
    return Focus(
      // The panel never takes focus itself — its controls do.
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
        label: l10n.infoPanelLabel,
        child: _body(context, l10n, colors, target),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colors,
    RemoteFileEntry? target,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, l10n, target),
        if (target != null) ...[
          const SizedBox(height: 4),
          if (controller.selectedCount > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                l10n.infoPanelSelectedCount(controller.selectedCount),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          _detailRows(context, l10n, target),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text(
              l10n.infoPanelEmpty,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    AppLocalizations l10n,
    RemoteFileEntry? target,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: ExcludeSemantics(
            child: kindIcon(
              context,
              target == null
                  ? PaneKindCategory.other
                  : paneKindCategory(target),
              size: 20,
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
        _permissionsSection(context, l10n, target),
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

  /// The Permissions row (02 §2.6, D28): the display line — symbolic +
  /// octal render, plus the reason it cannot be edited — for a
  /// mode-less target, a flagged name (02 §13), a symlink, or a pane
  /// whose filesystem has no POSIX modes; the live editor otherwise.
  Widget _permissionsSection(
    BuildContext context,
    AppLocalizations l10n,
    RemoteFileEntry target,
  ) {
    if (controller.permissionsEdit == null) {
      return _InfoRow(
        label: l10n.infoPanelPermissions,
        value: target.mode == null
            ? paneUnevaluated
            : l10n.infoPanelPermissionsValue(
                formatPosixModeSymbolic(target.mode!),
                formatPosixModeOctal(target.mode!),
              ),
        detail: switch (controller.permissionsReadOnly) {
          PermissionsReadOnly.flaggedName => l10n.infoPanelPermBlockedName,
          PermissionsReadOnly.symbolicLink => l10n.infoPanelPermBlockedLink,
          PermissionsReadOnly.unsupportedFilesystem =>
            l10n.infoPanelPermBlockedUnsupported,
          null => null,
        },
      );
    }
    return _PermissionsEditor(controller: controller, target: target);
  }
}

/// The D28 permissions editor (02 §2.6): the symbolic preview, the
/// four-digit octal field — the leading special-bits digit included —
/// and the rwx checkbox grid it stays in lockstep with; Apply writes
/// the draft to the target, and a folder additionally offers "Apply to
/// enclosed items…" with its progress line, working Cancel, and
/// terminal tallies.
///
/// The octal text is the controller draft's verbatim string: keystrokes
/// land through [PaneController.editPermissionsOctal] so an invalid
/// value stays put for correction, while checkbox edits and reverts
/// re-seed the text through [PermissionsEditSession.octalRevision] —
/// the field never re-seeds mid-keystroke.
class _PermissionsEditor extends StatefulWidget {
  const _PermissionsEditor({required this.controller, required this.target});

  final PaneController controller;
  final RemoteFileEntry target;

  @override
  State<_PermissionsEditor> createState() => _PermissionsEditorState();
}

class _PermissionsEditorState extends State<_PermissionsEditor> {
  late final TextEditingController _octal;
  PermissionsEditSession? _seededSession;
  int _seededRevision = -1;

  @override
  void initState() {
    super.initState();
    _octal = TextEditingController();
  }

  @override
  void dispose() {
    _octal.dispose();
    super.dispose();
  }

  /// Re-seeds the field's text on a new session or a bumped revision —
  /// a checkbox edit, a revert, or a fresh draft. The user's own
  /// keystrokes never touch the revision, so typing is undisturbed.
  void _reseed(PermissionsEditSession session) {
    if (identical(session, _seededSession) &&
        session.octalRevision == _seededRevision) {
      return;
    }
    _seededSession = session;
    _seededRevision = session.octalRevision;
    // Written post-frame: assigning a controller's value notifies the
    // EditableText, and doing that mid-build only works while the field
    // stays a strict descendant of this widget — a fragile invariant.
    final text = session.octalText;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _octal.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final session = widget.controller.permissionsEdit;
    if (session == null) {
      // A retarget or a dropped channel can retire the draft between
      // the parent's read and this build — render nothing rather than
      // edit a dead draft.
      return const SizedBox.shrink();
    }
    _reseed(session);

    final enclosed = widget.controller.enclosedApply;
    final enclosedHere =
        enclosed != null && enclosed.targetPath == session.targetPath;
    final inFlight = widget.controller.applyToEnclosedInFlight;
    final editable = !session.applying && !inFlight;
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    final labelStyle = bodySmall?.copyWith(color: colors.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                l10n.infoPanelPermissions,
                style: labelStyle,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        formatPosixModeSymbolic(session.mode),
                        style: poltergeistMonoTextStyle.copyWith(fontSize: 12),
                      ),
                    ),
                    SizedBox(
                      width: 84,
                      child: _octalField(l10n, session, editable),
                    ),
                  ],
                ),
                _checkboxGrid(context, l10n, session, editable),
                if (session.applyError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _permissionError(l10n, session.applyError!),
                      style: bodySmall?.copyWith(color: colors.error),
                    ),
                  ),
                _affordances(l10n, session, editable),
                if (enclosedHere) _enclosedBlock(l10n, colors, enclosed),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The octal field: four digits, leading special-bits digit included.
  /// Esc is 02 §8.2's field tier — it reverts a pending draft or flags
  /// an invalid one; a clean field lets the key fall through to the
  /// panel's own close slot. Enter submits a dirty, valid draft — the
  /// same commit-on-submit convention the other inline fields use.
  Widget _octalField(
    AppLocalizations l10n,
    PermissionsEditSession session,
    bool editable,
  ) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        // The field is disabled while a write is in flight — the revert
        // tier is gated identically so Esc can't retire the draft
        // mid-apply.
        final draft = widget.controller.permissionsEdit;
        if (editable && draft != null && (draft.dirty || draft.octalInvalid)) {
          widget.controller.revertPermissionsEdit();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        key: const ValueKey('infoPanel.octalField'),
        controller: _octal,
        enabled: editable,
        keyboardType: TextInputType.number,
        style: poltergeistMonoTextStyle.copyWith(fontSize: 12),
        decoration: InputDecoration(
          isDense: true,
          labelText: l10n.infoPanelPermOctal,
          errorMaxLines: 3,
          errorText: session.octalInvalid ? l10n.infoPanelPermInvalid : null,
        ),
        onChanged: widget.controller.editPermissionsOctal,
        onSubmitted: (_) {
          final draft = widget.controller.permissionsEdit;
          if (draft != null && draft.dirty && !draft.octalInvalid) {
            unawaited(widget.controller.applyPermissions());
          }
        },
      ),
    );
  }

  /// The rwx grid — one row per class (owner/group/others), one
  /// checkbox per bit. The column heads are the rwx notation's own
  /// letters; the localized tooltips and cell semantics carry the
  /// words.
  Widget _checkboxGrid(
    BuildContext context,
    AppLocalizations l10n,
    PermissionsEditSession session,
    bool editable,
  ) {
    final colors = Theme.of(context).colorScheme;
    final headStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    final rowLabels = [
      l10n.infoPanelPermOwner,
      l10n.infoPanelPermGroup,
      l10n.infoPanelPermOthers,
    ];
    final columnLabels = [
      l10n.infoPanelPermRead,
      l10n.infoPanelPermWrite,
      l10n.infoPanelPermExecute,
    ];
    const rowKeys = ['owner', 'group', 'others'];
    const columnKeys = ['read', 'write', 'execute'];
    const bits = [
      [permissionOwnerRead, permissionOwnerWrite, permissionOwnerExecute],
      [permissionGroupRead, permissionGroupWrite, permissionGroupExecute],
      [permissionOtherRead, permissionOtherWrite, permissionOtherExecute],
    ];
    Widget cell(int row, int column) => SizedBox(
      width: 40,
      height: 28,
      child: Center(
        child: Semantics(
          label: l10n.infoPanelPermCell(
            rowLabels[row],
            columnLabels[column],
          ),
          child: Checkbox(
            key: ValueKey(
              'infoPanel.permCell.${rowKeys[row]}.${columnKeys[column]}',
            ),
            value: session.mode & bits[row][column] != 0,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            onChanged: editable
                ? (set) => widget.controller.setPermissionBit(
                    bits[row][column],
                    set ?? false,
                  )
                : null,
          ),
        ),
      ),
    );
    Widget head(int column) => SizedBox(
      width: 40,
      child: Center(
        child: Tooltip(
          message: columnLabels[column],
          child: Text(columnKeys[column][0].toUpperCase(), style: headStyle),
        ),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 48),
            for (var c = 0; c < 3; c++) head(c),
          ],
        ),
        for (var r = 0; r < 3; r++)
          Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(rowLabels[r], style: headStyle),
              ),
              for (var c = 0; c < 3; c++) cell(r, c),
            ],
          ),
      ],
    );
  }

  /// The write affordances: Apply writes the draft for the target; a
  /// folder adds "Apply to enclosed items…" (02 §2.6, D28), whose
  /// confirmation dialog this widget presents.
  Widget _affordances(
    AppLocalizations l10n,
    PermissionsEditSession session,
    bool editable,
  ) {
    return Wrap(
      spacing: 4,
      children: [
        TextButton(
          key: const ValueKey('infoPanel.applyPermissions'),
          onPressed: editable && session.dirty && !session.octalInvalid
              ? () => unawaited(widget.controller.applyPermissions())
              : null,
          child: Text(l10n.infoPanelApplyPermissions),
        ),
        if (widget.target.isDirectory)
          TextButton(
            key: const ValueKey('infoPanel.applyEnclosed'),
            // The draft mode applies even when it equals the listed one
            // — re-applying a mode to later-added contents is the verb.
            onPressed: editable && !session.octalInvalid
                ? () => unawaited(
                    widget.controller.requestApplyToEnclosed(
                      confirm: _confirmEnclosed,
                    ),
                  )
                : null,
            child: Text(l10n.infoPanelApplyEnclosed),
          ),
      ],
    );
  }

  /// The destructive-class confirmation (02 §10's family): the dialog
  /// renders the operation's live stage — counting progress, then the
  /// quantified or hedged copy. A dismissed dialog answers declined.
  /// The barrier is non-dismissible and system-back routes through the
  /// dialog's `_answer`, so every dismissal flows through its latch —
  /// a scrim tap or back gesture can never race `_settle` into a second
  /// pop of the route beneath.
  Future<bool> _confirmEnclosed() async {
    if (!mounted) return false;
    final granted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          _EnclosedApplyDialog(controller: widget.controller),
    );
    return granted ?? false;
  }

  /// The enclosed operation's live line: progress with a working Cancel
  /// while the walk runs, the terminal tally block once it settles.
  /// Counting and confirming render in the dialog instead — the modal
  /// owns the ask stages.
  Widget _enclosedBlock(
    AppLocalizations l10n,
    ColorScheme colors,
    EnclosedApplyProgress session,
  ) {
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    final tallies = [
      if (session.skippedUndecodable > 0)
        l10n.infoPanelEnclosedSkipped(session.skippedUndecodable),
      if (session.linksSkipped > 0)
        l10n.infoPanelEnclosedLinks(session.linksSkipped),
      if (session.unreadable > 0)
        l10n.infoPanelEnclosedUnreadable(session.unreadable),
      if (session.failed > 0)
        l10n.infoPanelEnclosedRefused(session.failed),
    ];
    Widget tallyLines() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in tallies)
          Text(
            line,
            style: bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
      ],
    );
    return switch (session.stage) {
      EnclosedApplyStage.counting ||
      EnclosedApplyStage.confirming => const SizedBox.shrink(),
      EnclosedApplyStage.applying => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.infoPanelEnclosedProgress(
                    PermissionsEditSession.octalTextFor(session.mode),
                    session.applied,
                  ),
                  style: bodySmall,
                ),
              ),
              TextButton(
                key: const ValueKey('infoPanel.cancelEnclosed'),
                onPressed: widget.controller.cancelEnclosedApply,
                child: Text(l10n.infoPanelEnclosedCancel),
              ),
            ],
          ),
          const LinearProgressIndicator(),
        ],
      ),
      EnclosedApplyStage.done => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.infoPanelEnclosedDone(session.applied), style: bodySmall),
          tallyLines(),
        ],
      ),
      EnclosedApplyStage.cancelled => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.infoPanelEnclosedCancelled(session.applied),
            style: bodySmall,
          ),
          tallyLines(),
        ],
      ),
      EnclosedApplyStage.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.infoPanelEnclosedFailed,
            style: bodySmall?.copyWith(color: colors.error),
          ),
          if (session.error != null)
            Text(
              _permissionError(l10n, session.error!),
              style: bodySmall?.copyWith(color: colors.error),
            ),
          tallyLines(),
        ],
      ),
    };
  }

  /// The inline refusal copy: the typed VFS failures map to their
  /// authored strings; anything else reports the generic line — a fault
  /// never shows the engine's raw text as UI copy.
  String _permissionError(AppLocalizations l10n, Object error) {
    if (error is RemoteFileException) {
      return switch (error.kind) {
        RemoteFileErrorKind.unsupported =>
          l10n.infoPanelPermErrorUnsupported,
        RemoteFileErrorKind.permissionDenied => l10n.infoPanelPermErrorDenied,
        RemoteFileErrorKind.notFound => l10n.infoPanelPermErrorNotFound,
        _ => l10n.infoPanelPermError,
      };
    }
    return l10n.infoPanelPermError;
  }
}

/// The "Apply to enclosed items…" confirmation (02 §10's family): the
/// count pass's progress line first, then the quantified copy — or the
/// hedged fallback when the pass could not complete — with the
/// undecodable-name and link disclosures (02 §13's never-silent rule).
/// The dialog retires itself the moment the operation's session leaves
/// the ask stages: a root refusal, a panel close, or a cancel under it
/// never strands a modal holding a stale grant.
class _EnclosedApplyDialog extends StatefulWidget {
  const _EnclosedApplyDialog({required this.controller});

  final PaneController controller;

  @override
  State<_EnclosedApplyDialog> createState() => _EnclosedApplyDialogState();
}

class _EnclosedApplyDialogState extends State<_EnclosedApplyDialog> {
  /// The answer latch: the dialog's own pop and the listener's settle
  /// race during the pop animation — the controller's applying publish
  /// lands while the route is still mounted, and a second pop would
  /// take the route beneath.
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_settle);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_settle);
    super.dispose();
  }

  void _answer(bool value) {
    if (_answered || !mounted) return;
    _answered = true;
    Navigator.of(context).pop(value);
  }

  void _settle() {
    final session = widget.controller.enclosedApply;
    if (session != null &&
        (session.stage == EnclosedApplyStage.counting ||
            session.stage == EnclosedApplyStage.confirming)) {
      return;
    }
    // The ask ended without this dialog answering — declined, so a
    // stranded modal can never deliver a stale grant later.
    _answer(false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = widget.controller.enclosedApply;
    if (session == null) return const SizedBox.shrink();
    final counting = session.stage == EnclosedApplyStage.counting;
    final octal = PermissionsEditSession.octalTextFor(session.mode);
    final colors = Theme.of(context).colorScheme;
    // canPop: false routes system-back through _answer — the imperative
    // Navigator.pop there still force-pops, so every dismissal (button
    // or back) flows through the _answered latch once.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _answer(false);
      },
      child: AlertDialog(
        title: Text(l10n.infoPanelEnclosedTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (counting) ...[
            Text(l10n.infoPanelEnclosedCounting(session.targetName)),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ] else ...[
            Text(
              session.flagPassComplete
                  ? l10n.infoPanelEnclosedBodyCounted(
                      octal,
                      session.targetName,
                      session.counted,
                    )
                  : l10n.infoPanelEnclosedBody(octal, session.targetName),
            ),
            // The disclosures: the counted forms once the pass saw
            // every reachable listing, the hedge whenever it did not —
            // an incomplete pass can never claim zero flagged names.
            if (session.flagPassComplete) ...[
              if (session.countedFlagged > 0)
                Text(
                  l10n.infoPanelEnclosedFlaggedCounted(
                    session.countedFlagged,
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              if (session.countedLinks > 0)
                Text(
                  l10n.infoPanelEnclosedLinksCounted(session.countedLinks),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ] else
              Text(
                l10n.infoPanelEnclosedIncomplete,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('infoPanel.enclosedDecline'),
          onPressed: () => _answer(false),
          child: Text(l10n.infoPanelEnclosedCancel),
        ),
        FilledButton(
          key: const ValueKey('infoPanel.enclosedConfirm'),
          onPressed: counting ? null : () => _answer(true),
          child: Text(l10n.infoPanelEnclosedApply),
        ),
        ],
      ),
    );
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
