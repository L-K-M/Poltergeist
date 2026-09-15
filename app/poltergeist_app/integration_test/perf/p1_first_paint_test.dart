// P1 (02 §12): first paint of a 10 000-entry local directory < 150 ms.
// Measured navigate()-issue to first-painted-frame raster completion —
// the listing fetch is inside the number. Reported per repetition in
// bench-results.json; not gated while the budget stays unlanded.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'bench_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const scenario = 'P1';
  const scenarioConfig = 'local-entries-10000-first-paint';
  const entries = 10000;

  testWidgets('P1 first paint, 10k-entry local directory', (tester) async {
    await runBenchScenario(
      tester,
      name: scenario,
      measure: (rig, results) async {
        final target = '${BenchConfig.fixtureRoot}/entries-10000';
        final parent = BenchConfig.fixtureRoot;

        // One warmup leg, unmeasured: the first navigation pays
        // one-time costs (channel caches, font shaders) no user-facing
        // budget means to sample.
        await settlePane(rig, parent);
        await measureFirstPaintMicros(
          rig,
          targetPath: target,
          expectedEntries: entries,
        );

        var successes = 0;
        Object? lastError;
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
            successes++;
            // Evidence line for the run log artifact.
            // ignore: avoid_print
            print('P1 rep$rep: ${micros / 1000.0} ms first paint');
          } catch (error) {
            lastError = error;
            results.addError(
              scenario: scenario,
              repetition: rep,
              error: '$error',
              scenarioConfig: scenarioConfig,
            );
          }
        }
        // The error rows are published either way; a drive exiting zero
        // on an all-error scenario would read as a successful leg.
        if (successes == 0) {
          throw StateError('no successful repetitions; last: $lastError');
        }
      },
    );
  }, timeout: const Timeout(Duration(minutes: 8)));
}
