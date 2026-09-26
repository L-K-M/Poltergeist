import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 06 §5.1's `poltergeist/quicklook` method channel (03 §7.1's channel
/// naming): the macOS `QLPreviewPanel` surface Space drives. The Swift
/// side lives in `QuickLookHost.swift` — every workspace window answers
/// `acceptsPreviewPanelControl`/`beginPreviewPanelControl`/
/// `endPreviewPanelControl` through it, and it serves the produced local
/// paths as the `QLPreviewPanelDataSource`.
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

/// The production channel: `poltergeist/quicklook` over the engine's
/// binary messenger, one per workspace window (00 D39).
///
/// There is one panel for the app, and whichever window last showed
/// something owns it: every call carries the caller's `viewId`, the
/// native side answers `isVisible` true only to the owner, ignores a
/// `hidePreview` from any other window, and reports the close edge as
/// `closed` with the owner's `viewId`, including when another window takes
/// the panel over. The channel has one handler, so the instances share it
/// and route each `closed` to theirs.
final class MethodChannelQuickLook implements QuickLookChannel {
  MethodChannelQuickLook({this.viewId = 0}) {
    if (_open.isEmpty) _channel.setMethodCallHandler(_handle);
    _open[viewId] = this;
  }

  static const MethodChannel _channel = MethodChannel(
    'poltergeist/quicklook',
  );

  /// The open instances by view: the one `closed` goes to.
  static final _open = <int, MethodChannelQuickLook>{};

  static Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'closed') return null;
    final arguments = call.arguments;
    final viewId = arguments is Map ? arguments['viewId'] : null;
    // A runner without view ids closes the main window's session.
    _open[viewId is int ? viewId : 0]?._closed.add(null);
    return null;
  }

  /// The workspace window's view this instance drives the panel for.
  final int viewId;

  final _closed = StreamController<void>.broadcast();

  /// Stops routing `closed` here: the window's shell is gone.
  void dispose() {
    if (identical(_open[viewId], this)) _open.remove(viewId);
    if (_open.isEmpty) _channel.setMethodCallHandler(null);
    _closed.close();
  }

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
        'viewId': viewId,
        'paths': paths,
        'index': index,
      });

  @override
  Future<void> updatePreview(List<String> paths, int index) =>
      _channel.invokeMethod<void>('updatePreview', {
        'viewId': viewId,
        'paths': paths,
        'index': index,
      });

  @override
  Future<void> hidePreview() =>
      _channel.invokeMethod<void>('hidePreview', {'viewId': viewId});

  @override
  Future<bool> isVisible() async =>
      await _channel.invokeMethod<bool>('isVisible', {'viewId': viewId}) ??
      false;

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
