import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/ui/adaptive_shell.dart';

void main() {
  testWidgets('renders localized two-pane workspace with quiet chrome', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const PoltergeistApp());

    expect(find.byKey(AdaptiveShell.primaryPaneKey), findsOneWidget);
    expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsOneWidget);
    expect(find.byKey(AdaptiveShell.splitterKey), findsOneWidget);
    expect(find.text('Poltergeist'), findsOneWidget);
    expect(find.text('Choose a location'), findsNWidgets(2));

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme?.visualDensity, VisualDensity.compact);
    expect(app.darkTheme?.visualDensity, VisualDensity.compact);
  });

  testWidgets('reports the first rendered content size', (tester) async {
    final sizes = <Size>[];
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(PoltergeistApp(onContentSizeChanged: sizes.add));
    await tester.pump();

    expect(sizes, [const Size(1180, 760)]);
  });
}
