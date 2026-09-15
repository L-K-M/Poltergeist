// P2 (02 §12): first paint of a 100 000-entry local directory < 1 s,
// exercised through the production virtualized ListView (fixed-extent
// builder — only the visible rows build). Same measurement discipline
// as P1; reported, not gated.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'bench_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const scenario = 'P2';
  const scenarioConfig = 'local-entries-100000-first-paint';
  const entries = 100000;

  testWidgets('P2 first paint, 100k-entry local directory', (tester) async {
    await runBenchScenario(
      tester,
      name: scenario,
      measure: (rig, results) async {
        final target = '${BenchConfig.fixtureRoot}/entries-100000';
        final parent = BenchConfig.fixtureRoot;

        await settlePane(rig, parent);
        await measureFirstPaintMicros(
          rig,
          targetPath: target,
          expectedEntries: entries,
        );

        for (var rep = 0; rep < 3; rep++) {
          await settlePane(rig, parent);
          try {
            final micros = await measureFirstPaintMicros(
              rig,
              targetPath: target,
              expectedEntries: entries,
            );
            results.addValue(
              scenario: scenario,
              repetition: rep,
              value: micros / 1000.0,
              unit: 'ms',
              scenarioConfig: scenarioConfig,
            );
            // ignore: avoid_print
            print('P2 rep$rep: ${micros / 1000.0} ms first paint');
          } catch (error) {
            results.addError(
              scenario: scenario,
              repetition: rep,
              error: '$error',
              scenarioConfig: scenarioConfig,
            );
          }
        }
      },
    );
  }, timeout: const Timeout(Duration(minutes: 12)));
}
