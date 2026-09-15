import 'dart:io';

import 'package:seance_core/seance_core.dart';

/// The OS-default-application launch behind [OpenLocalFileRequest] (02
/// §2.6's Open on a local file). Process mechanics stay engine-side
/// (D8 — the UI isolate never spawns) behind this injectable seam: the
/// production default selects the platform's opener binary, tests
/// script the launch and its failures.
abstract interface class LocalFileOpener {
  factory LocalFileOpener.platform() => const _PlatformLocalFileOpener();

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
final class _PlatformLocalFileOpener implements LocalFileOpener {
  const _PlatformLocalFileOpener();

  @override
  Future<void> open(String path) async {
    if (Platform.isWindows) {
      // explorer.exe's exit code is unreliable (it returns nonzero even
      // on a successful hand-off), so the spawn is detached and only a
      // launch failure is typed — the same fire-and-forget honesty as a
      // missing opener below.
      try {
        await Process.start(
          'explorer.exe',
          [path],
          mode: ProcessStartMode.detached,
        );
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
      result = await Process.run(
        Platform.isMacOS ? 'open' : 'xdg-open',
        [path],
      );
    } on ProcessException catch (error) {
      throw _launchFailure(path, error.message);
    }
    if (result.exitCode != 0) {
      final stderr = '${result.stderr}'.trim();
      throw _launchFailure(
        path,
        stderr.isEmpty
            ? 'The system opener exited with status ${result.exitCode}.'
            : stderr,
      );
    }
  }

  RemoteFileException _launchFailure(String path, String message) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'open',
        path: path,
        message: message,
      );
}
