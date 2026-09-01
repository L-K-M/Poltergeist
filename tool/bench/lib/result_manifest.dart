const _throughputVariants = ['dart-hash-on', 'dart-hash-off', 'openssh'];
const _throughputDirections = ['download', 'upload'];
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
const _slowScenarioSet = {
  'dart-hash-on-upload-1gb-rtt100',
  'dart-hash-off-upload-1gb-rtt100',
  'openssh-upload-1gb-rtt100',
};
const standardShardScenarioCount = 75;
const slowShardScenarioCount = 3;
const m0ScenarioCount = 78;

/// One ordering controls shard assignment, validation, and report input.
final List<String> m0ScenarioManifest = List.unmodifiable([
  for (final link in _linkProfiles)
    for (final payload in _throughputPayloads)
      for (final direction in _throughputDirections)
        for (final variant in _throughputVariants)
          '$variant-$direction-$payload-$link',
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

/// The standard shard contains every scenario except shaped 1 GB uploads.
final List<String> standardShardScenarios = List.unmodifiable(
  m0ScenarioManifest.where((scenario) => !_slowScenarioSet.contains(scenario)),
);

/// These uploads are isolated because their sequential writes dominate CI.
final List<String> slowShardScenarios = List.unmodifiable(
  m0ScenarioManifest.where(_slowScenarioSet.contains),
);
