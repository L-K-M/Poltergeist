import 'dart:io';

import 'harness.dart';

const sourceEnvelopeSchemaVersion = 3;
const fixtureDataVersion = 2;
const localIdentityPrefix = 'local-';
const pendingIdentityPrefix = 'pending-';
const _runtimeFields = {
  'dartVersion',
  'operatingSystem',
  'operatingSystemVersion',
  'architecture',
  'runnerName',
  'runnerImage',
  'runnerImageVersion',
};
const _dependencyFields = {'dartssh2Version', 'seanceRevision'};
const _fixtureFields = {
  'tree',
  'imageId',
  'openSshClientVersion',
  'openSshServerVersion',
  'dataVersion',
};
const _identityFields = {
  'poltergeistSha',
  'workflowRunId',
  'workflowRunAttempt',
  'workflowJob',
  'shardId',
  'host',
  'runtime',
  'dependencies',
  'fixture',
};
const _envelopeFields = {
  'schemaVersion',
  'state',
  'identity',
  'deadlineStartedAtUtc',
  'deadlineStartedAtMonotonicUs',
  'startedAtUtc',
  'finishedAtUtc',
  'lifecycleElapsedUs',
  'exitStatus',
  'failure',
  'rows',
  'attempts',
};

enum EvidenceState { running, succeeded, failed }

enum IdentityCapturePhase { running, terminal }

class EvidenceException implements Exception {
  final String message;

  const EvidenceException(this.message);

  @override
  String toString() => message;
}

class RuntimeIdentity {
  final String dartVersion;
  final String operatingSystem;
  final String operatingSystemVersion;
  final String architecture;
  final String runnerName;
  final String runnerImage;
  final String runnerImageVersion;

  const RuntimeIdentity({
    required this.dartVersion,
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.architecture,
    this.runnerName = 'runner',
    required this.runnerImage,
    required this.runnerImageVersion,
  });

  factory RuntimeIdentity.fromJson(Map<String, Object?> json) {
    _expectFields(json, _runtimeFields, 'runtime identity');

    return RuntimeIdentity(
      dartVersion: _string(json, 'dartVersion'),
      operatingSystem: _string(json, 'operatingSystem'),
      operatingSystemVersion: _string(json, 'operatingSystemVersion'),
      architecture: _string(json, 'architecture'),
      runnerName: _string(json, 'runnerName'),
      runnerImage: _string(json, 'runnerImage'),
      runnerImageVersion: _string(json, 'runnerImageVersion'),
    );
  }

  Map<String, Object?> toJson() => {
    'dartVersion': dartVersion,
    'operatingSystem': operatingSystem,
    'operatingSystemVersion': operatingSystemVersion,
    'architecture': architecture,
    'runnerName': runnerName,
    'runnerImage': runnerImage,
    'runnerImageVersion': runnerImageVersion,
  };
}

class DependencyIdentity {
  final String dartssh2Version;
  final String seanceRevision;

  const DependencyIdentity({
    required this.dartssh2Version,
    required this.seanceRevision,
  });

  factory DependencyIdentity.fromJson(Map<String, Object?> json) {
    _expectFields(json, _dependencyFields, 'dependency identity');

    return DependencyIdentity(
      dartssh2Version: _string(json, 'dartssh2Version'),
      seanceRevision: _string(json, 'seanceRevision'),
    );
  }

  Map<String, Object?> toJson() => {
    'dartssh2Version': dartssh2Version,
    'seanceRevision': seanceRevision,
  };
}

class FixtureIdentity {
  final String tree;
  final String imageId;
  final String openSshClientVersion;
  final String openSshServerVersion;
  final int dataVersion;

  const FixtureIdentity({
    required this.tree,
    required this.imageId,
    required this.openSshClientVersion,
    required this.openSshServerVersion,
    required this.dataVersion,
  });

  factory FixtureIdentity.fromJson(Map<String, Object?> json) {
    _expectFields(json, _fixtureFields, 'fixture identity');

    return FixtureIdentity(
      tree: _string(json, 'tree'),
      imageId: _string(json, 'imageId'),
      openSshClientVersion: _string(json, 'openSshClientVersion'),
      openSshServerVersion: _string(json, 'openSshServerVersion'),
      dataVersion: _integer(json, 'dataVersion'),
    );
  }

  Map<String, Object?> toJson() => {
    'tree': tree,
    'imageId': imageId,
    'openSshClientVersion': openSshClientVersion,
    'openSshServerVersion': openSshServerVersion,
    'dataVersion': dataVersion,
  };

  Map<String, Object?> commonJson() => {
    'tree': tree,
    'openSshClientVersion': openSshClientVersion,
    'openSshServerVersion': openSshServerVersion,
    'dataVersion': dataVersion,
  };
}

class SourceIdentity {
  final String poltergeistSha;
  final String workflowRunId;
  final int workflowRunAttempt;
  final String workflowJob;
  final String shardId;
  final String host;
  final RuntimeIdentity runtime;
  final DependencyIdentity dependencies;
  final FixtureIdentity fixture;

  const SourceIdentity({
    required this.poltergeistSha,
    required this.workflowRunId,
    required this.workflowRunAttempt,
    this.workflowJob = 'm0_bench',
    required this.shardId,
    required this.host,
    required this.runtime,
    required this.dependencies,
    required this.fixture,
  });

  factory SourceIdentity.fromEnvironment({
    required String shardId,
    Map<String, String>? environment,
    IdentityCapturePhase phase = IdentityCapturePhase.terminal,
  }) {
    final values = environment ?? Platform.environment;
    final attempt = int.tryParse(values['GITHUB_RUN_ATTEMPT'] ?? '') ?? 0;
    final workflow = values.containsKey('GITHUB_RUN_ID');
    String fixtureValue(String key, String label) =>
        values[key] ??
        (phase == IdentityCapturePhase.running && workflow
            ? '$pendingIdentityPrefix$label'
            : '$localIdentityPrefix$label');

    return SourceIdentity(
      poltergeistSha: values['GITHUB_SHA'] ?? 'local-uncommitted',
      workflowRunId: values['GITHUB_RUN_ID'] ?? 'local-run',
      workflowRunAttempt: attempt,
      workflowJob: values['GITHUB_JOB'] ?? 'local-job',
      shardId: shardId,
      host: Platform.localHostname,
      runtime: RuntimeIdentity(
        dartVersion: Platform.version,
        operatingSystem: Platform.operatingSystem,
        operatingSystemVersion: Platform.operatingSystemVersion,
        architecture: values['RUNNER_ARCH'] ?? 'local-unknown-architecture',
        runnerName: values['RUNNER_NAME'] ?? 'local-unknown-runner',
        runnerImage: values['ImageOS'] ?? 'local-unknown-image',
        runnerImageVersion:
            values['ImageVersion'] ?? 'local-unknown-image-version',
      ),
      dependencies: const DependencyIdentity(
        dartssh2Version: resolvedDartssh2Version,
        seanceRevision: pinnedSeanceRevision,
      ),
      fixture: FixtureIdentity(
        tree: fixtureValue(
          'POLTERGEIST_M0_FIXTURE_TREE',
          'unresolved-fixture-tree',
        ),
        imageId: fixtureValue(
          'POLTERGEIST_M0_FIXTURE_IMAGE_ID',
          'unresolved-fixture-image',
        ),
        openSshClientVersion: fixtureValue(
          'POLTERGEIST_M0_OPENSSH_CLIENT_VERSION',
          'unresolved-openssh-client',
        ),
        openSshServerVersion: fixtureValue(
          'POLTERGEIST_M0_OPENSSH_SERVER_VERSION',
          'unresolved-openssh-server',
        ),
        dataVersion: fixtureDataVersion,
      ),
    );
  }

  factory SourceIdentity.fromJson(Map<String, Object?> json) {
    _expectFields(json, _identityFields, 'source identity');

    return SourceIdentity(
      poltergeistSha: _string(json, 'poltergeistSha'),
      workflowRunId: _string(json, 'workflowRunId'),
      workflowRunAttempt: _integer(json, 'workflowRunAttempt'),
      workflowJob: _string(json, 'workflowJob'),
      shardId: _string(json, 'shardId'),
      host: _string(json, 'host'),
      runtime: RuntimeIdentity.fromJson(_object(json, 'runtime')),
      dependencies: DependencyIdentity.fromJson(_object(json, 'dependencies')),
      fixture: FixtureIdentity.fromJson(_object(json, 'fixture')),
    );
  }

  Map<String, Object?> toJson() => {
    'poltergeistSha': poltergeistSha,
    'workflowRunId': workflowRunId,
    'workflowRunAttempt': workflowRunAttempt,
    'workflowJob': workflowJob,
    'shardId': shardId,
    'host': host,
    'runtime': runtime.toJson(),
    'dependencies': dependencies.toJson(),
    'fixture': fixture.toJson(),
  };

  Map<String, Object?> commonJson() => {
    'poltergeistSha': poltergeistSha,
    'workflowRunId': workflowRunId,
    'workflowRunAttempt': workflowRunAttempt,
    'workflowJob': workflowJob,
    'dependencies': dependencies.toJson(),
    'fixture': fixture.commonJson(),
  };
}

class SourceEnvelope {
  final int schemaVersion;
  final EvidenceState state;
  final SourceIdentity identity;
  final DateTime deadlineStartedAtUtc;
  final Duration deadlineStartedAtMonotonic;
  final DateTime startedAtUtc;
  final DateTime? finishedAtUtc;
  final Duration? lifecycleElapsed;
  final int? exitStatus;
  final String? failure;
  final List<Map<String, Object?>> rows;
  final List<Map<String, Object?>> attempts;

  const SourceEnvelope({
    required this.schemaVersion,
    required this.state,
    required this.identity,
    required this.deadlineStartedAtUtc,
    required this.deadlineStartedAtMonotonic,
    required this.startedAtUtc,
    required this.finishedAtUtc,
    required this.lifecycleElapsed,
    required this.exitStatus,
    required this.failure,
    required this.rows,
    required this.attempts,
  });

  factory SourceEnvelope.running(
    SourceIdentity identity, {
    DateTime? deadlineStartedAtUtc,
    required Duration deadlineStartedAtMonotonic,
    DateTime? startedAtUtc,
  }) {
    final resolvedStart = (startedAtUtc ?? DateTime.now()).toUtc();

    return SourceEnvelope(
      schemaVersion: sourceEnvelopeSchemaVersion,
      state: EvidenceState.running,
      identity: identity,
      deadlineStartedAtUtc: (deadlineStartedAtUtc ?? resolvedStart).toUtc(),
      deadlineStartedAtMonotonic: deadlineStartedAtMonotonic,
      startedAtUtc: resolvedStart,
      finishedAtUtc: null,
      lifecycleElapsed: null,
      exitStatus: null,
      failure: null,
      rows: const [],
      attempts: const [],
    );
  }

  factory SourceEnvelope.fromJson(Map<String, Object?> json) {
    _expectFields(json, _envelopeFields, 'source envelope');
    final stateName = _string(json, 'state');
    final states = EvidenceState.values.where(
      (state) => state.name == stateName,
    );
    if (states.isEmpty) throw EvidenceException('Unknown state: $stateName.');

    return SourceEnvelope(
      schemaVersion: _integer(json, 'schemaVersion'),
      state: states.single,
      identity: SourceIdentity.fromJson(_object(json, 'identity')),
      deadlineStartedAtUtc: _utcDate(json, 'deadlineStartedAtUtc'),
      deadlineStartedAtMonotonic: _duration(
        json,
        'deadlineStartedAtMonotonicUs',
      ),
      startedAtUtc: _utcDate(json, 'startedAtUtc'),
      finishedAtUtc: _nullableUtcDate(json, 'finishedAtUtc'),
      lifecycleElapsed: _nullableDuration(json, 'lifecycleElapsedUs'),
      exitStatus: _nullableInteger(json, 'exitStatus'),
      failure: _nullableString(json, 'failure'),
      rows: _objectList(json, 'rows'),
      attempts: _objectList(json, 'attempts'),
    );
  }

  SourceEnvelope finalized({
    required SourceIdentity finalIdentity,
    required int status,
    required List<Map<String, Object?>> finalRows,
    required List<Map<String, Object?>> finalAttempts,
    required DateTime finishedAtUtc,
    required Duration lifecycleElapsed,
    String? failureMessage,
  }) {
    if (state != EvidenceState.running) {
      throw EvidenceException('${identity.shardId} is already ${state.name}.');
    }
    final succeeded = status == 0;

    return SourceEnvelope(
      schemaVersion: schemaVersion,
      state: succeeded ? EvidenceState.succeeded : EvidenceState.failed,
      identity: finalIdentity,
      deadlineStartedAtUtc: deadlineStartedAtUtc,
      deadlineStartedAtMonotonic: deadlineStartedAtMonotonic,
      startedAtUtc: startedAtUtc,
      finishedAtUtc: finishedAtUtc.toUtc(),
      lifecycleElapsed: lifecycleElapsed,
      exitStatus: status,
      failure: succeeded
          ? null
          : failureMessage ?? 'benchmark exited with status $status',
      rows: List.unmodifiable(finalRows),
      attempts: List.unmodifiable(finalAttempts),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'state': state.name,
    'identity': identity.toJson(),
    'deadlineStartedAtUtc': deadlineStartedAtUtc.toUtc().toIso8601String(),
    'deadlineStartedAtMonotonicUs': deadlineStartedAtMonotonic.inMicroseconds,
    'startedAtUtc': startedAtUtc.toUtc().toIso8601String(),
    'finishedAtUtc': finishedAtUtc?.toUtc().toIso8601String(),
    'lifecycleElapsedUs': lifecycleElapsed?.inMicroseconds,
    'exitStatus': exitStatus,
    'failure': failure,
    'rows': rows,
    'attempts': attempts,
  };
}

void _expectFields(
  Map<String, Object?> json,
  Set<String> expected,
  String label,
) {
  final actual = json.keys.toSet();
  if (actual.length == expected.length && actual.containsAll(expected)) return;

  throw EvidenceException('$label has invalid fields.');
}

Map<String, Object?> _object(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map<String, Object?>) return value;
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return value.cast<String, Object?>();
  }

  throw EvidenceException('$key must be an object.');
}

List<Map<String, Object?>> _objectList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List<Object?>) {
    throw EvidenceException('$key must be an array.');
  }

  return List.unmodifiable([
    for (var index = 0; index < value.length; index++)
      _listObject(value[index], '$key[$index]'),
  ]);
}

Map<String, Object?> _listObject(Object? value, String label) {
  if (value is Map<String, Object?>) return value;
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return value.cast<String, Object?>();
  }

  throw EvidenceException('$label must be an object.');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;

  throw EvidenceException('$key must be a non-empty string.');
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;

  throw EvidenceException('$key must be a string or null.');
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;

  throw EvidenceException('$key must be an integer.');
}

int? _nullableInteger(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is int) return value as int?;

  throw EvidenceException('$key must be an integer or null.');
}

Duration? _nullableDuration(Map<String, Object?> json, String key) {
  final microseconds = _nullableInteger(json, key);
  if (microseconds == null) return null;
  if (microseconds >= 0) return Duration(microseconds: microseconds);

  throw EvidenceException('$key must not be negative.');
}

Duration _duration(Map<String, Object?> json, String key) {
  final microseconds = _integer(json, key);
  if (microseconds >= 0) return Duration(microseconds: microseconds);

  throw EvidenceException('$key must not be negative.');
}

DateTime _utcDate(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed != null && parsed.isUtc && value.endsWith('Z')) return parsed;

  throw EvidenceException('$key must be a UTC timestamp.');
}

DateTime? _nullableUtcDate(Map<String, Object?> json, String key) {
  if (json[key] == null) return null;

  return _utcDate(json, key);
}
