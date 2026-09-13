@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Real kernel queue overflow (STATUS open item 14, closed by the Linux
/// inotify backend): a watched directory whose consumer cannot drain the
/// inotify queue must surface the overflow as an immediate backend error —
/// the production adapter's `lost` — never a silent partial watch.
///
/// The fixture suspends the OWNED child process (SIGSTOP stops every
/// thread, so no event-handler thread drains the queue), generates more
/// distinct create/delete events than the child's kernel queue capacity,
/// resumes it, and requires the child to report a lost signal naming the
/// overflow. `/proc/sys/fs/inotify/max_queued_events` is only ever read.
void main() {
  test(
    'a real kernel queue overflow surfaces as an immediate lost signal',
    () async {
      final capacity = _queuedEventCapacity();
      final fixture = await Directory.systemTemp.createTemp('pg-overflow-');
      final child = await _spawnChild(fixture.path);

      final stdoutLines = _LineFeed();
      final stderrLines = _LineFeed();
      child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(stdoutLines.add);
      child.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(stderrLines.add);

      var exited = false;
      try {
        await stdoutLines.takeLine(
          RegExp('^WATCHING\$'),
          const Duration(seconds: 30),
          () => 'stdout: ${stdoutLines.lines}\nstderr: ${stderrLines.lines}',
        );

        // A real create seen through the production stack proves the watch
        // is installed before the child can be suspended. Anchored so a
        // MARKER_TIMEOUT stage cannot read as success.
        File(p.join(fixture.path, 'marker')).writeAsStringSync('ready');
        await stdoutLines.takeLine(
          RegExp('^MARKER\$'),
          const Duration(seconds: 30),
          () => 'stdout: ${stdoutLines.lines}\nstderr: ${stderrLines.lines}',
        );

        child.kill(ProcessSignal.sigstop);
        await _awaitStopped(child.pid);
        _generateEvents(fixture.path, capacity + _overflowMargin);

        child.kill(ProcessSignal.sigcont);
        final code = await child.exitCode.timeout(
          const Duration(seconds: 120),
        );
        exited = true;

        expect(code, 0, reason: 'stdout: ${stdoutLines.lines}');
        final lost = stdoutLines.lines.firstWhere(
          (line) => line.startsWith('LOST '),
        );
        // The detail ties the loss to the overflow itself, not to an
        // incidental close or unrelated error.
        expect(lost, contains('overflow'),
            reason: 'stdout: ${stdoutLines.lines}');
      } finally {
        if (!exited) {
          child.kill(ProcessSignal.sigcont);
          child.kill(ProcessSignal.sigkill);
          await child.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () => -1,
          );
        }
        if (fixture.existsSync()) fixture.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

/// Extra events beyond the kernel queue capacity, so the queue is
/// provably overrun even if a few events raced the suspension.
const _overflowMargin = 4096;

const _probeNames = ['probe-a', 'probe-b', 'probe-c', 'probe-d'];

int _queuedEventCapacity() {
  const procPath = '/proc/sys/fs/inotify/max_queued_events';
  final value = int.tryParse(File(procPath).readAsStringSync().trim());
  if (value == null || value <= 0) fail('$procPath is unreadable');
  return value;
}

Future<Process> _spawnChild(String directory) async {
  // Isolate.packageConfigSync points at the workspace's .dart_tool, so the
  // child resolves the same package config no matter where the suite runs.
  final config = Isolate.packageConfigSync!;
  final root = p.dirname(p.dirname(p.fromUri(config)));
  return Process.start(
    Platform.resolvedExecutable,
    [
      'run',
      p.join(root, 'packages', 'poltergeist_core', 'test', 'engine',
          'inotify_overflow_child.dart'),
      directory,
    ],
    workingDirectory: root,
  );
}

Future<void> _awaitStopped(int pid) async {
  String? lastState;
  for (var attempt = 0; attempt < 25; attempt++) {
    try {
      lastState = _processState(pid);
    } on PathNotFoundException {
      // The child is gone; it can never reach the stopped state, and the
      // captured output explains why better than a /proc read error.
      break;
    }
    if (lastState == 'T' || lastState == 't') return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('child never reached the stopped state (last state: $lastState)');
}

/// The state letter follows the final ')' because the comm field may
/// contain spaces and parentheses of its own (proc(5)).
String _processState(int pid) {
  final stat = File('/proc/$pid/stat').readAsStringSync();
  final commEnd = stat.lastIndexOf(')');
  return stat.substring(commEnd + 2, commEnd + 3);
}

void _generateEvents(String directory, int target) {
  var generated = 0;
  var round = 0;
  while (generated < target) {
    final file = File(p.join(directory, _probeNames[round++ % _probeNames.length]));
    file.createSync();
    file.deleteSync();
    generated += 2;
  }
}

/// Buffers child output lines and lets assertions await a matching line
/// with a diagnosis snapshot on timeout.
final class _LineFeed {
  final lines = <String>[];
  final _waiters = <void Function()>[];

  void add(String line) {
    lines.add(line);
    for (final waiter in List.of(_waiters)) {
      waiter();
    }
  }

  Future<void> takeLine(
    Pattern pattern,
    Duration limit,
    String Function() diagnosis,
  ) {
    for (final line in lines) {
      if (line.contains(pattern)) return Future<void>.value();
    }

    final completer = Completer<void>();
    late final void Function() waiter;
    waiter = () {
      for (final line in lines) {
        if (line.contains(pattern)) {
          if (!completer.isCompleted) completer.complete();
          _waiters.remove(waiter);
          return;
        }
      }
    };
    _waiters.add(waiter);
    return completer.future.timeout(
      limit,
      onTimeout: () => fail('no line matching $pattern; ${diagnosis()}'),
    );
  }
}
