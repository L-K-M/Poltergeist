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
typedef SshExchangeMeasurement =
    Future<Duration> Function(String host, int port);
typedef UtcNow = DateTime Function();

enum RttOutputFormat { medianMs, json }

class SshRttEvidence {
  final List<int> samplesUs;
  final Duration median;
  final DateTime capturedAtUtc;

  SshRttEvidence({
    required List<int> samplesUs,
    required this.median,
    required DateTime capturedAtUtc,
  }) : samplesUs = List.unmodifiable(samplesUs),
       capturedAtUtc = capturedAtUtc.toUtc();

  int get medianMs => roundRttMilliseconds(median);

  Map<String, Object> toJson() => {
    'samplesUs': samplesUs,
    'medianMs': medianMs,
    'capturedAtUtc': capturedAtUtc.toIso8601String(),
  };
}

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

/// Captures independent SSH identification-to-KEX timings in probe order.
Future<SshRttEvidence> measureSshRtt(
  String host,
  int port, {
  SshExchangeMeasurement measureExchange = _measureSshExchange,
  UtcNow utcNow = _utcNow,
}) async {
  final capturedAtUtc = utcNow().toUtc();
  final samples = <Duration>[];
  for (var index = 0; index < _sampleCount; index++) {
    final sample = await measureExchange(host, port);
    if (sample <= Duration.zero) {
      throw StateError('SSH RTT samples must be positive');
    }

    samples.add(sample);
  }

  return SshRttEvidence(
    samplesUs: [for (final sample in samples) sample.inMicroseconds],
    median: medianRtt(samples),
    capturedAtUtc: capturedAtUtc,
  );
}

/// Returns the middle sample, or the floored midpoint for an even sample set.
Duration medianRtt(Iterable<Duration> samples) {
  final ordered = samples.toList();
  if (ordered.isEmpty) throw ArgumentError.value(samples, 'samples', 'empty');
  if (ordered.any((sample) => sample <= Duration.zero)) {
    throw ArgumentError.value(samples, 'samples', 'must be positive');
  }

  ordered.sort();
  final upperIndex = ordered.length ~/ 2;
  if (ordered.length.isOdd) return ordered[upperIndex];

  final lowerUs = ordered[upperIndex - 1].inMicroseconds;
  final upperUs = ordered[upperIndex].inMicroseconds;
  return Duration(microseconds: lowerUs + (upperUs - lowerUs) ~/ 2);
}

int roundRttMilliseconds(Duration duration) {
  final microseconds = duration.inMicroseconds;
  if (microseconds <= 0) {
    throw ArgumentError.value(duration, 'duration', 'must be positive');
  }

  return (microseconds + _microsecondsPerMillisecond ~/ 2) ~/
      _microsecondsPerMillisecond;
}

String formatRttEvidence(SshRttEvidence evidence, RttOutputFormat format) =>
    switch (format) {
      RttOutputFormat.medianMs => '${evidence.medianMs}',
      RttOutputFormat.json => jsonEncode(evidence.toJson()),
    };

Future<void> main(List<String> arguments) async {
  var format = RttOutputFormat.medianMs;
  var operands = arguments;
  if (arguments.isNotEmpty && arguments.first == '--json') {
    format = RttOutputFormat.json;
    operands = arguments.sublist(1);
  }

  if (operands.length != 2) {
    stderr.writeln('usage: measure_rtt.dart [--json] HOST PORT');
    exitCode = 2;
    return;
  }

  final host = operands[0];
  final port = int.tryParse(operands[1]);
  if (port == null) {
    stderr.writeln('invalid port');
    exitCode = 2;
    return;
  }

  final evidence = await measureSshRtt(host, port);
  stdout.writeln(formatRttEvidence(evidence, format));
}

Future<Duration> _measureSshExchange(String host, int port) =>
    measureSshExchange(host, port);

DateTime _utcNow() => DateTime.now().toUtc();

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
