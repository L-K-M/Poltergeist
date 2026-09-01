import 'dart:convert';
import 'dart:io';

import 'harness.dart';
import 'result_manifest.dart';

const _resultFields = [
  'scenario',
  'bytes',
  'dartssh2Version',
  'seanceRev',
  'rttMs',
  'elapsedUs',
  'note',
  'timestampUtc',
  'host',
];
const _shapedLinkSuffix = '-rtt100';
const _clientSupportPrefix = 'algorithm-client-support-';
const _jsonEncoder = JsonEncoder.withIndent('  ');
final _utcTimestampSuffix = RegExp(r'(?:[zZ]|[+-]00(?::?00)?)$');

enum _ResultShard { standard, slow }

class ResultAggregationException implements Exception {
  final String message;

  const ResultAggregationException(this.message);

  @override
  String toString() => message;
}

/// Validates both shards and returns untouched rows in manifest order.
List<Map<String, Object?>> aggregateResultShards({
  required List<Map<String, Object?>> standardRows,
  required List<Map<String, Object?>> slowRows,
}) {
  final standard = _validateShard(
    shard: _ResultShard.standard,
    rows: standardRows,
    expectedScenarios: standardShardScenarios,
  );
  final slow = _validateShard(
    shard: _ResultShard.slow,
    rows: slowRows,
    expectedScenarios: slowShardScenarios,
  );
  final byScenario = {...standard, ...slow};
  if (byScenario.length != m0ScenarioCount) {
    throw ResultAggregationException(
      'Shard union must contain $m0ScenarioCount unique scenarios.',
    );
  }

  return List.unmodifiable([
    for (final scenario in m0ScenarioManifest) byScenario[scenario]!,
  ]);
}

/// Reads explicit shard files and atomically writes canonical JSON.
Future<void> aggregateResultFiles({
  required String standardPath,
  required String slowPath,
  required String outputPath,
}) async {
  final inputs = await Future.wait([
    _readRows(standardPath, _ResultShard.standard),
    _readRows(slowPath, _ResultShard.slow),
  ]);
  final rows = aggregateResultShards(
    standardRows: inputs[0],
    slowRows: inputs[1],
  );
  final target = File(outputPath);
  final temporary = File('$outputPath.tmp');
  await target.parent.create(recursive: true);
  await temporary.writeAsString('${_jsonEncoder.convert(rows)}\n', flush: true);
  await temporary.rename(target.path);
}

Map<String, Map<String, Object?>> _validateShard({
  required _ResultShard shard,
  required List<Map<String, Object?>> rows,
  required List<String> expectedScenarios,
}) {
  final expected = expectedScenarios.toSet();
  final byScenario = <String, Map<String, Object?>>{};
  for (final row in rows) {
    final scenario = row['scenario'];
    if (scenario is! String || scenario.isEmpty) {
      throw ResultAggregationException(
        '${shard.name} shard has a row without a scenario.',
      );
    }
    if (byScenario.containsKey(scenario)) {
      throw ResultAggregationException(
        '${shard.name} shard duplicates $scenario.',
      );
    }
    if (!expected.contains(scenario)) {
      final assignment = _assignedShard(scenario);
      final detail = assignment == null
          ? 'is not in the M0 manifest'
          : 'belongs to the ${assignment.name} shard';
      throw ResultAggregationException('$scenario $detail.');
    }

    _validateRow(row, scenario);
    byScenario[scenario] = _canonicalRow(row);
  }

  final missing = expected.difference(byScenario.keys.toSet());
  if (missing.isNotEmpty) {
    throw ResultAggregationException(
      '${shard.name} shard is missing ${missing.join(', ')}.',
    );
  }

  _validateShardCell(shard, byScenario.values);

  return byScenario;
}

void _validateRow(Map<String, Object?> row, String scenario) {
  final fields = row.keys.toSet();
  final expectedFields = _resultFields.toSet();
  final missingFields = expectedFields.difference(fields);
  final extraFields = fields.difference(expectedFields);
  if (missingFields.isNotEmpty || extraFields.isNotEmpty) {
    throw ResultAggregationException(
      '$scenario has invalid fields: '
      'missing=${missingFields.join(',')}; extra=${extraFields.join(',')}.',
    );
  }

  late final BenchResult result;
  try {
    result = BenchResult.fromJson(row);
  } on Object catch (error) {
    throw ResultAggregationException('$scenario has invalid data: $error.');
  }
  if (result.dartssh2Version != resolvedDartssh2Version) {
    throw ResultAggregationException(
      '$scenario uses dartssh2 ${result.dartssh2Version}.',
    );
  }
  if (result.seanceRev != pinnedSeanceRevision) {
    throw ResultAggregationException(
      '$scenario uses Seance revision ${result.seanceRev}.',
    );
  }
  if (result.host.trim().isEmpty) {
    throw ResultAggregationException('$scenario has an empty host.');
  }
  if (result.bytes < 0) {
    throw ResultAggregationException('$scenario has negative bytes.');
  }
  if (!result.timestampUtc.isUtc) {
    throw ResultAggregationException('$scenario timestamp is not UTC.');
  }
  final timestampText = row['timestampUtc']! as String;
  if (!_utcTimestampSuffix.hasMatch(timestampText)) {
    throw ResultAggregationException('$scenario timestamp is not UTC.');
  }

  _validateRtt(result);
  _validateElapsed(result);
}

void _validateShardCell(
  _ResultShard shard,
  Iterable<Map<String, Object?>> rows,
) {
  // A shard is one runner; mixed hosts would merge separate experiments.
  final hosts = rows.map((row) => row['host']! as String).toSet();
  if (hosts.length != 1) {
    throw ResultAggregationException(
      '${shard.name} shard contains multiple hosts.',
    );
  }
  if (shard != _ResultShard.slow) return;

  // The three slow variants share one measured shaped-link cell.
  final measuredRtts = rows.map((row) => row['rttMs']! as int).toSet();
  if (measuredRtts.length == 1) return;

  throw const ResultAggregationException(
    'slow shard contains multiple measured RTTs.',
  );
}

void _validateRtt(BenchResult result) {
  final shaped = result.scenario.endsWith(_shapedLinkSuffix);
  if (shaped && (result.rttMs == null || result.rttMs! <= 0)) {
    throw ResultAggregationException(
      '${result.scenario} needs a positive measured RTT.',
    );
  }
  if (!shaped && result.rttMs != null) {
    throw ResultAggregationException(
      '${result.scenario} must have a null RTT.',
    );
  }
}

void _validateElapsed(BenchResult result) {
  final elapsedUs = result.elapsed.inMicroseconds;
  final clientSupport = result.scenario.startsWith(_clientSupportPrefix);
  if (clientSupport && elapsedUs >= 0) return;
  if (!clientSupport && elapsedUs > 0) return;

  throw ResultAggregationException(
    '${result.scenario} has invalid elapsedUs=$elapsedUs.',
  );
}

Map<String, Object?> _canonicalRow(Map<String, Object?> row) => {
  for (final field in _resultFields) field: row[field],
};

_ResultShard? _assignedShard(String scenario) {
  if (standardShardScenarios.contains(scenario)) {
    return _ResultShard.standard;
  }
  if (slowShardScenarios.contains(scenario)) return _ResultShard.slow;
  return null;
}

Future<List<Map<String, Object?>>> _readRows(
  String path,
  _ResultShard shard,
) async {
  late final Object? decoded;
  try {
    decoded = jsonDecode(await File(path).readAsString());
  } on FormatException catch (error) {
    throw ResultAggregationException(
      '${shard.name} shard is not valid JSON: ${error.message}.',
    );
  }
  if (decoded is! List<Object?>) {
    throw ResultAggregationException(
      '${shard.name} shard must be a JSON array.',
    );
  }

  final rows = <Map<String, Object?>>[];
  for (var index = 0; index < decoded.length; index++) {
    final value = decoded[index];
    if (value is! Map<Object?, Object?> ||
        value.keys.any((key) => key is! String)) {
      throw ResultAggregationException(
        '${shard.name} shard row $index must be a JSON object.',
      );
    }
    rows.add(value.cast<String, Object?>());
  }
  return rows;
}
