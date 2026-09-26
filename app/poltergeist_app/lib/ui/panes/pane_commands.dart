import 'package:flutter/material.dart';

import 'dart:async';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show FileSortKey, RemoteFileType;

import '../../services/pane_controller.dart';
import '../../services/pane_permissions.dart' show nameIsFlagged;
import '../../services/preview_session.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';
import '../../theme/app_theme.dart' show isDesktopPlatform;
import '../../theme/family_hues.dart';
import '../layout/pane_allocation.dart' show desktopStageBoundary;
import 'pane_view.dart' show PaneView;

const kGoBackCommandId = 'go.back';
const kGoEditPathCommandId = 'go.editPath';
const kGoEnclosingCommandId = 'go.enclosing';
const kGoForwardCommandId = 'go.forward';
const kGoHomeCommandId = 'go.home';
const kGoOpenCommandId = 'go.open';
const kGoToFolderCommandId = 'go.toFolder';
const kFileEditBuiltInCommandId = 'file.editBuiltIn';
const kFileGetInfoCommandId = 'file.getInfo';
const kFilePreviewCommandId = 'file.preview';
const kFileRenameCommandId = 'file.rename';
const kViewRefreshCommandId = 'view.refresh';
const kViewToggleSidebarCommandId = 'view.toggleSidebar';
const kViewToggleSecondPaneCommandId = 'view.toggleSecondPane';
const kViewToggleActivityPanelCommandId = 'view.toggleActivityPanel';
const kViewTogglePreviewCommandId = 'view.togglePreview';
const kViewToggleSyncBrowsingCommandId = 'view.toggleSyncBrowsing';
const kPaneFocusLeftCommandId = 'pane.focusLeft';
const kPaneFocusRightCommandId = 'pane.focusRight';
const kPaneSwapFocusCommandId = 'pane.swapFocus';
const kEditUndoSelectionCommandId = 'edit.undoSelection';
const kEditRedoSelectionCommandId = 'edit.redoSelection';
const kEditSelectAllCommandId = 'edit.selectAll';
const kEditInvertSelectionCommandId = 'edit.invertSelection';
const kSelectionQuickSelectCommandId = 'selection.quickSelect';
const kViewFilterCommandId = 'view.filter';
const kTabNewCommandId = 'tab.new';
const kTabCloseCommandId = 'tab.close';
const kTabReopenClosedCommandId = 'tab.reopenClosed';
const kTabNextCommandId = 'tab.next';
const kTabPreviousCommandId = 'tab.previous';
const kViewToggleHiddenCommandId = 'view.toggleHidden';
const kSelectionCopyPathCommandId = 'selection.copyPath';
const kViewSortByCommandId = 'view.sortBy';

/// The Details columns `view.sortBy` offers, in header order (D32 §6).
const _sortColumns = [FileSortKey.name, FileSortKey.size, FileSortKey.modified];

/// `selection.copyPath`'s payload for [pane]: the selected rows' paths
/// in listing order, one per line; else the cursor row's; else the
/// folder the pane stands in (Finder's ⌥⌘C). Null when there is nothing
/// to name.
String? paneCopyPathText(PaneController pane) {
  final selected = pane.selectedEntries;
  if (selected.isNotEmpty) {
    return [for (final entry in selected) entry.path].join('\n');
  }
  final cursor = pane.cursorIndex;
  if (cursor != null && cursor >= 0 && cursor < pane.entries.length) {
    return pane.entries[cursor].path;
  }
  return pane.location?.path;
}

/// Writes [text] to the clipboard and posts the pane's transient
/// "Path copied" confirmation (the notice channel every pane-moment
/// confirmation shares).
Future<void> copyPanePath(PaneController pane, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  pane.notePathCopied();
}

/// The pane-command registry slice (D21): every pane action this
/// foundation ships is a registered command. Commands resolve the
/// workspace's ACTIVE pane at invocation time — never a captured one
/// (02 §8.1's CommandContext rule, foundation form).
List<RegisteredCommand> buildPaneCommands({
  required WorkspaceController workspace,
  required VoidCallback focusLeft,
  required VoidCallback focusRight,
  required VoidCallback swapFocus,
  bool Function()? sidebarAvailable,

  /// Opens/closes the stage-1/2 overlay drawer the sidebar mounts in —
  /// the shell supplies its own Scaffold key (a command-run context sits
  /// above that Scaffold, so `Scaffold.maybeOf` cannot find it). Null
  /// leaves the narrow-window branch inert.
  void Function()? toggleSidebarDrawer,

  /// The 06 §5 preview driver behind `file.preview` and
  /// `view.togglePreview`. Both commands register unconditionally
  /// (D21); a null session leaves them visible-disabled — the same
  /// posture `queue.togglePause` takes without a queue.
  PreviewSession? preview,

  /// Whether the sidebar currently lives in the overlay drawer (D32's
  /// allocation decides, not a bare window-width check); null falls back
  /// to the 02 §1 stage boundary.
  bool Function()? sidebarIsDrawer,

  /// D32 §4: `view.filter` focuses the header's filter field; null keeps
  /// the pane's own filter strip.
  VoidCallback? focusFilter,
}) {
  // Browsing commands resolve the active pane's ACTIVE TAB at invocation
  // time (02 §8.1) — null while the pane sits on the launcher, and every
  // enabled getter below treats null as disabled. Tab commands act on
  // the strip itself.
  PaneController? activeTab() => workspace.activeTabController;

  return [
    RegisteredCommand(
      id: kGoBackCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.goBackLabel,
      icon: Icons.arrow_back_outlined,
      // ⌘[ on macOS, Alt+Left elsewhere (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true),
        ],
        other: const [SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true)],
      ),
      // Disabled at the trail's start (02 §2.1) and on a pane with no
      // live channel — canGoBack is the single definition of both.
      enabled: () => activeTab()?.canGoBack ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoBack,
      run: (_) async {
        activeTab()?.goBack();
      },
      // 02 §9's Go menu leads with Back/Forward.
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.leading,
        order: 20,
        group: 1,
      ),
      menuPlacement: const CommandMenuPlacement(menu: AppMenuId.go, order: 10),
    ),
    RegisteredCommand(
      id: kGoForwardCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.goForwardLabel,
      icon: Icons.arrow_forward_outlined,
      // ⌘] on macOS, Alt+Right elsewhere (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.bracketRight, meta: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.arrowRight, alt: true),
        ],
      ),
      enabled: () => activeTab()?.canGoForward ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoForward,
      run: (_) async {
        activeTab()?.goForward();
      },
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.leading,
        order: 21,
        group: 1,
      ),
      menuPlacement: const CommandMenuPlacement(menu: AppMenuId.go, order: 20),
    ),
    RegisteredCommand(
      id: kGoEnclosingCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.goEnclosingLabel,
      icon: Icons.arrow_upward_outlined,
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.arrowUp, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.arrowUp, alt: true)],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.goUp();
      },
      // 10 §8's Go menu opens with Back, Forward, Enclosing Folder, Home.
      menuPlacement: const CommandMenuPlacement(menu: AppMenuId.go, order: 30),
    ),
    RegisteredCommand(
      id: kGoHomeCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.goHomeLabel,
      icon: Icons.home,
      hue: FamilyHue.blue,
      // ⇧⌘H on macOS, Ctrl+Shift+H elsewhere (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyH, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyH, control: true, shift: true),
        ],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.goHome();
      },
      menuPlacement: const CommandMenuPlacement(menu: AppMenuId.go, order: 40),
    ),
    RegisteredCommand(
      id: kGoToFolderCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.goToFolderLabel,
      icon: Icons.folder_open,
      hue: FamilyHue.blue,
      // ⇧⌘G on macOS, Ctrl+Shift+G elsewhere (02 §8.3's table): opens
      // the same in-bar path editor as `go.editPath`, seeded empty.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyG, control: true, shift: true),
        ],
      ),
      enabled: () => activeTab()?.acceptsPathInput ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.goToFolder();
      },
      // 10 §8's Go menu: the path-field section.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.go,
        order: 50,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kGoEditPathCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.goEditPathLabel,
      icon: Icons.edit_location_alt_outlined,
      // ⌘L / Ctrl+L (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyL, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyL, control: true)],
      ),
      enabled: () => activeTab()?.acceptsPathInput ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.editPath();
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.go,
        order: 60,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kGoOpenCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.goOpenLabel,
      icon: Icons.subdirectory_arrow_right_outlined,
      // Enter (Windows/Linux) and ⌘↓/⌘O (macOS) are the §8.3 bindings.
      // The unmodified Enter leg is dispatched by the pane's focus node
      // (02 §8.2 scopes single keys there), never by the chord layer.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.arrowDown, meta: true),
          SingleActivator(LogicalKeyboardKey.keyO, meta: true),
        ],
        other: const [SingleActivator(LogicalKeyboardKey.enter)],
      ),
      enabled: () {
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        return pane != null &&
            pane.verbsEnabled &&
            cursor != null &&
            cursor >= 0 &&
            cursor < pane.entries.length;
      },
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (_) async {
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        if (pane == null ||
            cursor == null ||
            cursor < 0 ||
            cursor >= pane.entries.length) {
          return;
        }
        pane.openEntry(pane.entries[cursor]);
      },
      // 10 §8's File menu: the open section follows the New block.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 60,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kFileEditBuiltInCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.fileEditBuiltInLabel,
      icon: Icons.edit_note_outlined,
      // ⌥⌘E on macOS, Ctrl+Alt+E elsewhere (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyE, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyE, control: true, alt: true),
        ],
      ),
      // The cursor's FILE row is the editor's target (06 §4.2): files
      // and symlinks qualify — a remote symlink's checkout refuses with
      // the typed unsupported error and a local one resolves at open —
      // directories and untyped entries do not.
      enabled: () {
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        if (pane == null ||
            !pane.verbsEnabled ||
            cursor == null ||
            cursor < 0 ||
            cursor >= pane.entries.length) {
          return false;
        }
        final type = pane.entries[cursor].type;
        return type == RemoteFileType.file ||
            type == RemoteFileType.symbolicLink;
      },
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (_) async {
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        if (pane == null ||
            cursor == null ||
            cursor < 0 ||
            cursor >= pane.entries.length) {
          return;
        }
        await pane.editInBuiltInEditor(pane.entries[cursor]);
      },
      // 02 §9's File menu: Open, the (unregistered) Open With ▸ slot,
      // Edit in Poltergeist, then Get Info — order 63 leaves the Open
      // With slot open between 60 and this one.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 63,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kFileGetInfoCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.fileGetInfoLabel,
      icon: Icons.info,
      hue: FamilyHue.blue,
      // ⌘I on macOS, Alt+Enter elsewhere (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyI, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.enter, alt: true)],
      ),
      // D32: Get Info is the inspector's Info tab, which follows the
      // focused item — live whenever a browsing tab exists (an empty
      // selection shows the Info tab's own empty state), and a toggle:
      // the chord hides the inspector when Info is already showing.
      enabled: () => activeTab() != null,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async => workspace.toggleInspectorTab(InspectorTab.info),
      // 10 §8's File menu: Get Info leads the Get Info, Rename,
      // Duplicate section.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 65,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kFilePreviewCommandId,
      scope: CommandScope.selection,
      // The label names the surface Space actually opens: Quick Look on
      // every desktop (the native panel on macOS, the in-app overlay on
      // Linux and Windows); touch platforms answer on the Info tab, so
      // the label stays neutral there.
      label: (l10n) => isDesktopPlatform(defaultTargetPlatform)
          ? l10n.filePreviewLabel
          : l10n.filePreviewLabelNeutral,
      icon: Icons.visibility_outlined,
      // Space on every platform (02 §8.3's table). Unmodified, so the
      // chord layer skips it by design — the pane's focus node
      // dispatches (02 §8.2); the activator documents the binding for
      // menus and reachability, it never fires here.
      activators: (_) => const [SingleActivator(LogicalKeyboardKey.space)],
      // Live while Space has something to act on: a focused row, or an
      // open Quick Look the same key closes. The Info tab being on
      // screen is not enough — Space never hides the inspector.
      enabled: () {
        if (preview != null && preview.quickLookActive) return true;
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        return pane != null &&
            pane.verbsEnabled &&
            cursor != null &&
            cursor >= 0 &&
            cursor < pane.entries.length;
      },
      disabledReason: (l10n) => l10n.commandDisabledNoSelection,
      run: (_) async {
        preview?.previewFocused();
      },
      // 10 §8's File menu: Quick Look follows Edit in Poltergeist in the
      // open section.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 67,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kFileRenameCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.fileRenameLabel,
      icon: Icons.drive_file_rename_outline,
      // Return on macOS, F2 elsewhere (02 §8.3's table). Both are
      // unmodified keys, so the chord layer skips them by design and
      // the pane's focus node dispatches (02 §8.2) — the activator
      // documents the binding for menus and reachability, it never
      // fires here.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.enter)],
        other: const [SingleActivator(LogicalKeyboardKey.f2)],
      ),
      enabled: () {
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        return pane != null &&
            pane.verbsEnabled &&
            cursor != null &&
            cursor >= 0 &&
            cursor < pane.entries.length &&
            // A flagged (U+FFFD) name can't round-trip to the wire —
            // §13 withholds the verb rather than letting the command
            // run and the controller refuse.
            !nameIsFlagged(pane.entries[cursor].name);
      },
      disabledReason: (l10n) {
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        final flagged = pane != null &&
            cursor != null &&
            cursor >= 0 &&
            cursor < pane.entries.length &&
            nameIsFlagged(pane.entries[cursor].name);
        return flagged
            ? l10n.paneFlaggedNameTooltip
            : l10n.commandDisabledNoSelection;
      },
      run: (_) async {
        activeTab()?.startRename();
      },
      // 10 §8's File menu: Rename follows Get Info.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 70,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kViewRefreshCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.viewRefreshLabel,
      icon: Icons.refresh,
      // Dual macOS/Ctrl registration per 09 §3: meta on macOS, control
      // everywhere else.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyR, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyR, control: true)],
      ),
      enabled: () {
        final pane = activeTab();
        return pane != null &&
            pane.phase == PanePhase.browsing &&
            !pane.connectionLost;
      },
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.refresh();
      },
      // 10 §8's View menu: Refresh in its own section, above Enter
      // Full Screen.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 110,
        group: 3,
      ),
    ),
    RegisteredCommand(
      id: kViewToggleSidebarCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.viewToggleSidebarLabel,
      icon: Icons.view_sidebar_outlined,
      // ⌃⌘S on macOS, the platform's sidebar standard (10 §4, which
      // supersedes 02 §8.3's ⌥⌘S); Ctrl+Alt+S elsewhere.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyS, control: true, meta: true),
        ],
        // Windows reports AltGr as Ctrl+Alt, so AltGr+S (ś/ş on Polish
        // and Turkish layouts) also matches this activator — a known
        // spec-level collision with 02 §8.3's table, pending a spec
        // decision (or suppressing app-scope activators while a text
        // field has focus).
        other: const [
          SingleActivator(LogicalKeyboardKey.keyS, control: true, alt: true),
        ],
      ),
      // Disabled while no sidebar exists (no bookmark store wired —
      // the region is absent, not hidden). An unwired embedding fails
      // closed too: an enabled-but-inert entry is a fake affordance.
      enabled: sidebarAvailable ?? () => false,
      disabledReason: (l10n) => l10n.commandDisabledNoSidebar,
      run: (context) async {
        // Below the stage-0 boundary the sidebar lives in the overlay
        // drawer — the toggle opens/closes it there rather than latching
        // the inline region's hidden intent (02 §1's stage table).
        final drawer =
            sidebarIsDrawer?.call() ??
            MediaQuery.sizeOf(context).width < desktopStageBoundary;
        if (drawer) {
          toggleSidebarDrawer?.call();
          return;
        }
        workspace.toggleSidebar();
      },
      checked: () => !workspace.sidebarHidden,
      // 10 §8's View menu: Sidebar, Inspector, Second Pane.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 60,
      ),
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.leading,
        order: 10,
      ),
    ),
    RegisteredCommand(
      id: kViewToggleSecondPaneCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.viewToggleSecondPaneLabel,
      icon: Icons.vertical_split_outlined,
      // ⇧⌘D on macOS, Ctrl+Shift+D elsewhere (02 §8.3's table). Hiding
      // keeps the second pane's strip and per-tab state whole — the
      // layout unmounts it; the workspace objects live on (02 §3).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyD, control: true, shift: true),
        ],
      ),
      run: (_) async {
        workspace.toggleSecondPane();
      },
      // 10 §8's View menu: after Show/Hide Inspector (65).
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 70,
      ),
    ),
    RegisteredCommand(
      id: kViewToggleActivityPanelCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.viewToggleActivityPanelLabel,
      icon: Icons.swap_vert,
      hue: FamilyHue.cyan,
      // ⌥⌘A on macOS, Ctrl+Alt+A elsewhere (02 §8.3's table). Hiding is
      // user intent — the panel un-hides on the first-task edge again
      // (02 §6: rows are the queue's only window, D16).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyA, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyA, control: true, alt: true),
        ],
      ),
      run: (_) async {
        workspace.toggleActivityPanel();
      },
      // 10 §8's View menu names the inspector tab it toggles: Info,
      // Transfers, Alerts.
      checked: () => !workspace.activityPanelHidden,
      toolbarPlacement: const CommandToolbarPlacement(
        slot: ToolbarSlot.status,
        order: 10,
        group: 1,
      ),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 85,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kViewTogglePreviewCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.viewTogglePreviewLabel,
      icon: Icons.preview_outlined,
      // ⌥⌘P on macOS, Ctrl+Alt+P elsewhere (02 §8.3's table). While the
      // docked panel is visible on macOS it owns Space — Quick Look is
      // suppressed for as long as it stays open (06 §5's split).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyP, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyP, control: true, alt: true),
        ],
      ),
      enabled: () => preview != null,
      disabledReason: (l10n) => l10n.commandDisabledNoPreview,
      run: (_) async {
        preview?.togglePanel();
      },
      // 10 §8's View menu: the Info tab, where the preview renders,
      // leads the inspector-tab section.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 80,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kViewToggleSyncBrowsingCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.viewToggleSyncBrowsingLabel,
      icon: Icons.link,
      hue: FamilyHue.indigo,
      // ⌥⌘B on macOS, Ctrl+Alt+B elsewhere (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyB, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyB, control: true, alt: true),
        ],
      ),
      // Disabled until both visible tabs stand at committed directories
      // — an unbound pane has nothing to anchor. Once armed the toggle
      // stays live so the link can always be dropped.
      enabled: () =>
          workspace.syncBrowsing.enabled || workspace.syncBrowsing.canLink,
      disabledReason: (l10n) => l10n.commandDisabledSyncAnchors,
      run: (_) async {
        workspace.syncBrowsing.toggle();
      },
      // 10 §8's Go menu: after Focus Left/Right Pane.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.go,
        order: 80,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kPaneFocusLeftCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.paneFocusLeftLabel,
      icon: Icons.west_outlined,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true, alt: true),
        ],
        other: const [
          // The 02 §8.3 spec chord; note Ctrl+Alt+arrows is OS-reserved on
          // some desktops (Intel display rotation on Windows, virtual-
          // desktop switching on KDE/X11) — the secondary Ctrl+PageUp
          // below is never reserved, so focus works on stock installs;
          // delivery still needs verification and the settings slice
          // must allow rebinding.
          SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            control: true,
            alt: true,
          ),
          SingleActivator(LogicalKeyboardKey.pageUp, control: true),
        ],
      ),
      run: (_) async {
        focusLeft();
      },
      // 10 §8's Go menu: Focus Left/Right Pane, Sync Browsing.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.go,
        order: 70,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kPaneFocusRightCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.paneFocusRightLabel,
      icon: Icons.east_outlined,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.arrowRight, meta: true, alt: true),
        ],
        other: const [
          // Same OS-reservation note as pane.focusLeft above; the
          // Ctrl+PageDown secondary mirrors it.
          SingleActivator(
            LogicalKeyboardKey.arrowRight,
            control: true,
            alt: true,
          ),
          SingleActivator(LogicalKeyboardKey.pageDown, control: true),
        ],
      ),
      run: (_) async {
        focusRight();
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.go,
        order: 72,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kPaneSwapFocusCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.paneSwapFocusLabel,
      // Plain Tab only while a listing holds focus (02 §8.2): the pane's
      // focus node dispatches it, not a global chord.
      activators: (_) => const [SingleActivator(LogicalKeyboardKey.tab)],
      run: (_) async {
        swapFocus();
      },
    ),
    RegisteredCommand(
      id: kEditUndoSelectionCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.editUndoSelectionLabel,
      icon: Icons.undo,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyZ, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyZ, control: true, alt: true),
        ],
      ),
      enabled: () => activeTab()?.canUndoSelection ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoSelectionUndo,
      run: (_) async => activeTab()?.undoSelection(),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 10,
      ),
    ),
    RegisteredCommand(
      id: kEditRedoSelectionCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.editRedoSelectionLabel,
      icon: Icons.redo,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(
            LogicalKeyboardKey.keyZ,
            meta: true,
            alt: true,
            shift: true,
          ),
        ],
        other: const [
          SingleActivator(
            LogicalKeyboardKey.keyZ,
            control: true,
            alt: true,
            shift: true,
          ),
        ],
      ),
      enabled: () => activeTab()?.canRedoSelection ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoSelectionRedo,
      run: (_) async => activeTab()?.redoSelection(),
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 20,
      ),
    ),
    RegisteredCommand(
      id: kEditSelectAllCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.editSelectAllLabel,
      icon: Icons.select_all,
      // ⌘A / Ctrl+A (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyA, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyA, control: true)],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.selectAll();
      },
      // Selection undo/redo has its own group before the selection verbs.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 60,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kEditInvertSelectionCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.editInvertSelectionLabel,
      icon: Icons.flip,
      // ⇧⌘I / Ctrl+Shift+I (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyI, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyI, control: true, shift: true),
        ],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.invertSelection();
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 70,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kSelectionQuickSelectCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.selectionQuickSelectLabel,
      icon: Icons.manage_search_outlined,
      // ⌘E / Ctrl+E (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyE, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyE, control: true)],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        activeTab()?.openQuickSelect();
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 80,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kViewFilterCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.viewFilterLabel,
      icon: Icons.filter_list_outlined,
      // ⌘F / Ctrl+F (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyF, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyF, control: true)],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        if (focusFilter != null) {
          focusFilter();
          return;
        }
        activeTab()?.openFilter();
      },
      // 10 §8's Edit menu: Filter in its own last section.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 90,
        group: 4,
      ),
    ),
    RegisteredCommand(
      id: kTabNewCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabNewLabel,
      icon: Icons.add,
      // ⌘T / Ctrl+T (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyT, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyT, control: true)],
      ),
      // Always live — a launcher pane takes a new tab too.
      run: (_) async {
        workspace.activePane.newTab();
      },
      // 10 §8's File menu opens with New Tab, New Folder, New File.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 10,
      ),
    ),
    RegisteredCommand(
      id: kTabCloseCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabCloseLabel,
      icon: Icons.close,
      // ⌘W / Ctrl+W (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyW, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyW, control: true)],
      ),
      enabled: () => workspace.activePane.activeTab != null,
      disabledReason: (l10n) => l10n.commandDisabledNoTab,
      run: (_) async {
        // THE close operation: the guard and confirm live inside it, so
        // this chord and middle-click can never bypass them (02 §3).
        final strip = workspace.activePane;
        final tab = strip.activeTab;
        if (tab != null) await strip.requestCloseTab(tab);
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 30,
        group: 5,
      ),
    ),
    RegisteredCommand(
      id: kTabReopenClosedCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabReopenClosedLabel,
      icon: Icons.restart_alt_outlined,
      // ⇧⌘T / Ctrl+Shift+T (02 §8.3's table), dual registration.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyT, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true),
        ],
      ),
      enabled: () => workspace.activePane.canReopen,
      disabledReason: (l10n) => l10n.commandDisabledNoClosedTab,
      run: (_) async {
        await workspace.activePane.reopenClosedTab();
      },
      // 10 §8's File menu: Reopen Closed Tab and Close Tab share their
      // own section after Move to Trash.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 20,
        group: 5,
      ),
    ),
    RegisteredCommand(
      id: kTabNextCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabNextLabel,
      icon: Icons.tab_outlined,
      // ⌃⇥ on every platform; ⇧⌘] is the additional macOS binding (02
      // §8.3). Cycling is pane-scoped: it never crosses into the other
      // pane's strip.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.tab, control: true),
          SingleActivator(
            LogicalKeyboardKey.bracketRight,
            meta: true,
            shift: true,
          ),
        ],
        other: const [SingleActivator(LogicalKeyboardKey.tab, control: true)],
      ),
      enabled: () => workspace.activePane.tabs.length >= 2,
      disabledReason: (l10n) => l10n.commandDisabledMultipleTabs,
      run: (_) async {
        workspace.activePane.activateNextTab();
      },
      // 02 §9's Window menu carries the tab-navigation rows beside the
      // platform-standard items (group 0 on macOS) — the tab.select1–9
      // block follows at slot 30+.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.window,
        order: 10,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kTabPreviousCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabPreviousLabel,
      icon: Icons.tab_outlined,
      // ⌃⇧⇥ on every platform; ⇧⌘[ is the additional macOS binding.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
          SingleActivator(
            LogicalKeyboardKey.bracketLeft,
            meta: true,
            shift: true,
          ),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
        ],
      ),
      enabled: () => workspace.activePane.tabs.length >= 2,
      disabledReason: (l10n) => l10n.commandDisabledMultipleTabs,
      run: (_) async {
        workspace.activePane.activatePreviousTab();
      },
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.window,
        order: 20,
        group: 1,
      ),
    ),
    RegisteredCommand(
      id: kViewToggleHiddenCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.viewToggleHiddenLabel,
      icon: Icons.visibility_off_outlined,
      // ⇧⌘. is Finder's chord; Ctrl+H is the GNOME/KDE file managers'.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.period, meta: true, shift: true),
        ],
        other: const [SingleActivator(LogicalKeyboardKey.keyH, control: true)],
      ),
      // The tab-local override (02 §2.5): live on any browsing tab — the
      // lens re-derives from the accepted listing, no re-list needed.
      enabled: () => activeTab()?.location != null,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      checked: () => activeTab()?.showHidden ?? false,
      run: (_) async {
        final pane = activeTab();
        if (pane == null) return;
        pane.showHidden = !pane.showHidden;
      },
      // 10 §8's View menu: Show Hidden Files in its own section between
      // the inspector tabs and Refresh.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 100,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kViewSortByCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.viewSortByLabel,
      icon: Icons.sort,
      // The column header's keyboard and menu path (D21: the header's
      // clicks are this command's rows): Sort By ▸ Name / Size / Date
      // Modified, checked on the sorted column. Choosing the sorted
      // column flips its direction, exactly as a header click does.
      enabled: () => activeTab()?.location != null,
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      // The palette's non-menu invocation flips the current column.
      run: (_) async {
        final pane = activeTab();
        if (pane == null) return;
        pane.sortByColumn(pane.sortKey);
      },
      submenuItems: (l10n) => [
        for (final key in _sortColumns)
          RegisteredCommand(
            // Parameter-bound items share the parent's registry id —
            // the suffix only keeps menu keys unique.
            id: '$kViewSortByCommandId:${key.name}',
            scope: CommandScope.pane,
            label: (l10n) => switch (key) {
              FileSortKey.size => l10n.paneColumnSize,
              FileSortKey.modified => l10n.paneColumnModified,
              _ => l10n.paneColumnName,
            },
            enabled: () => activeTab()?.location != null,
            checked: () => activeTab()?.sortKey == key,
            run: (_) async => activeTab()?.sortByColumn(key),
          ),
      ],
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.view,
        order: 105,
        group: 2,
      ),
    ),
    RegisteredCommand(
      id: kSelectionCopyPathCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.selectionCopyPathLabel,
      icon: Icons.content_paste_go_outlined,
      // ⌥⌘C on macOS (Finder's Copy as Pathname), Ctrl+Alt+C elsewhere.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyC, meta: true, alt: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyC, control: true, alt: true),
        ],
      ),
      enabled: () {
        final pane = activeTab();
        return pane != null && paneCopyPathText(pane) != null;
      },
      disabledReason: (l10n) => l10n.commandDisabledNoListing,
      run: (_) async {
        final pane = activeTab();
        final text = pane == null ? null : paneCopyPathText(pane);
        if (pane == null || text == null) return;
        await copyPanePath(pane, text);
      },
      // 10 §8's Edit menu: Copy Path in its own section between the
      // selection verbs and Filter.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.edit,
        order: 85,
        group: 3,
      ),
    ),
  ];
}

List<ShortcutActivator> Function(TargetPlatform) _perPlatform({
  required List<ShortcutActivator> macOS,
  required List<ShortcutActivator> other,
}) {
  return (platform) => platform == TargetPlatform.macOS ? macOS : other;
}

/// Dispatches modified command chords for the shell (02 §8.3's table).
/// A registered chord is owned by the command layer relative to scopes
/// FARTHER from focus — including a disabled command's chord, which is
/// consumed without falling through to outer scopes (standard Flutter
/// focus precedence still lets a nearer surface take a chord first) —
/// locked in by test.
/// Single keys with no ctrl/meta/alt modifier — including shift-only
/// combos like Shift+Tab — are deliberately excluded; they belong to the
/// pane focus nodes (02 §8.2), so this layer can never fire Enter or Tab
/// globally.
///
/// 02 §8.2's field-first precedence: while any text surface (an
/// [EditableText] — the Quick Select field today, the path editor and
/// filter later) holds primary focus, NO chord fires here at all — not
/// even a disabled command's — and the event keeps propagating to the
/// field's own editing shortcuts (⌘A/⌘C/⌘V/⌘X/⌘Z and their Ctrl
/// equivalents live at app scope, which this layer would otherwise
/// intercept first). Dialog routes push above the shell, so their
/// fields never see these chords either.
/// Keys that bind unmodified at the chord layer because they never type
/// text: the Commander-style F5 copy / F6 move to the other pane / F7
/// new folder, and Delete (Move to Trash off macOS; Shift+Delete deletes
/// permanently — both fire only from a pane listing, [_listingOnly]).
/// F2 is not here — rename's F2 stays a pane key (02 §8.2).
final _functionKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.delete,
};

/// The delete family: a selection verb bound to Delete or Backspace
/// (Delete and Shift+Delete off macOS, ⌘⌫ and ⌥⌘⌫ on it). The
/// selection it acts on is a pane listing's, so its chords fire only
/// while a pane listing's own focus node holds primary focus. Pressed
/// on a sidebar row, a tab chip, an inspector or activity row, or a
/// header button, the key must not trash the active pane's selection
/// behind the user's back: there it is consumed without running, the
/// way a disabled command's chord is.
bool _listingOnly(RegisteredCommand command, ShortcutActivator activator) =>
    command.scope == CommandScope.selection &&
    activator is SingleActivator &&
    (activator.trigger == LogicalKeyboardKey.delete ||
        activator.trigger == LogicalKeyboardKey.backspace);

bool _isPaneListing(FocusNode? node) {
  final pane = node?.context?.findAncestorWidgetOfExactType<PaneView>();
  return pane != null && identical(pane.focusNode, node);
}

/// Whether a keystroke on [activator] may run [command] while [focus]
/// holds primary focus: everything may, except the delete family away
/// from a pane listing ([_listingOnly]). The chord scope applies it, and
/// so does the macOS menu for a key equivalent nothing in the window
/// took (AppMenuHost).
bool keyMayRunFrom(
  RegisteredCommand command,
  ShortcutActivator activator,
  FocusNode? focus,
) {
  // The native menu may receive an otherwise unhandled key equivalent.
  // Preserve the chord scope's field-first rule for selection history too.
  if ((command.id == kEditUndoSelectionCommandId ||
          command.id == kEditRedoSelectionCommandId) &&
      focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
    return false;
  }
  return !_listingOnly(command, activator) || _isPaneListing(focus);
}

class CommandChordScope extends StatelessWidget {
  const CommandChordScope({
    super.key,
    required this.commands,
    required this.child,
  });

  final List<RegisteredCommand> commands;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final bindings = <ShortcutActivator, VoidCallback>{};
    final listingOnly = <ShortcutActivator>{};
    for (final command in commands) {
      final activators = command.activators?.call(platform);
      if (activators == null) continue;
      for (final activator in activators) {
        // Unmodified keys — any activator type — stay with the pane focus
        // nodes (02 §8.2), not only SingleActivator spellings; skip them
        // BEFORE the duplicate diagnostics so an unmodified overlap is
        // not misreported as a chord collision.
        // Function keys are never typing keys, so an unmodified F5/F6
        // (the dual-pane copy/move convention) binds at this layer too.
        final bool unmodified = activator is SingleActivator
            ? !activator.control &&
                  !activator.meta &&
                  !activator.alt &&
                  !_functionKeys.contains(activator.trigger)
            : activator is CharacterActivator &&
                  !activator.control &&
                  !activator.meta &&
                  !activator.alt;
        if (unmodified) {
          continue;
        }
        // Two commands claiming one chord is a registration bug; debug
        // builds fail it immediately (release keeps later-command-wins,
        // the documented fallback).
        assert(
          !bindings.containsKey(activator),
          'Duplicate shortcut activator $activator: later command wins',
        );
        // Release builds keep later-command-wins silently by design; the
        // print keeps user-reported "shortcut does nothing" diagnosable.
        if (bindings.containsKey(activator)) {
          debugPrint(
            'Duplicate shortcut activator $activator: later command wins',
          );
        }
        if (_listingOnly(command, activator)) listingOnly.add(activator);
        bindings[activator] = () {
          if (!command.enabled()) return;
          // Pane commands complete without escaping routes, but a
          // future app-scope chord must not leak an unhandled zone
          // error — the guard mirrors _runCommand's.
          unawaited(
            command.run(context).catchError((Object error, StackTrace st) {
              FlutterError.reportError(
                FlutterErrorDetails(exception: error, stack: st),
              );
            }),
          );
        };
      }
    }

    return Focus(
      // Same posture CallbackShortcuts takes: this node only dispatches,
      // it never takes focus or traversal itself.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        // Keep CallbackShortcuts' event contract: bindings fire on
        // down/repeat only — never on key-up.
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        // Field-first precedence (02 §8.2): with a text surface focused,
        // chords belong to its editing shortcuts — returning ignored
        // keeps the event propagating upward to them, where a consumed
        // command chord would have swallowed ⌘A mid-typing.
        final primary = FocusManager.instance.primaryFocus;
        if (primary?.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
          return KeyEventResult.ignored;
        }
        var result = KeyEventResult.ignored;
        for (final activator in bindings.keys) {
          if (activator.accepts(event, HardwareKeyboard.instance)) {
            if (!listingOnly.contains(activator) || _isPaneListing(primary)) {
              bindings[activator]!();
            }
            result = KeyEventResult.handled;
          }
        }
        return result;
      },
      child: child,
    );
  }
}
