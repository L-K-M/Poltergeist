import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../editor/built_in_text_document.dart';
import 'preview_kinds.dart';

/// The pane's text payload: [text] is the decoded window and
/// [truncated] marks a source longer than [previewTextMaximumBytes] —
/// the pane's "Preview truncated" affordance keys off it (06 §5.3).
final class PreviewTextContent {
  const PreviewTextContent(this.text, {required this.truncated});

  final String text;
  final bool truncated;
}

/// 06 §5.3's preview read path: loads at most the first
/// [previewTextMaximumBytes] of [file], truncating on a UTF-8 codepoint
/// boundary, stripping one leading BOM, normalizing nothing else — the
/// preview renders bytes as they are; line-ending and BOM preservation
/// are the editor's save-time concern.
///
/// Refusals reuse the §1 strings verbatim: a NUL byte anywhere in the
/// window reads as binary, and a strict-decode failure reads as
/// non-UTF-8. Both surface in the pane as a refusal card, never a
/// thrown-away error.
Future<PreviewTextContent> loadPreviewText(File file) async {
  final length = await file.length();
  final windowBytes = length > previewTextMaximumBytes
      ? previewTextMaximumBytes
      : length;
  final raf = await file.open();
  final Uint8List bytes;
  try {
    bytes = await raf.read(windowBytes);
  } finally {
    await raf.close();
  }
  final truncated = length > bytes.length;
  final window = truncated ? _clipToCodepointBoundary(bytes) : bytes;
  // A BOM anywhere but byte zero is a real U+FEFF; the editor's loader
  // strips a leading one, so the preview does the same.
  final body = _stripBom(window);
  final String text;
  try {
    text = utf8.decode(body, allowMalformed: false);
  } on FormatException {
    throw const BuiltInEditorException(
      'This file is not valid UTF-8 text.',
    );
  }
  if (text.contains('\x00')) {
    throw const BuiltInEditorException(
      'This file appears to be binary, not editable text.',
    );
  }
  return PreviewTextContent(text, truncated: truncated);
}

/// Whether [bytes] are plausibly previewable text — the
/// unknown-extension re-check (06 §5.3: a file whose name classified
/// [PreviewKind.metadata] still renders as text when its bytes are
/// valid non-NUL UTF-8). Reads at most the text window.
Future<bool> fileLooksLikeUtf8Text(File file) async {
  try {
    await loadPreviewText(file);
    return true;
  } on BuiltInEditorException {
    return false;
  }
}

/// A truncated window must not end mid-codepoint: drop a trailing
/// incomplete UTF-8 sequence (1–3 bytes) so the decode boundary is a
/// character boundary.
Uint8List _clipToCodepointBoundary(Uint8List bytes) {
  final end = bytes.length;
  // Walk back over continuation bytes (10xxxxxx); if we land on a
  // leading byte whose sequence would extend past `end`, the tail is
  // incomplete and gets clipped.
  var continuation = 0;
  while (end - 1 - continuation >= 0 &&
      (bytes[end - 1 - continuation] & 0xC0) == 0x80 &&
      continuation < 3) {
    continuation++;
  }
  if (continuation == 0) return bytes;
  final leadIndex = end - 1 - continuation;
  final lead = bytes[leadIndex];
  final expected = _sequenceLength(lead);
  if (expected > 0 && leadIndex + expected > end) {
    return Uint8List.sublistView(bytes, 0, leadIndex);
  }
  return bytes;
}

int _sequenceLength(int lead) {
  if (lead & 0x80 == 0) return 1;
  if (lead & 0xE0 == 0xC0) return 2;
  if (lead & 0xF0 == 0xE0) return 3;
  if (lead & 0xF8 == 0xF0) return 4;
  return 0; // stray continuation byte — the strict decode refuses anyway
}

Uint8List _stripBom(Uint8List bytes) {
  const bom = [0xEF, 0xBB, 0xBF];
  if (bytes.length >= 3 &&
      bytes[0] == bom[0] &&
      bytes[1] == bom[1] &&
      bytes[2] == bom[2]) {
    return Uint8List.sublistView(bytes, 3);
  }
  return bytes;
}
