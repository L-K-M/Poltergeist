import 'dart:io';

const _sampleCount = 7;
const _connectionTimeout = Duration(seconds: 5);
const _microsecondsPerMillisecond = 1000;

Future<int> _measureHandshake(String host, int port) async {
  final stopwatch = Stopwatch()..start();
  final socket = await Socket.connect(host, port, timeout: _connectionTimeout);
  stopwatch.stop();
  socket.destroy();

  return stopwatch.elapsedMicroseconds;
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('usage: measure_rtt.dart HOST PORT');
    exitCode = 2;
    return;
  }

  final host = arguments[0];
  final port = int.tryParse(arguments[1]);
  if (port == null) {
    stderr.writeln('invalid port');
    exitCode = 2;
    return;
  }

  final samples = <int>[];
  for (var index = 0; index < _sampleCount; index++) {
    samples.add(await _measureHandshake(host, port));
  }
  samples.sort();

  final medianMicroseconds = samples[samples.length ~/ 2];
  final roundedMilliseconds =
      (medianMicroseconds + _microsecondsPerMillisecond ~/ 2) ~/
      _microsecondsPerMillisecond;
  stdout.writeln(roundedMilliseconds);
}
