import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'evidence.dart';
import 'fixture_data.dart';
import 'result_manifest.dart';

const sourceArtifactPrefix = 'm0-bench-source';
const sourceEnvelopeFileName = 'bench-shard.json';
const canonicalEvidenceFileName = 'm0-evidence.json';
const rawEvidenceDirectoryName = 'raw';
const sha256ManifestFileName = 'SHA256SUMS';
const canonicalEvidenceSchemaVersion = 1;
const _jsonEncoder = JsonEncoder.withIndent('  ');
const _baseRowFields = {
  'scenario',
  'bytes',
  'dartssh2Version',
  'seanceRev',
  'rttMs',
  'elapsedUs',
  'note',
  'timestampUtc',
  'host',
};
const _optionalRowFields = {'rttEvidence', 'throughputTrials'};
const _attemptFields = {
  'reference',
  'scenario',
  'direction',
  'variant',
  'replicate',
  'ordinal',
  'phase',
  'payloadBytes',
  'status',
  'startedAtUtc',
  'endedAtUtc',
  'elapsedUs',
  'primeReference',
  'warmupReference',
  'rttEvidence',
  'integrity',
  'error',
};
const _bundleFields = {'sourcePrime', 'warmupSourcePrime', 'warmup', 'trial'};
const _rttProbeSampleCount = 7;
final _gitShaPattern = RegExp(r'^[0-9a-f]{40}$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final _workflowRunPattern = RegExp(r'^[0-9]+$');
final _imageIdPattern = RegExp(r'^(?:sha256:)?[0-9a-f]{12,64}$');

enum _AttemptPhase { prime, warmup, trial }

enum _CanonicalAttribution { singleSource, distributed }

class ResultAggregationException implements Exception {
  final String message;

  const ResultAggregationException(this.message);

  @override
  String toString() => message;
}

class CanonicalEvidenceBundle {
  final Map<String, Object?> identity;
  final List<Map<String, Object?>> sources;
  final List<Map<String, Object?>> results;

  const CanonicalEvidenceBundle({
    required this.identity,
    required this.sources,
    required this.results,
  });

  Map<String, Object?> toJson() => {
    'schemaVersion': canonicalEvidenceSchemaVersion,
    'identity': identity,
    'sources': sources,
    'results': results,
  };
}

/// Scans all source artifacts, validates them as one experiment, then writes
/// an immutable canonical bundle beside byte-for-byte source copies.
Future<CanonicalEvidenceBundle> aggregateEvidenceDirectory({
  required String inputRoot,
  required String outputDirectory,
  required String expectedRunId,
  required int expectedRunAttempt,
  required String expectedGitSha,
  required String expectedDartssh2Version,
  required String expectedSeanceRevision,
}) async {
  if (!_gitShaPattern.hasMatch(expectedGitSha)) {
    throw ResultAggregationException(
      'Invalid expected git SHA: $expectedGitSha.',
    );
  }
  if (expectedRunId.trim().isEmpty || expectedRunAttempt <= 0) {
    throw const ResultAggregationException(
      'Invalid expected workflow identity.',
    );
  }
  if (expectedDartssh2Version.trim().isEmpty ||
      expectedSeanceRevision.trim().isEmpty) {
    throw const ResultAggregationException(
      'Invalid expected dependency pins.',
    );
  }

  final sources = await _readSources(inputRoot);
  _validateSourceIdentities(
    sources,
    expectedRunId: expectedRunId,
    expectedRunAttempt: expectedRunAttempt,
    expectedGitSha: expectedGitSha,
    expectedDartssh2Version: expectedDartssh2Version,
    expectedSeanceRevision: expectedSeanceRevision,
  );
  final validated = [
    for (final source in sources)
      _validateSource(
        source,
        expectedDartssh2Version: expectedDartssh2Version,
        expectedSeanceRevision: expectedSeanceRevision,
      ),
  ];
  final results = _canonicalResults(validated);
  final bundle = CanonicalEvidenceBundle(
    identity: sources.first.envelope.identity.commonJson(),
    sources: List.unmodifiable([
      for (final source in sources) source.envelope.toJson(),
    ]),
    results: List.unmodifiable(results),
  );
  await _writeBundle(outputDirectory, bundle, sources);

  return bundle;
}

class _SourceArtifact {
  final M0SourceSpec spec;
  final SourceEnvelope envelope;
  final List<int> rawBytes;

  const _SourceArtifact({
    required this.spec,
    required this.envelope,
    required this.rawBytes,
  });
}

class _ValidatedSource {
  final _SourceArtifact artifact;
  final Map<String, Map<String, Object?>> rows;
  final Map<String, List<String>> samplesByScenario;

  const _ValidatedSource({
    required this.artifact,
    required this.rows,
    required this.samplesByScenario,
  });
}

Future<List<_SourceArtifact>> _readSources(String inputRoot) async {
  final root = Directory(inputRoot);
  if (!await root.exists()) {
    throw ResultAggregationException('Input root does not exist: $inputRoot.');
  }
  final expectedNames = {
    for (final source in m0SourceManifest) '$sourceArtifactPrefix-${source.id}',
  };
  final entities = await root.list(followLinks: false).toList();
  final actualNames = <String>{};
  for (final entity in entities) {
    final name = _basename(entity.path);
    if (entity is! Directory || !expectedNames.contains(name)) {
      throw ResultAggregationException('Unexpected source artifact: $name.');
    }
    if (!actualNames.add(name)) {
      throw ResultAggregationException('Duplicate source artifact: $name.');
    }
  }
  final missing = expectedNames.difference(actualNames);
  if (missing.isNotEmpty) {
    throw ResultAggregationException(
      'Missing source artifacts: ${_sorted(missing).join(', ')}.',
    );
  }

  final sources = <_SourceArtifact>[];
  for (final spec in m0SourceManifest) {
    final directory = Directory(
      '${root.path}/$sourceArtifactPrefix-${spec.id}',
    );
    final entries = await directory.list(followLinks: false).toList();
    if (entries.length != 1 ||
        entries.single is! File ||
        _basename(entries.single.path) != sourceEnvelopeFileName) {
      throw ResultAggregationException(
        '${spec.id} must contain only $sourceEnvelopeFileName.',
      );
    }
    final rawBytes = await File(entries.single.path).readAsBytes();
    try {
      final decoded = jsonDecode(utf8.decode(rawBytes));
      if (decoded is! Map<Object?, Object?> ||
          decoded.keys.any((key) => key is! String)) {
        throw const EvidenceException('Source envelope must be an object.');
      }
      final envelope = SourceEnvelope.fromJson(decoded.cast<String, Object?>());
      if (envelope.identity.shardId != spec.id) {
        throw ResultAggregationException(
          '${spec.id} declares shard ${envelope.identity.shardId}.',
        );
      }
      sources.add(
        _SourceArtifact(spec: spec, envelope: envelope, rawBytes: rawBytes),
      );
    } on ResultAggregationException {
      rethrow;
    } on Object catch (error) {
      throw ResultAggregationException('${spec.id} is invalid: $error.');
    }
  }

  return List.unmodifiable(sources);
}

void _validateSourceIdentities(
  List<_SourceArtifact> sources, {
  required String expectedRunId,
  required int expectedRunAttempt,
  required String expectedGitSha,
  required String expectedDartssh2Version,
  required String expectedSeanceRevision,
}) {
  String? commonIdentity;
  for (final source in sources) {
    final envelope = source.envelope;
    final identity = envelope.identity;
    if (envelope.schemaVersion != sourceEnvelopeSchemaVersion) {
      throw ResultAggregationException(
        '${source.spec.id} uses source schema ${envelope.schemaVersion}.',
      );
    }
    if (envelope.state != EvidenceState.succeeded ||
        envelope.exitStatus != 0 ||
        envelope.failure != null ||
        envelope.finishedAtUtc == null) {
      throw ResultAggregationException(
        '${source.spec.id} did not finalize successfully.',
      );
    }
    if (!envelope.finishedAtUtc!.isAfter(envelope.startedAtUtc)) {
      throw ResultAggregationException(
        '${source.spec.id} has an invalid source time range.',
      );
    }
    final lifecycleElapsed = envelope.lifecycleElapsed;
    if (lifecycleElapsed == null || lifecycleElapsed <= Duration.zero) {
      throw ResultAggregationException(
        '${source.spec.id} has invalid monotonic lifecycle evidence.',
      );
    }
    final setupDelay = envelope.startedAtUtc.difference(
      envelope.deadlineStartedAtUtc,
    );
    if (setupDelay.isNegative || setupDelay > sourceDeadlineSetupTolerance) {
      throw ResultAggregationException(
        '${source.spec.id} has an invalid deadline anchor.',
      );
    }
    if (source.spec.kind == M0SourceKind.isolated &&
        (envelope.finishedAtUtc!.isAfter(
              envelope.deadlineStartedAtUtc.add(isolatedSourceLifecycleBudget),
            ) ||
            lifecycleElapsed > isolatedSourceLifecycleBudget)) {
      throw ResultAggregationException(
        '${source.spec.id} exceeded its lifecycle deadline.',
      );
    }
    if (identity.poltergeistSha != expectedGitSha ||
        identity.workflowRunId != expectedRunId ||
        identity.workflowRunAttempt != expectedRunAttempt) {
      throw ResultAggregationException(
        '${source.spec.id} has mixed workflow identity.',
      );
    }
    if (!_gitShaPattern.hasMatch(identity.poltergeistSha) ||
        !_workflowRunPattern.hasMatch(identity.workflowRunId) ||
        identity.workflowRunAttempt <= 0 ||
        !_gitShaPattern.hasMatch(identity.fixture.tree) ||
        !_imageIdPattern.hasMatch(identity.fixture.imageId) ||
        identity.fixture.dataVersion != fixtureDataVersion) {
      throw ResultAggregationException(
        '${source.spec.id} has malformed workflow identity.',
      );
    }
    if (identity.dependencies.dartssh2Version != expectedDartssh2Version ||
        identity.dependencies.seanceRevision != expectedSeanceRevision) {
      throw ResultAggregationException(
        '${source.spec.id} has unexpected dependency pins.',
      );
    }
    if (_containsUnresolvedIdentity(identity.toJson())) {
      throw ResultAggregationException(
        '${source.spec.id} contains local identity placeholders.',
      );
    }
    final encodedCommon = jsonEncode(identity.commonJson());
    commonIdentity ??= encodedCommon;
    if (encodedCommon != commonIdentity) {
      throw ResultAggregationException(
        '${source.spec.id} has mixed experiment identity.',
      );
    }
  }
}

_ValidatedSource _validateSource(
  _SourceArtifact artifact, {
  required String expectedDartssh2Version,
  required String expectedSeanceRevision,
}) {
  final envelope = artifact.envelope;
  final expectedScenarios = artifact.spec.scenarios.toSet();
  final rows = <String, Map<String, Object?>>{};
  for (final row in envelope.rows) {
    final scenario = _requiredString(row, 'scenario', artifact.spec.id);
    if (!expectedScenarios.contains(scenario)) {
      throw ResultAggregationException(
        '$scenario is assigned to the wrong source ${artifact.spec.id}.',
      );
    }
    if (rows.containsKey(scenario)) {
      throw ResultAggregationException(
        '${artifact.spec.id} duplicates $scenario.',
      );
    }
    _validateRow(
      row,
      scenario,
      envelope,
      expectedDartssh2Version: expectedDartssh2Version,
      expectedSeanceRevision: expectedSeanceRevision,
    );
    rows[scenario] = row;
  }
  final missingRows = expectedScenarios.difference(rows.keys.toSet());
  if (missingRows.isNotEmpty) {
    throw ResultAggregationException(
      '${artifact.spec.id} is missing ${_sorted(missingRows).join(', ')}.',
    );
  }

  final attempts = _attemptsByReference(artifact);
  final samplesByScenario = <String, List<String>>{};
  final linkedPrimes = <String>{};
  final linkedWarmups = <String>{};
  final linkedTrials = <String>{};
  for (final row in rows.values) {
    final scenario = row['scenario']! as String;
    final throughput = _isThroughputScenario(scenario);
    final bundleValues = row['throughputTrials'];
    if (!throughput) {
      if (bundleValues != null) {
        throw ResultAggregationException(
          '$scenario has unexpected throughput trials.',
        );
      }
      continue;
    }
    if (bundleValues is! List<Object?>) {
      throw ResultAggregationException('$scenario needs throughput trials.');
    }
    final expectedSamples = artifact.spec.kind == M0SourceKind.standard ? 2 : 1;
    if (bundleValues.length != expectedSamples) {
      throw ResultAggregationException(
        '$scenario needs $expectedSamples raw samples.',
      );
    }
    final sampleIds = <String>[];
    final elapsedSamples = <int>[];
    for (var index = 0; index < bundleValues.length; index++) {
      final bundle = _asObject(bundleValues[index], '$scenario sample $index');
      final sample = _validateBundle(
        bundle,
        row: row,
        artifact: artifact,
        attempts: attempts,
      );
      if (!linkedWarmups.add(sample.warmupReference) ||
          !linkedTrials.add(sample.trialReference)) {
        throw ResultAggregationException('$scenario reuses a raw attempt.');
      }
      linkedPrimes
        ..add(sample.sourcePrimeReference)
        ..add(sample.warmupPrimeReference);
      sampleIds.add(sample.trialReference);
      elapsedSamples.add(sample.elapsedUs);
    }
    final rowElapsed = _requiredInteger(row, 'elapsedUs', scenario);
    final expectedElapsed = artifact.spec.kind == M0SourceKind.standard
        ? _midpoint(elapsedSamples)
        : elapsedSamples.single;
    if (rowElapsed != expectedElapsed) {
      throw ResultAggregationException(
        '$scenario elapsedUs is not its raw-sample midpoint.',
      );
    }
    samplesByScenario[scenario] = List.unmodifiable(sampleIds);
  }

  final trialAttempts = attempts.values
      .where((attempt) => attempt['phase'] == _AttemptPhase.trial.name)
      .toList();
  final warmupAttempts = attempts.values
      .where((attempt) => attempt['phase'] == _AttemptPhase.warmup.name)
      .toList();
  final primeAttempts = attempts.values
      .where((attempt) => attempt['phase'] == _AttemptPhase.prime.name)
      .toList();
  final expectedRawCount = artifact.spec.kind == M0SourceKind.standard
      ? standardRawTrialCount
      : 1;
  final expectedPrimeCount = artifact.spec.kind == M0SourceKind.standard
      ? affordableThroughputCells.length
      : 2;
  if (trialAttempts.length != expectedRawCount ||
      warmupAttempts.length != expectedRawCount ||
      linkedTrials.length != trialAttempts.length ||
      linkedWarmups.length != warmupAttempts.length ||
      primeAttempts.length != expectedPrimeCount ||
      linkedPrimes.length != primeAttempts.length) {
    throw ResultAggregationException(
      '${artifact.spec.id} has invalid raw attempt counts.',
    );
  }
  _validateTrialAssignment(artifact, trialAttempts);
  _validatePrimeScope(artifact, trialAttempts, attempts);

  return _ValidatedSource(
    artifact: artifact,
    rows: Map.unmodifiable(rows),
    samplesByScenario: Map.unmodifiable(samplesByScenario),
  );
}

void _validateRow(
  Map<String, Object?> row,
  String scenario,
  SourceEnvelope envelope, {
  required String expectedDartssh2Version,
  required String expectedSeanceRevision,
}) {
  final fields = row.keys.toSet();
  final missing = _baseRowFields.difference(fields);
  final extra = fields.difference({..._baseRowFields, ..._optionalRowFields});
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throw ResultAggregationException(
      '$scenario has invalid result fields: missing=${_sorted(missing)}; '
      'extra=${_sorted(extra)}.',
    );
  }
  final bytes = _requiredInteger(row, 'bytes', scenario);
  if (bytes != expectedBytesForScenario(scenario)) {
    throw ResultAggregationException(
      '$scenario has invalid byte count $bytes.',
    );
  }
  final elapsedUs = _requiredInteger(row, 'elapsedUs', scenario);
  final clientSupport = scenario.startsWith('algorithm-client-support-');
  if ((!clientSupport && elapsedUs <= 0) || (clientSupport && elapsedUs < 0)) {
    throw ResultAggregationException(
      '$scenario has invalid elapsedUs=$elapsedUs.',
    );
  }
  if (_requiredString(row, 'dartssh2Version', scenario) !=
          expectedDartssh2Version ||
      _requiredString(row, 'seanceRev', scenario) != expectedSeanceRevision) {
    throw ResultAggregationException(
      '$scenario has invalid dependency attribution.',
    );
  }
  if (_requiredString(row, 'host', scenario) != envelope.identity.host) {
    throw ResultAggregationException('$scenario has invalid host attribution.');
  }
  final timestamp = _requiredUtc(row, 'timestampUtc', scenario);
  if (timestamp.isBefore(envelope.startedAtUtc) ||
      timestamp.isAfter(envelope.finishedAtUtc!)) {
    throw ResultAggregationException(
      '$scenario timestamp is outside its source.',
    );
  }
  final note = row['note'];
  if (note != null && note is! String) {
    throw ResultAggregationException('$scenario has invalid note.');
  }
  final shaped = scenario.endsWith('-rtt100');
  final rttMs = row['rttMs'];
  if (!shaped) {
    if (rttMs != null || row['rttEvidence'] != null) {
      throw ResultAggregationException('$scenario has RTT evidence on LAN.');
    }
    return;
  }
  if (rttMs is! int || rttMs <= 0) {
    throw ResultAggregationException(
      '$scenario needs a positive measured RTT.',
    );
  }
  final evidence = _asObject(row['rttEvidence'], '$scenario RTT evidence');
  final captured = _requiredUtc(evidence, 'capturedAtUtc', scenario);
  if (_validateRttEvidence(evidence, envelope, scenario) != rttMs ||
      captured.isAfter(timestamp)) {
    throw ResultAggregationException(
      '$scenario has inconsistent RTT evidence.',
    );
  }
}

Map<String, Map<String, Object?>> _attemptsByReference(
  _SourceArtifact artifact,
) {
  final envelope = artifact.envelope;
  final attempts = <String, Map<String, Object?>>{};
  final destinations = <String>{};
  for (final attempt in envelope.attempts) {
    final fields = attempt.keys.toSet();
    if (!_setEquals(fields, _attemptFields)) {
      throw ResultAggregationException(
        '${envelope.identity.shardId} has invalid attempt fields.',
      );
    }
    final reference = _requiredString(
      attempt,
      'reference',
      envelope.identity.shardId,
    );
    if (attempts.containsKey(reference)) {
      throw ResultAggregationException(
        '${envelope.identity.shardId} duplicates attempt $reference.',
      );
    }
    final phaseName = _requiredString(attempt, 'phase', reference);
    final phases = _AttemptPhase.values.where(
      (phase) => phase.name == phaseName,
    );
    if (phases.isEmpty) {
      throw ResultAggregationException(
        '$reference has invalid phase $phaseName.',
      );
    }
    final phase = phases.single;
    if (phase == _AttemptPhase.prime) {
      if (attempt['variant'] != null ||
          attempt['replicate'] != null ||
          attempt['ordinal'] != null ||
          attempt['primeReference'] != null ||
          attempt['warmupReference'] != null) {
        throw ResultAggregationException(
          '$reference has invalid prime attribution.',
        );
      }
    } else {
      final variant = attempt['variant'];
      final replicate = attempt['replicate'];
      final ordinal = attempt['ordinal'];
      if (variant is! String ||
          M0ThroughputVariant.fromLabel(variant) == null ||
          replicate is! int ||
          (replicate != 1 && replicate != 2) ||
          (artifact.spec.kind == M0SourceKind.standard && ordinal is! int) ||
          (artifact.spec.kind == M0SourceKind.isolated && ordinal != null)) {
        throw ResultAggregationException(
          '$reference has invalid sample attribution.',
        );
      }
    }
    final elapsedUs = _requiredInteger(attempt, 'elapsedUs', reference);
    if (attempt['status'] != 'success' ||
        attempt['error'] != null ||
        _requiredInteger(attempt, 'payloadBytes', reference) <= 0 ||
        elapsedUs <= 0) {
      throw ResultAggregationException('$reference did not succeed.');
    }
    final started = _requiredUtc(attempt, 'startedAtUtc', reference);
    final ended = _requiredUtc(attempt, 'endedAtUtc', reference);
    if (started.isBefore(envelope.startedAtUtc) ||
        ended.isAfter(envelope.finishedAtUtc!) ||
        ended.isBefore(started)) {
      throw ResultAggregationException(
        '$reference has invalid timing provenance.',
      );
    }
    final wallUs = ended.difference(started).inMicroseconds;
    if (elapsedUs > wallUs) {
      throw ResultAggregationException(
        '$reference elapsed time exceeds wall time.',
      );
    }
    if (artifact.spec.kind == M0SourceKind.isolated &&
        phase == _AttemptPhase.trial) {
      if (elapsedUs > isolatedTransferBudget.inMicroseconds) {
        throw ResultAggregationException(
          '$reference exceeded its transfer deadline.',
        );
      }
      final trialDeadline = envelope.deadlineStartedAtUtc.add(
        isolatedTrialCompletionBudget,
      );
      if (ended.isAfter(trialDeadline)) {
        throw ResultAggregationException(
          '$reference consumed its post-transfer reserve.',
        );
      }
    }
    _validateIntegrity(attempt, reference);
    if (phaseName != _AttemptPhase.prime.name) {
      final integrity = attempt['integrity']! as Map<Object?, Object?>;
      final destination = integrity['destination']! as String;
      if (!destinations.add(destination)) {
        throw ResultAggregationException(
          '${envelope.identity.shardId} reuses destination $destination.',
        );
      }
    }
    attempts[reference] = attempt;
  }
  if (attempts.isEmpty) {
    throw ResultAggregationException(
      '${envelope.identity.shardId} has no structured attempts.',
    );
  }

  return attempts;
}

class _RawSample {
  final String sourcePrimeReference;
  final String warmupPrimeReference;
  final String trialReference;
  final String warmupReference;
  final int elapsedUs;

  const _RawSample({
    required this.sourcePrimeReference,
    required this.warmupPrimeReference,
    required this.trialReference,
    required this.warmupReference,
    required this.elapsedUs,
  });
}

_RawSample _validateBundle(
  Map<String, Object?> bundle, {
  required Map<String, Object?> row,
  required _SourceArtifact artifact,
  required Map<String, Map<String, Object?>> attempts,
}) {
  final scenario = row['scenario']! as String;
  if (!_setEquals(bundle.keys.toSet(), _bundleFields)) {
    throw ResultAggregationException('$scenario has invalid sample fields.');
  }
  final sourcePrime = _linkedAttempt(bundle, 'sourcePrime', attempts, scenario);
  final warmupPrime = _linkedAttempt(
    bundle,
    'warmupSourcePrime',
    attempts,
    scenario,
  );
  final warmup = _linkedAttempt(bundle, 'warmup', attempts, scenario);
  final trial = _linkedAttempt(bundle, 'trial', attempts, scenario);
  _expectPhase(sourcePrime, _AttemptPhase.prime, scenario);
  _expectPhase(warmupPrime, _AttemptPhase.prime, scenario);
  _expectPhase(warmup, _AttemptPhase.warmup, scenario);
  _expectPhase(trial, _AttemptPhase.trial, scenario);

  final sourcePrimeReference = sourcePrime['reference']! as String;
  final warmupPrimeReference = warmupPrime['reference']! as String;
  final warmupReference = warmup['reference']! as String;
  final trialReference = trial['reference']! as String;
  if (warmup['primeReference'] != warmupPrimeReference ||
      trial['primeReference'] != sourcePrimeReference ||
      trial['warmupReference'] != warmupReference) {
    throw ResultAggregationException(
      '$scenario has broken attempt provenance.',
    );
  }
  if (sourcePrime['payloadBytes'] != row['bytes'] ||
      trial['payloadBytes'] != row['bytes'] ||
      warmupPrime['payloadBytes'] != fixturePayload1MbBytes ||
      warmup['payloadBytes'] != fixturePayload1MbBytes) {
    throw ResultAggregationException(
      '$scenario has invalid prime or warmup bytes.',
    );
  }
  final match = RegExp(
    r'^(dart-hash-on|dart-hash-off|openssh)-(download|upload)-(1mb|100mb|1gb)-(lan|rtt100)$',
  ).firstMatch(scenario)!;
  final variant = match.group(1)!;
  final direction = match.group(2)!;
  final payload = match.group(3)!;
  final link = match.group(4)!;
  final expectedSourcePrime = '$direction-$payload-$link-source-prime';
  final expectedWarmupPrime = '$direction-1mb-$link-source-prime';
  if (sourcePrime['scenario'] != expectedSourcePrime ||
      warmupPrime['scenario'] != expectedWarmupPrime ||
      warmup['scenario'] != scenario ||
      trial['scenario'] != scenario ||
      sourcePrime['direction'] != direction ||
      warmupPrime['direction'] != direction) {
    throw ResultAggregationException('$scenario has misassigned attempts.');
  }
  for (final attempt in [warmup, trial]) {
    if (attempt['direction'] != direction ||
        attempt['variant'] != variant ||
        attempt['replicate'] != trial['replicate'] ||
        attempt['ordinal'] != trial['ordinal']) {
      throw ResultAggregationException(
        '$scenario has mixed sample attribution.',
      );
    }
  }
  final primeEnded = _requiredUtc(
    sourcePrime,
    'endedAtUtc',
    sourcePrimeReference,
  );
  final warmupPrimeEnded = _requiredUtc(
    warmupPrime,
    'endedAtUtc',
    warmupPrimeReference,
  );
  final warmupStarted = _requiredUtc(warmup, 'startedAtUtc', warmupReference);
  final warmupEnded = _requiredUtc(warmup, 'endedAtUtc', warmupReference);
  final trialStarted = _requiredUtc(trial, 'startedAtUtc', trialReference);
  if (primeEnded.isAfter(warmupStarted) ||
      warmupPrimeEnded.isAfter(warmupStarted) ||
      warmupEnded.isAfter(trialStarted)) {
    throw ResultAggregationException(
      '$scenario was not primed and warmed first.',
    );
  }
  final shaped = scenario.endsWith('-rtt100');
  for (final attempt in [sourcePrime, warmupPrime, warmup, trial]) {
    final rttValue = attempt['rttEvidence'];
    if (!shaped && rttValue != null) {
      throw ResultAggregationException(
        '$scenario has RTT evidence on LAN attempts.',
      );
    }
    if (!shaped) continue;
    final evidence = _asObject(rttValue, '$scenario attempt RTT evidence');
    final median = _validateRttEvidence(evidence, artifact.envelope, scenario);
    final captured = _requiredUtc(evidence, 'capturedAtUtc', scenario);
    final attemptStarted = _requiredUtc(
      attempt,
      'startedAtUtc',
      attempt['reference']! as String,
    );
    if (median != row['rttMs'] ||
        !_deepEquals(evidence, row['rttEvidence']) ||
        captured.isAfter(attemptStarted)) {
      throw ResultAggregationException(
        '$scenario has mismatched RTT attribution.',
      );
    }
  }

  return _RawSample(
    sourcePrimeReference: sourcePrimeReference,
    warmupPrimeReference: warmupPrimeReference,
    trialReference: trialReference,
    warmupReference: warmupReference,
    elapsedUs: _requiredInteger(trial, 'elapsedUs', trialReference),
  );
}

Map<String, Object?> _linkedAttempt(
  Map<String, Object?> bundle,
  String key,
  Map<String, Map<String, Object?>> attempts,
  String scenario,
) {
  final embedded = _asObject(bundle[key], '$scenario $key');
  final reference = _requiredString(embedded, 'reference', scenario);
  final recorded = attempts[reference];
  if (recorded == null || !_deepEquals(embedded, recorded)) {
    throw ResultAggregationException('$scenario has unrecorded $key evidence.');
  }

  return recorded;
}

void _expectPhase(
  Map<String, Object?> attempt,
  _AttemptPhase expected,
  String scenario,
) {
  if (attempt['phase'] == expected.name) return;

  throw ResultAggregationException(
    '$scenario has invalid ${expected.name} evidence.',
  );
}

void _validateIntegrity(Map<String, Object?> attempt, String reference) {
  final integrity = _asObject(attempt['integrity'], '$reference integrity');
  const fields = {
    'status',
    'expectedBytes',
    'actualBytes',
    'expectedSha256',
    'actualSha256',
    'destination',
    'detail',
  };
  if (!_setEquals(integrity.keys.toSet(), fields) ||
      integrity['status'] != 'verified' ||
      integrity['detail'] != null) {
    throw ResultAggregationException(
      '$reference has invalid integrity evidence.',
    );
  }
  final payloadBytes = _requiredInteger(attempt, 'payloadBytes', reference);
  final expectedBytes = _requiredInteger(integrity, 'expectedBytes', reference);
  final actualBytes = _requiredInteger(integrity, 'actualBytes', reference);
  final expectedDigest = _requiredString(
    integrity,
    'expectedSha256',
    reference,
  );
  final actualDigest = _requiredString(integrity, 'actualSha256', reference);
  final knownDigest = _fixtureDigest(payloadBytes);
  if (payloadBytes != expectedBytes ||
      expectedBytes != actualBytes ||
      expectedDigest != knownDigest ||
      actualDigest != expectedDigest ||
      !_sha256Pattern.hasMatch(actualDigest) ||
      _requiredString(integrity, 'destination', reference).trim().isEmpty) {
    throw ResultAggregationException(
      '$reference failed byte or digest integrity.',
    );
  }
}

int _validateRttEvidence(
  Map<String, Object?> evidence,
  SourceEnvelope envelope,
  String label,
) {
  const fields = {'reference', 'samplesUs', 'medianMs', 'capturedAtUtc'};
  if (!_setEquals(evidence.keys.toSet(), fields)) {
    throw ResultAggregationException('$label has invalid RTT fields.');
  }
  _requiredString(evidence, 'reference', label);
  final samplesValue = evidence['samplesUs'];
  if (samplesValue is! List<Object?> ||
      samplesValue.length != _rttProbeSampleCount ||
      samplesValue.any((sample) => sample is! int || sample <= 0)) {
    throw ResultAggregationException('$label needs seven positive RTT probes.');
  }
  final samples = samplesValue.cast<int>().toList()..sort();
  final medianMs = (samples[samples.length ~/ 2] + 500) ~/ 1000;
  if (evidence['medianMs'] != medianMs || medianMs <= 0) {
    throw ResultAggregationException(
      '$label has invalid RTT midpoint arithmetic.',
    );
  }
  final captured = _requiredUtc(evidence, 'capturedAtUtc', label);
  if (captured.isBefore(envelope.startedAtUtc) ||
      captured.isAfter(envelope.finishedAtUtc!)) {
    throw ResultAggregationException('$label RTT probe is outside its source.');
  }
  final canonicalProbe = <String, Object?>{
    'samplesUs': samplesValue,
    'medianMs': medianMs,
    'capturedAtUtc': captured.toIso8601String(),
  };
  final reference =
      'rtt-sha256:'
      '${sha256.convert(utf8.encode(jsonEncode(canonicalProbe)))}';
  if (evidence['reference'] != reference) {
    throw ResultAggregationException('$label has invalid RTT provenance.');
  }

  return medianMs;
}

void _validateTrialAssignment(
  _SourceArtifact artifact,
  List<Map<String, Object?>> trials,
) {
  final actual = <String>{};
  for (final trial in trials) {
    final reference = trial['reference']! as String;
    final scenario = _requiredString(trial, 'scenario', reference);
    final direction = _requiredString(trial, 'direction', reference);
    final variant = _requiredString(trial, 'variant', reference);
    final replicate = _requiredInteger(trial, 'replicate', reference);
    final ordinal = trial['ordinal'];
    if (ordinal != null && ordinal is! int) {
      throw ResultAggregationException('$reference has invalid ordinal.');
    }
    actual.add('$scenario|$direction|$variant|$replicate|$ordinal');
  }
  late final Set<String> expected;
  if (artifact.spec.kind == M0SourceKind.standard) {
    expected = {
      for (final trial in standardThroughputTrialSpecs)
        '${trial.scenario}|${trial.cell.direction.label}|${trial.variant.label}|'
            '${trial.replicate}|${trial.ordinal}',
    };
  } else {
    final scenario = artifact.spec.scenarios.single;
    final direction = M0ThroughputDirection.values.firstWhere(
      (candidate) => scenario.contains('-${candidate.label}-'),
    );
    final variant = M0ThroughputVariant.values.firstWhere(
      (candidate) => scenario.startsWith('${candidate.label}-'),
    );
    expected = {
      '$scenario|${direction.label}|${variant.label}|'
          '${artifact.spec.replicate}|null',
    };
  }
  if (!_setEquals(actual, expected)) {
    throw ResultAggregationException(
      '${artifact.spec.id} violates ABCCBA or replicate assignment.',
    );
  }
  if (artifact.spec.kind == M0SourceKind.standard) {
    final trialsByCell = <String, List<Map<String, Object?>>>{};
    for (final trial in trials) {
      final scenario = trial['scenario']! as String;
      final match = RegExp(
        r'^(?:dart-hash-on|dart-hash-off|openssh)-(download|upload)-(1mb|100mb|1gb)-(lan|rtt100)$',
      ).firstMatch(scenario)!;
      final cell = '${match.group(3)}-${match.group(2)}-${match.group(1)}';
      trialsByCell.putIfAbsent(cell, () => []).add(trial);
    }
    for (final cellTrials in trialsByCell.values) {
      cellTrials.sort(
        (left, right) =>
            _requiredUtc(
              left,
              'startedAtUtc',
              left['reference']! as String,
            ).compareTo(
              _requiredUtc(
                right,
                'startedAtUtc',
                right['reference']! as String,
              ),
            ),
      );
      final ordinals = [for (final trial in cellTrials) trial['ordinal']];
      if (!_listEquals(ordinals, const [1, 2, 3, 4, 5, 6])) {
        throw ResultAggregationException(
          '${artifact.spec.id} did not execute ABCCBA in ordinal order.',
        );
      }
    }
  }
}

void _validatePrimeScope(
  _SourceArtifact artifact,
  List<Map<String, Object?>> trials,
  Map<String, Map<String, Object?>> attempts,
) {
  final sourceRefsByCell = <String, Set<String>>{};
  final warmupRefsByCell = <String, Set<String>>{};
  for (final trial in trials) {
    final scenario = trial['scenario']! as String;
    final match = RegExp(
      r'^(?:dart-hash-on|dart-hash-off|openssh)-(download|upload)-(1mb|100mb|1gb)-(lan|rtt100)$',
    ).firstMatch(scenario)!;
    final direction = match.group(1)!;
    final payload = match.group(2)!;
    final link = match.group(3)!;
    final cell = '$link-$payload-$direction';
    final warmupCell = '$link-1mb-$direction';
    final sourceReference = trial['primeReference'];
    final warmupReference = trial['warmupReference'];
    final warmup = attempts[warmupReference];
    if (sourceReference is! String ||
        warmupReference is! String ||
        warmup == null ||
        warmup['primeReference'] is! String) {
      throw ResultAggregationException(
        '${artifact.spec.id} has incomplete prime provenance.',
      );
    }
    sourceRefsByCell.putIfAbsent(cell, () => <String>{}).add(sourceReference);
    warmupRefsByCell
        .putIfAbsent(warmupCell, () => <String>{})
        .add(warmup['primeReference']! as String);
    if (payload == '1mb' && sourceReference != warmup['primeReference']) {
      throw ResultAggregationException(
        '${artifact.spec.id} does not reuse its 1 MB source prime.',
      );
    }
  }
  if (sourceRefsByCell.values.any((references) => references.length != 1) ||
      warmupRefsByCell.values.any((references) => references.length != 1)) {
    throw ResultAggregationException(
      '${artifact.spec.id} repeats source priming within a cell.',
    );
  }
  final expectedCellCount = artifact.spec.kind == M0SourceKind.standard
      ? affordableThroughputCells.length
      : 1;
  if (sourceRefsByCell.length != expectedCellCount) {
    throw ResultAggregationException(
      '${artifact.spec.id} has incomplete source-prime coverage.',
    );
  }
}

List<Map<String, Object?>> _canonicalResults(List<_ValidatedSource> sources) {
  final standard = sources.first;
  final isolatedByScenario = <String, List<_ValidatedSource>>{};
  for (final source in sources.skip(1)) {
    isolatedByScenario
        .putIfAbsent(source.artifact.spec.scenarios.single, () => [])
        .add(source);
  }
  final results = <Map<String, Object?>>[];
  for (final scenario in m0ScenarioManifest) {
    if (!isIsolatedThroughputScenario(scenario)) {
      final row = standard.rows[scenario]!;
      results.add(
        _canonicalRow(
          row,
          sampleIds: standard.samplesByScenario[scenario] ?? const [],
          sourceIds: const [standardSourceId],
          attribution: _CanonicalAttribution.singleSource,
        ),
      );
      continue;
    }
    final sourceRows = isolatedByScenario[scenario];
    if (sourceRows == null || sourceRows.length != 2) {
      throw ResultAggregationException('$scenario needs two isolated sources.');
    }
    sourceRows.sort(
      (left, right) => left.artifact.spec.replicate!.compareTo(
        right.artifact.spec.replicate!,
      ),
    );
    final rows = [for (final source in sourceRows) source.rows[scenario]!];
    final elapsed = _midpoint([
      for (final row in rows) row['elapsedUs']! as int,
    ]);
    final first = Map<String, Object?>.of(rows.first)..['elapsedUs'] = elapsed;
    first['note'] =
        'samples=2; aggregate=floor-midpoint; '
        'execution=isolated-hosted-jobs';
    results.add(
      _canonicalRow(
        first,
        sampleIds: [
          for (final source in sourceRows)
            ...source.samplesByScenario[scenario]!,
        ],
        sourceIds: [for (final source in sourceRows) source.artifact.spec.id],
        attribution: _CanonicalAttribution.distributed,
      ),
    );
  }
  if (results.length != m0ScenarioCount) {
    throw const ResultAggregationException('Canonical result count is not 78.');
  }

  return results;
}

Map<String, Object?> _canonicalRow(
  Map<String, Object?> row, {
  required List<String> sampleIds,
  required List<String> sourceIds,
  required _CanonicalAttribution attribution,
}) => {
  'scenario': row['scenario'],
  'bytes': row['bytes'],
  'dartssh2Version': row['dartssh2Version'],
  'seanceRev': row['seanceRev'],
  'elapsedUs': row['elapsedUs'],
  'note': row['note'],
  if (attribution == _CanonicalAttribution.singleSource) ...{
    'rttMs': row['rttMs'],
    'timestampUtc': row['timestampUtc'],
    'host': row['host'],
    if (row['rttEvidence'] != null) 'rttEvidence': row['rttEvidence'],
  },
  'sampleIds': List.unmodifiable(sampleIds),
  'sourceShardIds': List.unmodifiable(sourceIds),
};

Future<void> _writeBundle(
  String outputDirectory,
  CanonicalEvidenceBundle bundle,
  List<_SourceArtifact> sources,
) async {
  final target = Directory(outputDirectory).absolute;
  if (await target.exists()) {
    throw ResultAggregationException('${target.path} already exists.');
  }
  await target.parent.create(recursive: true);
  final temporary = Directory('${target.path}.$pid.tmp');
  if (await temporary.exists()) {
    throw ResultAggregationException('${temporary.path} already exists.');
  }
  await temporary.create();
  try {
    final canonical = File('${temporary.path}/$canonicalEvidenceFileName');
    await canonical.writeAsString(
      '${_jsonEncoder.convert(bundle.toJson())}\n',
      flush: true,
    );
    final rawDirectory = Directory(
      '${temporary.path}/$rawEvidenceDirectoryName',
    );
    await rawDirectory.create();
    for (final source in sources) {
      await File(
        '${rawDirectory.path}/${source.spec.id}.json',
      ).writeAsBytes(source.rawBytes, flush: true);
    }
    final relativePaths = <String>[
      canonicalEvidenceFileName,
      for (final source in sources)
        '$rawEvidenceDirectoryName/${source.spec.id}.json',
    ]..sort();
    final lines = <String>[];
    for (final relativePath in relativePaths) {
      final digest = sha256.convert(
        await File('${temporary.path}/$relativePath').readAsBytes(),
      );
      lines.add('$digest  $relativePath');
    }
    await File(
      '${temporary.path}/$sha256ManifestFileName',
    ).writeAsString('${lines.join('\n')}\n', flush: true);
    await temporary.rename(target.path);
  } finally {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  }
}

bool _isThroughputScenario(String scenario) => RegExp(
  r'^(?:dart-hash-on|dart-hash-off|openssh)-(?:download|upload)-',
).hasMatch(scenario);

String _fixtureDigest(int bytes) => switch (bytes) {
  fixturePayload1MbBytes => fixturePayload1MbSha256,
  fixturePayload100MbBytes => fixturePayload100MbSha256,
  fixturePayload1GbBytes => fixturePayload1GbSha256,
  _ => throw ResultAggregationException('Unknown fixture byte count: $bytes.'),
};

int _midpoint(List<int> samples) {
  if (samples.length != 2) {
    throw const ResultAggregationException(
      'A midpoint needs exactly two samples.',
    );
  }
  final ordered = [...samples]..sort();
  return (ordered[0] + ordered[1]) ~/ 2;
}

Map<String, Object?> _asObject(Object? value, String label) {
  if (value is Map<String, Object?>) return value;
  if (value is Map<Object?, Object?> &&
      value.keys.every((key) => key is String)) {
    return value.cast<String, Object?>();
  }

  throw ResultAggregationException('$label must be an object.');
}

String _requiredString(Map<String, Object?> value, String key, String label) {
  final field = value[key];
  if (field is String && field.trim().isNotEmpty) return field;

  throw ResultAggregationException('$label has invalid $key.');
}

int _requiredInteger(Map<String, Object?> value, String key, String label) {
  final field = value[key];
  if (field is int) return field;

  throw ResultAggregationException('$label has invalid $key.');
}

DateTime _requiredUtc(Map<String, Object?> value, String key, String label) {
  final text = value[key];
  final parsed = text is String ? DateTime.tryParse(text) : null;
  if (parsed != null && parsed.isUtc && (text as String).endsWith('Z')) {
    return parsed;
  }

  throw ResultAggregationException('$label has invalid UTC $key.');
}

bool _containsUnresolvedIdentity(Object? value) {
  if (value is String) {
    return value.startsWith(localIdentityPrefix) ||
        value.startsWith(pendingIdentityPrefix);
  }
  if (value is List<Object?>) return value.any(_containsUnresolvedIdentity);
  if (value is Map<Object?, Object?>) {
    return value.values.any(_containsUnresolvedIdentity);
  }

  return false;
}

bool _deepEquals(Object? left, Object? right) {
  if (left is Map<Object?, Object?> && right is Map<Object?, Object?>) {
    if (!_setEquals(left.keys.toSet(), right.keys.toSet())) return false;
    for (final key in left.keys) {
      if (!_deepEquals(left[key], right[key])) return false;
    }
    return true;
  }
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }

  return left == right;
}

bool _setEquals(Set<Object?> left, Set<Object?> right) =>
    left.length == right.length && left.containsAll(right);

bool _listEquals(List<Object?> left, List<Object?> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

List<String> _sorted(Iterable<String> values) => values.toList()..sort();

String _basename(String path) => path.split(Platform.pathSeparator).last;
