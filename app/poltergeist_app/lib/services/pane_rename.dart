import 'package:flutter/foundation.dart';

/// Why a typed inline-rename name was rejected (02 §2.6).
///
/// The three shapes the field checks before the engine call:
/// [empty] covers a blank or whitespace-only input, [separator] covers a
/// name containing the listing's path separator `/`, and [invalid]
/// covers characters the pane's filesystem family forbids — a local pane
/// on Windows rejects the NTFS set (`<>:"\|?*` and control characters),
/// the DOS device names, and a trailing dot or space, rather than
/// letting the engine fail the request — while a remote pane stays
/// POSIX-permissive because an SFTP server may accept names the client's
/// OS would not.
enum RenameNameError { empty, separator, invalid }

/// Validates one typed inline-rename name.
///
/// Returns null for an acceptable name. [remote] keeps remote panes on
/// the POSIX rule set (only empty and `/` are rejected); [platform]
/// decides which local rules apply — Windows adds the NTFS forbidden
/// set, the DOS device names, and a trailing dot or space. Callers pass
/// the typed string untrimmed: leading/trailing spaces are legal POSIX
/// names (Windows alone rejects a trailing one), so only an
/// all-whitespace input counts as [RenameNameError.empty].
RenameNameError? renameNameError(
  String name, {
  required bool remote,
  required TargetPlatform platform,
}) {
  if (name.trim().isEmpty) return RenameNameError.empty;
  if (name.contains('/')) return RenameNameError.separator;
  if (!remote && platform == TargetPlatform.windows) {
    if (name.contains(_windowsForbidden) ||
        name.codeUnits.any(_isControl) ||
        _windowsReserved.hasMatch(name) ||
        name.endsWith('.') ||
        name.endsWith(' ')) {
      return RenameNameError.invalid;
    }
  }
  return null;
}

final _windowsForbidden = RegExp(r'[<>:"\\|?*]');

/// The DOS device names Win32 reserves with or without an extension —
/// `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`. Suffix
/// digits past 9 (`COM10`) and longer stems (`console`) are ordinary
/// names.
final _windowsReserved = RegExp(
  r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
  caseSensitive: false,
);

bool _isControl(int unit) => unit < 0x20 || unit == 0x7F;
