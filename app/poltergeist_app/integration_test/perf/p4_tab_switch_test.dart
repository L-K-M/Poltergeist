// P4 (02 §12): tab switch < 100 ms — the interval from the switch
// command (`PaneTabsController.activateTab`, the one call both chip
// taps and ⌃⇥ cycling funnel into) to the raster completion of the
// first frame painting the target tab's listing. The strip holds five
// tabs bound to the 10 000-entry fixture: a five-location working set
// is the heavy end of an everyday strip (02 §3's ghost ring caps
// closed-tab history at 10; active strips carry a handful). Reported
// per repetition — the checker medians them; unlanded, trend-only.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';

import 'bench_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const scenario = 'P4';
  const tabCount = 5;
  const entries = 10000;
  const scenarioConfig = 'local-tabs-$tabCount-entries-$entries-tab-switch';

  testWidgets('P4 tab switch, five 10k-entry tabs', (tester) async {
    await runBenchScenario(
      tester,
      name: scenario,
      measure: (rig, results) async {
        final tabs = rig.tabs;
        final fixture = '${BenchConfig.fixtureRoot}/entries-$entries';

        // Seed the strip: the boot tab plus launcher-target tabs, then
        // bind every tab to the fixture listing. `newTab` activates
        // each one, so the strip ends on the last-created tab. The
        // loop is bounded so a capped strip fails fast instead of
        // spinning until the test timeout.
        for (var i = tabs.tabs.length; i < tabCount; i++) {
          tabs.newTab(target: NewTabTarget.launcher);
        }
        if (tabs.tabs.length != tabCount) {
          throw StateError(
            'newTab stopped growing the strip at '
            '${tabs.tabs.length}/$tabCount tabs',
          );
        }
        for (final tab in tabs.tabs) {
          unawaited(tab.controller.openLocalAt(fixture));
        }
        await waitFor(
          tester,
          () => tabs.tabs.every(
            (tab) =>
                tab.controller.error != null ||
                (!tab.controller.loading &&
                    tab.controller.entries.length >= entries),
          ),
          'all $tabCount tabs settled on the $entries-entry fixture',
        );
        for (final tab in tabs.tabs) {
          final error = tab.controller.error;
          if (error != null) {
            throw StateError('tab ${tab.id} failed to list $fixture: $error');
          }
        }

        // One unmeasured warmup pass over every tab — the strip
        // mounts only the ACTIVE tab's PaneView, so each tab's first
        // data-laden paint (plus shader warm) is a one-time cost no
        // steady-state budget means to sample.
        for (var i = 1; i <= tabCount; i++) {
          await measureTabSwitchMicros(rig, tab: tabs.tabs[i % tabCount]);
        }

        // Every rep then targets a different tab than the one the
        // previous switch left active, so all five tabs serve as a
        // measured target exactly once.
        var successes = 0;
        Object? lastError;
        for (var rep = 0; rep < tabCount; rep++) {
          final tab = tabs.tabs[(rep + 1) % tabCount];
          try {
            final micros = await measureTabSwitchMicros(rig, tab: tab);
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
            print('P4 rep$rep: ${micros / 1000.0} ms switch to ${tab.id}');
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
