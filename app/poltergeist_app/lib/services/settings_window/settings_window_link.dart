// The Settings window's wire: channel names, the method table, and the
// JSON codecs for what crosses between the app's isolate and the window's.
//
// The Settings window runs on a second Flutter engine (Flutter stable has no
// multi-window API), whose isolate shares nothing with the app's. Each runner
// (macos/Runner/SettingsWindow.swift, linux/runner/settings_window.cc,
// windows/runner/settings_window.cpp) relays every message one engine sends
// on [settingsWindowLinkChannel] to the other, byte for byte, with its reply.
// Every payload is a JSON string in both directions, so each side decodes
// exactly what the other encoded.
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../theme/app_appearance.dart';
import '../../theme/theme_palette.dart';
import '../bookmark_backup_service.dart'
    show BackupSwitchOutcome, RetainedBackupAccount;

/// On the app's engine only: `open` in, `closed` out.
const MethodChannel settingsWindowControlChannel = MethodChannel(
  'poltergeist/settings_window',
);

/// On both engines, relayed between them by the runner.
const MethodChannel settingsWindowLinkChannel = MethodChannel(
  'poltergeist/settings_link',
);

/// What the runners start the window's engine with; `main` runs the
/// Settings window instead of the app when it sees it.
const String settingsWindowArgument = '--poltergeist-settings-window';

/// The Settings window's tabs, in order (02 §10's Settings screen, as far as
/// its sections exist). Appearance follows General, as it does in Séance's
/// Settings.
enum SettingsWindowTab { general, appearance, editing, sync }

/// Opens the desktop Settings window on a tab; false when there is no window
/// to open (a runner without one, or a test), and the caller shows its
/// dialog instead. `SettingsWindowHost.open` in the app.
typedef OpenSettingsWindow = Future<bool> Function(SettingsWindowTab tab);

/// The link's methods; each crosses as its [name], so a typo is a compile
/// error rather than a silent `null` on the far side.
enum SettingsLinkMethod {
  // Window → app.
  hello,
  setCheckForUpdates,
  setAppearance,
  registerEditor,
  removeEditor,
  setDefaultEditor,
  pickEditor,
  setPreviewCapacity,
  setPreviewThreshold,
  clearPreviewCache,
  setSyncSecrets,
  registerSeparate,
  loginAccount,
  backUpNow,
  signOut,
  deleteSeparateAccount,
  switchToShared,
  resolvePinConflict,
  deleteRetainedSeparateAccount,
  declineRetainedDelete,
  requestAppExit,

  // App → window.
  snapshot,
  selectTab,
  hidden,
  show,
}

/// The control channel's methods: `open` from the app, `closed` from the
/// runner.
enum SettingsWindowControl { open, closed }

/// The keys of every JSON object on the link, spelled once for both sides:
/// each crosses as its [name].
enum SettingsLinkKey {
  account,
  appearance,
  available,
  backup,
  baseUrl,
  capacityBytes,
  checkForUpdates,
  conflict,
  deleteSeparateOffered,
  editors,
  encryptionPassphrase,
  gate,
  general,
  hashLength,
  held,
  iterations,
  keepLocal,
  lastSyncAt,
  lastSyncError,
  local,
  locator,
  memory,
  minimumSharedVersion,
  mode,
  notices,
  palette,
  parallelism,
  passphraseUnverified,
  passphraseWarning,
  password,
  pinConflicts,
  preview,
  pulled,
  quarantinedPath,
  retainedAccount,
  sharedIncludesSeance56Fix,
  snapshot,
  syncSecrets,
  syncing,
  tab,
  thresholdBytes,
  trippedIds,
  username,
}

/// Why a call failed in the app's isolate, as the error code of the
/// [PlatformException] that carries it. The enrollment errors the Backup
/// section words differently cross as themselves, and the window rebuilds
/// the same exception, so `describeEnrollmentError` needs no link case.
enum SettingsLinkError {
  kdfDowngrade,
  registrationClosed,
  failed;

  static SettingsLinkError? byName(String code) {
    for (final value in values) {
      if (value.name == code) return value;
    }
    return null;
  }
}

/// [error] as the link carries it: a [PlatformException] whose code is a
/// [SettingsLinkError] and whose message is what the error printed.
PlatformException encodeLinkError(Object error) => switch (error) {
  KdfDowngradeException(:final offered) => PlatformException(
    code: SettingsLinkError.kdfDowngrade.name,
    message: '$error',
    details: {
      SettingsLinkKey.memory.name: offered.memory,
      SettingsLinkKey.iterations.name: offered.iterations,
      SettingsLinkKey.parallelism.name: offered.parallelism,
      SettingsLinkKey.hashLength.name: offered.hashLength,
    },
  ),
  RegistrationClosedException() => PlatformException(
    code: SettingsLinkError.registrationClosed.name,
    message: '$error',
  ),
  _ => PlatformException(
    code: SettingsLinkError.failed.name,
    message: '$error',
  ),
};

/// The inverse of [encodeLinkError], in the window.
Exception decodeLinkError(PlatformException error) {
  switch (SettingsLinkError.byName(error.code)) {
    case SettingsLinkError.kdfDowngrade:
      final details = (error.details as Map).cast<String, Object?>();
      return KdfDowngradeException(
        Argon2Params(
          memory: details[SettingsLinkKey.memory.name]! as int,
          iterations: details[SettingsLinkKey.iterations.name]! as int,
          parallelism: details[SettingsLinkKey.parallelism.name]! as int,
          hashLength: details[SettingsLinkKey.hashLength.name]! as int,
        ),
      );
    case SettingsLinkError.registrationClosed:
      return const RegistrationClosedException();
    case SettingsLinkError.failed:
    case null:
      return SettingsLinkException(error.message ?? error.code);
  }
}

/// A failure in the app's isolate that has no type of its own on this side:
/// what it printed there.
final class SettingsLinkException implements Exception {
  const SettingsLinkException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The theme crosses in the form the settings file stores. Its palette is
/// decoded as leniently as a launch decodes it; its mode by name, as the
/// link's other values are, since both ends are one build.
Map<String, Object?> encodeAppearance(AppAppearance appearance) => {
  SettingsLinkKey.palette.name: appearance.palette.toJson(),
  SettingsLinkKey.mode.name: appearance.mode.name,
};

AppAppearance decodeAppearance(Map<String, Object?> json) => AppAppearance(
  palette: ThemePalette.decodeStored(json[SettingsLinkKey.palette.name]),
  mode: ThemeModePreference.values.byName(
    json[SettingsLinkKey.mode.name]! as String,
  ),
);

Map<String, Object?> encodeSyncAccount(SyncAccount account) => {
  SettingsLinkKey.baseUrl.name: account.baseUrl,
  SettingsLinkKey.username.name: account.username,
  SettingsLinkKey.mode.name: account.mode.name,
};

SyncAccount decodeSyncAccount(Map<String, Object?> json) => SyncAccount(
  baseUrl: json[SettingsLinkKey.baseUrl.name]! as String,
  username: json[SettingsLinkKey.username.name]! as String,
  mode: SyncAccountMode.values.byName(
    json[SettingsLinkKey.mode.name]! as String,
  ),
);

Map<String, Object?> encodeRetainedAccount(RetainedBackupAccount account) => {
  SettingsLinkKey.baseUrl.name: account.baseUrl,
  SettingsLinkKey.username.name: account.username,
};

RetainedBackupAccount decodeRetainedAccount(Map<String, Object?> json) =>
    RetainedBackupAccount(
      baseUrl: json[SettingsLinkKey.baseUrl.name]! as String,
      username: json[SettingsLinkKey.username.name]! as String,
    );

/// A conflict crosses whole: resolving it reads the host and port of both
/// keys, and the fingerprints are public facts about a server.
Map<String, Object?> encodeHostKeyConflict(HostKeyConflict conflict) => {
  SettingsLinkKey.locator.name: conflict.locator,
  SettingsLinkKey.local.name: conflict.local.toJson(),
  SettingsLinkKey.pulled.name: conflict.pulled.toJson(),
};

HostKeyConflict decodeHostKeyConflict(Map<String, Object?> json) =>
    HostKeyConflict(
      locator: json[SettingsLinkKey.locator.name]! as String,
      local: HostKey.fromJson(
        (json[SettingsLinkKey.local.name]! as Map).cast<String, dynamic>(),
      ),
      pulled: HostKey.fromJson(
        (json[SettingsLinkKey.pulled.name]! as Map).cast<String, dynamic>(),
      ),
    );

Map<String, Object?> encodeSwitchOutcome(BackupSwitchOutcome outcome) => {
  SettingsLinkKey.held.name: [
    for (final conflict in outcome.held) encodeHostKeyConflict(conflict),
  ],
  SettingsLinkKey.passphraseUnverified.name: outcome.passphraseUnverified,
  SettingsLinkKey.passphraseWarning.name: outcome.passphraseWarning,
};

BackupSwitchOutcome decodeSwitchOutcome(Map<String, Object?> json) =>
    BackupSwitchOutcome(
      held: [
        for (final conflict in json[SettingsLinkKey.held.name]! as List)
          decodeHostKeyConflict((conflict as Map).cast<String, Object?>()),
      ],
      passphraseUnverified:
          json[SettingsLinkKey.passphraseUnverified.name]! as bool,
      passphraseWarning:
          json[SettingsLinkKey.passphraseWarning.name] as String?,
    );
