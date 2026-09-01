import 'dart:io';

import 'throughput_attempt.dart';

const defaultSshHost = '127.0.0.1';
const defaultSshPort = 2201;
const defaultSshUser = 'poltergeist';
const defaultSshPassword = 'poltergeist-test-only';
const defaultRemoteRoot = '/home/poltergeist/bench';

class BenchEndpoint {
  final String host;
  final int port;
  final String username;
  final String password;

  const BenchEndpoint({
    this.host = defaultSshHost,
    this.port = defaultSshPort,
    this.username = defaultSshUser,
    this.password = defaultSshPassword,
  });

  factory BenchEndpoint.fromJson(Map<String, Object?> json) => BenchEndpoint(
    host: json['host']! as String,
    port: json['port']! as int,
    username: json['username']! as String,
    password: json['password']! as String,
  );

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password,
  };
}

class BenchConfig {
  final BenchEndpoint endpoint;
  final String remoteRoot;
  final String identityFile;
  final String outputFile;
  final String linkName;
  final String fixtureRoot;
  final String uploadRoot;
  final RttEvidence? rttEvidence;
  final DateTime? deadlineStartedAtUtc;
  final Duration? deadlineStartedAtMonotonic;

  const BenchConfig({
    required this.endpoint,
    required this.remoteRoot,
    required this.identityFile,
    required this.outputFile,
    required this.linkName,
    required this.fixtureRoot,
    required this.uploadRoot,
    required this.rttEvidence,
    this.deadlineStartedAtUtc,
    this.deadlineStartedAtMonotonic,
  });

  int? get measuredRttMs => rttEvidence?.medianMs;

  factory BenchConfig.defaults({
    String linkName = 'lan',
    RttEvidence? rttEvidence,
  }) {
    final repositoryRoot = _findRepositoryRoot(Directory.current);

    return BenchConfig(
      endpoint: const BenchEndpoint(),
      remoteRoot: defaultRemoteRoot,
      identityFile:
          '${repositoryRoot.path}/test/integration/runtime/id_ed25519',
      outputFile: '${repositoryRoot.path}/tool/bench/bench-results.json',
      linkName: linkName,
      fixtureRoot: '${repositoryRoot.path}/test/integration/runtime/data',
      uploadRoot: '${repositoryRoot.path}/test/integration/runtime/uploads',
      rttEvidence: rttEvidence,
    );
  }
}

Directory _findRepositoryRoot(Directory start) {
  var current = start.absolute;
  while (true) {
    if (File('${current.path}/docs/IMPLEMENTOR.md').existsSync()) {
      return current;
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not find the Poltergeist repository root.');
    }
    current = parent;
  }
}
