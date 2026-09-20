import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

import '../checkout/managed_remote_file_store.dart' show streamedFileSha256;
import '../fs/local_fs_safety.dart';

// Ported from Séance
// app/seance_app/lib/ui/built_in_text_editor.dart @ 2e6d1f1 (the pure
// document-I/O layer — load/save and the size cap); see docs/PORTS.md.

/// The built-in editor's hard size limit (06 §1, D17): UTF-8 text up to
/// 4 MiB — a config-file editor, not a general-purpose one.
const int builtInEditorMaximumBytes = 4 * 1024 * 1024;

/// The dominant line-ending family a document was loaded with (06 §2.1):
/// `\r\n` count vs lone-`\n` count, majority vote. Ties and break-free
/// files resolve to [lf] — a single-line file must never grow CRLF.
enum LineEnding { lf, crlf }

/// One loaded document (06 §2.1). The in-memory invariant is always
/// LF line endings and no BOM; [hasUtf8Bom] and [lineEnding] record the
/// disk form so a save can reconstruct it.
final class BuiltInTextDocument {
  /// The decoded text: LF-folded, BOM stripped.
  final String text;

  /// Whether the disk bytes started with a UTF-8 BOM.
  final bool hasUtf8Bom;

  /// The majority line-ending family of the raw decoded text.
  final LineEnding lineEnding;

  /// The post-read digest — the save's `expectedSha256` baseline.
  final String sha256;

  const BuiltInTextDocument({
    required this.text,
    required this.hasUtf8Bom,
    required this.lineEnding,
    required this.sha256,
  });
}

/// A refusal or conflict the document layer raises (06 §1/§2.1). Every
/// message is an exact §1 string that surfaces verbatim in the editor's
/// error body and the save toast — [toString] returns the bare message
/// with no `Exception:`/`Bad state:` prefix (06 §2.4's toast contract,
/// a deliberate divergence from Séance's `StateError`).
final class BuiltInEditorException implements Exception {
  const BuiltInEditorException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A checkout refused for exceeding the caller's byte cap (06 §3.2) —
/// raised on the known-size preflight, the unknown-size stream abort,
/// and the post-download length check alike. The message is user-facing
/// (the open-in-editor flow toasts it), so [toString] returns it bare.
final class CheckoutLimitException implements Exception {
  const CheckoutLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _tooLargeMessage(int maximumBytes) =>
    'The built-in editor supports text files up to '
    '${(maximumBytes / (1024 * 1024)).toStringAsFixed(0)} MB.';

/// Resolves a symlinked local target once at open (06 §2.1 step 2): the
/// editor and the save dance operate on the real file so the link is
/// never replaced by a regular file. Non-links return unchanged; a
/// dangling or non-file resolution fails in the loader, not here.
Future<File> resolveBuiltInEditorTarget(File file) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    return File(await file.resolveSymbolicLinks());
  }
  return file;
}

Future<String> loadBuiltInTextDocument(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
  Future<String> Function(File file)? sha256Of,
}) async => (await loadBuiltInTextDocumentDetails(
  file,
  maximumBytes: maximumBytes,
  sha256Of: sha256Of,
)).text;

/// Loads [file] into the LF/no-BOM in-memory form (06 §2.1), refusing
/// with the exact §1 strings: over-cap on both the declared length and
/// the bytes actually read, changed-while-open on the streamed digest
/// pair, invalid UTF-8 under a strict decode, and binary on a NUL byte.
Future<BuiltInTextDocument> loadBuiltInTextDocumentDetails(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
  Future<String> Function(File file)? sha256Of,
}) async {
  final digestOf = sha256Of ?? streamedFileSha256;
  final length = await file.length();
  if (length > maximumBytes) {
    throw BuiltInEditorException(_tooLargeMessage(maximumBytes));
  }
  final before = await digestOf(file);
  final bytes = await file.readAsBytes();
  if (bytes.length > maximumBytes) {
    throw BuiltInEditorException(_tooLargeMessage(maximumBytes));
  }
  final after = await digestOf(file);
  if (before != after) {
    throw const BuiltInEditorException(
      'The local copy changed while it was being opened.',
    );
  }
  final hasUtf8Bom =
      bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  late final String raw;
  try {
    // The BOM is stripped on BYTES before decode — not after: a U+FEFF
    // elsewhere in the payload is content and survives (and Dart's
    // decoder skips a leading BOM itself, so a substring on the decoded
    // text would eat a real character).
    raw = const Utf8Decoder(
      allowMalformed: false,
    ).convert(hasUtf8Bom ? bytes.sublist(3) : bytes);
  } on FormatException {
    throw const BuiltInEditorException('This file is not valid UTF-8 text.');
  }
  if (raw.contains('\u0000')) {
    throw const BuiltInEditorException(
      'This file appears to be binary, not editable text.',
    );
  }
  // Detection runs on the RAW decoded text (BOM stripped — it is not
  // content), then the in-memory invariant folds CRLF and lone CR to
  // LF. Detecting after the fold would let lone-LF always win (06 §2.1).
  final crlfCount = RegExp(r'\r\n').allMatches(raw).length;
  final lfCount = RegExp(r'(?<!\r)\n').allMatches(raw).length;
  return BuiltInTextDocument(
    text: raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
    hasUtf8Bom: hasUtf8Bom,
    lineEnding: crlfCount > lfCount ? LineEnding.crlf : LineEnding.lf,
    sha256: after,
  );
}

/// Saves [text] to [file] through the atomic two-sibling dance
/// (06 §2.1, ported step-for-step):
///
/// 1. Exclusive-create `.poltergeist-<uuid>.edit` and chmod it 0600 on
///    POSIX BEFORE any plaintext byte lands — at umask 0644 the content
///    would sit group/world-readable for the whole write/flush/close/SHA
///    sequence, and a crash would strand a world-readable temp the D15
///    ignore rules hide from listings. Write, flush, close, SHA it — the
///    digest is the return value and the next baseline.
/// 2. Verify the target is still a regular file (`followLinks: false` —
///    a symlinked target reports `link` and the dance refuses rather
///    than replace the link with a regular file).
/// 3. `rename(file → .poltergeist-<uuid>.backup)`, then SHA the backup
///    against [expectedSha256]; a mismatch means another program wrote
///    the file — rename back and throw the conflict string.
/// 4. Verify nothing re-created the target mid-save; re-apply the
///    original file's mode to the temp (step 1's 0600 must not tighten
///    a 0644 original); `rename(temp → file)`; restore the backup on
///    failure.
/// 5. Delete the backup, tolerating failure — a stray beats a false
///    save failure; inside checkout dirs the store's reconcile sweep
///    reaps the `.poltergeist-*` shapes.
/// 6. `finally`: close any open handle, delete a leftover temp. The
///    size cap is re-checked on the encoded output.
Future<String> saveBuiltInTextDocument(
  File file,
  String text, {
  bool hasUtf8Bom = false,
  LineEnding lineEnding = LineEnding.lf,
  String? expectedSha256,

  /// Test seam: observes the exclusive-created temp before step 3 —
  /// the only window where its 0600 mode is observable before step 4
  /// restores the original mode.
  Future<void> Function(File temporary)? observeTemporary,
}) async {
  final normalized = _normalizeLineEndings(text, lineEnding);
  final bytes = <int>[
    if (hasUtf8Bom) ...const [0xef, 0xbb, 0xbf],
    ...utf8.encode(normalized),
  ];
  if (bytes.length > builtInEditorMaximumBytes) {
    throw const BuiltInEditorException(
      'The edited file exceeds the 4 MB built-in editor limit.',
    );
  }
  final temporary = File('${file.path}.poltergeist-${uuidV4()}.edit');
  final backup = File('${file.path}.poltergeist-${uuidV4()}.backup');
  RandomAccessFile? handle;
  try {
    await temporary.create(exclusive: true);
    // Owner-only BEFORE the first plaintext byte (06 §2.1 step 1).
    await restrictLocalPathPermissions(temporary.path, '600');
    handle = await temporary.open(mode: FileMode.writeOnly);
    await handle.writeFrom(bytes);
    await handle.flush();
    await handle.close();
    handle = null;
    final savedSha256 = await streamedFileSha256(temporary);
    await observeTemporary?.call(temporary);

    final stat = await FileStat.stat(file.path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const BuiltInEditorException(
        'The local copy is a symbolic link, not a regular file.',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw const BuiltInEditorException(
        'The local copy is missing or no longer a regular file.',
      );
    }
    await file.rename(backup.path);
    if (expectedSha256 != null) {
      final String backupSha256;
      try {
        backupSha256 = await streamedFileSha256(backup);
      } catch (_) {
        // The digest read is part of the guard window — a failure here
        // must still restore the original, not leave it stranded at the
        // backup path (the reconcile sweep reaps `.poltergeist-*`).
        await backup.rename(file.path);
        rethrow;
      }
      if (backupSha256 != expectedSha256) {
        await backup.rename(file.path);
        throw const BuiltInEditorException(
          'The local copy changed in another editor. Reopen it before '
          'saving to avoid losing those changes.',
        );
      }
    }
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const BuiltInEditorException(
          'The local copy changed while it was being saved.',
        );
      }
      // Restore the ORIGINAL mode on the temp before it lands: the
      // step-1 0600 must not silently tighten a laxer original (06 §2.1
      // step 4).
      await _restoreFileMode(temporary.path, stat.mode);
      await temporary.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
    try {
      await backup.delete();
    } on FileSystemException {
      // The new file is safely committed; retaining a backup is
      // preferable to rolling back or reporting a false save failure.
    }
    return savedSha256;
  } finally {
    await handle?.close();
    if (await temporary.exists()) await temporary.delete();
  }
}

/// Re-applies the ORIGINAL file's permission bits to the temp sibling
/// (06 §2.1 step 4): the low 9 bits of the stat mode, rendered as the
/// octal `chmod` accepts. Windows/unsupported stat modes degrade to the
/// step-1 0600 — owner-only is never loosened there.
Future<void> _restoreFileMode(String path, int mode) async {
  if (!Platform.isLinux && !Platform.isMacOS) return;
  final bits = mode & 0x1ff;
  await restrictLocalPathPermissions(path, bits.toRadixString(8));
}

/// The save-time normalization (06 §2.1): fold CRLF AND surviving lone
/// CR to LF, then expand to CRLF only for a CRLF-family document —
/// a `\r\n`-only fold could not produce the pinned lone-`\r` outcome.
String _normalizeLineEndings(String text, LineEnding lineEnding) {
  final folded = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (lineEnding != LineEnding.crlf) return folded;
  return folded.replaceAll('\n', '\r\n');
}

/// The §3.2 stream cap for unknown-size checkout downloads (the ported
/// `_MaximumByteSink`): counts forwarded bytes and throws the moment the
/// running total passes [maximumBytes], so a remote file whose listing
/// entry carried no size aborts at the limit instead of downloading in
/// full to a certain refusal.
final class MaximumByteSink implements StreamSink<List<int>> {
  MaximumByteSink(this._inner, {required this.maximumBytes});

  final StreamSink<List<int>> _inner;
  final int maximumBytes;
  int _written = 0;

  void _count(List<int> event) {
    _written += event.length;
    if (_written > maximumBytes) {
      throw CheckoutLimitException(
        'The file is larger than the $maximumBytes-byte '
        'editor limit.',
      );
    }
  }

  @override
  void add(List<int> event) {
    _count(event);
    _inner.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.map((event) {
      _count(event);
      return event;
    }),
  );

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}
