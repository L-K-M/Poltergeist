import 'dart:async';

import 'package:flutter/foundation.dart';

import 'pane_controller.dart';
import 'pane_location.dart';
import 'pane_tabs_controller.dart';
import 'workspace_controller.dart';

/// Why the link is suspended (02 §7): the two navigation causes carry
/// distinct chip copy; the re-visibility and diverged cases render the
/// bare suspended line.
enum SyncBrowseSuspension {
  /// The replay's mirror target does not exist on the other pane —
  /// '"foo" missing on right' (02 §7).
  mirrorMissing,

  /// The navigating pane's commit left the anchored subtree —
  /// 'outside the anchor subtree' (02 §7).
  outsideAnchor,

  /// An anchored tab is not its pane's visible tab, or the second pane
  /// is hidden — the spec's re-visibility suspension, identical for a
  /// tab switch and a hidden pane.
  pairNotVisible,

  /// The visible anchored pair stands at different relative paths — a
  /// suspended link only ever resumes when a navigation (or a
  /// re-visibility) lands both at the same valid relative path.
  diverged,
}

/// The suspension detail the chips render: [kind] plus, for
/// [SyncBrowseSuspension.mirrorMissing], the missing mirror directory's
/// display name and which pane lacks it.
final class SyncBrowseCause {
  const SyncBrowseCause(
    this.kind, {
    this.missingName,
    this.missingOnLeftPane,
  });

  final SyncBrowseSuspension kind;

  /// The mirror directory's name — set only for
  /// [SyncBrowseSuspension.mirrorMissing].
  final String? missingName;

  /// Which pane the mirror probe failed on — set only for
  /// [SyncBrowseSuspension.mirrorMissing].
  final bool? missingOnLeftPane;

  @override
  bool operator ==(Object other) =>
      other is SyncBrowseCause &&
      other.kind == kind &&
      other.missingName == missingName &&
      other.missingOnLeftPane == missingOnLeftPane;

  @override
  int get hashCode => Object.hash(kind, missingName, missingOnLeftPane);
}

/// Sync Browsing (02 §7): the workspace-level link between the two
/// panes' visible tabs. While linked, a committed relative navigation
/// in either pane replays at the same relative path below the other
/// pane's fixed anchor; the anchors themselves never move while the
/// link is enabled.
///
/// Every transition keys on the panes' [PaneController.committedLocation]
/// — a directory the channel verifiably listed — never the optimistic
/// [PaneController.location]. That is what makes the spec's rules
/// coherent: a failed navigation cannot replay or suspend (the pane did
/// not move), and a server change drops the link only when its landing
/// listing commits, so an Esc-cancelled rebind keeps it.
///
/// The controller listens to the strips and the workspace rather than
/// the pane controllers directly: the anchored tab's every state change
/// forwards through its strip, and tab activation/close arrive on the
/// same lane — one notify source covers navigation, tabs, and pane
/// visibility.
class SyncBrowsingController extends ChangeNotifier {
  SyncBrowsingController({required WorkspaceController workspace})
    : _workspace = workspace {
    workspace.addListener(_evaluate);
    workspace.left.addListener(_evaluate);
    workspace.right.addListener(_evaluate);
  }

  final WorkspaceController _workspace;

  PaneTab? _leftTab;
  PaneTab? _rightTab;
  PaneLocation? _leftAnchor;
  PaneLocation? _rightAnchor;

  /// The committed location each anchored tab was last seen at — a
  /// notify compares against these to name the pane that moved.
  PaneLocation? _lastLeft;
  PaneLocation? _lastRight;

  SyncBrowseCause? _cause;

  /// Kills an in-flight mirror probe: a newer commit (or drop) owns the
  /// replay decision, so a late answer must not navigate or suspend.
  int _replaySerial = 0;

  /// Re-entrancy guard: every write the evaluation makes (anchor flags,
  /// the other pane's navigation issue) notifies back through the
  /// strips. The outer call loops until a pass lands clean.
  bool _evaluating = false;
  bool _evaluateAgain = false;
  bool _disposed = false;

  /// Whether the link is armed — anchored pair recorded. [suspended]
  /// subdivides the armed state; a dropped link reports neither.
  bool get enabled => _leftAnchor != null;

  /// Whether the link is armed but not replaying — the amber chip state.
  bool get suspended => _cause != null;

  /// Why the link is suspended — null while linked or dropped.
  SyncBrowseCause? get cause => _cause;

  /// The fixed anchor pair (02 §7: enabling records BOTH panes' current
  /// directories; the pair never moves while the link is enabled).
  PaneLocation? get leftAnchor => _leftAnchor;
  PaneLocation? get rightAnchor => _rightAnchor;

  /// Whether a link can be armed right now: both panes' visible tabs
  /// stand at a committed directory. Unbound and mid-rebind panes have
  /// nothing to anchor.
  bool get canLink =>
      _workspace.left.activeTab?.controller.committedLocation != null &&
      _workspace.right.activeTab?.controller.committedLocation != null;

  /// `view.toggleSyncBrowsing` (02 §7, ⌥⌘B / Ctrl+Alt+B): arms the link
  /// on the two visible tabs' current directories, or drops it.
  void toggle() {
    if (_disposed) return;
    if (enabled) {
      _dropLink();
    } else {
      _enable();
    }
  }

  void _enable() {
    final leftTab = _workspace.left.activeTab;
    final rightTab = _workspace.right.activeTab;
    final leftAnchor = leftTab?.controller.committedLocation;
    final rightAnchor = rightTab?.controller.committedLocation;
    if (leftTab == null ||
        rightTab == null ||
        leftAnchor == null ||
        rightAnchor == null) {
      return;
    }
    _leftTab = leftTab;
    _rightTab = rightTab;
    _leftAnchor = leftAnchor;
    _rightAnchor = rightAnchor;
    _lastLeft = leftAnchor;
    _lastRight = rightAnchor;
    _cause = null;
    _replaySerial++;
    leftTab.controller.syncAnchorActive = true;
    rightTab.controller.syncAnchorActive = true;
    notifyListeners();
  }

  void _dropLink() {
    if (!enabled) return;
    final leftTab = _leftTab;
    final rightTab = _rightTab;
    _leftTab = null;
    _rightTab = null;
    _leftAnchor = null;
    _rightAnchor = null;
    _lastLeft = null;
    _lastRight = null;
    _cause = null;
    _replaySerial++;
    leftTab?.controller.syncAnchorActive = false;
    rightTab?.controller.syncAnchorActive = false;
    notifyListeners();
  }

  void _evaluate() {
    if (_disposed || !enabled) return;
    if (_evaluating) {
      _evaluateAgain = true;
      return;
    }
    _evaluating = true;
    try {
      do {
        _evaluateAgain = false;
        _evaluateOnce();
        // A mid-loop drop ends evaluation — the pair is gone.
        if (!enabled) break;
      } while (_evaluateAgain);
    } finally {
      _evaluating = false;
    }
  }

  void _evaluateOnce() {
    final leftTab = _leftTab!;
    final rightTab = _rightTab!;
    final left = _workspace.left;
    final right = _workspace.right;

    // Anchor residency: a confirmed close removed the tab — the link
    // drops silently (02 §7). The cross-pane containment check also
    // drops it if a drag ever lands both anchors on one strip.
    if (!left.tabs.contains(leftTab) ||
        !right.tabs.contains(rightTab) ||
        left.tabs.contains(rightTab) ||
        right.tabs.contains(leftTab)) {
      _dropLink();
      return;
    }

    final leftLoc = leftTab.controller.committedLocation;
    final rightLoc = rightTab.controller.committedLocation;
    final leftMoved = leftLoc != _lastLeft;
    final rightMoved = rightLoc != _lastRight;
    _lastLeft = leftLoc;
    _lastRight = rightLoc;

    // The server-change rule: a committed location on another endpoint
    // drops the link — on every pass, visible or not, so a commit that
    // lands while the pair is suspended (a rebind finishing under a
    // hidden pane or a switched tab) still drops it (02 §7). An
    // abandoned rebind keeps the link: its committed location never
    // changed. Evaluated only at commit — a null mid-rebind location
    // cannot drop.
    final leftAnchor = _leftAnchor!;
    final rightAnchor = _rightAnchor!;
    if ((leftLoc != null && !_sameEndpoint(leftLoc, leftAnchor)) ||
        (rightLoc != null && !_sameEndpoint(rightLoc, rightAnchor))) {
      _dropLink();
      return;
    }

    // The re-visibility rule: both anchored tabs must be their pane's
    // visible tab AND both panes on screen — a tab switch and a hidden
    // pane suspend exactly the same.
    final visible =
        identical(left.activeTab, leftTab) &&
        identical(right.activeTab, rightTab) &&
        _workspace.secondPaneShown;
    if (!visible) {
      _suspend(const SyncBrowseCause(SyncBrowseSuspension.pairNotVisible));
      return;
    }

    // A side standing nowhere (mid-rebind, detached) cannot be mirrored
    // into — its own commit re-evaluates when it lands.
    if (leftLoc == null || rightLoc == null) return;

    final leftRel = _relativeWithin(leftAnchor.path, leftLoc.path);
    final rightRel = _relativeWithin(rightAnchor.path, rightLoc.path);

    // THE auto-resume predicate (02 §7): both anchored panes committed
    // at the same relative path inside their anchored subtrees —
    // existence on both sides is inherent, since only accepted listings
    // commit. No snap-into-place: resume changes only the link state.
    if (leftRel != null &&
        rightRel != null &&
        listEquals(leftRel, rightRel)) {
      _resume();
      return;
    }

    // A stale pairNotVisible cause still reclassifies on a no-move
    // pass: the pair is visible again, so the cause that named the
    // suspension must move on to the truth (diverged, or a restated
    // escape). Every other no-move pass is an unrelated notify.
    if (!leftMoved &&
        !rightMoved &&
        _cause?.kind != SyncBrowseSuspension.pairNotVisible) {
      return;
    }

    if (_cause != null) {
      // Suspended: a fresh escape restates that cause; a mover that
      // stays inside but off the other's path leaves the pair diverged.
      _suspend(
        (leftMoved && leftRel == null) || (rightMoved && rightRel == null)
            ? const SyncBrowseCause(SyncBrowseSuspension.outsideAnchor)
            : const SyncBrowseCause(SyncBrowseSuspension.diverged),
      );
      return;
    }

    // Linked, exactly one side committed elsewhere: an escape suspends
    // without a mirror probe; an in-subtree commit replays when the
    // mirror exists. (Two movers in one pass should be unreachable —
    // commits notify individually — but a diverged pair is never
    // ambiguously replayed.)
    if (leftMoved && !rightMoved) {
      _replay(fromLeft: true, rel: leftRel, committed: leftLoc);
    } else if (rightMoved && !leftMoved) {
      _replay(fromLeft: false, rel: rightRel, committed: rightLoc);
    } else {
      _suspend(const SyncBrowseCause(SyncBrowseSuspension.diverged));
    }
  }

  /// The one-way replay (02 §7): the origin pane already committed; the
  /// other pane navigates to the same relative path below its own fixed
  /// anchor — through the pane's ordinary navigation machinery, so
  /// generations, stale-answer drops, and Esc-cancel all apply to it.
  void _replay({
    required bool fromLeft,
    required List<String>? rel,
    required PaneLocation committed,
  }) {
    if (rel == null) {
      // The escape rule: leaving the anchored subtree suspends instead
      // of replaying `..` chains.
      _suspend(const SyncBrowseCause(SyncBrowseSuspension.outsideAnchor));
      return;
    }
    final other = (fromLeft ? _rightTab : _leftTab)!.controller;
    final mirrorAnchor = fromLeft ? _rightAnchor! : _leftAnchor!;
    final mirrorPath = _joinUnder(mirrorAnchor.path, rel);
    final serial = ++_replaySerial;
    unawaited(() async {
      // Probe BEFORE moving the other pane: a missing mirror suspends
      // and leaves it where it stands — never an optimistic error move
      // onto a nonexistent location.
      final exists = await other.directoryExists(mirrorPath);
      if (_disposed ||
          serial != _replaySerial ||
          !enabled ||
          _cause != null) {
        return;
      }
      // The origin must still stand at the commit that asked for this
      // replay — a newer commit superseded it and owns its own probe.
      final originCommitted = fromLeft
          ? _leftTab!.controller.committedLocation
          : _rightTab!.controller.committedLocation;
      if (originCommitted != committed) return;
      if (!exists) {
        _suspend(
          SyncBrowseCause(
            SyncBrowseSuspension.mirrorMissing,
            missingName: paneLastSegment(mirrorPath),
            missingOnLeftPane: !fromLeft,
          ),
        );
        return;
      }
      other.navigate(mirrorPath);
    }());
  }

  void _suspend(SyncBrowseCause cause) {
    if (_cause == cause) return;
    _cause = cause;
    notifyListeners();
  }

  void _resume() {
    if (_cause == null) return;
    _cause = null;
    notifyListeners();
  }

  /// The anchor's endpoint identity: the local volume, or a remote's
  /// serverId. A committed location on another endpoint is 02 §7's
  /// "tab changing server" — the link drops.
  static bool _sameEndpoint(PaneLocation a, PaneLocation b) =>
      switch ((a, b)) {
        (RemotePaneLocation a, RemotePaneLocation b) =>
          a.serverId == b.serverId,
        (LocalPaneLocation(), LocalPaneLocation()) => true,
        _ => false,
      };

  /// [path]'s segments below [anchor], or null when [path] is not inside
  /// the anchored subtree — the anchor itself is the empty relative path.
  /// Separator mismatches never share a subtree.
  static List<String>? _relativeWithin(String anchor, String path) {
    final separator = paneSeparator(anchor);
    if (paneSeparator(path) != separator) return null;
    if (path == anchor) return const [];
    final prefix = anchor.endsWith(separator) ? anchor : '$anchor$separator';
    if (!path.startsWith(prefix)) return null;
    final rel = path.substring(prefix.length);
    return rel.isEmpty ? null : rel.split(separator);
  }

  /// The mirror path [rel] names below [anchor] — the other pane's replay
  /// target. Empty rel is the anchor itself.
  static String _joinUnder(String anchor, List<String> rel) {
    if (rel.isEmpty) return anchor;
    final separator = paneSeparator(anchor);
    // A root anchor ('/', 'C:\') already carries its separator.
    return anchor.endsWith(separator)
        ? '$anchor${rel.join(separator)}'
        : '$anchor$separator${rel.join(separator)}';
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _workspace.removeListener(_evaluate);
    _workspace.left.removeListener(_evaluate);
    _workspace.right.removeListener(_evaluate);
    // Clear the anchor flags without notifying — listeners are gone and
    // the strips may already be mid-dispose.
    _leftTab?.controller.syncAnchorActive = false;
    _rightTab?.controller.syncAnchorActive = false;
    super.dispose();
  }
}
