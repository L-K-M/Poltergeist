import 'dart:convert';
import 'dart:io';

import 'harness.dart';
import 'throughput_attempt.dart';

const _attemptFileSuffix = '.attempts.json';
const _temporaryFileSuffix = '.tmp';
const _jsonEncoder = JsonEncoder.withIndent('  ');

/// Appends atomically so a failed later scenario preserves earlier evidence.
Future<void> appendResults(String path, Iterable<BenchResult> additions) async {
  final target = File(path).absolute;
  await target.parent.create(recursive: true);

  final results = <BenchResult>[];
  if (await target.exists()) {
    final decoded = jsonDecode(await target.readAsString()) as List<Object?>;
    results.addAll(
      decoded.map(
        (row) => BenchResult.fromJson((row! as Map).cast<String, Object?>()),
      ),
    );
  }
  results.addAll(additions);

  final temporary = File('${target.path}$_temporaryFileSuffix');
  await temporary.writeAsString(
    '${_jsonEncoder.convert(results)}\n',
    flush: true,
  );
  await temporary.rename(target.path);
}

String throughputAttemptOutputPath(String resultPath) =>
    '$resultPath$_attemptFileSuffix';

/// Replaces one state record without losing completed transfer evidence.
class ThroughputAttemptStore {
  final String _path;

  const ThroughputAttemptStore(String path) : _path = path;

  Future<void> checkpoint(ThroughputAttempt checkpoint) async {
    final target = File(_path).absolute;
    await target.parent.create(recursive: true);

    final attempts = await _readAttempts(target);
    final index = attempts.indexWhere(
      (attempt) => attempt.reference == checkpoint.reference,
    );
    if (index < 0) {
      attempts.add(checkpoint);
    } else {
      attempts[index] = checkpoint;
    }

    final temporary = File('${target.path}$_temporaryFileSuffix');
    await temporary.writeAsString(
      '${_jsonEncoder.convert(attempts)}\n',
      flush: true,
    );
    await temporary.rename(target.path);
  }
}

Future<List<ThroughputAttempt>> _readAttempts(File target) async {
  if (!await target.exists()) return [];

  final decoded = jsonDecode(await target.readAsString()) as List<Object?>;
  return decoded
      .map(
        (row) =>
            ThroughputAttempt.fromJson((row! as Map).cast<String, Object?>()),
      )
      .toList();
}
