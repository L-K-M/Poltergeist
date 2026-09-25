// The app's side of the Settings window: opens it, answers what it asks
// through the same models the Settings dialogs use, and sends it a fresh
// snapshot whenever one of them changes while it shows.
//
// The window is created the first time Settings opens and kept until the
// app quits: closing it only hides it. Tearing a second engine down is what
// the runners avoid — on Linux, Flutter 3.47's embedder terminates the EGL
// display every engine in the process shares when one is disposed, and the
// app's window then dies with an X error (measured in Séance, whose window
// this ports; docs/PORTS.md). What a hidden window must not keep is its
// screen, so the window drops it on `hidden` and mounts a fresh one, from
// the settings as they are then, on `show`.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../ui/settings/general_settings.dart';
import '../../ui/settings/preview_settings.dart';
import '../external_file_opener.dart';
import '../settings_models.dart';
import '../sync_account_gate.dart';
import 'settings_window_link.dart';

/// Where the Settings window's sections come from in the app. Each is
/// optional, as in the dialogs: a boot without the seam has nothing to show
/// there, and the window leaves the section out.
final class SettingsWindowSources {
  const SettingsWindowSources({
    this.general,
    this.editors,
    this.opener = const ExternalFileOpener(),
    this.previewDownloads,
    this.backup,
    this.gate = const SyncAccountGate.production(),
    this.changes = const [],
  });

  /// The General rows, read afresh at each use (a lookup, like the dialog's).
  final GeneralSettings Function()? general;

  final EditorRegistryModel? editors;

  /// The platform picker behind `Add Editor…`, run in the app's engine
  /// where its channels and plugins live.
  final ExternalFileOpener opener;

  /// The Preview & downloads rows, read afresh at each use.
  final PreviewDownloadsSettings? Function()? previewDownloads;

  final BackupSettingsModel? backup;

  final SyncAccountGate gate;

  /// What else moves a value the window shows (the update-check
  /// controller behind [general]); [editors] and [backup] are listened to
  /// already.
  final List<Listenable> changes;
}

class SettingsWindowHost {
  SettingsWindowHost({
    this._control = settingsWindowControlChannel,
    this._link = settingsWindowLinkChannel,
    @visibleForTesting Future<AppExitResponse> Function()? requestAppExit,
  }) : _requestAppExit =
           requestAppExit ?? WidgetsBinding.instance.handleRequestAppExit {
    _control.setMethodCallHandler(_handleControl);
    _link.setMethodCallHandler(_handleLink);
  }

  final MethodChannel _control;
  final MethodChannel _link;

  /// The app's answer to "may the application quit?": its own observers',
  /// the quit guard and the exit flush among them. The window forwards the
  /// question here because on macOS every engine makes itself the app
  /// delegate's termination handler when it starts, so once the window's
  /// engine exists ⌘Q — and the quit guard's own terminate — asks the
  /// window's isolate, which would answer "exit" without consulting them.
  final Future<AppExitResponse> Function() _requestAppExit;

  SettingsWindowSources _sources = const SettingsWindowSources();
  List<Listenable> _listening = const [];

  /// Whether the window's engine has said hello. It is never torn down, so
  /// this stays true once set, unless the link stops answering.
  bool _connected = false;

  /// Whether the window is showing, rather than closed and hidden.
  bool _visible = false;

  SettingsWindowTab _tab = SettingsWindowTab.general;
  String? _lastSnapshot;
  bool _snapshotScheduled = false;

  @visibleForTesting
  bool get connected => _connected;

  @visibleForTesting
  bool get visible => _visible;

  /// Bind the sections — the workspace shell's, which owns some of them
  /// (the preview threshold lives in its state). Rebinding replaces them.
  void attach(SettingsWindowSources sources) {
    for (final listenable in _listening) {
      listenable.removeListener(_scheduleSnapshot);
    }
    _sources = sources;
    _listening = [?sources.editors, ?sources.backup, ...sources.changes];
    for (final listenable in _listening) {
      listenable.addListener(_scheduleSnapshot);
    }
    _scheduleSnapshot();
  }

  /// Open the window on [tab], or bring it forward and switch it there.
  /// False when the runner has no Settings window — a build from before it
  /// existed, or a test — so the caller can show the dialog instead.
  Future<bool> open(SettingsWindowTab tab) async {
    _tab = tab;
    if (_connected) {
      try {
        if (_visible) {
          await _link.invokeMethod<void>(
            SettingsLinkMethod.selectTab.name,
            jsonEncode(tab.name),
          );
        } else {
          // A fresh screen from the settings as they are now, before the
          // window reappears: nothing was sent while it was hidden.
          final snapshot = _snapshot();
          _lastSnapshot = jsonEncode(snapshot);
          await _link.invokeMethod<void>(
            SettingsLinkMethod.show.name,
            jsonEncode({
              SettingsLinkKey.snapshot.name: snapshot,
              SettingsLinkKey.tab.name: tab.name,
            }),
          );
        }
      } on MissingPluginException {
        // The engine went away after all; a new one says hello, and opens
        // on `_tab`.
        _connected = false;
      }
    }
    try {
      await _control.invokeMethod<void>(SettingsWindowControl.open.name);
    } on MissingPluginException {
      return false;
    } on PlatformException {
      // The runner could not create the window: the dialog instead.
      return false;
    }
    // A first window becomes visible when it says hello, which may already
    // have happened; one being shown again, here.
    if (_connected) _visible = true;
    // A change made while `show` was in flight was not sent, since the
    // window did not count as showing yet; the dedupe makes this a no-op
    // when nothing changed.
    _scheduleSnapshot();
    return true;
  }

  void dispose() {
    for (final listenable in _listening) {
      listenable.removeListener(_scheduleSnapshot);
    }
    _listening = const [];
    _control.setMethodCallHandler(null);
    _link.setMethodCallHandler(null);
  }

  Future<Object?> _handleControl(MethodCall call) async {
    if (call.method != SettingsWindowControl.closed.name) return null;
    _visible = false;
    _lastSnapshot = null;
    if (_connected) {
      try {
        await _link.invokeMethod<void>(SettingsLinkMethod.hidden.name);
      } on MissingPluginException {
        _connected = false;
      }
    }
    return null;
  }

  /// Coalesce a burst of changes into one snapshot, sent after the current
  /// event; a hidden window is sent nothing.
  void _scheduleSnapshot() {
    if (!_connected || !_visible || _snapshotScheduled) return;
    _snapshotScheduled = true;
    scheduleMicrotask(() {
      _snapshotScheduled = false;
      unawaited(_sendSnapshot());
    });
  }

  Future<void> _sendSnapshot() async {
    if (!_connected || !_visible) return;
    final encoded = jsonEncode(_snapshot());
    if (encoded == _lastSnapshot) return;
    _lastSnapshot = encoded;
    try {
      await _link.invokeMethod<void>(SettingsLinkMethod.snapshot.name, encoded);
    } on MissingPluginException {
      _connected = false;
      _lastSnapshot = null;
    } on PlatformException {
      // The window failed to apply it. Forgotten, so the next change sends
      // it again rather than the dedupe skipping what never arrived; and
      // caught, since nothing awaits this.
      _lastSnapshot = null;
    }
  }

  /// Everything the window renders. Sections the app has no seam for are
  /// null, and the window leaves them out.
  Map<String, Object?> _snapshot() {
    final general = _sources.general?.call();
    final preview = _sources.previewDownloads?.call();
    final editors = _sources.editors;
    final backup = _sources.backup;
    final gate = _sources.gate;
    return {
      SettingsLinkKey.general.name: general == null
          ? null
          : {SettingsLinkKey.checkForUpdates.name: general.checkForUpdates},
      SettingsLinkKey.editors.name: editors?.registry.toJson(),
      SettingsLinkKey.preview.name: preview == null
          ? null
          : {
              SettingsLinkKey.available.name: preview.available,
              SettingsLinkKey.capacityBytes.name: preview.capacityBytes,
              SettingsLinkKey.thresholdBytes.name: preview.thresholdBytes,
            },
      SettingsLinkKey.backup.name: backup == null
          ? null
          : _backupSnapshot(backup),
      SettingsLinkKey.gate.name: {
        SettingsLinkKey.minimumSharedVersion.name: gate.minimumSharedVersion,
        SettingsLinkKey.sharedIncludesSeance56Fix.name:
            gate.sharedIncludesSeance56Fix,
      },
    };
  }

  static Map<String, Object?> _backupSnapshot(BackupSettingsModel backup) {
    final account = backup.account;
    final retained = backup.retainedAccount;
    return {
      SettingsLinkKey.account.name: account == null
          ? null
          : encodeSyncAccount(account),
      SettingsLinkKey.syncing.name: backup.syncing,
      SettingsLinkKey.syncSecrets.name: backup.syncSecrets,
      SettingsLinkKey.notices.name: backup.notices.toList()..sort(),
      SettingsLinkKey.passphraseUnverified.name: backup.passphraseUnverified,
      SettingsLinkKey.pinConflicts.name: [
        for (final conflict in backup.pinConflicts)
          encodeHostKeyConflict(conflict),
      ],
      SettingsLinkKey.trippedIds.name: backup.trippedIds.toList()..sort(),
      SettingsLinkKey.quarantinedPath.name: backup.quarantinedPath,
      SettingsLinkKey.lastSyncAt.name:
          backup.lastSyncAt?.millisecondsSinceEpoch,
      SettingsLinkKey.lastSyncError.name: backup.lastSyncError,
      SettingsLinkKey.retainedAccount.name: retained == null
          ? null
          : encodeRetainedAccount(retained),
      SettingsLinkKey.deleteSeparateOffered.name: backup.deleteSeparateOffered,
    };
  }

  Future<Object?> _handleLink(MethodCall call) async {
    final method = SettingsLinkMethod.values
        .where((value) => value.name == call.method)
        .firstOrNull;
    if (method == null) {
      throw MissingPluginException('No Settings window method ${call.method}');
    }
    try {
      final Object? argument = call.arguments is String
          ? jsonDecode(call.arguments as String)
          : null;
      final result = await _dispatch(method, argument);
      return result == null ? null : jsonEncode(result);
    } on MissingPluginException {
      rethrow;
    } catch (error, stackTrace) {
      // The window shows the failure as the dialog would; the app's error
      // reporter hears about it here, where the stack is.
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stackTrace),
      );
      throw encodeLinkError(error);
    }
  }

  Future<Object?> _dispatch(SettingsLinkMethod method, Object? argument) async {
    Map<String, Object?> map() => (argument! as Map).cast<String, Object?>();
    String text(String key) => map()[key]! as String;
    final backup = _sources.backup;
    final editors = _sources.editors;
    switch (method) {
      case SettingsLinkMethod.hello:
        // Built first: a window whose hello failed is not connected.
        final snapshot = _snapshot();
        _lastSnapshot = jsonEncode(snapshot);
        _connected = true;
        _visible = true;
        return {
          SettingsLinkKey.snapshot.name: snapshot,
          SettingsLinkKey.tab.name: _tab.name,
        };
      case SettingsLinkMethod.setCheckForUpdates:
        await _require(
          _sources.general,
        )().onCheckForUpdatesChanged(argument! as bool);
      case SettingsLinkMethod.registerEditor:
        await _require(editors).register(
          ExternalEditorDefinition.fromJson(map().cast<String, dynamic>()),
        );
      case SettingsLinkMethod.removeEditor:
        await _require(editors).remove(argument! as String);
      case SettingsLinkMethod.setDefaultEditor:
        await _require(editors).setDefault(argument! as String);
      case SettingsLinkMethod.pickEditor:
        final picked = await _sources.opener.pickEditor(
          dialogTitle: argument! as String,
        );
        return picked?.toJson();
      case SettingsLinkMethod.setPreviewCapacity:
        await _require(
          _sources.previewDownloads?.call(),
        ).onCapacityChanged(argument! as int);
        // The cap lives in the shell's cache, which notifies no one.
        _scheduleSnapshot();
      case SettingsLinkMethod.setPreviewThreshold:
        await _require(
          _sources.previewDownloads?.call(),
        ).onThresholdChanged(argument! as int);
        _scheduleSnapshot();
      case SettingsLinkMethod.clearPreviewCache:
        return await _require(_sources.previewDownloads?.call()).onClearCache();
      case SettingsLinkMethod.setSyncSecrets:
        await _require(backup).setSyncSecrets(argument! as bool);
      case SettingsLinkMethod.registerSeparate:
        await _require(backup).registerSeparate(
          baseUrl: text(SettingsLinkKey.baseUrl.name),
          username: text(SettingsLinkKey.username.name),
          password: text(SettingsLinkKey.password.name),
          encryptionPassphrase: text(SettingsLinkKey.encryptionPassphrase.name),
        );
      case SettingsLinkMethod.loginAccount:
        await _require(backup).loginAccount(
          baseUrl: text(SettingsLinkKey.baseUrl.name),
          username: text(SettingsLinkKey.username.name),
          password: text(SettingsLinkKey.password.name),
          encryptionPassphrase: text(SettingsLinkKey.encryptionPassphrase.name),
          mode: SyncAccountMode.values.byName(text(SettingsLinkKey.mode.name)),
        );
      case SettingsLinkMethod.backUpNow:
        await _require(backup).backUpNow();
      case SettingsLinkMethod.signOut:
        await _require(backup).signOut();
      case SettingsLinkMethod.deleteSeparateAccount:
        await _require(
          backup,
        ).deleteSeparateAccount(confirmedName: argument! as String);
      case SettingsLinkMethod.switchToShared:
        return encodeSwitchOutcome(
          await _require(backup).switchToShared(
            baseUrl: text(SettingsLinkKey.baseUrl.name),
            username: text(SettingsLinkKey.username.name),
            password: text(SettingsLinkKey.password.name),
            encryptionPassphrase: text(
              SettingsLinkKey.encryptionPassphrase.name,
            ),
          ),
        );
      case SettingsLinkMethod.resolvePinConflict:
        final json = map();
        await _require(backup).resolvePinConflict(
          decodeHostKeyConflict(
            (json[SettingsLinkKey.conflict.name]! as Map)
                .cast<String, Object?>(),
          ),
          keepLocal: json[SettingsLinkKey.keepLocal.name]! as bool,
        );
      case SettingsLinkMethod.deleteRetainedSeparateAccount:
        await _require(
          backup,
        ).deleteRetainedSeparateAccount(confirmedName: argument! as String);
      case SettingsLinkMethod.declineRetainedDelete:
        await _require(backup).declineRetainedDelete();
      case SettingsLinkMethod.requestAppExit:
        return (await _requestAppExit()).name;
      case SettingsLinkMethod.snapshot:
      case SettingsLinkMethod.selectTab:
      case SettingsLinkMethod.hidden:
      case SettingsLinkMethod.show:
        throw MissingPluginException('${method.name} goes to the window');
    }
    return null;
  }

  /// A section the window could only have shown if the app had it.
  static T _require<T extends Object>(T? source) =>
      source ?? (throw StateError('This section is not available.'));
}
