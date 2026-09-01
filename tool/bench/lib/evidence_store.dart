import 'dart:convert';
import 'dart:io';

import 'evidence.dart';
import 'monotonic_clock.dart';
import 'result_manifest.dart';

const _jsonEncoder = JsonEncoder.withIndent('  ');
final _gitObjectPattern = RegExp(r'^[0-9a-f]{40}$');
final _workflowRunPattern = RegExp(r'^[0-9]+$');
final _imageIdPattern = RegExp(r'^(?:sha256:)?[0-9a-f]{12,64}$');

class EvidenceStore {
  final String path;
  final DateTime Function() _clock;
  final MonotonicClock _monotonicClock;

  EvidenceStore(
    this.path, {
    DateTime Function()? clock,
    MonotonicClock? monotonicClock,
  }) : _clock = clock ?? _utcNow,
       _monotonicClock = monotonicClock ?? HostMonotonicClock.read;

  Future<void> start(
    SourceIdentity identity, {
    DateTime? deadlineStartedAtUtc,
    Duration? deadlineStartedAtMonotonic,
  }) async {
    final target = File(path).absolute;
    if (await target.exists()) {
      throw EvidenceException('${target.path} already exists.');
    }

    final startedAtUtc = _clock().toUtc();
    await _write(
      SourceEnvelope.running(
        identity,
        deadlineStartedAtUtc: deadlineStartedAtUtc ?? startedAtUtc,
        deadlineStartedAtMonotonic:
            deadlineStartedAtMonotonic ?? _monotonicClock(),
        startedAtUtc: startedAtUtc,
      ),
    );
  }

  Future<SourceEnvelope> read() async {
    final decoded = jsonDecode(await File(path).readAsString());
    if (decoded is! Map<Object?, Object?> ||
        decoded.keys.any((key) => key is! String)) {
      throw const EvidenceException('Source envelope must be a JSON object.');
    }

    return SourceEnvelope.fromJson(decoded.cast<String, Object?>());
  }

  Future<int> finish({
    required int exitStatus,
    required String rowsPath,
    required String attemptsPath,
    String? failureMessage,
    SourceIdentity? finalIdentity,
  }) async {
    final envelope = await read();
    if (envelope.state != EvidenceState.running) {
      if (envelope.exitStatus == exitStatus) return exitStatus;

      throw EvidenceException(
        '${envelope.identity.shardId} is ${envelope.state.name} with '
        'exit status ${envelope.exitStatus}, not $exitStatus.',
      );
    }
    final resolvedIdentity =
        finalIdentity ??
        SourceIdentity.fromEnvironment(shardId: envelope.identity.shardId);
    _validateStableIdentity(envelope.identity, resolvedIdentity);
    final rows = await _readOptionalArray(
      rowsPath,
      required: exitStatus == 0,
      label: 'rows',
    );
    final attempts = await _readOptionalArray(
      attemptsPath,
      required: exitStatus == 0,
      label: 'attempts',
    );
    final finishedAtUtc = _clock().toUtc();
    final lifecycleElapsed = _lifecycleElapsed(envelope, _monotonicClock());
    final effectiveStatus = _effectiveExitStatus(
      envelope,
      requestedStatus: exitStatus,
      lifecycleElapsed: lifecycleElapsed,
    );
    if (effectiveStatus == 0 && !_isResolved(resolvedIdentity)) {
      throw const EvidenceException(
        'Successful evidence has unresolved workflow or fixture identity.',
      );
    }
    final finalized = envelope.finalized(
      finalIdentity: resolvedIdentity,
      status: effectiveStatus,
      finalRows: rows,
      finalAttempts: attempts,
      finishedAtUtc: finishedAtUtc,
      lifecycleElapsed: lifecycleElapsed,
      failureMessage:
          exitStatus == 0 && effectiveStatus == isolatedSourceDeadlineExitStatus
          ? 'isolated lifecycle exceeded '
                '${isolatedSourceLifecycleBudget.inMinutes} minutes'
          : failureMessage,
    );
    await _write(finalized);

    if (effectiveStatus != 0 || !_isIsolated(envelope)) {
      return effectiveStatus;
    }
    final persistedElapsed = _lifecycleElapsed(envelope, _monotonicClock());
    if (persistedElapsed <= isolatedSourceLifecycleBudget) return 0;

    // A source is successful only when its durable terminal write fits.
    final deadlineFailure = envelope.finalized(
      finalIdentity: resolvedIdentity,
      status: isolatedSourceDeadlineExitStatus,
      finalRows: rows,
      finalAttempts: attempts,
      finishedAtUtc: _clock().toUtc(),
      lifecycleElapsed: persistedElapsed,
      failureMessage:
          'isolated lifecycle exceeded '
          '${isolatedSourceLifecycleBudget.inMinutes} minutes',
    );
    await _write(deadlineFailure);

    return isolatedSourceDeadlineExitStatus;
  }

  Future<void> _write(SourceEnvelope envelope) async {
    final target = File(path).absolute;
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.$pid.tmp');
    try {
      await temporary.writeAsString(
        '${_jsonEncoder.convert(envelope.toJson())}\n',
        flush: true,
      );
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

DateTime _utcNow() => DateTime.now().toUtc();

int _effectiveExitStatus(
  SourceEnvelope envelope, {
  required int requestedStatus,
  required Duration lifecycleElapsed,
}) {
  if (requestedStatus != 0) return requestedStatus;
  if (!_isIsolated(envelope)) return requestedStatus;
  if (lifecycleElapsed <= isolatedSourceLifecycleBudget) {
    return requestedStatus;
  }

  return isolatedSourceDeadlineExitStatus;
}

bool _isIsolated(SourceEnvelope envelope) =>
    sourceSpecForId(envelope.identity.shardId)?.kind == M0SourceKind.isolated;

Duration _lifecycleElapsed(SourceEnvelope envelope, Duration finished) {
  final elapsed = finished - envelope.deadlineStartedAtMonotonic;
  if (!elapsed.isNegative) return elapsed;

  throw const EvidenceException('The monotonic lifecycle clock moved back.');
}

bool _isResolved(SourceIdentity identity) =>
    !_containsUnresolved(identity.toJson()) &&
    _gitObjectPattern.hasMatch(identity.poltergeistSha) &&
    _workflowRunPattern.hasMatch(identity.workflowRunId) &&
    identity.workflowRunAttempt > 0 &&
    _gitObjectPattern.hasMatch(identity.fixture.tree) &&
    _imageIdPattern.hasMatch(identity.fixture.imageId) &&
    identity.fixture.dataVersion == fixtureDataVersion;

void _validateStableIdentity(SourceIdentity started, SourceIdentity finished) {
  final startedJson = started.toJson()..remove('fixture');
  final finishedJson = finished.toJson()..remove('fixture');
  if (jsonEncode(startedJson) == jsonEncode(finishedJson)) return;

  throw const EvidenceException('Source identity changed during measurement.');
}

bool _containsUnresolved(Object? value) {
  if (value is String) {
    return value.startsWith(pendingIdentityPrefix) ||
        value.startsWith(localIdentityPrefix);
  }
  if (value is List<Object?>) return value.any(_containsUnresolved);
  if (value is Map<Object?, Object?>) {
    return value.values.any(_containsUnresolved);
  }

  return false;
}

Future<List<Map<String, Object?>>> _readOptionalArray(
  String path, {
  required bool required,
  required String label,
}) async {
  final file = File(path);
  if (!await file.exists()) {
    if (required) throw EvidenceException('$label file is missing: $path.');

    return const [];
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! List<Object?>) {
    throw EvidenceException('$label file must be a JSON array.');
  }

  return List.unmodifiable([
    for (var index = 0; index < decoded.length; index++)
      _arrayObject(decoded[index], '$label[$index]'),
  ]);
}

Map<String, Object?> _arrayObject(Object? value, String label) {
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return value.cast<String, Object?>();
  }

  throw EvidenceException('$label must be a JSON object.');
}
