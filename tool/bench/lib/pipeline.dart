import 'config.dart';
import 'fixture_data.dart';
import 'harness.dart';
import 'ssh_driver.dart';

const _singleChannelReadCounts = [8, 16, 32];
const _channelCounts = [1, 2, 4, 8];
const _transportCounts = [1, 2, 4];
const _readdirConcurrency = 8;
const _entriesPerFixtureDirectory = 100;
const _trialNote =
    'samples=2; aggregate=median; warmed=true; order=forward-reverse';
const pipelinePayloadSha256 = fixturePayload1MbSha256;

/// The narrow connection surface needed by channel-scaling trials.
abstract interface class PipelineChannelConnection {
  Future<ReadBatchResult> readAcrossChannels({
    required String path,
    required int channels,
    required String expectedDigest,
  });

  void close();
}

typedef PipelineChannelConnectionFactory =
    Future<PipelineChannelConnection> Function();

Future<List<BenchResult>> runPipeline(BenchConfig config) async {
  final path = '${config.remoteRoot}/fixtures/payload-1mb.bin';
  final results = <BenchResult>[];

  try {
    // generate-data.sh creates a sparse, zero-filled 1 MB fixture.
    const expectedDigest = pipelinePayloadSha256;
    final depthReads = await _runDepthTrials(
      config: config,
      path: path,
      expectedDigest: expectedDigest,
    );
    for (var index = 0; index < _singleChannelReadCounts.length; index++) {
      final pendingRequests = _singleChannelReadCounts[index];
      final read = depthReads[index];
      results.add(
        _readResult(
          config,
          'pipeline-one-channel-depth-$pendingRequests-${config.linkName}',
          read,
        ),
      );
    }

    final directories = List.generate(
      _readdirConcurrency,
      (index) =>
          '${config.remoteRoot}/fixtures/readdir-${index.toString().padLeft(2, '0')}',
    );
    final expectedEntries = _readdirConcurrency * _entriesPerFixtureDirectory;
    final listings = await _runListingTrials(
      config: config,
      directories: directories,
      expectedEntries: expectedEntries,
    );
    final sequential = listings.first;
    results.add(_listingResult(config, 1, sequential));

    final concurrent = listings.last;
    results.add(_listingResult(config, _readdirConcurrency, concurrent));

    final channelReads = await runChannelTrials(
      channelCounts: _channelCounts,
      path: path,
      expectedDigest: expectedDigest,
      openConnection: () async => _SshPipelineChannelConnection(
        await openBenchConnection(config.endpoint),
      ),
    );
    for (var index = 0; index < _channelCounts.length; index++) {
      final channels = _channelCounts[index];
      final read = channelReads[index];
      results.add(
        _readResult(
          config,
          'pipeline-$channels-channels-one-transport-${config.linkName}',
          read,
        ),
      );
    }

    final transportReads = await _runTransportTrials(
      config: config,
      path: path,
      expectedDigest: expectedDigest,
    );
    for (var index = 0; index < _transportCounts.length; index++) {
      final transports = _transportCounts[index];
      final read = transportReads[index];
      results.add(
        _readResult(
          config,
          'pipeline-$transports-transports-${config.linkName}',
          read,
        ),
      );
    }
  } on BenchRunFailure {
    rethrow;
  } on Object catch (error) {
    throw BenchRunFailure(
      'pipeline ${config.linkName} failed: ${error.runtimeType}: $error',
      List<BenchResult>.unmodifiable(results),
    );
  }

  return results;
}

Future<List<ReadBatchResult>> runChannelTrials({
  required Iterable<int> channelCounts,
  required String path,
  required String expectedDigest,
  required PipelineChannelConnectionFactory openConnection,
}) async {
  final reads = <ReadBatchResult>[];
  final counts = channelCounts.toList(growable: false);
  final samples = {for (final count in counts) count: <ReadBatchResult>[]};
  for (final channels in counts) {
    await _readChannelTrial(
      channels: channels,
      path: path,
      expectedDigest: expectedDigest,
      openConnection: openConnection,
    );
  }
  for (final channels in _mirrored(counts)) {
    samples[channels]!.add(
      await _readChannelTrial(
        channels: channels,
        path: path,
        expectedDigest: expectedDigest,
        openConnection: openConnection,
      ),
    );
  }
  for (final count in counts) {
    reads.add(_medianRead(samples[count]!));
  }
  return reads;
}

Future<ReadBatchResult> _readChannelTrial({
  required int channels,
  required String path,
  required String expectedDigest,
  required PipelineChannelConnectionFactory openConnection,
}) async {
  // Each count gets a transport so closed sessions cannot leak into N+1.
  final connection = await openConnection();
  try {
    return await connection.readAcrossChannels(
      path: path,
      channels: channels,
      expectedDigest: expectedDigest,
    );
  } finally {
    connection.close();
  }
}

class _SshPipelineChannelConnection implements PipelineChannelConnection {
  final BenchSshConnection _connection;

  const _SshPipelineChannelConnection(this._connection);

  @override
  Future<ReadBatchResult> readAcrossChannels({
    required String path,
    required int channels,
    required String expectedDigest,
  }) => _connection.readAcrossChannels(
    path: path,
    channels: channels,
    expectedDigest: expectedDigest,
  );

  @override
  void close() => _connection.close();
}

BenchResult _readResult(
  BenchConfig config,
  String scenario,
  ReadBatchResult read,
) => BenchResult.capture(
  scenario: scenario,
  bytes: read.bytes,
  elapsed: read.elapsed,
  note: 'sha256=${read.digest}; $_trialNote',
  rttMs: config.measuredRttMs,
);

BenchResult _listingResult(
  BenchConfig config,
  int depth,
  DirectoryBatchResult listing,
) {
  final entriesPerSecond =
      listing.entries *
      Duration.microsecondsPerSecond /
      listing.elapsed.inMicroseconds;
  return BenchResult.capture(
    scenario: 'pipeline-readdir-$depth-${config.linkName}',
    bytes: 0,
    elapsed: listing.elapsed,
    note:
        'entries=${listing.entries}; '
        'entriesPerSecond=${entriesPerSecond.toStringAsFixed(1)}; '
        '$_trialNote',
    rttMs: config.measuredRttMs,
  );
}

Future<List<ReadBatchResult>> _runDepthTrials({
  required BenchConfig config,
  required String path,
  required String expectedDigest,
}) async {
  final samples = {
    for (final depth in _singleChannelReadCounts) depth: <ReadBatchResult>[],
  };
  for (final depth in _singleChannelReadCounts) {
    await _readDepthTrial(
      config: config,
      path: path,
      depth: depth,
      expectedDigest: expectedDigest,
    );
  }
  for (final depth in _mirrored(_singleChannelReadCounts)) {
    samples[depth]!.add(
      await _readDepthTrial(
        config: config,
        path: path,
        depth: depth,
        expectedDigest: expectedDigest,
      ),
    );
  }
  return [
    for (final depth in _singleChannelReadCounts) _medianRead(samples[depth]!),
  ];
}

Future<ReadBatchResult> _readDepthTrial({
  required BenchConfig config,
  required String path,
  required int depth,
  required String expectedDigest,
}) async {
  final connection = await openBenchConnection(config.endpoint);
  try {
    return await connection.readWithPendingDepth(
      path: path,
      pendingRequests: depth,
      expectedDigest: expectedDigest,
    );
  } finally {
    connection.close();
  }
}

enum _ListingTrial { sequential, concurrent }

Future<List<DirectoryBatchResult>> _runListingTrials({
  required BenchConfig config,
  required List<String> directories,
  required int expectedEntries,
}) async {
  const order = [
    _ListingTrial.sequential,
    _ListingTrial.concurrent,
    _ListingTrial.concurrent,
    _ListingTrial.sequential,
  ];
  final samples = {
    for (final trial in _ListingTrial.values) trial: <DirectoryBatchResult>[],
  };
  for (final trial in _ListingTrial.values) {
    await _readListingTrial(
      config: config,
      directories: directories,
      expectedEntries: expectedEntries,
      trial: trial,
    );
  }
  for (final trial in order) {
    samples[trial]!.add(
      await _readListingTrial(
        config: config,
        directories: directories,
        expectedEntries: expectedEntries,
        trial: trial,
      ),
    );
  }
  return [
    _medianListing(samples[_ListingTrial.sequential]!),
    _medianListing(samples[_ListingTrial.concurrent]!),
  ];
}

Future<DirectoryBatchResult> _readListingTrial({
  required BenchConfig config,
  required List<String> directories,
  required int expectedEntries,
  required _ListingTrial trial,
}) async {
  final connection = await openBenchConnection(config.endpoint);
  try {
    final listing = trial == _ListingTrial.sequential
        ? await connection.listSequentially(directories)
        : await connection.listConcurrently(directories);
    validateDirectoryListings(
      listing,
      entriesPerDirectory: _entriesPerFixtureDirectory,
    );
    if (listing.entries != expectedEntries) {
      throw StateError(
        '${trial.name} readdir returned ${listing.entries}, '
        'expected $expectedEntries.',
      );
    }
    return listing;
  } finally {
    connection.close();
  }
}

Future<List<ReadBatchResult>> _runTransportTrials({
  required BenchConfig config,
  required String path,
  required String expectedDigest,
}) async {
  final samples = {
    for (final count in _transportCounts) count: <ReadBatchResult>[],
  };
  for (final transports in _transportCounts) {
    await readAcrossTransports(
      endpoint: config.endpoint,
      path: path,
      transports: transports,
      expectedDigest: expectedDigest,
    );
  }
  for (final transports in _mirrored(_transportCounts)) {
    samples[transports]!.add(
      await readAcrossTransports(
        endpoint: config.endpoint,
        path: path,
        transports: transports,
        expectedDigest: expectedDigest,
      ),
    );
  }
  return [for (final count in _transportCounts) _medianRead(samples[count]!)];
}

Iterable<int> _mirrored(List<int> values) sync* {
  yield* values;
  yield* values.reversed;
}

ReadBatchResult _medianRead(List<ReadBatchResult> samples) => ReadBatchResult(
  bytes: samples.first.bytes,
  elapsed: _medianDuration(samples.map((sample) => sample.elapsed)),
  digest: samples.first.digest,
);

DirectoryBatchResult _medianListing(List<DirectoryBatchResult> samples) =>
    DirectoryBatchResult(
      entriesByPath: samples.first.entriesByPath,
      elapsed: _medianDuration(samples.map((sample) => sample.elapsed)),
    );

Duration _medianDuration(Iterable<Duration> samples) {
  final ordered = samples.toList()..sort();
  final middle = ordered.length ~/ 2;
  if (ordered.length.isOdd) return ordered[middle];

  return Duration(
    microseconds:
        (ordered[middle - 1].inMicroseconds + ordered[middle].inMicroseconds) ~/
        2,
  );
}

void validateDirectoryListings(
  DirectoryBatchResult listing, {
  required int entriesPerDirectory,
}) {
  for (final response in listing.entriesByPath.entries) {
    final components = response.key.split('/').where((part) => part.isNotEmpty);
    final directory = components.last;
    final expected = {
      for (var index = 0; index < entriesPerDirectory; index++)
        '$directory-entry-${index.toString().padLeft(3, '0')}.txt',
    };
    final actual = response.value.toSet();
    if (response.value.length == expected.length &&
        actual.length == expected.length &&
        actual.containsAll(expected)) {
      continue;
    }

    throw StateError('$directory returned mismatched directory entries.');
  }
}
