import 'dart:io';

/// Runs a process and returns its exit code — injectable so tests never
/// spawn a file manager.
typedef RevealProcessRunner =
    Future<int> Function(String executable, List<String> arguments);

Future<int> _runProcess(String executable, List<String> arguments) async =>
    (await Process.run(executable, arguments)).exitCode;

/// D32 §11's "Show in Finder / File Manager / Explorer" for local items:
/// opens the platform file manager with [path] selected.
///
/// - macOS: `open -R` (Finder reveal).
/// - Windows: `explorer /select,` (Explorer's exit code is 1 even on
///   success, so any launch counts).
/// - Linux: the freedesktop `org.freedesktop.FileManager1.ShowItems`
///   D-Bus call (Nautilus, Dolphin, Nemo, Thunar implement it), falling
///   back to `xdg-open` on the parent folder when no file manager owns
///   the name — the folder opens even if the item cannot be selected.
final class FileManagerRevealer {
  const FileManagerRevealer({RevealProcessRunner? run, String? operatingSystem})
    : _run = run ?? _runProcess,
      _os = operatingSystem;

  final RevealProcessRunner _run;
  final String? _os;

  String get _platform => _os ?? Platform.operatingSystem;

  /// Whether this platform can reveal at all.
  bool get supported => const {'macos', 'windows', 'linux'}.contains(_platform);

  /// Reveals [path]; true when a file manager was asked to show it.
  Future<bool> reveal(String path) async {
    try {
      switch (_platform) {
        case 'macos':
          return await _run('open', ['-R', path]) == 0;
        case 'windows':
          await _run('explorer', ['/select,', path]);
          return true;
        case 'linux':
          final uri = Uri.file(path).toString();
          final showItems = await _run('dbus-send', [
            '--session',
            '--print-reply',
            '--dest=org.freedesktop.FileManager1',
            '--type=method_call',
            '/org/freedesktop/FileManager1',
            'org.freedesktop.FileManager1.ShowItems',
            'array:string:$uri',
            'string:',
          ]);
          if (showItems == 0) return true;
          return await _run('xdg-open', [File(path).parent.path]) == 0;
      }
    } on ProcessException {
      return false;
    }
    return false;
  }
}
