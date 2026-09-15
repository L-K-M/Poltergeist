// Unit coverage for the tier-B results writer (08 §6): row shape and
// the ok/error contract are what test/benchmarks/check_core.dart
// validates — a writer emitting the wrong shape would turn a real
// measurement into a malformed-input failure in CI.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/bench/bench_results.dart';

const fingerprint = BenchFingerprint(
  runnerImage: 'local',
  arch: 'linux_x64',
  dartVersion: '3.13.2 (stable)',
  flutterVersion: '3.47.2',
  mode: 'profile',
  cpuModel: 'test-cpu',
);

void main() {
  test('ok and error rows carry the schema the checker parses', () {
    final results = BenchResults(fingerprint: fingerprint)
      ..addValue(
        scenario: 'P1',
        repetition: 0,
        value: 42.5,
        unit: 'ms',
        scenarioConfig: 'local-entries-10000',
      )
      ..addError(
        scenario: 'P1',
        repetition: 1,
        error: 'listing timed out',
        scenarioConfig: 'local-entries-10000',
      );

    final document = results.toJson();
    expect(document['schema'], 'poltergeist-d12-results-1');
    final rows = document['rows']! as List<Object?>;
    expect(rows, hasLength(2));

    final ok = rows[0]! as Map<String, Object?>;
    expect(ok['status'], 'ok');
    expect(ok['value'], 42.5);
    expect(ok['unit'], 'ms');
    expect(ok.containsKey('error'), isFalse);

    final error = rows[1]! as Map<String, Object?>;
    expect(error['status'], 'error');
    expect(error['error'], 'listing timed out');
    // An errored observation must not carry a value — check_core
    // rejects the mixed form.
    expect(error.containsKey('value'), isFalse);

    final rowFingerprint = ok['fingerprint']! as Map<String, Object?>;
    expect(rowFingerprint['mode'], 'profile');
    expect(rowFingerprint['scenarioConfig'], 'local-entries-10000');
  });

  test('writeTo publishes the document', () async {
    final directory = await Directory.systemTemp.createTemp('bench-test-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/bench-results-p1.json';

    await (BenchResults(fingerprint: fingerprint)
          ..addValue(
            scenario: 'P6',
            repetition: 2,
            value: 0.1,
            unit: '%',
            scenarioConfig: 'local-entries-100000-scroll-30s@60hz',
          ))
        .writeTo(path);

    final decoded = jsonDecode(await File(path).readAsString());
    expect((decoded as Map<String, Object?>)['schema'], resultsSchemaId);
    expect((decoded['rows']! as List<Object?>).single, isNotNull);
    // The owned temp must not linger beside the published file.
    expect(
      directory.listSync().where((f) => f.path.endsWith('.tmp')),
      isEmpty,
    );
  });
}
