import 'dart:async';

import '../sidebar_controller.dart'
    show CollapsedSectionWriter, PinnedServerWriter, SidebarDensity;

/// What a window opened later starts from (00 D39): the window chrome as
/// the user last left it in any window, rather than as the app launched.
///
/// Each value is device-local and persisted as one app-wide setting that
/// every window writes. The persist sinks the windows get are wrapped here
/// so each write also moves the seed; windows already open keep their own
/// live copy until they close.
final class WindowSeeds {
  WindowSeeds({
    required this.paneRatio,
    required this.sidebarWidth,
    required this.inspectorWidth,
    required this.sidebarHidden,
    required this.sidebarCollapsedGroups,
    required this.sidebarDensity,
    required this.sidebarPinnedServers,
  });

  double paneRatio;
  double? sidebarWidth;
  double? inspectorWidth;
  bool sidebarHidden;
  Set<String> sidebarCollapsedGroups;
  SidebarDensity sidebarDensity;
  Set<String> sidebarPinnedServers;

  FutureOr<void> Function(double ratio) paneRatioSink(
    FutureOr<void> Function(double ratio) save,
  ) => (ratio) {
    paneRatio = ratio;
    return save(ratio);
  };

  FutureOr<void> Function(double width) sidebarWidthSink(
    FutureOr<void> Function(double width) save,
  ) => (width) {
    sidebarWidth = width;
    return save(width);
  };

  FutureOr<void> Function(double width) inspectorWidthSink(
    FutureOr<void> Function(double width) save,
  ) => (width) {
    inspectorWidth = width;
    return save(width);
  };

  FutureOr<void> Function(bool hidden) sidebarHiddenSink(
    FutureOr<void> Function(bool hidden) save,
  ) => (hidden) {
    sidebarHidden = hidden;
    return save(hidden);
  };

  void Function(SidebarDensity density) sidebarDensitySink(
    void Function(SidebarDensity density) save,
  ) => (density) {
    sidebarDensity = density;
    save(density);
  };

  /// The stored set the writer answers with is the seed: it already holds
  /// every other window's changes.
  CollapsedSectionWriter collapsedGroupsSink(CollapsedSectionWriter write) =>
      (key, {required collapsed}) async {
        final stored = await write(key, collapsed: collapsed);
        sidebarCollapsedGroups = stored;
        return stored;
      };

  PinnedServerWriter pinnedServersSink(PinnedServerWriter write) =>
      (serverId, {required pinned}) async {
        final stored = await write(serverId, pinned: pinned);
        sidebarPinnedServers = stored;
        return stored;
      };
}
