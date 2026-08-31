import 'dart:async';
import 'dart:isolate';

import 'package:seance_core/seance_core.dart';

import 'config.dart';
import 'harness.dart';
import 'progress_coalescer.dart';
import 'ssh_driver.dart';

const cancellationLatencyLimit = Duration(milliseconds: 100);
const mainIsolateStallLimit = Duration(milliseconds: 16);
const isolateThroughputParityFloor = 0.8;
const _timerProbeInterval = Duration(milliseconds: 4);
const _engineTimeout = Duration(minutes: 30);
const _isolateTransferCount = 4;
const _listingFixtureEntries = 10_000;
const _syntheticEvents = 20_000;
const _syntheticBatchSize = 200;
const _syntheticBatchPause = Duration(milliseconds: 10);
const _syntheticMinimumEventsPerSecond = 10_000;

enum _EngineCommand {
  singleTransfer,
  startCancellation,
  cancel,
  flood,
  workload,
  shutdown,
}

enum _EngineEvent {
  ready,
  progress,
  singleDone,
  cancelReady,
  cancelDone,
  floodDone,
  workloadDone,
  stopped,
  error,
}

enum _ProgressSource { flood, workload }

Future<List<BenchResult>> runIsolatePoc(BenchConfig config) async {
  final transferPath = '${config.remoteRoot}/fixtures/payload-100mb.bin';
  final cancellationPath = '${config.remoteRoot}/fixtures/payload-1gb.bin';
  final rootConnection = await openBenchConnection(config.endpoint);
  late final ReadBatchResult rootBaseline;
  try {
    rootBaseline = await rootConnection.download(path: transferPath);
  } finally {
    rootConnection.close();
  }

  final peer = await _EnginePeer.spawn(config.endpoint, config.remoteRoot);
  try {
    final isolateTransfer = await peer.runSingleTransfer();
    final cancellation = await peer.measureCancellation(cancellationPath);
    final flood = await peer.runFlood();
    final workload = await peer.runWorkloadWithTimerProbe();

    final rootRate = rootBaseline.bytes / rootBaseline.elapsed.inMicroseconds;
    final isolateRate =
        isolateTransfer.bytes / isolateTransfer.elapsed.inMicroseconds;
    final parity = isolateRate / rootRate;
    final results = [
      BenchResult.capture(
        scenario: 'isolate-root-baseline',
        bytes: rootBaseline.bytes,
        elapsed: rootBaseline.elapsed,
        note: 'sha256=${rootBaseline.digest}',
      ),
      BenchResult.capture(
        scenario: 'isolate-single-transfer',
        bytes: isolateTransfer.bytes,
        elapsed: isolateTransfer.elapsed,
        note: 'rootParity=${parity.toStringAsFixed(3)}',
      ),
      BenchResult.capture(
        scenario: 'isolate-cancellation',
        bytes: 0,
        elapsed: cancellation,
        note: 'limitUs=${cancellationLatencyLimit.inMicroseconds}',
      ),
      BenchResult.capture(
        scenario: 'isolate-progress-flood',
        bytes: 0,
        elapsed: flood.elapsed,
        note:
            'events=$_syntheticEvents; '
            'eventsPerSecond=${flood.eventsPerSecond.toStringAsFixed(2)}; '
            'flushes=${flood.flushes}; '
            'flushesPerSecond=${flood.flushesPerSecond.toStringAsFixed(2)}',
      ),
      BenchResult.capture(
        scenario: 'isolate-four-transfers-listing',
        bytes: workload.bytes,
        elapsed: workload.elapsed,
        note:
            'entries=${workload.entries}; progressFlushes=${workload.progressFlushes}; maxMainStallUs=${workload.maxStall.inMicroseconds}',
      ),
    ];
    final failures = <String>[];
    if (parity < isolateThroughputParityFloor) {
      failures.add(
        'isolate parity ${parity.toStringAsFixed(3)} < '
        '$isolateThroughputParityFloor',
      );
    }
    if (cancellation >= cancellationLatencyLimit) {
      failures.add(
        'cancellation ${cancellation.inMicroseconds}µs >= '
        '${cancellationLatencyLimit.inMicroseconds}µs',
      );
    }
    if (flood.flushesPerSecond > progressFlushesPerSecond) {
      failures.add(
        'progress ${flood.flushesPerSecond.toStringAsFixed(2)}/s > '
        '$progressFlushesPerSecond/s',
      );
    }
    if (flood.eventsPerSecond < _syntheticMinimumEventsPerSecond) {
      failures.add(
        'synthetic load ${flood.eventsPerSecond.toStringAsFixed(2)}/s < '
        '$_syntheticMinimumEventsPerSecond/s',
      );
    }
    if (workload.maxStall > mainIsolateStallLimit) {
      failures.add(
        'main stall ${workload.maxStall.inMicroseconds}µs > '
        '${mainIsolateStallLimit.inMicroseconds}µs',
      );
    }
    if (failures.isNotEmpty) {
      throw BenchRunFailure(failures.join('; '), results);
    }
    return results;
  } finally {
    await peer.close();
  }
}

class _EnginePeer {
  final ReceivePort _receivePort;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;
  final Isolate _isolate;
  final SendPort _commands;
  final Stream<Map<String, Object?>> _events;
  final StreamController<Map<String, Object?>> _controller;
  final List<StreamSubscription<dynamic>> _subscriptions;
  final _EngineTerminal _terminal;

  _EnginePeer._(
    this._receivePort,
    this._errorPort,
    this._exitPort,
    this._isolate,
    this._commands,
    StreamController<Map<String, Object?>> controller,
    this._subscriptions,
    this._terminal,
  ) : _events = controller.stream,
      _controller = controller;

  static Future<_EnginePeer> spawn(
    BenchEndpoint endpoint,
    String remoteRoot,
  ) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final controller = StreamController<Map<String, Object?>>.broadcast(
      sync: true,
    );
    final terminal = _EngineTerminal();
    final subscriptions = <StreamSubscription<dynamic>>[
      receivePort.listen(
        (message) => controller.add((message! as Map).cast<String, Object?>()),
      ),
      errorPort.listen((message) {
        final parts = message is List ? message : [message];
        terminal.publish(
          controller,
          error: parts.isEmpty ? 'unknown isolate error' : '${parts.first}',
          stack: parts.length > 1 ? '${parts[1]}' : '',
        );
      }),
      exitPort.listen((_) {
        terminal.publishExit(controller);
      }),
    ];
    final readyFuture = _nextEvent(
      controller.stream,
      _EngineEvent.ready,
      terminal,
    );
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _engineMain,
        {
          'events': receivePort.sendPort,
          'endpoint': endpoint.toJson(),
          'remoteRoot': remoteRoot,
        },
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
      final ready = await readyFuture;
      return _EnginePeer._(
        receivePort,
        errorPort,
        exitPort,
        isolate,
        ready['commands']! as SendPort,
        controller,
        subscriptions,
        terminal,
      );
    } catch (error, stack) {
      terminal.publish(
        controller,
        error: 'engine isolate spawn failed: $error',
        stack: '$stack',
      );
      try {
        await readyFuture;
      } on Object {
        // Preserve the original spawn failure after draining the ready waiter.
      }
      isolate?.kill();
      terminal.close();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      receivePort.close();
      errorPort.close();
      exitPort.close();
      await controller.close();
      rethrow;
    }
  }

  Future<ReadBatchResult> runSingleTransfer() async {
    final done = _nextEvent(_events, _EngineEvent.singleDone, _terminal);
    _send(_EngineCommand.singleTransfer);
    final event = await done;
    return ReadBatchResult(
      bytes: event['bytes']! as int,
      elapsed: Duration(microseconds: event['elapsedUs']! as int),
      digest: event['digest']! as String,
    );
  }

  Future<Duration> measureCancellation(String path) async {
    final ready = _nextEvent(_events, _EngineEvent.cancelReady, _terminal);
    _send(_EngineCommand.startCancellation, {'path': path});
    await ready;

    final stopwatch = Stopwatch()..start();
    final done = _nextEvent(_events, _EngineEvent.cancelDone, _terminal);
    _send(_EngineCommand.cancel);
    await done;
    stopwatch.stop();
    return stopwatch.elapsed;
  }

  Future<_FloodResult> runFlood() async {
    var flushes = 0;
    final subscription = _events.listen((event) {
      if (event['event'] != _EngineEvent.progress.name ||
          event['source'] != _ProgressSource.flood.name) {
        return;
      }
      flushes++;
    });
    late final Map<String, Object?> event;
    try {
      final done = _nextEvent(_events, _EngineEvent.floodDone, _terminal);
      _send(_EngineCommand.flood);
      event = await done;
    } finally {
      await subscription.cancel();
    }

    final elapsed = Duration(microseconds: event['elapsedUs']! as int);
    return _FloodResult(
      flushes: flushes,
      elapsed: elapsed,
      eventsPerSecond:
          _syntheticEvents *
          Duration.microsecondsPerSecond /
          elapsed.inMicroseconds,
      flushesPerSecond:
          flushes * Duration.microsecondsPerSecond / elapsed.inMicroseconds,
    );
  }

  Future<_WorkloadResult> runWorkloadWithTimerProbe() async {
    var progressFlushes = 0;
    final progressSubscription = _events.listen((event) {
      if (event['event'] != _EngineEvent.progress.name ||
          event['source'] != _ProgressSource.workload.name) {
        return;
      }
      progressFlushes++;
    });

    final probe = Stopwatch()..start();
    var previous = probe.elapsedMicroseconds;
    var maxStallUs = 0;
    final timer = Timer.periodic(_timerProbeInterval, (_) {
      final now = probe.elapsedMicroseconds;
      final stall = now - previous - _timerProbeInterval.inMicroseconds;
      if (stall > maxStallUs) maxStallUs = stall;
      previous = now;
    });

    late final Map<String, Object?> event;
    try {
      final done = _nextEvent(_events, _EngineEvent.workloadDone, _terminal);
      _send(_EngineCommand.workload);
      event = await done;
    } finally {
      timer.cancel();
      probe.stop();
      await progressSubscription.cancel();
    }

    return _WorkloadResult(
      bytes: event['bytes']! as int,
      entries: event['entries']! as int,
      elapsed: Duration(microseconds: event['elapsedUs']! as int),
      progressFlushes: progressFlushes,
      maxStall: Duration(microseconds: maxStallUs),
    );
  }

  Future<void> close() async {
    _terminal.expectShutdown();
    final stopped = _nextEvent(_events, _EngineEvent.stopped, _terminal);
    _send(_EngineCommand.shutdown);
    try {
      await stopped;
    } finally {
      _terminal.close();
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _receivePort.close();
      _errorPort.close();
      _exitPort.close();
      await _controller.close();
      _isolate.kill();
    }
  }

  void _send(_EngineCommand command, [Map<String, Object?>? fields]) {
    _commands.send({'command': command.name, ...?fields});
  }
}

class _FloodResult {
  final int flushes;
  final Duration elapsed;
  final double eventsPerSecond;
  final double flushesPerSecond;

  const _FloodResult({
    required this.flushes,
    required this.elapsed,
    required this.eventsPerSecond,
    required this.flushesPerSecond,
  });
}

class _WorkloadResult {
  final int bytes;
  final int entries;
  final Duration elapsed;
  final int progressFlushes;
  final Duration maxStall;

  const _WorkloadResult({
    required this.bytes,
    required this.entries,
    required this.elapsed,
    required this.progressFlushes,
    required this.maxStall,
  });
}

Future<Map<String, Object?>> _nextEvent(
  Stream<Map<String, Object?>> events,
  _EngineEvent expected,
  _EngineTerminal terminal,
) async {
  final completer = Completer<Map<String, Object?>>();
  late final StreamSubscription<Map<String, Object?>> subscription;
  subscription = events.listen((event) {
    if (event['event'] != expected.name &&
        event['event'] != _EngineEvent.error.name) {
      return;
    }
    if (!completer.isCompleted) completer.complete(event);
  });
  final terminalEvent = terminal.event;
  if (terminalEvent != null && !completer.isCompleted) {
    completer.complete(terminalEvent);
  }

  late final Map<String, Object?> event;
  try {
    event = await completer.future.timeout(_engineTimeout);
  } finally {
    await subscription.cancel();
  }
  if (event['event'] != _EngineEvent.error.name) return event;

  throw StateError('${event['error']}\n${event['stack']}');
}

class _EngineTerminal {
  Map<String, Object?>? event;
  bool _accepting = true;
  bool _shutdownExpected = false;

  void publish(
    StreamController<Map<String, Object?>> controller, {
    required String error,
    required String stack,
  }) {
    if (!_accepting || event != null) return;

    final terminalEvent = <String, Object?>{
      'event': _EngineEvent.error.name,
      'error': error,
      'stack': stack,
    };
    event = terminalEvent;
    controller.add(terminalEvent);
  }

  void publishExit(StreamController<Map<String, Object?>> controller) {
    if (!_shutdownExpected) {
      publish(
        controller,
        error: 'engine isolate exited unexpectedly',
        stack: '',
      );
      return;
    }
    if (!_accepting || event != null) return;

    final stopped = <String, Object?>{'event': _EngineEvent.stopped.name};
    event = stopped;
    controller.add(stopped);
  }

  void expectShutdown() => _shutdownExpected = true;

  void close() => _accepting = false;
}

Future<void> _engineMain(Map<String, Object?> initial) async {
  final events = initial['events']! as SendPort;
  final endpoint = BenchEndpoint.fromJson(
    (initial['endpoint']! as Map).cast<String, Object?>(),
  );
  final remoteRoot = initial['remoteRoot']! as String;
  final commands = ReceivePort();
  final engine = _IsolateEngine(events, endpoint, remoteRoot);
  events.send({
    'event': _EngineEvent.ready.name,
    'commands': commands.sendPort,
  });

  commands.listen((message) {
    final command = (message! as Map).cast<String, Object?>();
    final type = _EngineCommand.values.byName(command['command']! as String);
    switch (type) {
      case _EngineCommand.singleTransfer:
        unawaited(engine.runSingleTransfer());
        return;
      case _EngineCommand.startCancellation:
        unawaited(engine.startCancellation(command['path']! as String));
        return;
      case _EngineCommand.cancel:
        engine.cancel();
        return;
      case _EngineCommand.flood:
        unawaited(engine.runFlood());
        return;
      case _EngineCommand.workload:
        unawaited(engine.runWorkload());
        return;
      case _EngineCommand.shutdown:
        commands.close();
        events.send({'event': _EngineEvent.stopped.name});
        return;
    }
  });
}

class _IsolateEngine {
  final SendPort _events;
  final BenchEndpoint _endpoint;
  final String _remoteRoot;
  RemoteTransferCancellation? _cancellation;

  _IsolateEngine(this._events, this._endpoint, this._remoteRoot);

  Future<void> runSingleTransfer() => _guard(() async {
    final connection = await openBenchConnection(_endpoint);
    try {
      final read = await connection.download(
        path: '$_remoteRoot/fixtures/payload-100mb.bin',
      );
      _events.send({
        'event': _EngineEvent.singleDone.name,
        'bytes': read.bytes,
        'elapsedUs': read.elapsed.inMicroseconds,
        'digest': read.digest,
      });
    } finally {
      connection.close();
    }
  });

  Future<void> startCancellation(String path) => _guard(() async {
    final connection = await openBenchConnection(_endpoint);
    final cancellation = RemoteTransferCancellation();
    _cancellation = cancellation;
    var announced = false;
    try {
      await connection.download(
        path: path,
        digestMode: DigestMode.disabled,
        cancellation: cancellation,
        onProgress: (_, _) {
          if (announced) return;
          announced = true;
          _events.send({'event': _EngineEvent.cancelReady.name});
        },
      );
      throw StateError('Cancellation transfer completed before cancellation.');
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.cancelled) rethrow;

      _events.send({'event': _EngineEvent.cancelDone.name});
    } finally {
      _cancellation = null;
      connection.close();
    }
  });

  void cancel() => _cancellation?.cancel();

  Future<void> runFlood() => _guard(() async {
    var flushes = 0;
    final coalescer = ProgressCoalescer((taskId, samples) {
      flushes++;
      _events.send({
        'event': _EngineEvent.progress.name,
        'source': _ProgressSource.flood.name,
        'taskId': taskId,
        'samples': samples.length,
      });
    });
    final stopwatch = Stopwatch()..start();
    final batches = _syntheticEvents ~/ _syntheticBatchSize;
    for (var batch = 0; batch < batches; batch++) {
      for (var offset = 0; offset < _syntheticBatchSize; offset++) {
        final event = batch * _syntheticBatchSize + offset;
        coalescer.add(
          ProgressSample(
            taskId: 'synthetic-task',
            itemId: 'item-${event % _isolateTransferCount}',
            transferred: event,
            total: _syntheticEvents,
          ),
        );
      }
      await Future<void>.delayed(_syntheticBatchPause);
    }
    await coalescer.drain();
    stopwatch.stop();

    _events.send({
      'event': _EngineEvent.floodDone.name,
      'elapsedUs': stopwatch.elapsedMicroseconds,
      'flushes': flushes,
    });
  });

  Future<void> runWorkload() => _guard(() async {
    final connection = await openBenchConnection(_endpoint);
    final coalescer = ProgressCoalescer((taskId, samples) {
      _events.send({
        'event': _EngineEvent.progress.name,
        'source': _ProgressSource.workload.name,
        'taskId': taskId,
        'samples': samples.length,
      });
    });
    try {
      final workload = await connection.runCombinedWorkload(
        transferPath: '$_remoteRoot/fixtures/payload-100mb.bin',
        listingPath: '$_remoteRoot/fixtures/entries-10000',
        transfers: _isolateTransferCount,
        expectedEntries: _listingFixtureEntries,
        onProgress: (item, transferred, total) {
          coalescer.add(
            ProgressSample(
              taskId: 'transfer-$item',
              itemId: 'payload-100mb.bin',
              transferred: transferred,
              total: total,
            ),
          );
        },
      );
      await coalescer.drain();
      _events.send({
        'event': _EngineEvent.workloadDone.name,
        'bytes': workload.bytes,
        'entries': workload.entries,
        'elapsedUs': workload.elapsed.inMicroseconds,
      });
    } finally {
      connection.close();
    }
  });

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } catch (error, stack) {
      _events.send({
        'event': _EngineEvent.error.name,
        'error': '$error',
        'stack': '$stack',
      });
    }
  }
}
