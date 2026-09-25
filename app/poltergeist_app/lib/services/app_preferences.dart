import 'dart:ui';

import 'package:poltergeist_core/poltergeist_core.dart'
    show
        TransferConcurrency,
        defaultLargeDownloadThresholdBytes,
        defaultPreviewCacheCapacityBytes;

import 'double_click_action.dart';
import 'pane_tabs_controller.dart' show NewTabTarget;
import 'settings_store.dart';
import 'sidebar_controller.dart' show SidebarCollapseKeys, SidebarDensity;

const _defaultPaneRatio = 0.5;
const _paneRatioKey = 'layout.paneRatio';
const _windowLeftKey = 'window.left';
const _windowTopKey = 'window.top';
const _windowWidthKey = 'window.width';
const _windowHeightKey = 'window.height';
const _newTabTargetKey = 'tabs.newTabTarget';
const _doubleClickActionKey = 'panes.doubleClickAction';
const _reconnectRestoredTabsKey = 'tabs.reconnectRestored';
const _sidebarWidthKey = 'layout.sidebarWidth';
const _inspectorWidthKey = 'layout.inspectorWidth';
const _downloadLimitKey = 'transfer.downloadLimitBytesPerSecond';
const _uploadLimitKey = 'transfer.uploadLimitBytesPerSecond';
const _autoClearCompletedKey = 'transfer.autoClearCompleted';
const _transferConcurrencyKey = 'transfer.perServerConcurrency';
const _serverTransferConcurrencyKey = 'transfer.serverConcurrency';
const _sidebarHiddenKey = 'layout.sidebarHidden';
const _sidebarCollapsedGroupsKey = 'sidebar.collapsedGroups';
const _sidebarDensityKey = 'sidebar.density';
const _sidebarPinnedServersKey = 'sidebar.pinnedServers';
const _previewCacheCapacityKey = 'preview.cacheCapacityBytes';
const _previewThresholdKey = 'preview.largeDownloadThresholdBytes';
const _updateChecksEnabledKey = 'updates.checkEnabled';

/// How a server's own Automatic is spelled in the stored overrides; a
/// fixed cap is stored as its number.
const _automaticConcurrency = 'automatic';


class AppPreferences {
  AppPreferences({required SettingsStore store})
    // Keep the backing store private to the preference facade.
    // ignore: prefer_initializing_formals
    : _store = store;

  final SettingsStore _store;

  Future<double> loadPaneRatio() async {
    num? storedRatio;
    try {
      storedRatio = await _store.get<num>(_paneRatioKey);
    } catch (_) {
      // Startup continues while the store resets its load for a later retry.
      return _defaultPaneRatio;
    }

    if (storedRatio == null || !storedRatio.isFinite) {
      return _defaultPaneRatio;
    }

    final ratio = storedRatio.toDouble();
    return ratio.clamp(0, 1).toDouble();
  }

  Future<void> savePaneRatio(double ratio) {
    if (!ratio.isFinite) return Future.value();

    return _store.set(_paneRatioKey, ratio.clamp(0, 1).toDouble());
  }

  /// The "New tabs open" preference (02 §2.1): what `tab.new` binds a
  /// fresh tab to. The shell seeds each strip's live field with this
  /// value; an unreadable or unknown stored value falls back to the
  /// spec default rather than failing startup.
  Future<NewTabTarget> loadNewTabTarget() async {
    String? stored;
    try {
      stored = await _store.get<String>(_newTabTargetKey);
    } catch (_) {
      return NewTabTarget.duplicate;
    }
    for (final target in NewTabTarget.values) {
      if (target.name == stored) return target;
    }
    return NewTabTarget.duplicate;
  }

  Future<void> saveNewTabTarget(NewTabTarget target) =>
      _store.set(_newTabTargetKey, target.name);

  /// The "Double-click action" preference (02 §2.6): what the Open verb
  /// does to a file. The shell seeds each strip's live field with this
  /// value; an unreadable or unknown stored value falls back to the
  /// spec default (Open) rather than failing startup.
  Future<DoubleClickAction> loadDoubleClickAction() async {
    String? stored;
    try {
      stored = await _store.get<String>(_doubleClickActionKey);
    } catch (_) {
      return DoubleClickAction.open;
    }
    for (final action in DoubleClickAction.values) {
      if (action.name == stored) return action;
    }
    return DoubleClickAction.open;
  }

  Future<void> saveDoubleClickAction(DoubleClickAction action) =>
      _store.set(_doubleClickActionKey, action.name);

  /// The "Reconnect restored tabs automatically" setting (02 §3): when
  /// on, activating a session-restored remote tab reconnects without a
  /// click; when off, its Reconnect bar waits for the explicit action —
  /// activation alone never reconnects (the metered/VPN case). Defaults
  /// ON; an unreadable store falls back to the spec default.
  Future<bool> loadReconnectRestoredTabs() async {
    try {
      return await _store.get<bool>(_reconnectRestoredTabsKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> saveReconnectRestoredTabs(bool value) =>
      _store.set(_reconnectRestoredTabsKey, value);

  /// The D32 region widths (10 §3.1): plain logical pixels, null when
  /// never saved or unreadable — the shell applies its default and its
  /// clamp, so a stale value from a wider screen can never overflow.
  Future<double?> loadSidebarWidth() => _loadWidth(_sidebarWidthKey);

  Future<void> saveSidebarWidth(double width) =>
      _saveWidth(_sidebarWidthKey, width);

  Future<double?> loadInspectorWidth() => _loadWidth(_inspectorWidthKey);

  Future<void> saveInspectorWidth(double width) =>
      _saveWidth(_inspectorWidthKey, width);

  Future<double?> _loadWidth(String key) async {
    num? stored;
    try {
      stored = await _store.get<num>(key);
    } catch (_) {
      return null;
    }
    if (stored == null || !stored.isFinite || stored <= 0) return null;
    return stored.toDouble();
  }

  Future<void> _saveWidth(String key, double width) {
    if (!width.isFinite || width <= 0) return Future.value();
    return _store.set(key, width);
  }

  /// The throttle popover's persisted per-direction limits (02 §6's
  /// "applied immediately, persisted"): null means unlimited. A stored
  /// non-positive value decodes as unlimited — the limiter normalizes
  /// it the same way.
  Future<int?> loadDownloadLimit() => _loadLimit(_downloadLimitKey);

  Future<int?> loadUploadLimit() => _loadLimit(_uploadLimitKey);

  Future<int?> _loadLimit(String key) async {
    num? stored;
    try {
      stored = await _store.get<num>(key);
    } catch (_) {
      return null;
    }
    // A corrupt file can carry a non-finite double (jsonDecode
    // saturates over-range literals), and toInt() throws on it —
    // same guard the panel-height loader keeps.
    if (stored == null || !stored.isFinite) return null;
    final value = stored.toInt();
    return value > 0 ? value : null;
  }

  /// Persist a limit — or its removal ([bytesPerSecond] null = Off).
  Future<void> saveDownloadLimit(int? bytesPerSecond) =>
      _saveLimit(_downloadLimitKey, bytesPerSecond);

  Future<void> saveUploadLimit(int? bytesPerSecond) =>
      _saveLimit(_uploadLimitKey, bytesPerSecond);

  Future<void> _saveLimit(String key, int? bytesPerSecond) {
    // A null write decodes back to "no stored limit" — the same answer
    // as an absent key, so removal is not needed.
    final normalized =
        bytesPerSecond != null && bytesPerSecond > 0 ? bytesPerSecond : null;
    return _store.set(key, normalized);
  }

  /// D37's default cap on each server's simultaneous transfers:
  /// device-local, Automatic unless set. Anything stored but a positive
  /// whole number reads as Automatic, the behavior before the setting
  /// existed.
  Future<TransferConcurrency> loadTransferConcurrency() async {
    Object? stored;
    try {
      stored = await _store.get<Object>(_transferConcurrencyKey);
    } catch (_) {
      return const TransferConcurrency.automatic();
    }
    return _decodeConcurrency(stored) ?? const TransferConcurrency.automatic();
  }

  /// Automatic is stored as null, which decodes the same as no key.
  Future<void> saveTransferConcurrency(TransferConcurrency value) =>
      _store.set(_transferConcurrencyKey, value.files);

  /// The servers that chose their own cap (D37), keyed by server id:
  /// device-local, beside the default. Entries that do not decode are
  /// dropped, and an unreadable store reads as none for this launch,
  /// which is safe because no change writes this map back whole: see
  /// [setServerTransferConcurrency].
  Future<Map<String, TransferConcurrency>>
  loadServerTransferConcurrency() async {
    Object? stored;
    try {
      stored = await _store.get<Object>(_serverTransferConcurrencyKey);
    } catch (_) {
      return const {};
    }
    return _decodeConcurrencyMap(stored);
  }

  /// Sets [serverId]'s own cap, or clears it with null so the server
  /// follows the default again, in the overrides as stored when the
  /// write runs; completes with the overrides now stored. Fails, writing
  /// nothing, while the store cannot be read.
  Future<Map<String, TransferConcurrency>> setServerTransferConcurrency(
    String serverId,
    TransferConcurrency? value,
  ) async {
    final written = await _store.update(_serverTransferConcurrencyKey, (
      stored,
    ) {
      final overrides = _decodeConcurrencyMap(stored);
      if (value == null) {
        overrides.remove(serverId);
      } else {
        overrides[serverId] = value;
      }
      return <String, Object>{
        for (final MapEntry(:key, :value) in overrides.entries)
          key: value.files ?? _automaticConcurrency,
      };
    });
    return Map.unmodifiable(_decodeConcurrencyMap(written));
  }

  static Map<String, TransferConcurrency> _decodeConcurrencyMap(
    Object? stored,
  ) => {
    if (stored is Map)
      for (final MapEntry(:key, :value) in stored.entries)
        if (key is String)
          if (value == _automaticConcurrency)
            key: const TransferConcurrency.automatic()
          else
            key: ?_decodeConcurrency(value),
  };

  /// A positive whole number as a fixed cap, null for anything else.
  static TransferConcurrency? _decodeConcurrency(Object? stored) {
    if (stored is! num || !stored.isFinite) return null;
    if (stored != stored.truncate() || stored < 1) return null;
    return TransferConcurrency.fixed(stored.toInt());
  }

  /// 02 §6's "auto-remove on success" setting (default on): a
  /// completed row lingers then leaves the listing; turning it off
  /// keeps completed rows until Clear-completed.
  Future<bool> loadAutoClearCompletedTransfers() async {
    try {
      return await _store.get<bool>(_autoClearCompletedKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> saveAutoClearCompletedTransfers(bool value) =>
      _store.set(_autoClearCompletedKey, value);

  /// The sidebar's explicit visibility intent (02 §1): persisted per the
  /// §1 persistence list, default shown. The stage-1 auto-collapse is
  /// recomputed from window width and never written here.
  Future<bool> loadSidebarHidden() async {
    try {
      return await _store.get<bool>(_sidebarHiddenKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveSidebarHidden(bool hidden) =>
      _store.set(_sidebarHiddenKey, hidden);

  /// The sidebar's collapsed favorite-group keys (02 §4: collapse state
  /// persisted device-locally, 04 §2.3). A malformed stored value decodes
  /// to an empty set rather than failing startup — losing collapse
  /// memory is recoverable, losing the window is not. An unreadable
  /// store also reads as none, which is safe because no fold writes this
  /// set back: see [setSidebarGroupCollapsed].
  Future<Set<String>> loadSidebarCollapsedGroups() async {
    Object? stored;
    try {
      stored = await _store.get<Object>(_sidebarCollapsedGroupsKey);
    } catch (_) {
      return const {};
    }
    return _decodeIdSet(stored);
  }

  /// Folds or unfolds the section [key] in the set as stored when the
  /// write runs, and completes with the set now stored. Legacy keys are
  /// rewritten in the same write ([SidebarCollapseKeys.migrate]), so a
  /// section unfolded here cannot fold again from its old spelling on
  /// the next launch. Fails, writing nothing, while the store cannot be
  /// read.
  Future<Set<String>> setSidebarGroupCollapsed(
    String key, {
    required bool collapsed,
  }) => _updateIdSet(_sidebarCollapsedGroupsKey, (stored) {
    final keys = SidebarCollapseKeys.migrate(stored);
    if (collapsed) {
      keys.add(key);
    } else {
      keys.remove(key);
    }
    return keys;
  });

  /// The sidebar's row density (D33): device-local, comfortable by
  /// default on every platform. An unreadable or unknown stored value
  /// falls back to that default rather than failing startup.
  Future<SidebarDensity> loadSidebarDensity() async {
    String? stored;
    try {
      stored = await _store.get<String>(_sidebarDensityKey);
    } catch (_) {
      return SidebarDensity.comfortable;
    }
    for (final density in SidebarDensity.values) {
      if (density.name == stored) return density;
    }
    return SidebarDensity.comfortable;
  }

  Future<void> saveSidebarDensity(SidebarDensity density) =>
      _store.set(_sidebarDensityKey, density.name);

  /// The ids of the servers pinned to the sidebar's PINNED shortlist
  /// (D33), the account's and the remote favorites alike: device-local,
  /// like Séance's pins. The key keeps its `pinnedServers` spelling from
  /// the build where only the account's servers pinned, so those pins
  /// survive. A malformed stored value decodes to no pins (non-string
  /// entries are dropped) rather than failing startup. An unreadable
  /// store also reads as no pins for this launch, which is safe because
  /// no pin change writes this set back: see [setSidebarServerPinned].
  Future<Set<String>> loadSidebarPinnedServers() async {
    Object? stored;
    try {
      stored = await _store.get<Object>(_sidebarPinnedServersKey);
    } catch (_) {
      return const {};
    }
    return _decodeIdSet(stored);
  }

  /// Pin to top / Unpin: adds or removes [serverId] in the pins as stored
  /// when the write runs, and completes with the pins now stored. The
  /// sidebar's own set can be missing pins (it starts empty after a
  /// launch whose read failed), so writing that set would drop every
  /// pin it never saw; this change touches only [serverId]. Fails,
  /// writing nothing, while the store cannot be read.
  Future<Set<String>> setSidebarServerPinned(
    String serverId, {
    required bool pinned,
  }) => _updateIdSet(_sidebarPinnedServersKey, (stored) {
    if (pinned) {
      stored.add(serverId);
    } else {
      stored.remove(serverId);
    }
    return stored;
  });

  /// Rewrites the id set under [key] as [edit] of its value at write
  /// time (the store serializes it behind every queued write), keeping
  /// the stored shape: a JSON list of strings.
  Future<Set<String>> _updateIdSet(
    String key,
    Set<String> Function(Set<String> stored) edit,
  ) async {
    final written = await _store.update(
      key,
      (stored) => List<String>.unmodifiable(edit(_decodeIdSet(stored))),
    );
    return Set.unmodifiable(written);
  }

  /// A stored id set: anything but a list reads as empty, and non-string
  /// entries are dropped.
  static Set<String> _decodeIdSet(Object? stored) => {
    if (stored is List)
      for (final entry in stored)
        if (entry is String) entry,
  };

  /// The D19 update check's opt-out (00 D19/D23, 01 §6): ON by default
  /// — the check is a plain GET of a static URL carrying nothing — and
  /// an unreadable store decodes to the default rather than disabling
  /// a check the user never turned off.
  Future<bool> loadUpdateChecksEnabled() async {
    try {
      return await _store.get<bool>(_updateChecksEnabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> saveUpdateChecksEnabled(bool enabled) =>
      _store.set(_updateChecksEnabledKey, enabled);

  /// The §8 "Preview & downloads" cache cap (06 §8): bytes, default
  /// 512 MiB. A missing or corrupt value decodes to the default.
  Future<int> loadPreviewCacheCapacityBytes() => _loadBytes(
    _previewCacheCapacityKey,
    defaultPreviewCacheCapacityBytes,
  );

  Future<void> savePreviewCacheCapacityBytes(int bytes) => _store.set(
    _previewCacheCapacityKey,
    bytes > 0 ? bytes : defaultPreviewCacheCapacityBytes,
  );

  /// The §8 shared large-download confirmation threshold (06 §8):
  /// bytes, default 100 MiB — one setting gating remote previews,
  /// Quick Look productions, compare sides, and external-editor
  /// checkouts.
  Future<int> loadPreviewThresholdBytes() => _loadBytes(
    _previewThresholdKey,
    defaultLargeDownloadThresholdBytes,
  );

  Future<void> savePreviewThresholdBytes(int bytes) => _store.set(
    _previewThresholdKey,
    bytes > 0 ? bytes : defaultLargeDownloadThresholdBytes,
  );

  Future<int> _loadBytes(String key, int fallback) async {
    num? stored;
    try {
      stored = await _store.get<num>(key);
    } catch (_) {
      return fallback;
    }
    if (stored == null || !stored.isFinite) return fallback;
    final value = stored.toInt();
    return value > 0 ? value : fallback;
  }

  Future<Rect?> loadWindowBounds() async {
    late final List<num?> storedValues;
    try {
      storedValues = await Future.wait<num?>([
        _store.get<num>(_windowLeftKey),
        _store.get<num>(_windowTopKey),
        _store.get<num>(_windowWidthKey),
        _store.get<num>(_windowHeightKey),
      ]);
    } catch (_) {
      // An unreadable store must not prevent default window placement.
      return null;
    }

    if (storedValues.any((value) => value == null || !value.isFinite)) {
      return null;
    }

    final values = storedValues.map((value) => value!.toDouble()).toList();
    final width = values[2];
    final height = values[3];
    if (width <= 0 || height <= 0) return null;

    return Rect.fromLTWH(values[0], values[1], width, height);
  }

  Future<void> saveWindowBounds(Rect bounds) async {
    final values = [bounds.left, bounds.top, bounds.width, bounds.height];

    // Ignore transient invalid geometry reported during native window changes.
    if (values.any((value) => !value.isFinite) ||
        bounds.width <= 0 ||
        bounds.height <= 0) {
      return;
    }

    await _store.setAll({
      _windowLeftKey: bounds.left,
      _windowTopKey: bounds.top,
      _windowWidthKey: bounds.width,
      _windowHeightKey: bounds.height,
    });
  }
}
