const standardSourceId = 'standard';
const standardSourceScenarioCount = 72;
const isolatedCanonicalScenarioCount = 6;
const isolatedSourceCount = 12;
const standardRawTrialCount = 60;
const isolatedRawTrialCount = 12;
const m0ScenarioCount = 78;
const fixturePayloadOneMegabyteBytes = 1000000;
const fixturePayloadOneHundredMegabytesBytes = 100000000;
const fixturePayloadOneGigabyteBytes = 1000000000;
const sourceDeadlineSetupTolerance = Duration(minutes: 1);
const isolatedSourceLifecycleBudget = Duration(minutes: 315);
const isolatedTransferBudget = Duration(minutes: 240);
const isolatedPostTransferReserve = Duration(minutes: 30);
const isolatedTrialCompletionBudget = Duration(minutes: 285);
const isolatedSourceDeadlineExitStatus = 124;

const _throughputPayloads = ['1mb', '100mb', '1gb'];
const _linkProfiles = ['lan', 'rtt100'];
const _algorithmScenarios = [
  'algorithm-default',
  'algorithm-legacy-default',
  'algorithm-aes128-gcm',
  'algorithm-aes256-gcm',
  'algorithm-rsa-sha2-512',
  'algorithm-rsa-sha2-256',
  'algorithm-chacha-curve-pq',
  'algorithm-ed25519-only',
  'algorithm-client-support-chacha20-poly1305',
  'algorithm-client-support-curve25519',
  'algorithm-client-support-mlkem768x25519',
];
const _pipelineDepths = [8, 16, 32];
const _pipelineReaddirDepths = [1, 8];
const _pipelineChannelCounts = [1, 2, 3, 4, 8];
const _pipelineTransportCounts = [1, 2, 4];
const _isolateScenarios = [
  'isolate-root-baseline',
  'isolate-single-transfer',
  'isolate-cancellation',
  'isolate-progress-flood',
  'isolate-four-transfers-listing',
];
const _abccbaVariants = [
  M0ThroughputVariant.dartHashOn,
  M0ThroughputVariant.openSsh,
  M0ThroughputVariant.dartHashOff,
  M0ThroughputVariant.dartHashOff,
  M0ThroughputVariant.openSsh,
  M0ThroughputVariant.dartHashOn,
];
const _abccbaReplicates = [1, 1, 1, 2, 2, 2];

enum M0ThroughputVariant {
  dartHashOn('dart-hash-on'),
  dartHashOff('dart-hash-off'),
  openSsh('openssh');

  final String label;

  const M0ThroughputVariant(this.label);

  static M0ThroughputVariant? fromLabel(String value) {
    for (final variant in values) {
      if (variant.label == value) return variant;
    }

    return null;
  }
}

enum M0ThroughputDirection {
  download('download'),
  upload('upload');

  final String label;

  const M0ThroughputDirection(this.label);

  static M0ThroughputDirection? fromLabel(String value) {
    for (final direction in values) {
      if (direction.label == value) return direction;
    }

    return null;
  }
}

enum M0SourceKind { standard, isolated }

class ThroughputCellSpec {
  final String link;
  final String payload;
  final M0ThroughputDirection direction;

  const ThroughputCellSpec({
    required this.link,
    required this.payload,
    required this.direction,
  });

  String get id => '$link-$payload-${direction.label}';

  int get bytes => switch (payload) {
    '1mb' => fixturePayloadOneMegabyteBytes,
    '100mb' => fixturePayloadOneHundredMegabytesBytes,
    '1gb' => fixturePayloadOneGigabyteBytes,
    _ => throw StateError('Unknown payload: $payload'),
  };

  String scenarioFor(M0ThroughputVariant variant) =>
      '${variant.label}-${direction.label}-$payload-$link';
}

class ThroughputTrialSpec {
  final ThroughputCellSpec cell;
  final M0ThroughputVariant variant;
  final int replicate;
  final int? ordinal;

  const ThroughputTrialSpec({
    required this.cell,
    required this.variant,
    required this.replicate,
    required this.ordinal,
  });

  String get cellId => cell.id;
  String get scenario => cell.scenarioFor(variant);
  String get sampleId => '$scenario-r$replicate';
}

class M0SourceSpec {
  final String id;
  final M0SourceKind kind;
  final List<String> scenarios;
  final int? replicate;

  const M0SourceSpec({
    required this.id,
    required this.kind,
    required this.scenarios,
    required this.replicate,
  });
}

/// One ordering controls source assignment, validation, and report input.
final List<String> m0ScenarioManifest = List.unmodifiable([
  for (final link in _linkProfiles)
    for (final payload in _throughputPayloads)
      for (final direction in M0ThroughputDirection.values)
        for (final variant in M0ThroughputVariant.values)
          '${variant.label}-${direction.label}-$payload-$link',
  ..._algorithmScenarios,
  for (final link in _linkProfiles) ...[
    for (final depth in _pipelineDepths)
      'pipeline-one-channel-depth-$depth-$link',
    for (final depth in _pipelineReaddirDepths) 'pipeline-readdir-$depth-$link',
    for (final channels in _pipelineChannelCounts)
      'pipeline-$channels-channels-one-transport-$link',
    for (final transports in _pipelineTransportCounts)
      'pipeline-$transports-transports-$link',
  ],
  ..._isolateScenarios,
]);

bool isIsolatedThroughputScenario(String scenario) =>
    scenario.endsWith('-1gb-rtt100');

final List<String> isolatedSourceScenarios = List.unmodifiable(
  m0ScenarioManifest.where(isIsolatedThroughputScenario),
);

final List<String> standardSourceScenarios = List.unmodifiable(
  m0ScenarioManifest.where(
    (scenario) => !isIsolatedThroughputScenario(scenario),
  ),
);

final List<ThroughputCellSpec> affordableThroughputCells = List.unmodifiable([
  for (final link in _linkProfiles)
    for (final payload in _throughputPayloads)
      for (final direction in M0ThroughputDirection.values)
        if (!(link == 'rtt100' && payload == '1gb'))
          ThroughputCellSpec(
            link: link,
            payload: payload,
            direction: direction,
          ),
]);

final List<ThroughputTrialSpec> standardThroughputTrialSpecs =
    List.unmodifiable([
      for (final cell in affordableThroughputCells)
        for (var index = 0; index < _abccbaVariants.length; index++)
          ThroughputTrialSpec(
            cell: cell,
            variant: _abccbaVariants[index],
            replicate: _abccbaReplicates[index],
            ordinal: index + 1,
          ),
    ]);

final List<M0SourceSpec> isolatedSourceSpecs = List.unmodifiable([
  for (final direction in M0ThroughputDirection.values)
    for (final variant in M0ThroughputVariant.values)
      for (final replicate in [1, 2])
        M0SourceSpec(
          id: 'rtt100-1gb-${direction.label}-${variant.label}-r$replicate',
          kind: M0SourceKind.isolated,
          scenarios: ['${variant.label}-${direction.label}-1gb-rtt100'],
          replicate: replicate,
        ),
]);

final List<M0SourceSpec> m0SourceManifest = List.unmodifiable([
  M0SourceSpec(
    id: standardSourceId,
    kind: M0SourceKind.standard,
    scenarios: standardSourceScenarios,
    replicate: null,
  ),
  ...isolatedSourceSpecs,
]);

M0SourceSpec? sourceSpecForId(String id) {
  for (final source in m0SourceManifest) {
    if (source.id == id) return source;
  }

  return null;
}

int expectedBytesForScenario(String scenario) {
  final throughput = RegExp(
    r'^(?:dart-hash-on|dart-hash-off|openssh)-(?:download|upload)-(1mb|100mb|1gb)-(?:lan|rtt100)$',
  ).firstMatch(scenario);
  if (throughput != null) {
    return switch (throughput.group(1)) {
      '1mb' => fixturePayloadOneMegabyteBytes,
      '100mb' => fixturePayloadOneHundredMegabytesBytes,
      '1gb' => fixturePayloadOneGigabyteBytes,
      _ => throw StateError('Unknown payload in $scenario'),
    };
  }
  if (scenario.startsWith('algorithm-') ||
      scenario.startsWith('pipeline-readdir-') ||
      scenario == 'isolate-cancellation' ||
      scenario == 'isolate-progress-flood') {
    return 0;
  }
  if (scenario.startsWith('pipeline-one-channel-depth-')) {
    return fixturePayloadOneMegabyteBytes;
  }
  final channelCount = RegExp(
    r'^pipeline-(\d+)-channels-one-transport-',
  ).firstMatch(scenario);
  if (channelCount != null) {
    return int.parse(channelCount.group(1)!) * fixturePayloadOneMegabyteBytes;
  }
  final transportCount = RegExp(
    r'^pipeline-(\d+)-transports-',
  ).firstMatch(scenario);
  if (transportCount != null) {
    return int.parse(transportCount.group(1)!) * fixturePayloadOneMegabyteBytes;
  }
  if (scenario == 'isolate-root-baseline' ||
      scenario == 'isolate-single-transfer') {
    return fixturePayloadOneHundredMegabytesBytes;
  }
  if (scenario == 'isolate-four-transfers-listing') {
    return 4 * fixturePayloadOneHundredMegabytesBytes;
  }

  throw ArgumentError.value(scenario, 'scenario', 'Not in the M0 manifest');
}
