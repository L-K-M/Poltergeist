import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../panes/pane_format.dart';

/// The activity panel's transfer formatting (02 §5.3/§6): rates, ETAs,
/// route text, and the throttle popover's custom-rate parser. String
/// literals here are technical (units, separators, regex grammar) —
/// reviewed per file in the localization contract; authored copy lives
/// in the ARB.

/// The throttle popover's ceiling for a custom rate (02 §6's "bounded
/// input"): 10 GB/s is far past any link the app will see; larger
/// entries are rejected inline, never silently clamped.
const maxTransferRateBytesPerSecond = 10 * 1000 * 1000 * 1000;

/// A smoothed rate as "2.3 MB/s" — the row, footer, and status chip's
/// speed text. The `/s` suffix is machine grammar, not copy.
String formatTransferRate(
  double bytesPerSecond, {
  required TargetPlatform platform,
}) =>
    '${formatPaneSize(bytesPerSecond.round(), platform: platform)}/s';

/// One configured limit as the chip/popover shows it: the pane size
/// format plus the rate suffix; null (unlimited) renders the header
/// button's ∞ glyph — callers substitute the localized label there.
String formatTransferLimit(
  int bytesPerSecond, {
  required TargetPlatform platform,
}) =>
    '${formatPaneSize(bytesPerSecond, platform: platform)}/s';

/// ETA text (02 §5.3): compact, one-decimal-free, capped at days —
/// "45s", "4m 20s", "1h 3m", "2d 5h". The unit glyphs are technical
/// formatting, allowlisted in the localization contract.
String formatTransferEta(Duration eta) {
  var seconds = eta.inSeconds;
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ${seconds % 60}s';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}h ${minutes % 60}m';
  return '${hours ~/ 24}d ${hours % 24}h';
}

/// The custom-rate field's grammar (02 §6): a number optionally followed
/// by a byte unit (B, KB, MB, GB, TB — decimal like the size formatter)
/// and an optional `/s`. A bare number means bytes per second. Returns
/// bytes/sec, or null on anything the grammar does not cover — the
/// popover renders that as an inline error and never clamps.
int? parseTransferRate(String input) {
  final match = _ratePattern.firstMatch(input.trim());
  if (match == null) return null;
  final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  if (value == null || value <= 0) return null;
  final unit = match.group(2)?.toLowerCase();
  final multiplier = switch (unit) {
    null || '' || 'b' => 1,
    'k' || 'kb' => 1000,
    'm' || 'mb' => 1000 * 1000,
    'g' || 'gb' => 1000 * 1000 * 1000,
    't' || 'tb' => 1000 * 1000 * 1000 * 1000,
    _ => -1,
  };
  if (multiplier < 0) return null;
  // Reject before rounding: an over-range literal saturates the
  // product to Infinity, and Infinity.round() throws — an invalid
  // entry must surface the inline error, never crash or clamp.
  final product = value * multiplier;
  if (!product.isFinite || product > maxTransferRateBytesPerSecond) {
    return null;
  }
  final bytes = product.round();
  if (bytes <= 0) return null;
  return bytes;
}

final _ratePattern = RegExp(
  r'^(\d+(?:[.,]\d+)?)\s*([kmgt]?i?b)?(?:\s*/\s*s)?$',
  caseSensitive: false,
);

/// The leaf name of a source/destination path — task titles and item
/// rows. Handles both separators (a Windows local path on any host) and
/// a trailing separator (a root like `/`).
String pathBasename(String path) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith('\\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final slash = trimmed.lastIndexOf('/');
  final backslash = trimmed.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  if (cut < 0) return trimmed;
  return trimmed.substring(cut + 1);
}

/// The parent portion of [path], or null at a root. Display-side
/// arithmetic only — routing decisions keep the task's own paths.
String? pathDirname(String path) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith('\\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final slash = trimmed.lastIndexOf('/');
  final backslash = trimmed.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  if (cut <= 0) return cut == 0 ? trimmed.substring(0, 1) : null;
  return trimmed.substring(0, cut);
}

/// The longest shared parent directory across [paths] — the multi-root
/// route line's source side (a task's roots share a gesture, not
/// necessarily a directory).
String commonParentPath(List<String> paths) {
  if (paths.isEmpty) return '';
  // Seed with the first path itself — when it parents the rest it IS
  // the shared root, and seeding one level up would lose it.
  var candidate = paths.first;
  for (final path in paths.skip(1)) {
    // Ascend the candidate until it is an ancestor directory of this
    // path (prefix comparison on a separator boundary). The root is
    // an ancestor of every absolute path — '/a/' never starts with
    // '//', so it needs the explicit case.
    while (candidate.isNotEmpty &&
        !(candidate == '/' || '$path/'.startsWith('$candidate/')) &&
        path != candidate) {
      final parent = pathDirname(candidate);
      if (parent == null || parent == candidate) {
        candidate = '';
        break;
      }
      candidate = parent;
    }
  }
  return candidate;
}

/// A task's endpoint label for the `source → destination` line: the
/// localized "This computer" for a local side, the server id otherwise
/// (the bookmark label lookup rides the Connections surface; the id is
/// the honest fallback a task can always show).
String transferEndpointLabel(
  FsLocation location, {
  required String localLabel,
}) =>
    switch (location) {
      LocalFsLocation() => localLabel,
      ServerFsLocation(:final serverId) => serverId,
    };

/// The `source → destination` route text (02 §6's row grammar): each
/// endpoint's display path prefixed by its endpoint name. A multi-root
/// source collapses to the shared parent; a delete's destination is the
/// common parent (or remote trash run dir) the spec records.
String formatTransferRoute(
  TransferTask task, {
  required String localLabel,
}) {
  final sourcePath = task.rootPaths.length == 1
      ? task.rootPaths.first
      : commonParentPath(task.rootPaths);
  final source =
      '${transferEndpointLabel(task.source, localLabel: localLabel)}:'
      ' $sourcePath';
  final destination =
      '${transferEndpointLabel(task.destination, localLabel: localLabel)}:'
      ' ${task.destinationDir}';
  return '$source → $destination';
}
