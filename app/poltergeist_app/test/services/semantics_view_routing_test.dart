import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/semantics_view_routing.dart';

/// A root (id 0, as every view's is) over [children].
SemanticsNode _tree(List<SemanticsNode> children) {
  final root = SemanticsNode.root(
    owner: SemanticsOwner(onSemanticsUpdate: (_) {}),
  );
  root.updateWith(
    config: SemanticsConfiguration(),
    childrenInInversePaintOrder: children,
  );
  return root;
}

SemanticsNode _leaf() =>
    SemanticsNode()..updateWith(config: SemanticsConfiguration());

/// macOS addresses every accessibility action to the main window's view;
/// the node id says which window it was meant for (00 D39).
void main() {
  late SemanticsNode mainButton;
  late SemanticsNode extraButton;
  late SemanticsNode nested;
  late Map<int, SemanticsNode?> trees;

  setUp(() {
    mainButton = _leaf();
    extraButton = _leaf();
    nested = _leaf();
    final group = SemanticsNode()
      ..updateWith(
        config: SemanticsConfiguration(),
        childrenInInversePaintOrder: [nested],
      );
    trees = {
      0: _tree([mainButton]),
      2: null,
      3: _tree([extraButton, group]),
    };
  });

  int route(int viewId, int nodeId) =>
      semanticsActionView(viewId: viewId, nodeId: nodeId, trees: trees);

  test("the main window keeps the actions on its own nodes", () {
    expect(route(0, mainButton.id), 0);
  });

  test("an extra window's node takes its action back, at any depth", () {
    expect(route(0, extraButton.id), 3);
    expect(route(0, nested.id), 3);
  });

  test('every root is 0, so a root action stays with the main window', () {
    expect(route(0, 0), 0);
    // Whatever order the trees come in.
    trees = {3: trees[3], 2: null, 0: trees[0]};
    expect(route(0, 0), 0);
    expect(route(0, extraButton.id), 3);
  });

  test('a node no tree holds stays where it was addressed', () {
    expect(route(0, 60000), 0);
  });

  test('an action already addressed to an extra window is left alone', () {
    expect(route(3, mainButton.id), 3);
  });
}
