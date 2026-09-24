import 'dart:io';

import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart';

/// Runs [executable] with [arguments] to completion — `Process.run`'s
/// shape, injectable so the opener's fallback chain is testable.
typedef OpenerProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// The OS-default-application launch behind [OpenLocalFileRequest] (02
/// §2.6's Open on a local file). Process mechanics stay engine-side
/// (D8 — the UI isolate never spawns) behind this injectable seam: the
/// production default selects the platform's opener binary, tests
/// script the launch and its failures.
abstract interface class LocalFileOpener {
  factory LocalFileOpener.platform() => _PlatformLocalFileOpener(
    run: Process.run,
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
  );

  /// The Unix launch path over a scripted [run] (tests only).
  @visibleForTesting
  factory LocalFileOpener.unix({
    required OpenerProcessRunner run,
    bool isMacOS = false,
  }) => _PlatformLocalFileOpener(run: run, isMacOS: isMacOS, isWindows: false);

  /// Hands [path] to the operating system's default handler and
  /// completes once the launch itself was accepted — never when the
  /// launched application exits. Every failure is a typed
  /// [RemoteFileException] (operation `open`), so it crosses the
  /// isolate port like any other engine error.
  Future<void> open(String path);
}

/// The per-platform launch: `open` on macOS, `xdg-open` elsewhere —
/// except Windows, whose `explorer.exe` performs the file's default
/// verb. Argument lists only, no shell (03 §4.3's launch rule): the
/// path is one argv element and can never parse as flags or split on
/// spaces.
///
/// `xdg-open` ships in xdg-utils, which minimal and container installs
/// often lack while GLib's `gio` is present on every GTK desktop (the
/// app itself links GTK). A missing `xdg-open` therefore falls back to
/// `gio open`; only when neither exists does the launch fail.
final class _PlatformLocalFileOpener implements LocalFileOpener {
  const _PlatformLocalFileOpener({
    required this.run,
    required this.isMacOS,
    required this.isWindows,
  });

  final OpenerProcessRunner run;
  final bool isMacOS;
  final bool isWindows;

  @override
  Future<void> open(String path) async {
    if (isWindows) {
      // explorer.exe's exit code is unreliable (it returns nonzero even
      // on a successful hand-off), so the spawn is detached and only a
      // launch failure is typed — the same fire-and-forget honesty as a
      // missing opener below.
      try {
        await Process.start('explorer.exe', [
          path,
        ], mode: ProcessStartMode.detached);
      } on ProcessException catch (error) {
        throw _launchFailure(path, error.message);
      }
      return;
    }

    // The Unix openers are thin hand-off wrappers that exit immediately:
    // awaiting their exit code reports "no such file"/"no handler"
    // failures that a detached spawn would silently drop.
    final ProcessResult result;
    try {
      result = await run(isMacOS ? 'open' : 'xdg-open', [path]);
    } on ProcessException catch (error) {
      if (isMacOS) throw _launchFailure(path, error.message);
      return _openWithGio(path, error);
    }
    _checkExit(path, result);
  }

  Future<void> _openWithGio(String path, ProcessException missing) async {
    final ProcessResult result;
    try {
      result = await run('gio', ['open', path]);
    } on ProcessException {
      // Neither opener exists: name the one users install.
      throw _launchFailure(path, missing.message);
    }
    _checkExit(path, result);
  }

  void _checkExit(String path, ProcessResult result) {
    if (result.exitCode == 0) return;
    final stderr = '${result.stderr}'.trim();
    throw _launchFailure(
      path,
      stderr.isEmpty
          ? 'The system opener exited with status ${result.exitCode}.'
          : stderr,
    );
  }

  RemoteFileException _launchFailure(String path, String message) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'open',
        path: path,
        message: message,
      );
}
