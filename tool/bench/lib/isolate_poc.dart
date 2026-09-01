import 'dart:async';
import 'dart:isolate';

import 'package:seance_core/seance_core.dart';

import 'config.dart';
import 'harness.dart';
import 'progress_coalescer.dart';
import 'ssh_driver.dart';

const cancellationLatencyLimit = Duration(milliseconds: 100);
const mainIsolateStallLimit = Duration(milliseconds: 16);
const isolateThroughputParityTolerance = 0.10;
const isolateThroughputSampleCount = 3;
const _timerProbeInterval = Duration(milliseconds: 4);
const _engineTimeout = Duration(minutes: 30);
const _isolateTransferCount = 4;
final _workloadTaskIds = List<String>.unmodifiable(
  List.generate(_isolateTransferCount, (index) => 'transfer-$index'),
);
const _listingFixtureEntries = 10_000;
const _syntheticEvents = 20_000;
const _syntheticBatchSize = 200;
const _syntheticBatchPause = Duration(milliseconds: 10);
const _syntheticMinimumEventsPerSecond = 10_000;

/// Validates that coalesced progress crossed the isolate boundary intact.
List<String> validateFloodEvidence({
  required int uiFlushes,
  required int engineFlushes,
  required double uiFlushesPerSecond,
}) {
  final failures = <String>[];
  if (uiFlushes == 0) {
    failures.add('engine isolate delivered no progress flushes');
  }
  if (uiFlushes != engineFlushes) {
    failures.add('UI progress $uiFlushes != engine $engineFlushes');
  }
  if (uiFlushesPerSecond > progressFlushesPerSecond) {
    failures.add(
      'progress ${uiFlushesPerSecond.toStringAsFixed(2)}/s > '
      '$progressFlushesPerSecond/s',
    );
  }
  return failures;
}

/// Verifies the real four-transfer workload obeys the per-task flush cap.
List<String> validateWorkloadFlushEvidence({
  required Map<String, int> flushesByTask,
  required Duration elapsed,
  required Iterable<String> expectedTasks,
}) {
  final failures = <String>[];
  final tasks = expectedTasks.toSet();
  if (elapsed <= Duration.zero) {
    return ['workload progress window is not positive'];
  }

  for (final taskId in tasks) {
    final flushes = flushesByTask[taskId];
    if (flushes == null || flushes == 0) {
      failures.add('$taskId delivered no workload progress');
      continue;
    }

    final rate = _ratePerSecond(flushes, elapsed);
    if (rate > progressFlushesPerSecond) {
      failures.add(
        '$taskId progress ${rate.toStringAsFixed(2)}/s > '
        '$progressFlushesPerSecond/s',
      );
    }
  }

  final unexpected = flushesByTask.keys.toSet().difference(tasks);
  if (unexpected.isNotEmpty) {
    failures.add('unexpected workload progress tasks: ${unexpected.join(',')}');
  }

  final aggregateRate = _ratePerSecond(
    flushesByTask.values.fold(0, (sum, flushes) => sum + flushes),
    elapsed,
  );
  final aggregateLimit = progressFlushesPerSecond * tasks.length;
  if (aggregateRate > aggregateLimit) {
    failures.add(
      'aggregate progress ${aggregateRate.toStringAsFixed(2)}/s > '
      '$aggregateLimit/s',
    );
  }
  return failures;
}

double _ratePerSecond(int events, Duration elapsed) =>
    events * Duration.microsecondsPerSecond / elapsed.inMicroseconds;

String _workloadFlushRates(_WorkloadResult workload) {
  final entries = workload.progressFlushesByTask.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final rates = [
    for (final entry in entries)
      '${entry.key}='
          '${_ratePerSecond(entry.value, workload.progressElapsed).toStringAsFixed(2)}/s',
    'aggregate='
        '${_ratePerSecond(workload.progressFlushes, workload.progressElapsed).toStringAsFixed(2)}/s',
  ];
  return rates.join(',');
}

/// Compares warmed, interleaved median transfer rates in both isolates.
List<String> validateThroughputParity({
  required List<ReadBatchResult> rootSamples,
  required List<ReadBatchResult> isolateSamples,
}) {
  final failures = <String>[];
  if (rootSamples.length < isolateThroughputSampleCount ||
      isolateSamples.length < isolateThroughputSampleCount) {
    failures.add(
      'isolate parity needs $isolateThroughputSampleCount samples per side',
    );
    return failures;
  }

  final parity = _medianRate(isolateSamples) / _medianRate(rootSamples);
  final lowerBound = 1 - isolateThroughputParityTolerance;
  final upperBound = 1 + isolateThroughputParityTolerance;
  if (parity < lowerBound || parity > upperBound) {
    failures.add(
      'isolate parity ${parity.toStringAsFixed(3)} outside '
      '${lowerBound.toStringAsFixed(2)}–${upperBound.toStringAsFixed(2)}',
    );
  }
  return failures;
}

/// Returns event-loop delay beyond one expected probe interval.
Duration timerProbeOverrun({
  required Duration elapsed,
  required Duration previousTick,
  required Duration interval,
}) {
  final overrun = elapsed - previousTick - interval;
  return overrun.isNegative ? Duration.zero : overrun;
}

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
  error,
}

enum _ProgressSource { flood, workload }

enum _EngineShutdownMode { clean, delayedError }

const _shutdownProbeError = 'delayed shutdown probe error';

/// Exercises cancel delivery and the transport cleanup that follows it.
Future<Duration> runIsolateCancellationProbe(BenchConfig config) async {
  final path = '${config.remoteRoot}/fixtures/payload-1gb.bin';
  final peer = await _EnginePeer.spawn(config.endpoint, config.remoteRoot);
  try {
    return await peer.measureCancellation(path);
  } finally {
    await peer.close();
  }
}

/// Verifies that an uncaught error queued during shutdown reaches the caller.
Future<void> runIsolateShutdownErrorProbe() async {
  final peer = await _EnginePeer.spawn(
    const BenchEndpoint(),
    '',
    shutdownMode: _EngineShutdownMode.delayedError,
  );
  await peer.close();
}

Future<List<BenchResult>> runIsolatePoc(BenchConfig config) async {
  final transferPath = '${config.remoteRoot}/fixtures/payload-100mb.bin';
  final cancellationPath = '${config.remoteRoot}/fixtures/payload-1gb.bin';
  await _downloadInRoot(config.endpoint, transferPath);

  final peer = await _EnginePeer.spawn(config.endpoint, config.remoteRoot);
  try {
    await peer.runSingleTransfer();
    final rootSamples = <ReadBatchResult>[];
    final isolateSamples = <ReadBatchResult>[];
    for (var sample = 0; sample < isolateThroughputSampleCount; sample++) {
      if (sample.isEven) {
        rootSamples.add(await _downloadInRoot(config.endpoint, transferPath));
        isolateSamples.add(await peer.runSingleTransfer());
        continue;
      }

      isolateSamples.add(await peer.runSingleTransfer());
      rootSamples.add(await _downloadInRoot(config.endpoint, transferPath));
    }
    final rootBaseline = _medianSample(rootSamples);
    final isolateTransfer = _medianSample(isolateSamples);
    final cancellation = await peer.measureCancellation(cancellationPath);
    final flood = await peer.runFlood();
    final workload = await peer.runWorkloadWithTimerProbe();

    final rootRate = rootBaseline.bytes / rootBaseline.elapsed.inMicroseconds;
    final isolateRate =
        isolateTransfer.bytes / isolateTransfer.elapsed.inMicroseconds;
    final parity = isolateRate / rootRate;
    const parityNote =
        'samples=$isolateThroughputSampleCount; aggregate=median; '
        'warmed=true; order=interleaved';
    final results = [
      BenchResult.capture(
        scenario: 'isolate-root-baseline',
        bytes: rootBaseline.bytes,
        elapsed: rootBaseline.elapsed,
        note: 'sha256=${rootBaseline.digest}; $parityNote',
      ),
      BenchResult.capture(
        scenario: 'isolate-single-transfer',
        bytes: isolateTransfer.bytes,
        elapsed: isolateTransfer.elapsed,
        note: 'rootParity=${parity.toStringAsFixed(3)}; $parityNote',
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
            'uiFlushes=${flood.flushes}; '
            'engineFlushes=${flood.engineFlushes}; '
            'flushesPerSecond=${flood.flushesPerSecond.toStringAsFixed(2)}',
      ),
      BenchResult.capture(
        scenario: 'isolate-four-transfers-listing',
        bytes: workload.bytes,
        elapsed: workload.elapsed,
        note:
            'entries=${workload.entries}; '
            'progressFlushes=${workload.progressFlushes}; '
            'progressWindowUs=${workload.progressElapsed.inMicroseconds}; '
            'flushRates=${_workloadFlushRates(workload)}; '
            'maxMainStallUs=${workload.maxStall.inMicroseconds}',
      ),
    ];
    final failures = <String>[];
    failures.addAll(
      validateThroughputParity(
        rootSamples: rootSamples,
        isolateSamples: isolateSamples,
      ),
    );
    if (cancellation >= cancellationLatencyLimit) {
      failures.add(
        'cancellation ${cancellation.inMicroseconds}µs >= '
        '${cancellationLatencyLimit.inMicroseconds}µs',
      );
    }
    failures.addAll(
      validateFloodEvidence(
        uiFlushes: flood.flushes,
        engineFlushes: flood.engineFlushes,
        uiFlushesPerSecond: flood.flushesPerSecond,
      ),
    );
    failures.addAll(
      validateWorkloadFlushEvidence(
        flushesByTask: workload.progressFlushesByTask,
        elapsed: workload.progressElapsed,
        expectedTasks: _workloadTaskIds,
      ),
    );
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

Future<ReadBatchResult> _downloadInRoot(
  BenchEndpoint endpoint,
  String path,
) async {
  final connection = await openBenchConnection(endpoint);
  try {
    return await connection.download(path: path);
  } finally {
    await connection.close();
  }
}

ReadBatchResult _medianSample(List<ReadBatchResult> samples) {
  final ordered = [...samples]
    ..sort((left, right) => _rate(left).compareTo(_rate(right)));
  return ordered[ordered.length ~/ 2];
}

double _medianRate(List<ReadBatchResult> samples) =>
    _rate(_medianSample(samples));

double _rate(ReadBatchResult sample) =>
    sample.bytes / sample.elapsed.inMicroseconds;

class _EnginePeer {
  final ReceivePort _receivePort;
  final ReceivePort _terminalPort;
  final Isolate _isolate;
  final SendPort _commands;
  final Stream<Map<String, Object?>> _events;
  final StreamController<Map<String, Object?>> _controller;
  final List<StreamSubscription<dynamic>> _subscriptions;
  final _EngineTerminal _terminal;

  _EnginePeer._(
    this._receivePort,
    this._terminalPort,
    this._isolate,
    this._commands,
    StreamController<Map<String, Object?>> controller,
    this._subscriptions,
    this._terminal,
  ) : _events = controller.stream,
      _controller = controller;

  static Future<_EnginePeer> spawn(
    BenchEndpoint endpoint,
    String remoteRoot, {
    _EngineShutdownMode shutdownMode = _EngineShutdownMode.clean,
  }) async {
    final receivePort = ReceivePort();
    final terminalPort = ReceivePort();
    final controller = StreamController<Map<String, Object?>>.broadcast(
      sync: true,
    );
    final terminal = _EngineTerminal();
    final subscriptions = <StreamSubscription<dynamic>>[
      receivePort.listen(
        (message) => controller.add((message! as Map).cast<String, Object?>()),
      ),
      terminalPort.listen((message) {
        if (message == null) {
          terminal.publishExit(controller);
          return;
        }

        final parts = message is List ? message : [message];
        terminal.publish(
          controller,
          error: parts.isEmpty ? 'unknown isolate error' : '${parts.first}',
          stack: parts.length > 1 ? '${parts[1]}' : '',
        );
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
          'shutdownMode': shutdownMode.name,
        },
        onError: terminalPort.sendPort,
        onExit: terminalPort.sendPort,
        errorsAreFatal: true,
      );
      final ready = await readyFuture;
      return _EnginePeer._(
        receivePort,
        terminalPort,
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
      terminalPort.close();
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
      engineFlushes: event['flushes']! as int,
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
    final progressFlushesByTask = <String, int>{};
    final progressSubscription = _events.listen((event) {
      if (event['event'] != _EngineEvent.progress.name ||
          event['source'] != _ProgressSource.workload.name) {
        return;
      }

      final taskId = event['taskId']! as String;
      progressFlushesByTask.update(
        taskId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    });

    final probe = Stopwatch()..start();
    var previous = probe.elapsed;
    var maxStall = Duration.zero;
    void sampleTimer() {
      final now = probe.elapsed;
      final stall = timerProbeOverrun(
        elapsed: now,
        previousTick: previous,
        interval: _timerProbeInterval,
      );
      if (stall > maxStall) maxStall = stall;
      previous = now;
    }

    final timer = Timer.periodic(_timerProbeInterval, (_) => sampleTimer());

    late final Map<String, Object?> event;
    late final Duration progressElapsed;
    try {
      final done = _nextEvent(_events, _EngineEvent.workloadDone, _terminal);
      _send(_EngineCommand.workload);
      event = await done;
    } finally {
      // A completion message can run before an overdue timer callback.
      sampleTimer();
      timer.cancel();
      progressElapsed = probe.elapsed;
      probe.stop();
      await progressSubscription.cancel();
    }

    return _WorkloadResult(
      bytes: event['bytes']! as int,
      entries: event['entries']! as int,
      elapsed: Duration(microseconds: event['elapsedUs']! as int),
      progressFlushesByTask: progressFlushesByTask,
      progressElapsed: progressElapsed,
      maxStall: maxStall,
    );
  }

  Future<void> close() async {
    _terminal.expectShutdown();
    _send(_EngineCommand.shutdown);
    try {
      await _terminal.waitForExit();
    } finally {
      if (!_terminal.hasExited) _isolate.kill();

      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _receivePort.close();
      _terminalPort.close();
      await _controller.close();
      _terminal.close();
    }
  }

  void _send(_EngineCommand command, [Map<String, Object?>? fields]) {
    _commands.send({'command': command.name, ...?fields});
  }
}

class _FloodResult {
  final int flushes;
  final int engineFlushes;
  final Duration elapsed;
  final double eventsPerSecond;
  final double flushesPerSecond;

  const _FloodResult({
    required this.flushes,
    required this.engineFlushes,
    required this.elapsed,
    required this.eventsPerSecond,
    required this.flushesPerSecond,
  });
}

class _WorkloadResult {
  final int bytes;
  final int entries;
  final Duration elapsed;
  final Map<String, int> progressFlushesByTask;
  final Duration progressElapsed;
  final Duration maxStall;

  _WorkloadResult({
    required this.bytes,
    required this.entries,
    required this.elapsed,
    required Map<String, int> progressFlushesByTask,
    required this.progressElapsed,
    required this.maxStall,
  }) : progressFlushesByTask = Map.unmodifiable(progressFlushesByTask);

  int get progressFlushes =>
      progressFlushesByTask.values.fold(0, (sum, flushes) => sum + flushes);
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
  final Completer<Map<String, Object?>?> _exit = Completer();
  bool _accepting = true;
  bool _shutdownExpected = false;

  bool get hasExited => _exit.isCompleted;

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
    if (!_accepting || _exit.isCompleted) return;

    if (!_shutdownExpected && event == null) {
      publish(
        controller,
        error: 'engine isolate exited unexpectedly',
        stack: '',
      );
    }

    _accepting = false;
    _exit.complete(event);
  }

  void expectShutdown() => _shutdownExpected = true;

  Future<void> waitForExit() async {
    final terminalEvent = await _exit.future.timeout(_engineTimeout);
    if (terminalEvent == null) return;

    throw StateError('${terminalEvent['error']}\n${terminalEvent['stack']}');
  }

  void close() => _accepting = false;
}

Future<void> _engineMain(Map<String, Object?> initial) async {
  final events = initial['events']! as SendPort;
  final endpoint = BenchEndpoint.fromJson(
    (initial['endpoint']! as Map).cast<String, Object?>(),
  );
  final remoteRoot = initial['remoteRoot']! as String;
  final shutdownMode = _EngineShutdownMode.values.byName(
    initial['shutdownMode']! as String,
  );
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
        if (shutdownMode == _EngineShutdownMode.delayedError) {
          scheduleMicrotask(() => throw StateError(_shutdownProbeError));
        }
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
    late final ReadBatchResult read;
    try {
      read = await connection.download(
        path: '$_remoteRoot/fixtures/payload-100mb.bin',
      );
    } finally {
      await connection.close();
    }

    _events.send({
      'event': _EngineEvent.singleDone.name,
      'bytes': read.bytes,
      'elapsedUs': read.elapsed.inMicroseconds,
      'digest': read.digest,
    });
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
    } finally {
      _cancellation = null;
      await connection.close();
    }

    _events.send({'event': _EngineEvent.cancelDone.name});
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
    late final CombinedWorkloadResult workload;
    try {
      workload = await connection.runCombinedWorkload(
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
    } finally {
      await connection.close();
    }

    _events.send({
      'event': _EngineEvent.workloadDone.name,
      'bytes': workload.bytes,
      'entries': workload.entries,
      'elapsedUs': workload.elapsed.inMicroseconds,
    });
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
