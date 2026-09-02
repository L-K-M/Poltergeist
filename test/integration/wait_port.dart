import 'dart:convert';
import 'dart:io';

enum WaitMode { banner, free }

const _attemptTimeout = Duration(milliseconds: 500);
const _retryDelay = Duration(milliseconds: 200);
const _overallTimeout = Duration(seconds: 30);
const _sshBannerPrefix = 'SSH-';

Future<bool> _hasSshBanner(String host, int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: _attemptTimeout);
    final line = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first
        .timeout(_attemptTimeout);
    return line.startsWith(_sshBannerPrefix);
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}

Future<bool> _isPortFree(String host, int port) async {
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(host, port, shared: false);
    return true;
  } on SocketException {
    return false;
  } finally {
    await socket?.close();
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln('usage: wait_port.dart banner|free HOST PORT');
    exitCode = 2;
    return;
  }

  final mode = WaitMode.values.asNameMap()[arguments[0]];
  final port = int.tryParse(arguments[2]);
  if (mode == null || port == null) {
    stderr.writeln('invalid wait mode or port');
    exitCode = 2;
    return;
  }

  final host = arguments[1];
  final deadline = DateTime.now().add(_overallTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final ready = switch (mode) {
      WaitMode.banner => await _hasSshBanner(host, port),
      WaitMode.free => await _isPortFree(host, port),
    };
    if (ready) {
      return;
    }

    await Future<void>.delayed(_retryDelay);
  }

  stderr.writeln('timed out waiting for $mode at $host:$port');
  exitCode = 1;
}
