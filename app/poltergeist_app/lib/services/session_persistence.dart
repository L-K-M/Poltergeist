import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'session_state.dart';
import 'session_state_store.dart';
import 'workspace_controller.dart';

/// The session document 02 §3 restores on launch: both panes' strips
/// (ordered tabs and per-tab locations), the active tab per pane, the
/// active pane, and the pane toggle's user intent.
SessionState captureSessionState(WorkspaceController workspace) =>
    SessionState(
      activePaneId: workspace.activePane.paneId,
      secondPaneHidden: workspace.secondPaneHidden,
      activityPanelHidden: workspace.activityPanelHidden,
      inspectorHidden: workspace.inspectorHidden,
      inspectorTab: workspace.inspectorTab.name,
      panes: [
        workspace.left.captureSession(),
        workspace.right.captureSession(),
      ],
    );

/// 02 §3's safe-point persistence: every state change a window's workspace
/// reports — tab open/close/switch, navigation commit, pane toggle —
/// schedules a capture of the session document. Writes are debounced
/// (a navigation burst costs one write), deduplicated by content (a
/// selection-only notification changes nothing persisted), serialized
/// behind the store's own tail, and flushed synchronously at quit.
final class SessionPersistence {
  SessionPersistence({
    required SessionStateStore store,
    Duration saveDelay = _defaultSaveDelay,
    void Function() Function(Duration, Future<void> Function())?
    scheduleDebounce,
    void Function(Object, StackTrace)? onError,
  }) : // Keep the store seam private to the writer.
       // ignore: prefer_initializing_formals
       _store = store,
       // Keep the debounce window private; tests configure it by option.
       // ignore: prefer_initializing_formals
       _saveDelay = saveDelay,
       _scheduleDebounce = scheduleDebounce ?? _timerDebounce,
       // Keep the callback private while allowing test-only error injection.
       // ignore: prefer_initializing_formals
       _onError = onError;

  static const _defaultSaveDelay = Duration(milliseconds: 400);

  final SessionStateStore _store;
  final Duration _saveDelay;
  final void Function() Function(Duration, Future<void> Function())
  _scheduleDebounce;
  final void Function(Object, StackTrace)? _onError;

  /// The attached workspaces, one per open window, in the order their
  /// windows opened: the first is persisted as the v1 document, the rest
  /// beside it (00 D38).
  final _workspaces = <WorkspaceController>[];
  final _listened = <WorkspaceController, List<Listenable>>{};
  void Function()? _cancelScheduled;
  Future<void> _tail = Future<void>.value();
  // JSON of the last write attempt — notifications that leave the
  // persisted document identical (selection changes, view lenses) cost
  // no write.
  String? _lastEncoded;

  /// Starts persisting [workspace]'s state beside any already attached.
  /// Attaching also schedules a write so the freshly restored (or default)
  /// session is on disk before the user changes anything.
  void attach(WorkspaceController workspace) {
    if (_workspaces.contains(workspace)) return;
    _workspaces.add(workspace);
    final listened = [workspace, workspace.left, workspace.right];
    for (final listenable in listened) {
      listenable.addListener(_scheduleWrite);
    }
    _listened[workspace] = listened;
    // The dedupe key attests what is on disk for the previous set — an
    // attach must not inherit it and skip the first capture.
    _lastEncoded = null;
    _scheduleWrite();
  }

  /// Stops persisting [workspace]: its window closed, or its workspace is
  /// being rebuilt. With other windows still attached the document is
  /// rewritten without it; with none, any scheduled write is cancelled and
  /// the last document stays. [flush] remains callable — quit may
  /// legitimately arrive mid-rebuild.
  void detach(WorkspaceController workspace) {
    if (!_workspaces.remove(workspace)) return;
    for (final listenable in _listened.remove(workspace) ?? const []) {
      listenable.removeListener(_scheduleWrite);
    }
    if (_workspaces.isNotEmpty) {
      _scheduleWrite();
      return;
    }
    _cancelScheduled?.call();
    _cancelScheduled = null;
    _lastEncoded = null;
  }

  /// Detaches every workspace.
  void detachAll() {
    for (final workspace in List.of(_workspaces)) {
      detach(workspace);
    }
  }

  void _scheduleWrite() {
    if (_workspaces.isEmpty) return;
    _cancelScheduled?.call();
    _cancelScheduled = _scheduleDebounce(_saveDelay, _writeNow);
  }

  /// Writes the current session document now, waiting behind any write
  /// already in flight — the app-quit safe point calls this so the last
  /// state is on disk before the window destroys.
  Future<void> flush() {
    _cancelScheduled?.call();
    _cancelScheduled = null;
    return _writeNow();
  }

  Future<void> _writeNow() {
    final operation = _tail.then((_) => _write());
    _tail = operation.then((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _write() async {
    if (_workspaces.isEmpty) return;
    // Capture and encode sit inside the try too: a controller that
    // throws mid-capture reports through the same lane rather than
    // surfacing as an unhandled error on a scheduled write.
    try {
      final states = [
        for (final workspace in _workspaces) captureSessionState(workspace),
      ];
      final encoded = jsonEncode([
        for (final state in states) state.toJson(),
      ]);
      if (encoded == _lastEncoded) return;
      await _store.saveAll(states.first, states.sublist(1));
      _lastEncoded = encoded;
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }

  static void Function() _timerDebounce(
    Duration delay,
    Future<void> Function() callback,
  ) {
    final timer = Timer(delay, () => unawaited(callback()));
    return timer.cancel;
  }
}
