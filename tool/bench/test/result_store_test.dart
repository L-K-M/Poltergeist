import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/result_store.dart';
import 'package:test/test.dart';

void main() {
  test('appends complete rows without changing earlier evidence', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-result-store-',
    );
    final path = '${directory.path}/results.json';
    addTearDown(() => directory.delete(recursive: true));
    final first = _result('first');
    final second = _result('second');

    await appendResults(path, [first]);
    await appendResults(path, [second]);

    final decoded =
        jsonDecode(await File(path).readAsString()) as List<Object?>;
    expect(decoded, hasLength(2));
    expect((decoded.first! as Map)['scenario'], 'first');
    expect((decoded.last! as Map)['scenario'], 'second');
  });
}

BenchResult _result(String scenario) => BenchResult(
  scenario: scenario,
  bytes: 1,
  elapsed: const Duration(microseconds: 1),
  dartssh2Version: resolvedDartssh2Version,
  seanceRev: pinnedSeanceRevision,
  timestampUtc: DateTime.utc(2026),
  host: 'test',
);
