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
/// - Windows: `explorer.exe /select,"<path>"` (Explorer's exit code is 1
///   even on success, so any launch counts).
/// - Linux: the freedesktop `org.freedesktop.FileManager1.ShowItems`
///   D-Bus call (Nautilus, Dolphin, Nemo, Thunar implement it), falling
///   back to opening the parent folder with `xdg-open`, then `gio open`,
///   when no file manager owns the name or a tool is missing; the folder
///   opens even if the item cannot be selected.
final class FileManagerRevealer {
  const FileManagerRevealer({RevealProcessRunner? run, String? operatingSystem})
    : _run = run ?? _runProcess,
      _os = operatingSystem;

  final RevealProcessRunner _run;
  final String? _os;

  String get _platform => _os ?? Platform.operatingSystem;

  /// Whether this platform can reveal at all.
  bool get supported => const {'macos', 'windows', 'linux'}.contains(_platform);

  /// Reveals [path]; true when a file manager was asked to show it, false
  /// when every route failed, so the caller can say so rather than doing
  /// nothing.
  Future<bool> reveal(String path) async {
    switch (_platform) {
      case 'macos':
        return await _exitsCleanly('open', ['-R', path]);
      case 'windows':
        // Explorer parses its own command line and splits the /select
        // target on commas unless it is quoted. Dart escapes a quote
        // inside an argument for the C runtime (\"), which Explorer does
        // not understand, but it passes the executable string to
        // CreateProcessW verbatim once that string contains a quote, so
        // the whole line rides there. Windows file names cannot contain
        // `"`, so the quoting is always sound.
        return await _launches('explorer.exe /select,"$path"', const []);
      case 'linux':
        return await _showItems(path) ||
            await _exitsCleanly('xdg-open', [File(path).parent.path]) ||
            await _exitsCleanly('gio', ['open', File(path).parent.path]);
    }
    return false;
  }

  Future<bool> _showItems(String path) {
    // dbus-send splits `array:string:` values on commas and has no
    // escape, so a comma in the name is percent-encoded: the same file
    // URI, and one item instead of two that do not exist.
    final uri = Uri.file(path).toString().replaceAll(',', '%2C');
    return _exitsCleanly('dbus-send', [
      '--session',
      '--print-reply',
      '--dest=org.freedesktop.FileManager1',
      '--type=method_call',
      '/org/freedesktop/FileManager1',
      'org.freedesktop.FileManager1.ShowItems',
      'array:string:$uri',
      'string:',
    ]);
  }

  /// Whether [executable] ran and exited 0; a missing tool is a failed
  /// step, never the end of the fallback chain.
  Future<bool> _exitsCleanly(String executable, List<String> arguments) async {
    try {
      return await _run(executable, arguments) == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Whether [executable] started at all, whatever it exits with.
  Future<bool> _launches(String executable, List<String> arguments) async {
    try {
      await _run(executable, arguments);
      return true;
    } on ProcessException {
      return false;
    }
  }
}
