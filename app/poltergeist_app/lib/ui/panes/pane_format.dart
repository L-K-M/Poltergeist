import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:intl/intl.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show RemoteFileEntry, RemoteFileType;

/// Presentation formatting for pane rows (02 §2.3's rendering rules,
/// foundation subset). The literals here are technical (units, the
/// unevaluated dash), reviewed per file in the localization contract.
const _byteUnits = ['B', 'KB', 'MB', 'GB', 'TB'];
const _unevaluated = '—';

/// The shared "no value" glyph (02 §2.3's unevaluated dash) for surfaces
/// beyond the row formatter — the Get Info inspector renders absent VFS
/// metadata with the same dash the listing uses.
const paneUnevaluated = _unevaluated;

/// Decimal size for macOS/Linux, binary for Windows — the platform file
/// managers' convention (02 §2.3). The Linux decimal/binary preference
/// setting lands with the settings slice.
String formatPaneSize(int? bytes, {required TargetPlatform platform}) {
  if (bytes == null) return _unevaluated;
  final divisor = platform == TargetPlatform.windows ? 1024.0 : 1000.0;
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= divisor && unit < _byteUnits.length - 1) {
    value /= divisor;
    unit++;
  }
  if (unit == 0) return '$bytes ${_byteUnits[0]}';
  // Round numerically first so renormalization never depends on parsing
  // the formatted text (a later locale-aware formatter must not be able
  // to break the loop on comma decimals).
  double rounded() => value >= 10
      ? value.roundToDouble()
      : (value * 10).roundToDouble() / 10;
  var text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  // Rounding can push the mantissa back up to the divisor (999.999 KB
  // rounds to "1000 KB"); renormalize so a boundary value renders as
  // the next unit, like Finder/Explorer.
  while (rounded() >= divisor && unit < _byteUnits.length - 1) {
    unit++;
    value /= divisor;
    text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  }
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_byteUnits[unit]}';
}

/// Modified-time text: relative for today/yesterday, absolute otherwise
/// (02 §2.3). Links and unevaluated sizes carry null metadata — the dash.
String formatPaneModified(
  DateTime? modified, {
  required DateTime now,
  required String localeName,
  required String Function(String time) today,
  required String Function(String time) yesterday,
}) {
  if (modified == null) return _unevaluated;
  final localModified = modified.toLocal();
  final localNow = now.toLocal();
  final dayStart = DateTime(localNow.year, localNow.month, localNow.day);
  final time = DateFormat.jm(localeName).format(localModified);
  if (!localModified.isBefore(dayStart)) {
    // Same calendar day → "today"; genuinely future mtimes (clock skew,
    // migrated archives) fall through to the absolute format rather
    // than reading as today.
    final nextDayStart = DateTime(
      localNow.year,
      localNow.month,
      localNow.day + 1,
    );
    return localModified.isBefore(nextDayStart)
        ? today(time)
        : DateFormat.yMd(localeName).add_jm().format(localModified);
  }
  // Calendar-day arithmetic, not 24-hour subtraction: across a DST
  // transition, midnight minus 24h lands at 23:00 or 01:00 of the
  // previous day (Dart normalizes out-of-range day components).
  if (!localModified
      .isBefore(DateTime(localNow.year, localNow.month, localNow.day - 1))) {
    return yesterday(time);
  }
  return DateFormat.yMd(localeName)
      .add_jm()
      .format(localModified);
}

/// The `ls -l` symbolic rendering of a POSIX mode's permission bits
/// (02 §2.6's read-only rwx display): nine positions — user, group,
/// other — with suid/sgid/sticky folded into the execute slots the
/// standard way (s/S, s/S, t/T). The mode's file-type bits are ignored;
/// the kind column already names them. Char codes, not literals, keep
/// the localization contract free of glyph plumbing.
String formatPosixModeSymbolic(int mode) {
  final out = StringBuffer();
  const shifts = [6, 3, 0];
  const specials = [0x800, 0x400, 0x200];
  for (var triplet = 0; triplet < 3; triplet++) {
    final bits = (mode >> shifts[triplet]) & 7;
    out.writeCharCode((bits & 4) != 0 ? 0x72 : 0x2D); // r or -
    out.writeCharCode((bits & 2) != 0 ? 0x77 : 0x2D); // w or -
    final execute = (bits & 1) != 0;
    if ((mode & specials[triplet]) == 0) {
      out.writeCharCode(execute ? 0x78 : 0x2D); // x or -
    } else if (triplet == 2) {
      out.writeCharCode(execute ? 0x74 : 0x54); // t or T
    } else {
      out.writeCharCode(execute ? 0x73 : 0x53); // s or S
    }
  }
  return out.toString();
}

/// The mode's permission bits as four-digit octal (02 §2.6's octal
/// display): 0755, 0644, 4755 — the leading digit carries suid/sgid/
/// sticky, so nothing the symbolic render folded into its slots is lost.
String formatPosixModeOctal(int mode) =>
    (mode & 0xFFF).toRadixString(8).padLeft(4, '0');

/// The listing's kind-glyph families (D32 §6: "kind glyphs are tinted
/// by category"). A glyph is a sighted-user hint only — the announced
/// kind stays the entry's file type (02 §13), so a wrong guess from an
/// extension never misleads assistive tech.
enum PaneKindCategory { folder, link, image, text, archive, pdf, media, other }

// Extension families, lowercase, one space-separated table per family —
// machine data the classifier splits once, never rendered.
const _imageExtensions =
    'png jpg jpeg gif webp bmp tif tiff heic heif svg ico avif psd raw';
const _textExtensions =
    'txt md markdown rst log csv tsv json yaml yml toml xml html htm css';
const _codeExtensions =
    'scss js mjs ts jsx tsx dart py rb go rs java kt swift c h cc cpp hpp';
const _scriptExtensions =
    'm mm cs php sh bash zsh fish ps1 bat sql ini conf cfg env lock';
const _archiveExtensions =
    'zip tar gz tgz bz2 xz 7z rar zst lz4 dmg iso deb rpm pkg jar apk';
const _mediaExtensions =
    'mp3 wav flac aac ogg m4a opus mp4 mov mkv avi webm m4v wmv mpg';

Set<String> _extensionSet(List<String> tables) => {
  for (final table in tables) ...table.split(' '),
};

final _categoryByExtension = <String, PaneKindCategory>{
  for (final ext in _extensionSet([_imageExtensions]))
    ext: PaneKindCategory.image,
  for (final ext in _extensionSet([
    _textExtensions,
    _codeExtensions,
    _scriptExtensions,
  ]))
    ext: PaneKindCategory.text,
  for (final ext in _extensionSet([_archiveExtensions]))
    ext: PaneKindCategory.archive,
  for (final ext in _extensionSet([_mediaExtensions]))
    ext: PaneKindCategory.media,
  'pdf': PaneKindCategory.pdf,
};

/// The kind-glyph family for [entry]: its file type first (folders and
/// links are never guessed from a name), then the lowercase extension
/// after the last dot — a leading dot is part of a dotfile's stem, so
/// `.bashrc` has no extension and reads as a generic file.
PaneKindCategory paneKindCategory(RemoteFileEntry entry) {
  switch (entry.type) {
    case RemoteFileType.directory:
      return PaneKindCategory.folder;
    case RemoteFileType.symbolicLink:
      return PaneKindCategory.link;
    case RemoteFileType.file || RemoteFileType.other:
      break;
  }
  final name = entry.name;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return PaneKindCategory.other;
  final extension = name.substring(dot + 1).toLowerCase();
  return _categoryByExtension[extension] ?? PaneKindCategory.other;
}
