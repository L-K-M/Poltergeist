import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/src/engine/local_directory_watcher.dart';
import 'package:poltergeist_core/src/engine/protocol.dart'
    show DirectoryWatchSignal;

/// Owned child half of the native overflow fixture. NOT a test file: the
/// `dart test` runner never picks this up; the overflow test spawns it as
/// its own process so the fixture can be suspended at the process level.
///
/// Protocol (one flushed stdout line per stage):
///   WATCHING        the production-selected backend watch is installed
///   MARKER          a real create was observed through the production stack
///   `LOST <detail>` the watch signalled loss (exit 0)
///   TIMEOUT         no loss arrived within the bound (exit 3)
///   MARKER_TIMEOUT  the marker create was never observed (exit 4)
///
/// Exit 3 is the expected shape on a backend that cannot see the kernel's
/// queue overflow: the watch stays silently installed.
Future<void> main(List<String> args) async {
  final watcher = LocalDirectoryWatcher();
  final marked = Completer<void>();
  final lost = Completer<String>();

  watcher.signals.listen((signal) {
    if (signal.kind == DirectoryWatchSignal.lost) {
      if (!lost.isCompleted) lost.complete(signal.detail ?? '');
      return;
    }
    if (!marked.isCompleted) marked.complete();
  });

  await watcher.retarget(args.first);
  await _emit('WATCHING');

  try {
    await marked.future.timeout(const Duration(seconds: 30));
  } on TimeoutException {
    await _emit('MARKER_TIMEOUT');
    exit(4);
  }
  await _emit('MARKER');

  final String detail;
  try {
    detail = await lost.future.timeout(const Duration(seconds: 90));
  } on TimeoutException {
    await _emit('TIMEOUT');
    exit(3);
  }
  await _emit('LOST $detail');
  await watcher.dispose();
}

Future<void> _emit(String line) async {
  stdout.writeln(line);
  await stdout.flush();
}
