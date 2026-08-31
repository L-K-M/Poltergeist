import 'config.dart';
import 'harness.dart';
import 'ssh_driver.dart';

const _singleChannelReadCounts = [8, 16, 32];
const _channelCounts = [1, 2, 4, 8];
const _transportCounts = [1, 2, 4];
const _readdirConcurrency = 8;
const _entriesPerFixtureDirectory = 100;

Future<List<BenchResult>> runPipeline(BenchConfig config) async {
  final path = '${config.remoteRoot}/fixtures/payload-1mb.bin';
  final connection = await openBenchConnection(config.endpoint);
  final results = <BenchResult>[];

  try {
    final expectedDigest = await connection.digest(path);
    for (final pendingRequests in _singleChannelReadCounts) {
      final read = await connection.readWithPendingDepth(
        path: path,
        pendingRequests: pendingRequests,
        expectedDigest: expectedDigest,
      );
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
    final sequential = await connection.listSequentially(directories);
    _verifyListing(sequential, expectedEntries, 'Sequential');
    results.add(_listingResult(config, 1, sequential));

    final concurrent = await connection.listConcurrently(directories);
    _verifyListing(concurrent, expectedEntries, 'Concurrent');
    results.add(_listingResult(config, _readdirConcurrency, concurrent));

    for (final channels in _channelCounts) {
      final read = await connection.readAcrossChannels(
        path: path,
        channels: channels,
        expectedDigest: expectedDigest,
      );
      results.add(
        _readResult(
          config,
          'pipeline-$channels-channels-one-transport-${config.linkName}',
          read,
        ),
      );
    }

    for (final transports in _transportCounts) {
      final read = await readAcrossTransports(
        endpoint: config.endpoint,
        path: path,
        transports: transports,
        expectedDigest: expectedDigest,
      );
      results.add(
        _readResult(
          config,
          'pipeline-$transports-transports-${config.linkName}',
          read,
        ),
      );
    }
  } finally {
    connection.close();
  }

  return results;
}

BenchResult _readResult(
  BenchConfig config,
  String scenario,
  ReadBatchResult read,
) => BenchResult.capture(
  scenario: scenario,
  bytes: read.bytes,
  elapsed: read.elapsed,
  note: 'sha256=${read.digest}',
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
        'entriesPerSecond=${entriesPerSecond.toStringAsFixed(1)}',
    rttMs: config.measuredRttMs,
  );
}

void _verifyListing(
  DirectoryBatchResult listing,
  int expectedEntries,
  String label,
) {
  if (listing.entries == expectedEntries) return;

  throw StateError(
    '$label readdir returned ${listing.entries}, expected $expectedEntries.',
  );
}
