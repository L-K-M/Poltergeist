import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'double_click_action.dart';
import 'pane_controller.dart';
import 'pane_engine_lanes.dart';
import 'pane_location.dart';
import 'session_state.dart';
import 'sync_plan_controller.dart';
import 'view_preferences.dart';
import 'workspace_state.dart';

/// What `tab.new` (⌘T) binds a fresh tab to — the persisted "New tabs
/// open" preference's three values (02 §2.1, §3). Read at open time by
/// [PaneTabsController.newTab]; the settings slice writes it through the
/// live [PaneTabsController.newTabTarget] field.
enum NewTabTarget {
  /// The active tab's current location (the default): local duplicates
  /// the folder, remote reconnects the same server at the same path.
  /// An unbound source leaves the new tab on the launcher.
  duplicate,

  /// The pane's home: local home for a local tab, the remote binding's
  /// own landing path (bookmark path, else server home) for a remote one.
  home,

  /// The unbound launcher surface (02 §2.7) — no channel opens.
  launcher,
}

/// The close-guard trigger kinds — 02 §3's exact set, spelled as a
/// registry ([PaneTabsController._closeGuards]). Each entry's probe
/// reports whether the tab carries that in-flight state at close time.
/// Folder-size, apply-to-enclosed, and Sync anchor are declared now so
/// their slices add a probe line — never a reshape of the close
/// operation or of the confirm dialog's `List<TabCloseTrigger>`.
enum TabCloseTrigger {
  /// A listing navigation is outstanding on the tab (02 §3).
  navigation,

  /// The tab's inline-rename session is open. Nothing opens one this
  /// slice — the row-interactions slice writes [PaneController]'s flag;
  /// the probe already guards it.
  inlineRename,

  /// A recursive folder-size computation is running (02 §3). Declared
  /// for its slice; nothing produces it yet.
  folderSize,

  /// An apply-to-enclosed-items permissions change is running (02 §2.6,
  /// §3) — the inspector's count pass, pending confirmation, or chmod
  /// walk.
  applyToEnclosed,

  /// The tab anchors a Sync Browsing pair (02 §7). Declared for its
  /// slice; nothing produces it yet.
  syncAnchor,
}

/// One close-guard probe: whether [TabCloseTrigger]'s condition holds for
/// the controller — evaluated at close time, never cached.
typedef _CloseGuard = (TabCloseTrigger, bool Function(PaneController));

/// The active registry (02 §3's trigger set): the two v1 probes, the
/// Sync Browsing anchor probe (02 §7 — closing an anchored tab takes the
/// link down, so the guard asks first), then the declared-for-later
/// kinds. A later slice adds one line — a probe that reports its
/// trigger — and the guard, the dialog, and every close route pick it
/// up unchanged. (Not const: closures cannot be.)
final _closeGuards = <_CloseGuard>[
  (TabCloseTrigger.navigation, (c) => c.loading),
  (TabCloseTrigger.inlineRename, (c) => c.inlineRenameActive),
  (TabCloseTrigger.folderSize, (c) => c.folderSizeInFlight),
  (TabCloseTrigger.applyToEnclosed, (c) => c.applyToEnclosedInFlight),
  (TabCloseTrigger.syncAnchor, (c) => c.syncAnchorActive),
];

/// What [PaneTabsController.requestCloseTab] settled to.
enum TabCloseOutcome {
  /// The tab closed.
  closed,

  /// Guard triggers fired and the user declined — or no presenter was
  /// wired: a guard that cannot ask never drops in-flight state
  /// silently, so it fails closed.
  declined,

  /// The tab was already gone (a racing close settled first, or the
  /// pane was disposed mid-confirmation).
  stale,
}

/// The close-confirmation presenter the shell wires onto
/// [PaneTabsController.confirmClose]: given the tab and its active
/// triggers, answers whether the close proceeds.
typedef TabCloseConfirm =
    Future<bool> Function(PaneTab tab, List<TabCloseTrigger> triggers);

/// Proof that [PaneTabsController.confirmTabReplacement] asked the
/// presenter for every triggered tab and the user accepted — the token
/// [PaneTabsController.replaceTabs] consumes so the workspace open's
/// close phase never re-asks a question the confirm phase already
/// settled. Opaque on purpose: callers transport it, only the strip
/// that minted it reads it.
final class TabReplacementPermit {
  TabReplacementPermit._(this._confirmed);

  /// Each confirmed tab's trigger set AT CONFIRM TIME — matched against
  /// the live probes at close, so in-flight state that materialized
  /// while the dialogs were up can never ride a stale grant.
  final Map<PaneTab, List<TabCloseTrigger>> _confirmed;
}

/// One tab in a pane's strip: strip identity plus the engine-facing
/// browsing controller. Every per-tab state lives on the controller
/// (location, listing, selection, cursor, transient filter, hidden-file
/// override, view mode, Quick Select session), so switching tabs is an
/// atomic pointer change — nothing is copied or drained.
final class PaneTab {
  const PaneTab({
    required this.id,
    required this.controller,
    this.syncSession,
  });

  /// The strip's stable id — doubles as the engine channel's paneTabId
  /// (`pane.left.tab3`), so channels and strip keys share one identity.
  /// The pane prefix names where the tab was CREATED: a tab dragged to
  /// the other pane keeps its minted id, so the engine channel rides
  /// the move untouched (02 §3). Never parse the prefix back out to
  /// find a tab's current pane — the id names where it was minted,
  /// not where it lives.
  final String id;

  /// The tab's browsing state; owned and disposed by the strip.
  final PaneController controller;

  /// A sync plan-view session (05 §7): the tab mounts the plan view
  /// instead of the browsing view when set. The strip still owns the
  /// controller — identity, close-guard, and listener plumbing — while
  /// the session owns the sync lifecycle. Never persisted: a sync tab
  /// is a session, not a location, so it ghosts nor restores through
  /// neither ⇧⌘T nor the workspace document.
  final SyncPlanController? syncSession;
}

/// What a closed tab can bring back through ⇧⌘T: the binding identity and
/// the transient per-tab lenses. Selection and in-flight state are NOT
/// restorable — a ghost never replays rows or a cursor (selection keys
/// name live listing identities that no longer stand, 02 §2.5), and an
/// in-flight navigation has no committed answer to restore: the reopened
/// tab lists the location fresh.
final class _GhostTab {
  const _GhostTab({
    required this.location,
    required this.bookmark,
    required this.filterQuery,
    required this.filterFieldOpen,
    required this.showHidden,
    required this.viewMode,
  });

  /// The location the tab last pointed at (the optimistic target while
  /// a navigation was in flight — the user saw the tab committed to it).
  /// Null while the tab sat on the launcher.
  final PaneLocation? location;

  /// The remote binding to re-open; null for local and launcher tabs.
  final Bookmark? bookmark;

  final String filterQuery;
  final bool filterFieldOpen;
  final bool showHidden;
  final PaneViewMode viewMode;
}

/// One pane's tab strip state (02 §3): the ordered tab set, the active
/// tab, the ghost ring, and the tab lifecycle operations.
///
/// The close guard lives INSIDE [requestCloseTab] — the state operation
/// itself, per the SEA-009 lesson — so every close route (⌘W,
/// middle-click, a future workspace replace) shares the one decision
/// point and none can bypass it.
class PaneTabsController extends ChangeNotifier {
  PaneTabsController({
    required this.paneId,
    PaneEngineLanes? lanes,
    this.newTabTarget = NewTabTarget.duplicate,
    DoubleClickAction doubleClickAction = DoubleClickAction.open,
    this.builtInEditorOpen,
    this.externalEditorOpen,
    this.confirmClose,
    this.serverStillShared,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : // The live preference initializes the private field directly —
       // the setter's propagate-to-tabs write is for post-construction
       // changes, not the seed (no tabs exist yet).
       // ignore: prefer_initializing_formals
       _doubleClickAction = doubleClickAction,
       // Keep the lanes seam private to the strip.
       // ignore: prefer_initializing_formals
       _lanes = lanes,
       // Keep the reporter private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _onError = onError;

  /// 'pane.left' / 'pane.right' — prefixes the generated tab ids and
  /// selects the pane's name in semantics.
  final String paneId;

  /// The canonical pane ids (02 §1's pane A/pane B) — surfaces compare
  /// against these names rather than spreading the literal. The values
  /// themselves live with the session document's schema: its decode
  /// rejects any pane set that isn't exactly these two.
  static const leftPaneId = sessionLeftPaneId;
  static const rightPaneId = sessionRightPaneId;

  /// Whether this strip is the left pane (02 §1's pane A).
  bool get isLeftPane => paneId == leftPaneId;

  /// The "New tabs open" preference's live value (02 §2.1): read at
  /// every `tab.new`; the settings slice writes it.
  NewTabTarget newTabTarget;

  /// The "Reconnect restored tabs automatically" setting's live value
  /// (02 §3): read when a session-restored remote tab activates. With
  /// it off, activation alone never reconnects — the tab's Reconnect
  /// bar waits for the explicit click (the metered/VPN case). A
  /// restored LOCAL tab rebinds on activation regardless.
  bool reconnectRestoredTabs = true;

  /// The "Double-click action" preference's live value (02 §2.6): read
  /// at every file open through each tab's [PaneController]. Writing it
  /// propagates to every open tab immediately — the setting must not
  /// wait for the next tab to take effect — and [_appendTab] stamps it
  /// on every later arrival, so adopted, new, and ghost-reopened tabs
  /// all open files under the current value.
  DoubleClickAction get doubleClickAction => _doubleClickAction;
  set doubleClickAction(DoubleClickAction value) {
    if (_doubleClickAction == value) return;
    _doubleClickAction = value;
    for (final tab in _tabs) {
      tab.controller.doubleClickAction = value;
    }
  }

  DoubleClickAction _doubleClickAction;

  /// The built-in editor's open seam (06 §4.2), wired once at strip
  /// construction by the shell and stamped on every arriving tab in
  /// [_appendTab] — adopted, new, restored, and ghost-reopened
  /// controllers alike open files through the same wiring.
  final BuiltInEditorOpen? builtInEditorOpen;

  /// The external-editor open seam (06 §4.2), wired once at strip
  /// construction by the shell and stamped on every arriving tab like
  /// [builtInEditorOpen] — the remote Open verb and every Open With ▸
  /// choice resolve through it.
  final ExternalEditorOpen? externalEditorOpen;

  /// The close-confirmation presenter (the confirm lives inside the
  /// close operation — call sites never decide). Null makes a triggered
  /// close fail closed: a guard that cannot ask never drops in-flight
  /// state silently.
  final TabCloseConfirm? confirmClose;

  /// Whether another surface still browses [serverId] — the workspace
  /// wires the cross-pane check so a closed remote tab drops the server
  /// reference only when it was the last binding (the pooled server is
  /// shared across tabs AND panes, 03 §3.2). This pane's own tabs are
  /// counted internally regardless. Null means "no sibling knowledge":
  /// only this strip's other tabs count.
  final bool Function(String serverId, PaneController excluding)?
  serverStillShared;

  final PaneEngineLanes? _lanes;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  final _tabs = <PaneTab>[];

  /// The ghost ring — most-recently-closed last, capped at 10 (02 §3).
  final _ghosts = <_GhostTab>[];
  static const _ghostRingSize = 10;

  /// Re-entrant close guard: a second ⌘W while the confirm is up rides
  /// the same operation — never a second dialog.
  final _closeInFlight = <PaneTab, Future<TabCloseOutcome>>{};

  /// 02 §2.6's Get Info inspector: pane chrome, so the flag lives on the
  /// strip rather than any one tab — it retargets to the ACTIVE tab's
  /// selection, and a tab switch carries it to the new tab.
  bool _infoPanelOpen = false;

  int _nextTabOrdinal = 1;
  int _activeIndex = -1;
  bool _disposed = false;

  /// The strip's tabs in order.
  List<PaneTab> get tabs => List.unmodifiable(_tabs);

  /// The tab the pane renders; null while the pane sits on the launcher.
  PaneTab? get activeTab => _activeIndex >= 0 && _activeIndex < _tabs.length
      ? _tabs[_activeIndex]
      : null;

  /// Whether ⇧⌘T has a ghost to reopen.
  bool get canReopen => _ghosts.isNotEmpty;

  /// The active tab's browsing controller — the surface pane commands
  /// resolve against; null while the pane sits on the launcher.
  PaneController? get activeTabController => activeTab?.controller;

  /// Whether the Get Info inspector is showing (02 §2.6). Read as false
  /// while the pane sits on the launcher — there is no listing for the
  /// panel to slide over.
  bool get infoPanelOpen => _infoPanelOpen && activeTab != null;

  /// `file.getInfo` (⌘I / Alt+Enter): toggles the inspector over this
  /// pane's right edge. Opening needs no target check — the command's
  /// enablement owns that; closing ends every tab's folder-size
  /// measurement and enclosed-apply operation (the panel is their only
  /// consumer, so work outliving it would hold the close-guard trigger
  /// for nothing — and the apply's confirmation dialog would be
  /// orphaned).
  void toggleInfoPanel() {
    // No listing, no inspector: a chord landing on the launcher must
    // not latch the flag open for the next tab to inherit — the getter
    // masks it, so the toggle would otherwise move hidden state.
    if (_disposed || activeTab == null) return;
    _infoPanelOpen = !_infoPanelOpen;
    if (!_infoPanelOpen) {
      for (final tab in _tabs) {
        tab.controller.cancelFolderSize();
        tab.controller.cancelEnclosedApply();
      }
    }
    notifyListeners();
  }

  /// The inspector's Esc tier and ✕ affordance (02 §8.2's slot).
  void closeInfoPanel() {
    if (_infoPanelOpen) toggleInfoPanel();
  }

  /// `tab.new` (⌘T): creates, appends, and activates a tab per [target]
  /// (the persisted preference when omitted). The bind is initiated but
  /// not awaited — the tab opens immediately and its own surfaces render
  /// the progress.
  PaneTab newTab({NewTabTarget? target}) {
    assert(!_disposed, 'newTab on a disposed PaneTabsController');
    // Capture the duplicate source BEFORE the new tab activates —
    // "current location" means the tab that was active when ⌘T fired.
    final source = activeTab;
    final tab = _appendTab(
      PaneController(
        paneTabId: '$paneId.tab${_nextTabOrdinal++}',
        lanes: _lanes,
        onError: _onError,
      ),
    );
    activateTab(tab);
    _bindNewTab(tab, source, target ?? newTabTarget);
    return tab;
  }

  /// Adopts a caller-built controller as a tab — the tab-set seeding
  /// seam a workspace restore (02 §3's snapshots, a later slice) and the
  /// test surface both drive. The adopted tab activates when it is the
  /// pane's first.
  PaneTab addTab(PaneController controller) {
    assert(!_disposed, 'addTab on a disposed PaneTabsController');
    final tab = _appendTab(controller);
    if (_activeIndex < 0) activateTab(tab);
    return tab;
  }

  /// `sync.synchronizePanes` / savedSync activation (05 §7): opens the
  /// plan view as a first-class tab in THIS pane's strip. The session
  /// arrives fully built (the shell composes it from the pair); the
  /// strip owns a PaneController alongside it purely for identity and
  /// close-guard plumbing — it never lists.
  PaneTab openSyncPlanTab(SyncPlanController session) {
    assert(!_disposed, 'openSyncPlanTab on a disposed PaneTabsController');
    final controller = PaneController(
      paneTabId: '$paneId.tab${_nextTabOrdinal++}',
      lanes: _lanes,
      onError: _onError,
    );
    controller.doubleClickAction = _doubleClickAction;
    controller.addListener(_forwardTabChange);
    final tab = PaneTab(
      id: controller.paneTabId,
      controller: controller,
      syncSession: session,
    );
    _tabs.add(tab);
    activateTab(tab);
    return tab;
  }

  void _bindNewTab(PaneTab tab, PaneTab? source, NewTabTarget target) {
    final controller = tab.controller;
    switch (target) {
      case NewTabTarget.launcher:
        // Unbound by construction: the tab renders the launcher.
        return;
      case NewTabTarget.duplicate:
        final location = source?.controller.location;
        final bookmark = source?.controller.remoteBookmark;
        if (bookmark != null) {
          // initialPath may be null mid-connect: the bookmark's own
          // landing path stands in then.
          unawaited(
            controller.connectRemote(
              bookmark,
              initialPath: location is RemotePaneLocation
                  ? location.path
                  : null,
            ),
          );
        } else if (location is LocalPaneLocation) {
          unawaited(controller.openLocalAt(location.path));
        }
        // An unbound source duplicates to an unbound tab.
      case NewTabTarget.home:
        final bookmark = source?.controller.remoteBookmark;
        if (bookmark != null) {
          unawaited(controller.connectRemote(bookmark));
        } else {
          unawaited(controller.openLocalHome());
        }
    }
  }

  /// Makes [tab] the pane's visible tab — an atomic swap: every per-tab
  /// state lives on its own controller, so activation is a pointer
  /// change and nothing leaks across it.
  void activateTab(PaneTab tab) {
    if (_disposed) return;
    final index = _tabs.indexOf(tab);
    if (index < 0 || index == _activeIndex) return;
    _activeIndex = index;
    notifyListeners();
    _resumeRestoredTab(tab);
  }

  /// 02 §3's launch restoration: seeds the strip from the persisted
  /// session pane — the tab objects in order, the persisted active tab,
  /// and the id counter so post-restore mints cannot collide with the
  /// persisted ids. Nothing opens beyond the persisted set: a pane that
  /// saved zero tabs stays on its launcher (restoration never
  /// auto-opens), and an unbound persisted tab restores as unbound.
  /// The active restored tab then resumes per [reconnectRestoredTabs].
  void restoreSession(SessionPaneState state) {
    assert(!_disposed, 'restoreSession on a disposed PaneTabsController');
    for (final tabState in state.tabs) {
      final controller = PaneController(
        paneTabId: '$paneId.tab${_nextTabOrdinal++}',
        lanes: _lanes,
        onError: _onError,
      );
      controller.markRestored(tabState);
      _appendTab(controller);
    }
    if (state.nextTabOrdinal > _nextTabOrdinal) {
      _nextTabOrdinal = state.nextTabOrdinal;
    }
    _activeIndex = _tabs.isEmpty
        ? -1
        : state.activeTab.clamp(0, _tabs.length - 1);
    notifyListeners();
    final active = activeTab;
    if (active != null) _resumeRestoredTab(active);
  }

  /// The strip's half of the session document (02 §3): the ordered
  /// tabs, the active index (-1 on the launcher), and the id counter —
  /// persisted so post-restore mints stay collision-free.
  SessionPaneState captureSession() {
    // Sync tabs are sessions, not locations — they never persist.
    final restorable = _browsableTabs();
    return SessionPaneState(
      paneId: paneId,
      activeTab: _browsableActiveIndex(restorable),
      nextTabOrdinal: _nextTabOrdinal,
      tabs: List.unmodifiable([
        for (final tab in restorable) tab.controller.captureSessionTab(),
      ]),
    );
  }

  List<PaneTab> _browsableTabs() =>
      [for (final tab in _tabs) if (tab.syncSession == null) tab];

  int _browsableActiveIndex(List<PaneTab> restorable) {
    final active = activeTab;
    if (active == null) return -1;
    final index = restorable.indexOf(active);
    // The active tab IS a sync session: point the persisted strip at
    // its nearest browsable neighbor so restore lands somewhere real.
    if (index >= 0) return index;
    final activeRaw = _tabs.indexOf(active);
    for (var i = activeRaw - 1; i >= 0; i--) {
      final candidate = _tabs[i];
      if (candidate.syncSession == null) {
        return restorable.indexOf(candidate);
      }
    }
    return restorable.isEmpty ? -1 : 0;
  }

  /// The strip's half of a workspace snapshot (02 §3's "Save
  /// Workspace…"): everything [captureSession] records PLUS the
  /// transient per-tab lenses — filter, hidden override, view mode —
  /// which the session document excludes but a workspace must keep
  /// ("per-tab view state").
  WorkspacePaneState captureWorkspacePane() {
    final restorable = _browsableTabs();
    return WorkspacePaneState(
      paneId: paneId,
      activeTab: _browsableActiveIndex(restorable),
      tabs: List.unmodifiable([
        for (final tab in restorable)
          WorkspaceTabState(
            session: tab.controller.captureSessionTab(),
            filterQuery: tab.controller.filterQuery,
            filterFieldOpen: tab.controller.filterFieldOpen,
            showHidden: tab.controller.showHidden,
            viewMode: tab.controller.viewMode,
          ),
      ]),
    );
  }

  /// The workspace open's first phase (02 §3): asks [confirmClose] for
  /// every currently-triggered tab BEFORE anything closes — the
  /// workspace runs this on BOTH panes first, so a decline on either
  /// leaves every strip exactly as it stood. Returns the grant
  /// [replaceTabs] consumes, or null on decline, absent presenter, or
  /// presenter fault — the same fail-closed rules [requestCloseTab]
  /// applies to a single close.
  ///
  /// This is the batch form of [_closeGuarded]'s ask, not a second
  /// guard: it reads the same [_closeGuards] registry and the same
  /// presenter, so the workspace open can never dodge a trigger a ⌘W
  /// close would surface.
  Future<TabReplacementPermit?> confirmTabReplacement() async {
    if (_disposed) return null;
    final confirmed = <PaneTab, List<TabCloseTrigger>>{};
    for (final tab in List.of(_tabs)) {
      // A racing close may have settled the tab while an earlier
      // confirm was up — nothing to guard anymore.
      if (!_tabs.contains(tab)) continue;
      final triggers = closeTriggers(tab);
      if (triggers.isEmpty) continue;
      final presenter = confirmClose;
      if (presenter == null) {
        // A guard that cannot ask fails closed: in-flight state is
        // never dropped by a replacement that could not confirm it.
        _report(
          StateError('tab replacement guard fired with no presenter wired'),
          StackTrace.current,
        );
        return null;
      }
      final bool accepted;
      try {
        accepted = await presenter(tab, triggers);
      } catch (error, stackTrace) {
        _report(error, stackTrace);
        return null;
      }
      if (_disposed) return null;
      // A decline before the first close leaves the whole strip — and
      // the whole workspace — untouched (02 §3).
      if (!accepted) return null;
      confirmed[tab] = triggers;
    }
    return TabReplacementPermit._(confirmed);
  }

  /// The workspace open's second phase — reached only after THIS
  /// strip's [confirmTabReplacement] returned [permit]: closes every
  /// current tab through [_closeTab] (the same teardown
  /// [requestCloseTab] ends in — ghost ring, sibling-aware remote
  /// refcounting, channel release), then seeds [state] like
  /// [restoreSession], additionally restoring each tab's saved lenses.
  ///
  /// A tab whose live trigger set no longer matches its confirmed set —
  /// in-flight state that materialized while the dialogs were up —
  /// re-enters the guarded single close instead of dropping under a
  /// stale grant. A decline there keeps that tab (the user just refused
  /// to lose it); the rest of the swap still proceeds, and the survivor
  /// stays at its position ahead of the workspace tabs.
  Future<void> replaceTabs(
    WorkspacePaneState state,
    TabReplacementPermit permit,
  ) async {
    // Runtime, not assert-only: the snapshot is decoded external data,
    // and in release a swapped pane section would otherwise land on the
    // wrong strip silently.
    if (state.paneId != paneId) {
      throw ArgumentError.value(
        state.paneId,
        'state.paneId',
        'workspace pane state must match the strip it lands on',
      );
    }
    for (final tab in List.of(_tabs)) {
      if (_disposed || !_tabs.contains(tab)) continue;
      final granted = permit._confirmed[tab];
      final current = closeTriggers(tab);
      if (current.isNotEmpty &&
          (granted == null || !listEquals(current, granted))) {
        // New or changed in-flight state since the batch confirm — the
        // shared single-close operation re-asks rather than dropping it
        // silently.
        await requestCloseTab(tab);
        continue;
      }
      await _closeTab(tab);
    }
    if (_disposed) return;
    // Any surviving tabs keep their slots; the workspace tabs append
    // after them, and the saved active index counts from there.
    final offset = _tabs.length;
    for (final tabState in state.tabs) {
      final controller = PaneController(
        paneTabId: '$paneId.tab${_nextTabOrdinal++}',
        lanes: _lanes,
        onError: _onError,
      );
      controller.markRestored(tabState.session);
      // The lenses apply unconditionally — restoreTransientState is the
      // ghost ring's seam, and a workspace restores the view the user
      // saved rather than the keystrokes that produced it.
      controller.restoreTransientState(
        filterQuery: tabState.filterQuery,
        filterFieldOpen: tabState.filterFieldOpen,
        showHidden: tabState.showHidden,
        viewMode: tabState.viewMode,
      );
      _appendTab(controller);
    }
    if (state.tabs.isNotEmpty) {
      _activeIndex = offset + state.activeTab.clamp(0, state.tabs.length - 1);
    }
    notifyListeners();
    // The workspace's active tab resumes exactly like a launch-restored
    // one: local rebinds, remote honors reconnectRestoredTabs.
    final active = activeTab;
    if (active != null) _resumeRestoredTab(active);
  }

  /// The 02 §3 activation rule for session-restored tabs: a restored
  /// local tab rebinds on activation; a restored remote tab reconnects
  /// on activation only while the auto-reconnect preference allows —
  /// off, its Reconnect bar waits for the click and activation alone
  /// never reconnects.
  void _resumeRestoredTab(PaneTab tab) {
    final controller = tab.controller;
    if (!controller.restoredPending) return;
    if (controller.remoteBookmark != null && !reconnectRestoredTabs) {
      return;
    }
    unawaited(controller.resumeRestored());
  }

  /// `tab.next` (⌃⇥ / ⇧⌘]): cycles forward within this pane's strip,
  /// wrapping past the last tab.
  void activateNextTab() => _cycleTab(1);

  /// `tab.previous` (⌃⇧⇥ / ⇧⌘[): cycles backward, wrapping past the
  /// first tab.
  void activatePreviousTab() => _cycleTab(-1);

  void _cycleTab(int delta) {
    final count = _tabs.length;
    if (_disposed || count < 2 || _activeIndex < 0) return;
    // Dart's % is non-negative, so the backward leg wraps for free.
    _activeIndex = (_activeIndex + delta) % count;
    notifyListeners();
    _resumeRestoredTab(_tabs[_activeIndex]);
  }

  /// The guard triggers currently active on [tab] — the registry's
  /// probes evaluated at this instant (02 §3). The close operation reads
  /// this; the dialog renders it.
  List<TabCloseTrigger> closeTriggers(PaneTab tab) {
    final controller = tab.controller;
    return List.unmodifiable([
      for (final (trigger, probe) in _closeGuards)
        if (probe(controller)) trigger,
      // A running sync session guards its tab under the same anchor
      // trigger — the dialog's wording already names it.
      if (tab.syncSession?.isRunning ?? false) TabCloseTrigger.syncAnchor,
    ]);
  }

  /// THE close operation (02 §3) — ⌘W, middle-click, and every future
  /// close route share it, so the tab-scoped-state guard can never be
  /// bypassed. With no trigger active the tab closes silently; with any
  /// trigger the operation asks [confirmClose] — the confirmation is in
  /// the state operation itself, never the call site.
  ///
  /// Re-entrant calls while a confirmation is pending return the same
  /// in-flight operation.
  Future<TabCloseOutcome> requestCloseTab(PaneTab tab) {
    final pending = _closeInFlight[tab];
    if (pending != null) return pending;
    if (_disposed || !_tabs.contains(tab)) {
      return Future.value(TabCloseOutcome.stale);
    }
    // The entry is owned HERE, not by _closeGuarded: a guard path that
    // settles without awaiting (fail-closed with no presenter) completes
    // synchronously, and a finally inside the callee would run before
    // this line ever stored the future — leaving a stale entry that
    // dedupes every later close to the dead outcome.
    final future = _closeGuarded(tab).whenComplete(() {
      // A block body matters: Map.remove returns the removed future —
      // which IS the whenComplete wrapper — and a FutureOr-returning
      // callback would make whenComplete await its own future forever.
      _closeInFlight.remove(tab);
    });
    _closeInFlight[tab] = future;
    return future;
  }

  Future<TabCloseOutcome> _closeGuarded(PaneTab tab) async {
    final triggers = closeTriggers(tab);
    if (triggers.isNotEmpty) {
      final presenter = confirmClose;
      if (presenter == null) {
        // A guard that cannot ask fails closed: in-flight state is
        // never dropped by a close that could not confirm it.
        _report(
          StateError('tab close guard fired with no presenter wired'),
          StackTrace.current,
        );
        return TabCloseOutcome.declined;
      }
      // A presenter fault fails closed like a declined confirm: the tab
      // keeps its in-flight state and the close stays retryable — the
      // fire-and-forget call sites must never see the throw escape.
      final bool accepted;
      try {
        accepted = await presenter(tab, triggers);
      } catch (error, stackTrace) {
        _report(error, stackTrace);
        return TabCloseOutcome.declined;
      }
      // The await above is the SEA-009 window: the workspace may have
      // torn down, or a racing close may have settled the tab.
      if (_disposed || !_tabs.contains(tab)) return TabCloseOutcome.stale;
      if (!accepted) return TabCloseOutcome.declined;
    }
    await _closeTab(tab);
    return TabCloseOutcome.closed;
  }

  /// The actual removal — reached only after the guard cleared. Captures
  /// the ghost BEFORE the detach drops the binding, swaps the visible
  /// tab synchronously, then releases the engine binding.
  Future<void> _closeTab(PaneTab tab) async {
    final index = _tabs.indexOf(tab);
    if (index < 0) return;
    // Sync sessions never ghost — ⇧⌘T restores locations, and a closed
    // plan view's reviewed state is gone for good (a fresh scan is the
    // only honest reopen).
    if (tab.syncSession == null) _pushGhost(_ghostOf(tab));
    tab.syncSession?.dispose();
    _tabs.removeAt(index);
    if (_activeIndex == index) {
      // The neighbor at the closed tab's slot slides in; closing the
      // strip's last tab keeps the new last one, and closing the pane's
      // last tab leaves the pane on the launcher — never blank, never
      // an auto-opened replacement (02 §3).
      _activeIndex = _tabs.isEmpty ? -1 : index.clamp(0, _tabs.length - 1);
    } else if (_activeIndex > index) {
      _activeIndex--;
    }
    // The launcher has no listing to inspect — drop the flag with the
    // last tab so the next tab can't inherit a latched-open inspector.
    if (_tabs.isEmpty) _infoPanelOpen = false;
    notifyListeners();

    final controller = tab.controller;
    controller.removeListener(_forwardTabChange);
    final serverId = controller.remoteBookmark?.id;
    // A session-restored tab holds the bookmark but no pool reference —
    // closing it is a plain dispose, never a server detach.
    if (serverId != null && controller.hasLiveRemoteBinding) {
      // Remote close = the banner-cancel path's sibling rule (03 §3.2):
      // drop the pooled reference only when this was its last binding,
      // re-checked AFTER the detach's awaited channel release (a
      // sibling may bind the server mid-release).
      await controller.cancelRecovery(
        serverStillUnshared: () => !_serverStillBound(serverId, controller),
      );
    }
    controller.dispose();
  }

  bool _serverStillBound(String serverId, PaneController excluding) =>
      _tabs.any(
        (t) =>
            !identical(t.controller, excluding) &&
            t.controller.hasLiveRemoteBinding &&
            t.controller.remoteBookmark?.id == serverId,
      ) ||
      (serverStillShared?.call(serverId, excluding) ?? false);

  /// `tab.reopenClosed` (⇧⌘T): pops the most recent ghost, appends and
  /// activates a tab for it, re-opens its binding, then restores the
  /// transient lenses. The bind is awaited so the restore lands after
  /// the bind's own reset — and a failed reopen still carries the
  /// lenses it had (the bind fault surfaces on the tab's error state).
  Future<PaneTab?> reopenClosedTab() async {
    if (_disposed || _ghosts.isEmpty) return null;
    final ghost = _ghosts.removeLast();
    final tab = _appendTab(
      PaneController(
        paneTabId: '$paneId.tab${_nextTabOrdinal++}',
        lanes: _lanes,
        onError: _onError,
      ),
    );
    activateTab(tab);

    final controller = tab.controller;
    final bookmark = ghost.bookmark;
    final location = ghost.location;
    if (bookmark != null) {
      await controller.connectRemote(
        bookmark,
        initialPath: location is RemotePaneLocation ? location.path : null,
      );
    } else if (location is LocalPaneLocation) {
      await controller.openLocalAt(location.path);
    }
    // The reopened tab may itself have been closed while the bind was
    // in flight — its controller is disposed then, so the lens restore
    // must not run (the strip-disposed check alone misses that case).
    if (_disposed || !_tabs.contains(tab)) return tab;
    controller.restoreTransientState(
      filterQuery: ghost.filterQuery,
      filterFieldOpen: ghost.filterFieldOpen,
      showHidden: ghost.showHidden,
      viewMode: ghost.viewMode,
    );
    return tab;
  }

  /// The source half of the workspace's inter-pane move (02 §3's "drag
  /// tabs between panes"). Detaching is NOT a close: [requestCloseTab]'s
  /// guard does not run — moving a tab is not closing it, so an
  /// in-flight navigation, rename, or anchor state travels with the tab
  /// and settles on the destination pane. No ghost is pushed (⇧⌘T must
  /// not resurrect a tab that still lives), the controller is never
  /// disposed, and its engine channel — keyed to the tab's stable
  /// paneTabId — crosses untouched.
  ///
  /// A pane losing its last tab lands on the launcher, exactly as a
  /// guarded last close leaves it (02 §3): [activeTab] goes null.
  void detachTabForMove(PaneTab tab) {
    final index = _tabs.indexOf(tab);
    if (_disposed || index < 0) return;
    _tabs.removeAt(index);
    tab.controller.removeListener(_forwardTabChange);
    if (_activeIndex == index) {
      _activeIndex = _tabs.isEmpty ? -1 : index.clamp(0, _tabs.length - 1);
    } else if (_activeIndex > index) {
      _activeIndex--;
    }
    // A stripped pane lands on the launcher — no listing, no inspector.
    if (_tabs.isEmpty) _infoPanelOpen = false;
    notifyListeners();
  }

  /// The destination half of the move: [tab] — already detached by its
  /// source strip — inserts at [index] (clamped; null appends) and
  /// activates, since a dropped tab is the one the user is looking at.
  /// The strip's live settings stamp on arrival like any other tab.
  /// The guards run in release too, and a refusal is explicit: false
  /// means the tab was NOT adopted (the workspace re-homes it), so a
  /// live tab can never sit silently between strips.
  bool adoptMovedTab(PaneTab tab, {int? index}) {
    if (_disposed || _tabs.contains(tab)) return false;
    final insertion = (index ?? _tabs.length).clamp(0, _tabs.length);
    // Keep the active pointer on its own tab through the insertion.
    if (_activeIndex >= insertion) _activeIndex++;
    tab.controller.doubleClickAction = _doubleClickAction;
    tab.controller.addListener(_forwardTabChange);
    _tabs.insert(insertion, tab);
    activateTab(tab);
    return true;
  }

  _GhostTab _ghostOf(PaneTab tab) {
    final controller = tab.controller;
    return _GhostTab(
      location: controller.location,
      bookmark: controller.remoteBookmark,
      filterQuery: controller.filterQuery,
      filterFieldOpen: controller.filterFieldOpen,
      showHidden: controller.showHidden,
      viewMode: controller.viewMode,
    );
  }

  void _pushGhost(_GhostTab ghost) {
    _ghosts.add(ghost);
    // Oldest-out at the cap — reopen pops from the other end (most
    // recently closed first, 02 §3): a bounded LIFO stack, not a queue.
    while (_ghosts.length > _ghostRingSize) {
      _ghosts.removeAt(0);
    }
  }

  PaneTab _appendTab(PaneController controller) {
    // Every arrival opens files under the strip's current setting —
    // adopted, new, and ghost-reopened controllers alike.
    controller.doubleClickAction = _doubleClickAction;
    controller.builtInEditorOpen = builtInEditorOpen;
    controller.externalEditorOpen = externalEditorOpen;
    final tab = PaneTab(id: controller.paneTabId, controller: controller);
    // Strip surfaces (title, connection dot) follow the tab's own
    // browsing state — forward its changes as strip changes.
    controller.addListener(_forwardTabChange);
    _tabs.add(tab);
    return tab;
  }

  void _forwardTabChange() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final tab in _tabs) {
      tab.controller.removeListener(_forwardTabChange);
      tab.controller.dispose();
      tab.syncSession?.dispose();
    }
    _tabs.clear();
    _ghosts.clear();
    _closeInFlight.clear();
    _activeIndex = -1;
    super.dispose();
  }

  void _report(Object error, StackTrace stackTrace) {
    final sink = _onError;
    if (sink != null) {
      sink(error, stackTrace);
    } else {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stackTrace),
      );
    }
  }
}
