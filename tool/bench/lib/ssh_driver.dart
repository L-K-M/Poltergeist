import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:seance_core/src/ssh/remote_file_system.dart';

import 'config.dart';

const sshConnectTimeout = Duration(seconds: 15);

class ReadBatchResult {
  final int bytes;
  final Duration elapsed;
  final String digest;

  const ReadBatchResult({
    required this.bytes,
    required this.elapsed,
    required this.digest,
  });
}

class DirectoryBatchResult {
  final int entries;
  final Duration elapsed;

  const DirectoryBatchResult({required this.entries, required this.elapsed});
}

class CombinedWorkloadResult {
  final int bytes;
  final int entries;
  final Duration elapsed;

  const CombinedWorkloadResult({
    required this.bytes,
    required this.entries,
    required this.elapsed,
  });
}

enum DigestMode { enabled, disabled }

typedef WorkloadProgress = void Function(int item, int transferred, int total);

enum AlgorithmAuditOutcome { connected, failed }

class AlgorithmAuditResult {
  final AlgorithmAuditOutcome outcome;
  final Duration elapsed;
  final String detail;

  const AlgorithmAuditResult({
    required this.outcome,
    required this.elapsed,
    required this.detail,
  });
}

class BenchSshConnection {
  final SSHClient _client;
  final SftpClient _primarySftp;

  BenchSshConnection._(this._client, this._primarySftp);

  RemoteFileSystem get remoteFileSystem =>
      DartSshRemoteFileSystem(_primarySftp);

  Future<ReadBatchResult> download({
    required String path,
    DigestMode digestMode = DigestMode.enabled,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  }) async {
    final sink = File('/dev/null').openWrite();
    try {
      final stopwatch = Stopwatch()..start();
      final entry = await remoteFileSystem.download(
        path,
        sink,
        computeHash: digestMode == DigestMode.enabled,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      stopwatch.stop();

      final length = entry.size;
      if (length == null) {
        throw StateError('The server did not report a size for $path.');
      }
      return ReadBatchResult(
        bytes: length,
        elapsed: stopwatch.elapsed,
        digest: entry.contentSha256 ?? 'disabled',
      );
    } finally {
      await sink.close();
    }
  }

  Future<String> digest(String path) async {
    final file = await _primarySftp.open(path);
    try {
      return (await sha256.bind(file.read()).first).toString();
    } finally {
      await file.close();
    }
  }

  Future<ReadBatchResult> readWithPendingDepth({
    required String path,
    required int pendingRequests,
    required String expectedDigest,
  }) async {
    final file = await _primarySftp.open(path);
    try {
      final attrs = await file.stat();
      final length = attrs.size;
      if (length == null) {
        throw StateError('The server did not report a size for $path.');
      }

      final stopwatch = Stopwatch()..start();
      final chunks = await file
          .read(length: length, maxPendingRequests: pendingRequests)
          .toList();
      stopwatch.stop();

      final bytes = BytesBuilder(copy: false);
      for (final chunk in chunks) {
        bytes.add(chunk);
      }
      final digest = sha256.convert(bytes.takeBytes());
      _verifyDigests([digest], expectedDigest);

      return ReadBatchResult(
        bytes: length,
        elapsed: stopwatch.elapsed,
        digest: expectedDigest,
      );
    } finally {
      await file.close();
    }
  }

  Future<ReadBatchResult> readAcrossChannels({
    required String path,
    required int channels,
    required String expectedDigest,
  }) async {
    final clients = <SftpClient>[_primarySftp];
    for (var index = 1; index < channels; index++) {
      final client = await _client.sftp();
      await client.handshake;
      clients.add(client);
    }

    try {
      final files = await Future.wait(
        clients.map((client) => client.open(path)),
      );
      try {
        final attrs = await files.first.stat();
        final length = attrs.size;
        if (length == null) {
          throw StateError('The server did not report a size for $path.');
        }

        final stopwatch = Stopwatch()..start();
        final digests = await Future.wait(
          files.map((file) => sha256.bind(file.read(length: length)).first),
        );
        stopwatch.stop();

        _verifyDigests(digests, expectedDigest);
        return ReadBatchResult(
          bytes: length * channels,
          elapsed: stopwatch.elapsed,
          digest: expectedDigest,
        );
      } finally {
        await Future.wait(files.map((file) => file.close()));
      }
    } finally {
      for (final client in clients.skip(1)) {
        client.close();
      }
    }
  }

  Future<DirectoryBatchResult> listConcurrently(List<String> paths) async {
    final stopwatch = Stopwatch()..start();
    final results = await Future.wait(paths.map(_primarySftp.listdir));
    stopwatch.stop();

    final entries = results.fold<int>(
      0,
      (sum, names) =>
          sum +
          names
              .where((name) => name.filename != '.' && name.filename != '..')
              .length,
    );
    return DirectoryBatchResult(entries: entries, elapsed: stopwatch.elapsed);
  }

  Future<DirectoryBatchResult> listSequentially(List<String> paths) async {
    final results = <List<SftpName>>[];
    final stopwatch = Stopwatch()..start();
    for (final path in paths) {
      results.add(await _primarySftp.listdir(path));
    }
    stopwatch.stop();

    final entries = results.fold<int>(
      0,
      (sum, names) =>
          sum +
          names
              .where((name) => name.filename != '.' && name.filename != '..')
              .length,
    );
    return DirectoryBatchResult(entries: entries, elapsed: stopwatch.elapsed);
  }

  Future<CombinedWorkloadResult> runCombinedWorkload({
    required String transferPath,
    required String listingPath,
    required int transfers,
    required int expectedEntries,
    required WorkloadProgress onProgress,
  }) async {
    final expectedDigest = await digest(transferPath);
    final clients = <SftpClient>[];
    for (var index = 0; index < transfers; index++) {
      final client = await _client.sftp();
      await client.handshake;
      clients.add(client);
    }

    try {
      final files = await Future.wait(
        clients.map((client) => client.open(transferPath)),
      );
      try {
        final attrs = await files.first.stat();
        final length = attrs.size;
        if (length == null) {
          throw StateError(
            'The server did not report a size for $transferPath.',
          );
        }

        final stopwatch = Stopwatch()..start();
        final reads = <Future<Digest>>[];
        for (var index = 0; index < files.length; index++) {
          final item = index;
          reads.add(
            sha256
                .bind(
                  files[index].read(
                    length: length,
                    onProgress: (bytes) => onProgress(item, bytes, length),
                  ),
                )
                .first,
          );
        }
        final listing = _primarySftp.listdir(listingPath);
        final completed = await Future.wait(reads);
        final names = await listing;
        stopwatch.stop();

        _verifyDigests(completed, expectedDigest);
        final entries = names
            .where((name) => name.filename != '.' && name.filename != '..')
            .length;
        if (entries != expectedEntries) {
          throw StateError(
            'Combined listing returned $entries, expected $expectedEntries.',
          );
        }

        return CombinedWorkloadResult(
          bytes: length * transfers,
          entries: entries,
          elapsed: stopwatch.elapsed,
        );
      } finally {
        await Future.wait(files.map((file) => file.close()));
      }
    } finally {
      for (final client in clients) {
        client.close();
      }
    }
  }

  void close() {
    _primarySftp.close();
    _client.close();
  }
}

Future<BenchSshConnection> openBenchConnection(
  BenchEndpoint endpoint, {
  List<String>? diagnostics,
}) async {
  final socket = await SSHSocket.connect(
    endpoint.host,
    endpoint.port,
    timeout: sshConnectTimeout,
  );
  final client = SSHClient(
    socket,
    username: endpoint.username,
    onPasswordRequest: () => endpoint.password,
    onVerifyHostKey: (_, _) => true,
    printDebug: diagnostics == null
        ? null
        : (message) => diagnostics.add('$message'),
  );

  try {
    final sftp = await client.sftp().timeout(sshConnectTimeout);
    await sftp.handshake.timeout(sshConnectTimeout);
    return BenchSshConnection._(client, sftp);
  } catch (_) {
    client.close();
    rethrow;
  }
}

Future<ReadBatchResult> readAcrossTransports({
  required BenchEndpoint endpoint,
  required String path,
  required int transports,
  required String expectedDigest,
}) async {
  final connections = await Future.wait(
    List.generate(transports, (_) => openBenchConnection(endpoint)),
  );
  try {
    final files = await Future.wait(
      connections.map((connection) => connection._primarySftp.open(path)),
    );
    try {
      final attrs = await files.first.stat();
      final length = attrs.size;
      if (length == null) {
        throw StateError('The server did not report a size for $path.');
      }

      final stopwatch = Stopwatch()..start();
      final digests = await Future.wait(
        files.map((file) => sha256.bind(file.read(length: length)).first),
      );
      stopwatch.stop();

      _verifyDigests(digests, expectedDigest);
      return ReadBatchResult(
        bytes: length * transports,
        elapsed: stopwatch.elapsed,
        digest: expectedDigest,
      );
    } finally {
      await Future.wait(files.map((file) => file.close()));
    }
  } finally {
    for (final connection in connections) {
      connection.close();
    }
  }
}

Future<AlgorithmAuditResult> auditAlgorithms(BenchEndpoint endpoint) async {
  final diagnostics = <String>[];
  final stopwatch = Stopwatch()..start();
  try {
    final connection = await openBenchConnection(
      endpoint,
      diagnostics: diagnostics,
    );
    stopwatch.stop();
    connection.close();

    final selections = diagnostics.where(_isAlgorithmSelection).join('; ');
    return AlgorithmAuditResult(
      outcome: AlgorithmAuditOutcome.connected,
      elapsed: stopwatch.elapsed,
      detail: selections.isEmpty ? 'connected' : selections,
    );
  } catch (error) {
    stopwatch.stop();
    return AlgorithmAuditResult(
      outcome: AlgorithmAuditOutcome.failed,
      elapsed: stopwatch.elapsed,
      detail: '${error.runtimeType}: $error',
    );
  }
}

void _verifyDigests(Iterable<Digest> digests, String expected) {
  for (final digest in digests) {
    if (digest.toString() == expected) continue;

    throw StateError('Read digest ${digest.toString()} != $expected.');
  }
}

bool _isAlgorithmSelection(String line) =>
    line.contains('SSHTransport._kexType:') ||
    line.contains('SSHTransport._hostkeyType:') ||
    line.contains('SSHTransport._clientCipherType:') ||
    line.contains('SSHTransport._serverCipherType:') ||
    line.contains('SSHTransport._clientMacType:') ||
    line.contains('SSHTransport._serverMacType:');
