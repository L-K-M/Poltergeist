import 'package:poltergeist_m0_bench/result_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('partitions 78 rows across one standard and 12 isolated sources', () {
    expect(m0ScenarioManifest, hasLength(m0ScenarioCount));
    expect(standardSourceScenarios, hasLength(standardSourceScenarioCount));
    expect(isolatedSourceSpecs, hasLength(isolatedSourceCount));
    expect(
      isolatedSourceSpecs.expand((source) => source.scenarios).toSet(),
      hasLength(isolatedCanonicalScenarioCount),
    );
    expect({
      ...standardSourceScenarios,
      ...isolatedSourceScenarios,
    }, m0ScenarioManifest.toSet());
  });

  test('requires 60 ABCCBA standard trials and two isolated replicates', () {
    expect(standardThroughputTrialSpecs, hasLength(standardRawTrialCount));

    for (final cell in affordableThroughputCells) {
      final trials = standardThroughputTrialSpecs
          .where((trial) => trial.cellId == cell.id)
          .toList();
      expect(trials.map((trial) => trial.variant), [
        M0ThroughputVariant.dartHashOn,
        M0ThroughputVariant.openSsh,
        M0ThroughputVariant.dartHashOff,
        M0ThroughputVariant.dartHashOff,
        M0ThroughputVariant.openSsh,
        M0ThroughputVariant.dartHashOn,
      ]);
      expect(trials.map((trial) => trial.ordinal), [1, 2, 3, 4, 5, 6]);
      expect(trials.map((trial) => trial.replicate), [1, 1, 1, 2, 2, 2]);
    }

    for (final scenario in isolatedSourceScenarios) {
      final sources = isolatedSourceSpecs
          .where((source) => source.scenarios.single == scenario)
          .toList();
      expect(sources.map((source) => source.replicate), [1, 2]);
    }
  });
}
