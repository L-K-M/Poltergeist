// The Settings window's side of the link: the section models, each a copy
// of the app's replaced by every snapshot the host sends, whose every call
// runs in the app's isolate through [SettingsWindowHost].
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../ui/settings/general_settings.dart';
import '../../ui/settings/preview_settings.dart';
import '../bookmark_backup_service.dart'
    show BackupSwitchOutcome, RetainedBackupAccount;
import '../external_file_opener.dart';
import '../settings_models.dart';
import '../sync_account_gate.dart';
import 'settings_window_link.dart';

/// What the window shows: nothing while it is hidden, or a Settings screen
/// opened on [tab]. [generation] changes every time the window is shown, so
/// each showing is a fresh screen rather than the last one's fields and
/// half-typed passwords.
@immutable
class SettingsWindowPage {
  const SettingsWindowPage({required this.tab, required this.generation});

  final SettingsWindowTab tab;
  final int generation;
}

/// Calls into the app's isolate. A [PlatformException] from there is the
/// failure it reported, rebuilt as its own type where the sections word it
/// differently; no answer at all means the app is gone.
final class _Link {
  _Link(this.channel);

  final MethodChannel channel;

  /// Told when a call finds no app to answer it.
  VoidCallback? onLost;

  Future<Object?> call(SettingsLinkMethod method, [Object? argument]) async {
    try {
      final reply = await channel.invokeMethod<String>(
        method.name,
        argument == null ? null : jsonEncode(argument),
      );
      return reply == null ? null : jsonDecode(reply);
    } on PlatformException catch (error) {
      throw decodeLinkError(error);
    } on MissingPluginException {
      onLost?.call();
      throw const SettingsLinkException(_linkClosed);
    }
  }
}

/// A diagnostic, never shown: a window that loses the app says so in its
/// own words ([RemoteSettings.lost]).
const _linkClosed = 'Settings link closed';

/// The Settings window's view of the app's settings.
class RemoteSettings extends ChangeNotifier {
  RemoteSettings._(MethodChannel channel) : _link = _Link(channel) {
    _link.onLost = () {
      if (_lost) return;
      _lost = true;
      notifyListeners();
    };
  }

  bool _lost = false;

  /// Whether a call found no app to answer it: the app went away, and the
  /// window can only say so.
  bool get lost => _lost;

  final _Link _link;
  final StreamController<SettingsWindowTab> _tabRequests =
      StreamController<SettingsWindowTab>.broadcast();
  int _generation = 1;

  /// What the window shows; see [SettingsWindowPage].
  late final ValueNotifier<SettingsWindowPage?> page;

  /// Tabs the app asks a showing window to switch to (Settings chosen again
  /// from another entry point while the window is behind).
  Stream<SettingsWindowTab> get tabRequests => _tabRequests.stream;

  /// Say hello to the app and take its first snapshot. Throws when there is
  /// no app to answer — the window was started by hand rather than by the
  /// app.
  static Future<RemoteSettings> connect({
    MethodChannel link = settingsWindowLinkChannel,
  }) async {
    final remote = RemoteSettings._(link);
    link.setMethodCallHandler(remote._handle);
    try {
      final hello = (await remote._link.call(SettingsLinkMethod.hello))! as Map;
      remote._apply(
        (hello[SettingsLinkKey.snapshot.name]! as Map).cast<String, Object?>(),
      );
      remote.page = ValueNotifier(
        SettingsWindowPage(
          tab: SettingsWindowTab.values.byName(
            hello[SettingsLinkKey.tab.name]! as String,
          ),
          generation: 0,
        ),
      );
    } catch (_) {
      // Nothing may reach a window that never got its page.
      link.setMethodCallHandler(null);
      rethrow;
    }
    return remote;
  }

  bool? _checkForUpdates;
  Map<String, Object?>? _preview;
  RemoteEditorRegistry? _editors;
  RemoteBackupSettings? _backup;
  SyncAccountGate _gate = const SyncAccountGate.production();

  /// The General rows, or null when the app has none.
  GeneralSettings? get general {
    final checkForUpdates = _checkForUpdates;
    if (checkForUpdates == null) return null;
    return GeneralSettings(
      checkForUpdates: checkForUpdates,
      onCheckForUpdatesChanged: (enabled) =>
          _link.call(SettingsLinkMethod.setCheckForUpdates, enabled),
    );
  }

  /// The Preview & downloads rows, or null when the app has none.
  PreviewDownloadsSettings? get previewDownloads {
    final preview = _preview;
    if (preview == null) return null;
    return PreviewDownloadsSettings(
      available: preview[SettingsLinkKey.available.name]! as bool,
      capacityBytes: preview[SettingsLinkKey.capacityBytes.name]! as int,
      thresholdBytes: preview[SettingsLinkKey.thresholdBytes.name]! as int,
      onCapacityChanged: (bytes) =>
          _link.call(SettingsLinkMethod.setPreviewCapacity, bytes),
      onThresholdChanged: (bytes) =>
          _link.call(SettingsLinkMethod.setPreviewThreshold, bytes),
      onClearCache: () async =>
          (await _link.call(SettingsLinkMethod.clearPreviewCache))! as int,
    );
  }

  /// The editor registry, or null when the app has none.
  EditorRegistryModel? get editors => _editors;

  /// The Backup section's model, or null when the app has no backup
  /// service.
  BackupSettingsModel? get backup => _backup;

  SyncAccountGate get gate => _gate;

  /// `Add Editor…`'s picker, shown by the app: this engine has no plugins
  /// or runner channels of its own.
  Future<ExternalEditorDefinition?> pickEditor({
    required String dialogTitle,
  }) async {
    final json = await _link.call(SettingsLinkMethod.pickEditor, dialogTitle);
    return json == null
        ? null
        : ExternalEditorDefinition.fromJson(
            (json as Map).cast<String, dynamic>(),
          );
  }

  /// Whether the application may quit, as the app's isolate decides it —
  /// its quit guard and exit flush included. See
  /// [SettingsWindowHost]'s `_requestAppExit` for why this engine is the
  /// one asked on macOS. With no app left to ask, quitting is not held up.
  Future<AppExitResponse> requestAppExit() async {
    try {
      final name = await _link.call(SettingsLinkMethod.requestAppExit);
      return AppExitResponse.values.byName(name! as String);
    } on Exception {
      return AppExitResponse.exit;
    }
  }

  void _apply(Map<String, Object?> snapshot) {
    final general = snapshot[SettingsLinkKey.general.name] as Map?;
    _checkForUpdates = general?[SettingsLinkKey.checkForUpdates.name] as bool?;
    _preview = (snapshot[SettingsLinkKey.preview.name] as Map?)
        ?.cast<String, Object?>();

    final editors = snapshot[SettingsLinkKey.editors.name];
    if (editors == null) {
      _editors = null;
    } else {
      (_editors ??= RemoteEditorRegistry._(
        _link,
      ))._apply(EditorRegistry.fromJson(editors));
    }

    final backup = (snapshot[SettingsLinkKey.backup.name] as Map?)
        ?.cast<String, Object?>();
    if (backup == null) {
      _backup = null;
    } else {
      (_backup ??= RemoteBackupSettings._(_link))._apply(backup);
    }

    final gate = (snapshot[SettingsLinkKey.gate.name]! as Map)
        .cast<String, Object?>();
    _gate = SyncAccountGate(
      minimumSharedVersion:
          gate[SettingsLinkKey.minimumSharedVersion.name] as String?,
      sharedIncludesSeance56Fix:
          gate[SettingsLinkKey.sharedIncludesSeance56Fix.name]! as bool,
    );
  }

  Future<Object?> _handle(MethodCall call) async {
    final Object? argument = call.arguments is String
        ? jsonDecode(call.arguments as String)
        : null;
    final method = SettingsLinkMethod.values
        .where((value) => value.name == call.method)
        .firstOrNull;
    switch (method) {
      case SettingsLinkMethod.snapshot:
        _apply((argument! as Map).cast<String, Object?>());
        notifyListeners();
      case SettingsLinkMethod.selectTab:
        _tabRequests.add(SettingsWindowTab.values.byName(argument! as String));
      case SettingsLinkMethod.hidden:
        page.value = null;
      case SettingsLinkMethod.show:
        final json = (argument! as Map).cast<String, Object?>();
        _apply(
          (json[SettingsLinkKey.snapshot.name]! as Map).cast<String, Object?>(),
        );
        notifyListeners();
        page.value = SettingsWindowPage(
          tab: SettingsWindowTab.values.byName(
            json[SettingsLinkKey.tab.name]! as String,
          ),
          generation: _generation++,
        );
      default:
        throw MissingPluginException(
          'No Settings window method ${call.method}',
        );
    }
    return null;
  }

  @override
  void dispose() {
    _link.channel.setMethodCallHandler(null);
    unawaited(_tabRequests.close());
    page.dispose();
    super.dispose();
  }
}

/// [EditorRegistryModel] over the link.
final class RemoteEditorRegistry extends ChangeNotifier
    implements EditorRegistryModel {
  RemoteEditorRegistry._(this._link);

  final _Link _link;
  EditorRegistry _registry = EditorRegistry();
  String? _registryJson;

  void _apply(EditorRegistry registry) {
    final json = jsonEncode(registry.toJson());
    if (json == _registryJson) return;
    _registryJson = json;
    _registry = registry;
    notifyListeners();
  }

  @override
  EditorRegistry get registry => _registry;

  @override
  Future<void> register(ExternalEditorDefinition editor) =>
      _link.call(SettingsLinkMethod.registerEditor, editor.toJson());

  @override
  Future<void> remove(String id) =>
      _link.call(SettingsLinkMethod.removeEditor, id);

  @override
  Future<void> setDefault(String id) =>
      _link.call(SettingsLinkMethod.setDefaultEditor, id);
}

/// [BackupSettingsModel] over the link.
final class RemoteBackupSettings extends ChangeNotifier
    implements BackupSettingsModel {
  RemoteBackupSettings._(this._link);

  final _Link _link;
  Map<String, Object?> _state = const {};
  String? _stateJson;

  SyncAccount? _account;
  List<HostKeyConflict> _pinConflicts = const [];
  RetainedBackupAccount? _retainedAccount;

  void _apply(Map<String, Object?> state) {
    final json = jsonEncode(state);
    if (json == _stateJson) return;
    _stateJson = json;
    _state = state;
    final account = state[SettingsLinkKey.account.name] as Map?;
    _account = account == null
        ? null
        : decodeSyncAccount(account.cast<String, Object?>());
    _pinConflicts = [
      for (final conflict in state[SettingsLinkKey.pinConflicts.name]! as List)
        decodeHostKeyConflict((conflict as Map).cast<String, Object?>()),
    ];
    final retained = state[SettingsLinkKey.retainedAccount.name] as Map?;
    _retainedAccount = retained == null
        ? null
        : decodeRetainedAccount(retained.cast<String, Object?>());
    notifyListeners();
  }

  @override
  SyncAccount? get account => _account;

  @override
  bool get syncing => _state[SettingsLinkKey.syncing.name]! as bool;

  @override
  bool get syncSecrets => _state[SettingsLinkKey.syncSecrets.name]! as bool;

  @override
  Set<String> get notices => {
    ...(_state[SettingsLinkKey.notices.name]! as List).cast<String>(),
  };

  @override
  bool get passphraseUnverified =>
      _state[SettingsLinkKey.passphraseUnverified.name]! as bool;

  @override
  List<HostKeyConflict> get pinConflicts => _pinConflicts;

  @override
  Set<String> get trippedIds => {
    ...(_state[SettingsLinkKey.trippedIds.name]! as List).cast<String>(),
  };

  @override
  String? get quarantinedPath =>
      _state[SettingsLinkKey.quarantinedPath.name] as String?;

  @override
  DateTime? get lastSyncAt {
    final millis = _state[SettingsLinkKey.lastSyncAt.name] as int?;
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  @override
  String? get lastSyncError =>
      _state[SettingsLinkKey.lastSyncError.name] as String?;

  @override
  RetainedBackupAccount? get retainedAccount => _retainedAccount;

  @override
  bool get deleteSeparateOffered =>
      _state[SettingsLinkKey.deleteSeparateOffered.name]! as bool;

  @override
  Future<void> setSyncSecrets(bool enabled) =>
      _link.call(SettingsLinkMethod.setSyncSecrets, enabled);

  /// The password and passphrase cross to the app's isolate in memory
  /// only; nothing on the link is persisted.
  @override
  Future<void> registerSeparate({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) => _link.call(SettingsLinkMethod.registerSeparate, {
    SettingsLinkKey.baseUrl.name: baseUrl,
    SettingsLinkKey.username.name: username,
    SettingsLinkKey.password.name: password,
    SettingsLinkKey.encryptionPassphrase.name: encryptionPassphrase,
  });

  @override
  Future<void> loginAccount({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  }) => _link.call(SettingsLinkMethod.loginAccount, {
    SettingsLinkKey.baseUrl.name: baseUrl,
    SettingsLinkKey.username.name: username,
    SettingsLinkKey.password.name: password,
    SettingsLinkKey.encryptionPassphrase.name: encryptionPassphrase,
    SettingsLinkKey.mode.name: mode.name,
  });

  @override
  Future<void> backUpNow() => _link.call(SettingsLinkMethod.backUpNow);

  @override
  Future<void> signOut() => _link.call(SettingsLinkMethod.signOut);

  @override
  Future<void> deleteSeparateAccount({required String confirmedName}) =>
      _link.call(SettingsLinkMethod.deleteSeparateAccount, confirmedName);

  @override
  Future<BackupSwitchOutcome> switchToShared({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async => decodeSwitchOutcome(
    ((await _link.call(SettingsLinkMethod.switchToShared, {
              SettingsLinkKey.baseUrl.name: baseUrl,
              SettingsLinkKey.username.name: username,
              SettingsLinkKey.password.name: password,
              SettingsLinkKey.encryptionPassphrase.name: encryptionPassphrase,
            }))!
            as Map)
        .cast<String, Object?>(),
  );

  @override
  Future<void> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) => _link.call(SettingsLinkMethod.resolvePinConflict, {
    SettingsLinkKey.conflict.name: encodeHostKeyConflict(conflict),
    SettingsLinkKey.keepLocal.name: keepLocal,
  });

  @override
  Future<void> deleteRetainedSeparateAccount({required String confirmedName}) =>
      _link.call(
        SettingsLinkMethod.deleteRetainedSeparateAccount,
        confirmedName,
      );

  @override
  Future<void> declineRetainedDelete() =>
      _link.call(SettingsLinkMethod.declineRetainedDelete);
}
