import 'dart:async';

import 'package:flutter/foundation.dart';

import 'quick_look_channel.dart';

/// The Quick Look surface for Linux and Windows (D32): the same
/// [QuickLookChannel] contract the macOS `QLPreviewPanel` serves, backed
/// by an in-window overlay instead of a native panel. The session drives
/// it exactly as it drives the native one (show, follow the selection,
/// hide), so remote productions, the §8 confirmation cards and the
/// stale-completion rules need no second code path.
///
/// The overlay reads [visible], [paths] and [index] and closes itself
/// through [close] — the user's own close, which fires [onClosed] like
/// the native panel's Esc or ✕. [hidePreview] is the session's close and
/// fires nothing: the session already knows.
final class InAppQuickLook extends ChangeNotifier implements QuickLookChannel {
  final _closed = StreamController<void>.broadcast();

  bool _visible = false;
  List<String> _paths = const [];
  int _index = 0;
  bool _disposed = false;

  /// Whether the overlay is up.
  bool get visible => _visible;

  /// The produced local files the overlay steps through — every path is
  /// readable here (remote items land in the preview cache first).
  List<String> get paths => _paths;

  /// The item the overlay shows within [paths].
  int get index => _index;

  /// The file on screen, or null while hidden.
  String? get currentPath =>
      _visible && _index >= 0 && _index < _paths.length ? _paths[_index] : null;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> showPreview(List<String> paths, int index) async {
    _show(paths, index);
  }

  @override
  Future<void> updatePreview(List<String> paths, int index) async {
    if (!_visible) return;
    _show(paths, index);
  }

  @override
  Future<void> hidePreview() async {
    if (!_visible || _disposed) return;
    _visible = false;
    notifyListeners();
  }

  @override
  Future<bool> isVisible() async => _visible;

  @override
  Stream<void> get onClosed => _closed.stream;

  /// The overlay's own close (its ✕, Esc or Space while it holds focus):
  /// hides and reports the close edge so the session clears its Quick
  /// Look state.
  void close() {
    if (!_visible || _disposed) return;
    _visible = false;
    notifyListeners();
    _closed.add(null);
  }

  void _show(List<String> paths, int index) {
    if (_disposed) return;
    _paths = List.unmodifiable(paths);
    _index = paths.isEmpty ? 0 : index.clamp(0, paths.length - 1);
    _visible = paths.isNotEmpty;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_closed.close());
    super.dispose();
  }
}
