import 'package:poltergeist_m0_bench/isolate_poc.dart';
import 'package:poltergeist_m0_bench/ssh_driver.dart';
import 'package:test/test.dart';

void main() {
  test('rejects missing or lost cross-port progress flushes', () {
    expect(
      validateFloodEvidence(
        uiFlushes: 0,
        engineFlushes: 1,
        uiFlushesPerSecond: 0,
      ),
      contains(contains('delivered no progress')),
    );
    expect(
      validateFloodEvidence(
        uiFlushes: 1,
        engineFlushes: 2,
        uiFlushesPerSecond: 1,
      ),
      contains(contains('1 != engine 2')),
    );
  });

  test('accepts matching bounded progress flushes', () {
    expect(
      validateFloodEvidence(
        uiFlushes: 2,
        engineFlushes: 2,
        uiFlushesPerSecond: 2,
      ),
      isEmpty,
    );
  });

  test('bounds every workload task and their aggregate flush rate', () {
    const bounded = {
      'transfer-0': 30,
      'transfer-1': 30,
      'transfer-2': 30,
      'transfer-3': 30,
    };
    const unbounded = {
      'transfer-0': 31,
      'transfer-1': 30,
      'transfer-2': 30,
      'transfer-3': 30,
    };

    expect(
      validateWorkloadFlushEvidence(
        flushesByTask: bounded,
        elapsed: const Duration(seconds: 1),
        expectedTasks: bounded.keys,
      ),
      isEmpty,
    );
    expect(
      validateWorkloadFlushEvidence(
        flushesByTask: unbounded,
        elapsed: const Duration(seconds: 1),
        expectedTasks: bounded.keys,
      ),
      contains(contains('transfer-0')),
    );
    expect(
      validateWorkloadFlushEvidence(
        flushesByTask: const {'transfer-0': 1},
        elapsed: const Duration(seconds: 1),
        expectedTasks: bounded.keys,
      ),
      contains(contains('delivered no workload progress')),
    );
  });

  test('uses repeated medians for throughput parity', () {
    final failures = validateThroughputParity(
      rootSamples: [_read(300), _read(100), _read(100)],
      isolateSamples: [_read(105), _read(95), _read(100)],
    );

    expect(failures, isEmpty);
  });

  test('rejects median isolate throughput outside ten percent', () {
    expect(
      validateThroughputParity(
        rootSamples: [_read(100), _read(100), _read(100)],
        isolateSamples: [_read(112), _read(112), _read(112)],
      ),
      isNotEmpty,
    );
    expect(
      validateThroughputParity(
        rootSamples: [_read(100), _read(100), _read(100)],
        isolateSamples: [_read(88), _read(88), _read(88)],
      ),
      isNotEmpty,
    );
  });

  test('captures a final overdue timer interval', () {
    expect(
      timerProbeOverrun(
        elapsed: const Duration(milliseconds: 30),
        previousTick: const Duration(milliseconds: 4),
        interval: const Duration(milliseconds: 4),
      ),
      const Duration(milliseconds: 22),
    );
  });
}

ReadBatchResult _read(int elapsedMicroseconds) => ReadBatchResult(
  bytes: 1_000_000,
  elapsed: Duration(microseconds: elapsedMicroseconds),
  digest: 'fixture',
);
