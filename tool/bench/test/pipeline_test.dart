import 'package:poltergeist_m0_bench/pipeline.dart';
import 'package:poltergeist_m0_bench/ssh_driver.dart';
import 'package:test/test.dart';

const _defaultMaxTransports = 2;
const _defaultTransferChannelsPerTransport = 3;
const _defaultMaxChannelsPerTransport = 8;

void main() {
  test('measurement matrix covers every provisional pool default', () {
    expect(
      pipelineChannelCounts,
      containsAll([
        _defaultTransferChannelsPerTransport,
        _defaultMaxChannelsPerTransport,
      ]),
    );
    expect(pipelineTransportCounts, contains(_defaultMaxTransports));
  });

  test('each channel trial owns and closes a fresh transport', () async {
    final connections = <_FakeChannelConnection>[];

    final results = await runChannelTrials(
      channelCounts: const [1, 2, 4, 8],
      path: '/fixtures/payload-1mb.bin',
      expectedDigest: pipelinePayloadSha256,
      openConnection: () async {
        final connection = _FakeChannelConnection();
        connections.add(connection);
        return connection;
      },
    );

    expect(connections, hasLength(12));
    expect(connections.toSet(), hasLength(12));
    expect(connections.every((connection) => connection.closed), isTrue);
    expect(connections.expand((connection) => connection.channelCounts), [
      1,
      2,
      4,
      8,
      1,
      2,
      4,
      8,
      8,
      4,
      2,
      1,
    ]);
    expect(
      connections.expand((connection) => connection.expectedDigests),
      everyElement(pipelinePayloadSha256),
    );
    expect(results, hasLength(4));
  });

  test('rejects swapped or duplicated concurrent directory replies', () {
    final swapped = DirectoryBatchResult(
      entriesByPath: const {
        '/fixtures/readdir-00': ['readdir-01-entry-000.txt'],
        '/fixtures/readdir-01': ['readdir-00-entry-000.txt'],
      },
      elapsed: Duration.zero,
    );
    final duplicated = DirectoryBatchResult(
      entriesByPath: const {
        '/fixtures/readdir-00': ['readdir-00-entry-000.txt'],
        '/fixtures/readdir-01': ['readdir-00-entry-000.txt'],
      },
      elapsed: Duration.zero,
    );

    expect(
      () => validateDirectoryListings(swapped, entriesPerDirectory: 1),
      throwsStateError,
    );
    expect(
      () => validateDirectoryListings(duplicated, entriesPerDirectory: 1),
      throwsStateError,
    );
  });
}

class _FakeChannelConnection implements PipelineChannelConnection {
  final List<int> channelCounts = [];
  final List<String> expectedDigests = [];
  bool closed = false;

  @override
  Future<ReadBatchResult> readAcrossChannels({
    required String path,
    required int channels,
    required String expectedDigest,
  }) async {
    channelCounts.add(channels);
    expectedDigests.add(expectedDigest);
    return ReadBatchResult(
      bytes: channels,
      elapsed: const Duration(microseconds: 1),
      digest: expectedDigest,
    );
  }

  @override
  void close() {
    closed = true;
  }
}
