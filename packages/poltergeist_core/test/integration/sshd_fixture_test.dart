@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _umbrellaVariable = 'POLTERGEIST_SSHD';
const _modernPortVariable = 'POLTERGEIST_SSHD_MODERN';
const _sshBannerPrefix = 'SSH-';
const _connectionTimeout = Duration(seconds: 5);

void main() {
  final host = Platform.environment[_umbrellaVariable];
  final portText = Platform.environment[_modernPortVariable];
  final enabled = host != null && portText != null;

  test(
    'modern fixture completes an SSH banner exchange',
    () async {
      final port = int.parse(portText!);
      final socket = await Socket.connect(
        host!,
        port,
        timeout: _connectionTimeout,
      );
      addTearDown(socket.destroy);

      final banner = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(_connectionTimeout);

      expect(banner, startsWith(_sshBannerPrefix));
    },
    skip: enabled
        ? false
        : 'Set $_umbrellaVariable and $_modernPortVariable to enable.',
  );
}
