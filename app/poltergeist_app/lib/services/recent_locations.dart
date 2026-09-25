import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'bookmark_landing_path.dart';
import 'pane_location.dart';
import 'settings_store.dart';

/// One remembered browsing destination for Quick Open's Recents
/// section (02 §8.4): a local folder or a remote bookmark's path,
/// deduplicated by location and ordered most-recent-first.
final class RecentLocation {
  const RecentLocation.local({required this.label, required this.path})
    : serverId = null,
      remoteBookmark = null;

  const RecentLocation.remote({
    required this.label,
    required this.path,
    required this.serverId,
    required this.remoteBookmark,
  });

  /// The row's primary text: the remote's bookmark label, the local
  /// path's last segment.
  final String label;

  /// The bound path (a remote path is POSIX even on Windows).
  final String path;

  /// The remote's server identity (the bookmark's id) — null for a
  /// local folder.
  final String? serverId;

  /// The bookmark snapshot at record time. Open re-resolves the live
  /// bookmark by [serverId] first; the snapshot is the fallback for a
  /// favorite deleted since (connectRemote accepts it verbatim).
  final Bookmark? remoteBookmark;

  bool get isRemote => serverId != null;

  /// The dedupe key: a remote path on two servers is two recents.
  String get dedupeKey => isRemote ? 'remote:$serverId:$path' : 'local:$path';

  Map<String, Object?> toJson() => {
    'label': label,
    'path': path,
    if (serverId != null) 'serverId': serverId,
    if (remoteBookmark != null)
      'bookmark': withRemoteLandingPath(remoteBookmark!.toJson()),
  };

  /// Tolerant decode: a malformed entry reports through the caller's
  /// load path and drops out rather than failing the whole document
  /// (the same fail-closed posture the session document takes).
  factory RecentLocation.fromJson(Map<String, Object?> json) {
    final label = json['label'];
    final path = json['path'];
    if (label is! String || path is! String) {
      throw const FormatException('recent location entry');
    }
    final serverId = json['serverId'];
    if (serverId == null) {
      return RecentLocation.local(label: label, path: path);
    }
    if (serverId is! String) {
      throw const FormatException('recent location serverId');
    }
    final bookmarkJson = json['bookmark'];
    final bookmark = bookmarkJson is Map
        ? Bookmark.fromJson(
            withRemoteLandingPath(bookmarkJson.cast<String, dynamic>()),
            recordId: 'bookmark:$serverId',
          )
        : null;
    return RecentLocation.remote(
      label: label,
      path: path,
      serverId: serverId,
      remoteBookmark: bookmark,
    );
  }
}

/// The device-local recents list (02 §8.4): capped at [maxEntries],
/// newest first, persisted as one versioned document inside the shared
/// settings.json. Writes are debounced — a navigation burst costs one
/// write — and [flush] is the quit safe point. A malformed or
/// newer-schema document decodes to an empty list and is never
/// overwritten unread (the store's read-before-write keeps it).
final class RecentLocationsStore extends ChangeNotifier {
  RecentLocationsStore({
    required this._store,
    this._saveDelay = _defaultSaveDelay,
    void Function() Function(Duration, Future<void> Function())?
    scheduleDebounce,
    this._onError,
  }) : _scheduleDebounce = scheduleDebounce ?? _timerDebounce;

  static const String settingsKey = 'quickOpen.recentLocations';
  static const int maxEntries = 100;
  static const _schemaVersion = 1;
  static const _defaultSaveDelay = Duration(milliseconds: 400);

  final SettingsStore _store;
  final Duration _saveDelay;
  final void Function() Function(Duration, Future<void> Function())
  _scheduleDebounce;
  final void Function(Object, StackTrace)? _onError;

  final _entries = <RecentLocation>[];
  void Function()? _cancelScheduled;
  Future<void> _tail = Future<void>.value();
  Future<void>? _loadFuture;

  /// The live list, newest first. Read at palette-open time — the
  /// section snapshots rather than subscribing.
  List<RecentLocation> get entries => List.unmodifiable(_entries);

  /// Reads the persisted document once — memoized so concurrent
  /// callers await the same read. Tolerant: a malformed document or
  /// entry reports and yields an empty/partial list, never a boot
  /// failure.
  Future<void> load() => _loadFuture ??= _readPersisted();

  Future<void> _readPersisted() async {
    try {
      final raw = await _store.get<Object>(settingsKey);
      if (raw == null) return;
      if (raw is! Map || raw['version'] != _schemaVersion) {
        throw const FormatException('recent locations document');
      }
      final entries = raw['entries'];
      if (entries is! List) {
        throw const FormatException('recent locations entries');
      }
      for (final entry in entries) {
        if (entry is! Map) continue;
        try {
          final decoded = RecentLocation.fromJson(
            entry.cast<String, Object?>(),
          );
          // A record() that beat the load wins: the live entry is
          // newer than its persisted twin.
          final duplicate = _entries.any(
            (existing) => existing.dedupeKey == decoded.dedupeKey,
          );
          if (!duplicate) _entries.add(decoded);
        } catch (error, stack) {
          _report(error, stack);
        }
      }
      if (_entries.length > maxEntries) {
        _entries.removeRange(maxEntries, _entries.length);
      }
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  /// The commit hook (02 §8.4): one entry per location change. Pane
  /// controllers call this when an accepted listing commits a location;
  /// launchers, restored-but-unresumed tabs, and sync-plan tabs never
  /// reach the commit point, so they never record.
  void recordLocation(PaneLocation location, {Bookmark? remoteBookmark}) {
    switch (location) {
      case LocalPaneLocation(:final path):
        record(RecentLocation.local(label: paneLastSegment(path), path: path));
      case RemotePaneLocation(:final serverId, :final path):
        record(
          RecentLocation.remote(
            label: remoteBookmark?.label ?? paneLastSegment(path),
            path: path,
            serverId: serverId,
            remoteBookmark: remoteBookmark,
          ),
        );
    }
  }

  /// Moves [location] to the front (dedupe by location key), truncates
  /// at [maxEntries], notifies, and schedules the debounced write.
  void record(RecentLocation location) {
    _entries.removeWhere((entry) => entry.dedupeKey == location.dedupeKey);
    _entries.insert(0, location);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    _scheduleWrite();
  }

  void _scheduleWrite() {
    _cancelScheduled?.call();
    _cancelScheduled = _scheduleDebounce(_saveDelay, _writeNow);
  }

  /// Writes pending state now, behind any write already in flight —
  /// the app-quit safe point calls this so the last recents land before
  /// the window destroys.
  Future<void> flush() {
    _cancelScheduled?.call();
    _cancelScheduled = null;
    return _writeNow();
  }

  Future<void> _writeNow() {
    // Capture the tail BEFORE reassigning it: awaiting the field inside
    // the closure would make the operation wait on itself. And a write
    // must never land before the persisted read — without this ordering
    // a record() issued pre-load would flush only the live list and
    // clobber entries that were never read.
    final previous = _tail;
    final operation = load().then((_) => previous.then((_) => _write()));
    _tail = operation.then((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _write() async {
    try {
      await _store.set(settingsKey, {
        'version': _schemaVersion,
        'entries': [for (final entry in _entries) entry.toJson()],
      });
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  @override
  void dispose() {
    _cancelScheduled?.call();
    super.dispose();
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }

  static void Function() _timerDebounce(
    Duration delay,
    Future<void> Function() callback,
  ) {
    final timer = Timer(delay, () => unawaited(callback()));
    return timer.cancel;
  }
}
