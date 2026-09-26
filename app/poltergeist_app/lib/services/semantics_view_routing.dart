import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'workspace_windows/window_host.dart';

/// The app's binding: Flutter's, plus the routing that gives an extra
/// workspace window's accessibility actions to its own view (00 D39).
///
/// Flutter 3.47's macOS embedder dispatches every view's accessibility
/// actions as the implicit view's: its accessibility bridge calls the
/// engine without a view id (AccessibilityBridgeMac.mm, "Remove implicit
/// view assumption", flutter/flutter#142845). A VoiceOver press on a
/// button in an extra window would reach the main window's tree under the
/// button's node id, where no such node exists, and do nothing. The
/// runner routes each window's semantics tree to its own window
/// (PoltergeistFlutterViewController.m), so this is the other direction.
final class PoltergeistBinding extends WidgetsFlutterBinding {
  PoltergeistBinding._();

  static bool _initialized = false;

  /// Installs this binding, unless one is already running.
  static WidgetsBinding ensureInitialized() {
    if (!_initialized) {
      _initialized = true;
      PoltergeistBinding._();
    }
    return WidgetsBinding.instance;
  }

  @override
  void performSemanticsAction(SemanticsActionEvent action) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final viewId = semanticsActionView(
        viewId: action.viewId,
        nodeId: action.nodeId,
        trees: {
          for (final view in renderViews)
            view.flutterView.viewId:
                view.owner?.semanticsOwner?.rootSemanticsNode,
        },
      );
      if (viewId != action.viewId) {
        action = action.copyWith(viewId: viewId);
      }
    }
    super.performSemanticsAction(action);
  }
}

/// The view whose tree holds [nodeId], for an action the engine addressed
/// to [viewId].
///
/// Only an action addressed to the main window can be misaddressed (see
/// [PoltergeistBinding]), and the framework numbers semantics nodes from
/// one counter for every view, so a node id names one view's node, except
/// each tree's root, which is 0 in every view. The main window keeps
/// whatever it holds, and its root; any other node goes to the view that
/// has it. An id no tree holds stays where it was addressed: the screen
/// reader acted on a node a later update removed, which the framework
/// ignores.
@visibleForTesting
int semanticsActionView({
  required int viewId,
  required int nodeId,
  required Map<int, SemanticsNode?> trees,
}) {
  if (viewId != mainWindowViewId || nodeId == 0) return viewId;
  final main = trees[mainWindowViewId];
  if (main != null && _holds(main, nodeId)) return viewId;
  for (final MapEntry(key: other, value: root) in trees.entries) {
    if (other == mainWindowViewId || root == null) continue;
    if (_holds(root, nodeId)) return other;
  }
  return viewId;
}

bool _holds(SemanticsNode node, int id) {
  if (node.id == id) return true;
  var found = false;
  node.visitChildren((child) {
    found = _holds(child, id);
    return !found;
  });
  return found;
}
