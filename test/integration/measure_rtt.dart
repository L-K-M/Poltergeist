import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _sampleCount = 7;
const _connectionTimeout = Duration(seconds: 5);
const _exchangeTimeout = Duration(seconds: 5);
const _microsecondsPerMillisecond = 1000;
const _sshPacketHeaderBytes = 5;
const _maximumIdentificationBytes = 8192;
const _clientIdentification = 'SSH-2.0-Poltergeist_M0\r\n';

abstract interface class SshRttProbe {
  Future<void> readServerIdentification();

  Future<void> sendClientIdentification();

  Future<void> readServerKexHeader();

  Future<void> close();
}

typedef SshRttProbeFactory =
    Future<SshRttProbe> Function(String host, int port);
typedef MonotonicNow = Duration Function();

/// Times a request/response that must traverse sshd and in-container netem.
Future<Duration> measureSshExchange(
  String host,
  int port, {
  SshRttProbeFactory connect = _SocketSshRttProbe.connect,
  MonotonicNow? now,
}) async {
  final probe = await connect(host, port);
  try {
    await probe.readServerIdentification();

    final stopwatch = Stopwatch()..start();
    final readClock = now ?? () => stopwatch.elapsed;
    final startedAt = readClock();
    await probe.sendClientIdentification();
    await probe.readServerKexHeader();
    return readClock() - startedAt;
  } finally {
    await probe.close();
  }
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

  final samples = <Duration>[];
  for (var index = 0; index < _sampleCount; index++) {
    samples.add(await measureSshExchange(host, port));
  }
  samples.sort();

  final medianMicroseconds = samples[samples.length ~/ 2].inMicroseconds;
  final roundedMilliseconds =
      (medianMicroseconds + _microsecondsPerMillisecond ~/ 2) ~/
      _microsecondsPerMillisecond;
  stdout.writeln(roundedMilliseconds);
}

class _SocketSshRttProbe implements SshRttProbe {
  final Socket _socket;
  final StreamIterator<List<int>> _chunks;
  final List<int> _buffer = [];
  var _identificationBytes = 0;

  _SocketSshRttProbe._(this._socket) : _chunks = StreamIterator(_socket);

  static Future<SshRttProbe> connect(String host, int port) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: _connectionTimeout,
    );
    return _SocketSshRttProbe._(socket);
  }

  @override
  Future<void> readServerIdentification() async {
    while (true) {
      final line = await _readLine();
      if (!line.startsWith('SSH-')) continue;
      if (line.startsWith('SSH-2.0-') || line.startsWith('SSH-1.99-')) return;

      throw StateError('unsupported SSH identification: $line');
    }
  }

  @override
  Future<void> sendClientIdentification() async {
    if (_buffer.isNotEmpty) {
      throw StateError('server sent SSH packets before version exchange');
    }

    _socket.add(utf8.encode(_clientIdentification));
    await _socket.flush().timeout(_exchangeTimeout);
  }

  @override
  Future<void> readServerKexHeader() async {
    while (_buffer.length < _sshPacketHeaderBytes) {
      await _readChunk();
    }
  }

  @override
  Future<void> close() async {
    _socket.destroy();
    await _chunks.cancel();
  }

  Future<String> _readLine() async {
    while (true) {
      final newline = _buffer.indexOf(10);
      if (newline >= 0) {
        final lineBytes = _buffer.sublist(0, newline);
        _buffer.removeRange(0, newline + 1);
        if (lineBytes.isNotEmpty && lineBytes.last == 13) {
          lineBytes.removeLast();
        }
        return ascii.decode(lineBytes, allowInvalid: false);
      }

      await _readChunk();
      if (_identificationBytes > _maximumIdentificationBytes) {
        throw StateError(
          'SSH identification exceeded $_maximumIdentificationBytes bytes',
        );
      }
    }
  }

  Future<void> _readChunk() async {
    final hasChunk = await _chunks.moveNext().timeout(_exchangeTimeout);
    if (!hasChunk) throw StateError('SSH server closed during RTT probe');

    _buffer.addAll(_chunks.current);
    _identificationBytes += _chunks.current.length;
  }
}
