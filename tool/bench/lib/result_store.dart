import 'dart:convert';
import 'dart:io';

import 'harness.dart';

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

  final temporary = File('${target.path}.tmp');
  final encoder = const JsonEncoder.withIndent('  ');
  await temporary.writeAsString('${encoder.convert(results)}\n', flush: true);
  await temporary.rename(target.path);
}
