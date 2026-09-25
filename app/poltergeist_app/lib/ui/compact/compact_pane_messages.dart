import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/drag_out_controller.dart' show DragOutLeftOut;
import '../../services/pane_controller.dart';
import '../panes/drag_out_notice.dart';

/// The typed pane truth mapped to its ARB sentences (D20) for the
/// compact listing — the same mapping the desktop pane view renders, so
/// a fault reads identically in both postures. Every switch is
/// exhaustive over its enum: a new fault or notice fails to compile here
/// rather than rendering blank.

/// The inline error card's headline: a failed file Open is a FILE
/// problem, everything else takes the kind taxonomy's folder sentence.
String compactErrorTitle(AppLocalizations l10n, RemoteFileException error) =>
    switch (error) {
      OpenEntryError() => l10n.paneFaultOpenFile,
      _ => switch (error.kind) {
        RemoteFileErrorKind.notFound => l10n.paneErrorNotFound,
        RemoteFileErrorKind.permissionDenied => l10n.paneErrorPermissionDenied,
        RemoteFileErrorKind.unsupported => l10n.paneErrorUnsupported,
        RemoteFileErrorKind.disconnected => l10n.paneErrorDisconnected,
        RemoteFileErrorKind.conflict => l10n.paneErrorConflict,
        RemoteFileErrorKind.cancelled => l10n.paneErrorCancelled,
        RemoteFileErrorKind.other => l10n.paneErrorOther,
      },
    };

/// The card's diagnostic line: an authored fault maps to its sentence
/// (empty for the openFile fault, whose sentence is already the title);
/// an engine error keeps its own message.
String compactErrorDetail(AppLocalizations l10n, RemoteFileException error) =>
    switch (error) {
      PaneFaultException(fault: PaneFault.openFile) => '',
      PaneFaultException(:final fault) => compactFaultText(l10n, fault),
      _ => error.message,
    };

String compactFaultText(AppLocalizations l10n, PaneFault fault) =>
    switch (fault) {
      PaneFault.connectionOpen => l10n.paneFaultConnectionOpen,
      PaneFault.localOpen => l10n.paneFaultLocalOpen,
      PaneFault.listFolder => l10n.paneFaultListFolder,
      PaneFault.invalidPath => l10n.paneFaultInvalidPath,
      PaneFault.renameNameEmpty => l10n.paneFaultRenameNameEmpty,
      PaneFault.renameNameSeparator => l10n.paneFaultRenameNameSeparator,
      PaneFault.renameNameInvalid => l10n.paneFaultRenameNameInvalid,
      PaneFault.renameTargetGone => l10n.paneFaultRenameTargetGone,
      PaneFault.openFile => l10n.paneFaultOpenFile,
    };

/// A rename session's refusal, as the rename dialog shows it.
String compactRenameErrorText(
  AppLocalizations l10n,
  RemoteFileException error,
) => switch (error) {
  PaneFaultException(:final fault) => compactFaultText(l10n, fault),
  _ => error.message,
};

/// 02 §10's transient notice sentence. [dragOutLeftOut] carries the
/// counts [PaneNotice.dragOutLeftOut] reads.
String compactNoticeText(
  AppLocalizations l10n,
  PaneNotice notice, {
  required DragOutLeftOut dragOutLeftOut,
}) => switch (notice) {
  PaneNotice.openRemoteUnavailable => l10n.paneNoticeOpenRemoteUnavailable,
  PaneNotice.editLater => l10n.paneNoticeEditLater,
  PaneNotice.transferLater => l10n.paneNoticeTransferLater,
  PaneNotice.saveFavoriteLater => l10n.paneNoticeSaveFavoriteLater,
  PaneNotice.pathCopied => l10n.paneNoticePathCopied,
  PaneNotice.dragOutRemote => l10n.paneNoticeDragOutRemote,
  PaneNotice.dragOutLeftOut => dragOutLeftOutText(l10n, dragOutLeftOut),
  PaneNotice.watchStopped => l10n.paneNoticeWatchStopped,
};
