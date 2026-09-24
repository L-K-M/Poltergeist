import 'package:flutter/foundation.dart' show TargetPlatform;

import '../../theme/app_theme.dart';

/// D32 §3.2's last stage (10 §9): below this window width (logical px,
/// i.e. dp on Android) the workspace takes the compact posture — Home is
/// the full-screen sidebar and the browser shows one pane at a time.
const double compactPostureWidth = 600;

/// Whether a window of [width] on [platform] gets the compact posture.
///
/// Touch platforms only. A desktop window never gets this narrow (its
/// content minimum is 720 × 480, 10 §3.1), and the few desktop layouts
/// that do shrink the pane region below 600 keep `AdaptiveShell`'s
/// pane-B auto-hide — the desktop behavior this slice leaves unchanged.
/// Tablets at 600 dp and wider keep the desktop layout (10 §9).
bool compactPostureApplies({
  required double width,
  required TargetPlatform platform,
}) => width < compactPostureWidth && !isDesktopPlatform(platform);

/// The widget keys the compact surfaces expose to tests. Enum-valued on
/// purpose: they are plumbing, never copy, and an enum cannot drift into
/// a rendered string. Row-level keys pair a value with its path:
/// `ValueKey((CompactKey.row, entry.path))`.
enum CompactKey {
  workspace,
  home,
  homeSettings,
  homeMore,
  browser,
  browserBack,
  browserTitle,
  browserSubtitle,
  browserMore,
  browserFilter,
  filterField,
  filterClose,
  paneSwitcher,
  breadcrumbs,
  breadcrumb,
  listing,
  row,
  rowMore,
  rowCheck,
  loading,
  selectionBar,
  selectionClose,
  selectionTitle,
  selectionSelectAll,
  actionCopy,
  actionMove,
  actionDelete,
  actionMore,
  progressPill,
  inspectorSheet,
  inspectorHandle,
  inspectorTab,
  commandSheet,
  commandRow,
  renameDialog,
  renameField,
  renameConfirm,
  renameCancel,
  pathDialog,
  pathField,
  pathGo,
  quickSelect,
  quickSelectField,
  quickSelectDone,
  quickSelectCancel,
  launcher,
  banner,
  bannerRetry,
  bannerCancel,
  connectCancel,
  errorRetry,
  emptyFolder,
  filterEmptyClear,
  noticeDismiss,
}
