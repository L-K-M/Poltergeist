import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 06 §5.1's `poltergeist/quicklook` method channel (03 §7.1's channel
/// naming): the macOS `QLPreviewPanel` surface Space drives. The Swift
/// side lives in `MainFlutterWindow.swift` — the window overrides
/// `acceptsPreviewPanelControl`/`beginPreviewPanelControl`/
/// `endPreviewPanelControl` and a `QLPreviewPanelDataSource` serves the
/// produced local paths.
abstract interface class QuickLookChannel {
  /// Whether the platform serves Quick Look at all — the seam's
  /// availability check, kept async so a plugin answer and a stub share
  /// one shape. Only macOS answers true in v1.
  Future<bool> isAvailable();

  /// Opens the panel on [paths][index] — every path must be a produced
  /// local file (remote items land in the preview cache first; the
  /// panel is only ever called with paths Quick Look can read).
  Future<void> showPreview(List<String> paths, int index);

  /// Selection changed while the panel is open: same contract as
  /// [showPreview] — the panel re-keys to the new item set.
  Future<void> updatePreview(List<String> paths, int index);

  /// Closes the panel. Idempotent.
  Future<void> hidePreview();

  /// The native panel's live visibility — Dart-side caching of this is
  /// the session's job (the panel can close itself on Esc, and the
  /// [onClosed] stream below is the same edge delivered proactively).
  Future<bool> isVisible();

  /// Fires when the panel closes by ANY native route (Esc inside the
  /// panel, the ✕, focus loss to another app). The session clears its
  /// Quick Look state on it — a production still in flight then
  /// completes silently into the cache (06 §5.1's close rule).
  Stream<void> get onClosed;
}

/// The production channel: `poltergeist/quicklook` over the window's
/// binary messenger. The native side emits a bare `closed` method call
/// as the close edge.
final class MethodChannelQuickLook implements QuickLookChannel {
  MethodChannelQuickLook() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closed') {
        _closed.add(null);
      }
    });
  }

  static const MethodChannel _channel = MethodChannel(
    'poltergeist/quicklook',
  );

  final _closed = StreamController<void>.broadcast();

  @override
  Future<bool> isAvailable() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      // A non-macOS host answered the channel lookup — honest absence.
      return false;
    }
  }

  @override
  Future<void> showPreview(List<String> paths, int index) =>
      _channel.invokeMethod<void>('showPreview', {
        'paths': paths,
        'index': index,
      });

  @override
  Future<void> updatePreview(List<String> paths, int index) =>
      _channel.invokeMethod<void>('updatePreview', {
        'paths': paths,
        'index': index,
      });

  @override
  Future<void> hidePreview() => _channel.invokeMethod<void>('hidePreview');

  @override
  Future<bool> isVisible() async =>
      await _channel.invokeMethod<bool>('isVisible') ?? false;

  @override
  Stream<void> get onClosed => _closed.stream;
}

/// The unsupported-platform seam (06 §5.1): every verb is an honest
/// no-op, `isAvailable`/`isVisible` answer false, and [onClosed] never
/// fires — the session's panel path needs no platform branches beyond
/// the availability check.
final class NoopQuickLookChannel implements QuickLookChannel {
  const NoopQuickLookChannel();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> showPreview(List<String> paths, int index) async {}

  @override
  Future<void> updatePreview(List<String> paths, int index) async {}

  @override
  Future<void> hidePreview() async {}

  @override
  Future<bool> isVisible() async => false;

  @override
  Stream<void> get onClosed => const Stream.empty();
}
