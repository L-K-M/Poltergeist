// P6 (02 §12): scrolling a large listing — <= 0.2 % of frames over the
// display deadline across a scripted 30 s sweep of the 100 000-entry
// fixture. The refresh rate is measured from the captured vsync
// intervals and recorded in the scenario config; a capture below the
// floor (>= 1800 frames at 60 Hz) is an error row with the count, never
// a ratio over a too-small sample.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:poltergeist_app/bench/frame_stats.dart';

import 'bench_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const scenario = 'P6';
  const scenarioConfigBase = 'local-entries-100000-scroll-30s';
  const entries = 100000;
  const scrollDuration = Duration(seconds: 30);

  testWidgets('P6 scroll, 100k-entry listing', (tester) async {
    await runBenchScenario(
      tester,
      name: scenario,
      measure: (rig, results) async {
        final target = '${BenchConfig.fixtureRoot}/entries-100000';
        await settlePane(rig, target);
        await waitFor(
          tester,
          () => rig.pane.entries.length >= entries,
          'P6 fixture listing of $entries entries',
        );
        // The entries land in the controller a frame before the
        // ListView.builder exists in the element tree.
        await waitFor(
          tester,
          () => rig.listingMounted,
          'P6 listing scrollable built',
        );

        for (var rep = 0; rep < 3; rep++) {
          // ignore: avoid_print
          print('P6 rep$rep: starting 30 s scroll');
          final position = rig.listingScrollable().position;
          position.jumpTo(0);
          await tester.pump();

          final frames = await captureScroll(rig, duration: scrollDuration);
          try {
            final stats = summarizeScrollWindow(
              frames: frames,
              windowSeconds: scrollDuration.inMicroseconds / 1e6,
            );
            final scenarioConfig =
                '$scenarioConfigBase@${stats.refreshHz.round()}hz';
            results.addValue(
              scenario: scenario,
              repetition: rep,
              value: stats.latePercent,
              unit: '%',
              scenarioConfig: scenarioConfig,
            );
            // ignore: avoid_print
            print(
              'P6 rep$rep: ${stats.frameCount} frames at '
              '${stats.refreshHz.toStringAsFixed(2)} Hz measured, '
              '${stats.lateFrames} late '
              '(${stats.latePercent.toStringAsFixed(3)} %, deadline '
              '${stats.deadlineUs.toStringAsFixed(0)} us)',
            );
          } on InsufficientFramesException catch (error) {
            // Loud by construction: the checker fails an expected
            // scenario's errored row in every mode, and the message
            // carries the captured count.
            results.addError(
              scenario: scenario,
              repetition: rep,
              error: 'insufficient frame capture: $error',
              scenarioConfig: scenarioConfigBase,
            );
          }
        }
      },
    );
  }, timeout: const Timeout(Duration(minutes: 12)));
}
