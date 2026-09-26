// What the Settings sections read and call, apart from where they run.
//
// The sections render in the app's own dialogs and, on desktop, in the
// Settings window, which Flutter runs on a second engine: an isolate that
// shares no memory with the app. There each model is a proxy forwarding to
// the app's isolate (services/settings_window/), so the sections are
// written against these interfaces rather than the concrete controllers —
// which implement them unchanged.
import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import 'bookmark_backup_service.dart'
    show BackupSwitchOutcome, RetainedBackupAccount;
import 'external_file_opener.dart';

/// The Settings → Appearance section's model: [AppearanceController] in the
/// app. [value] is the theme the app is drawn in, and what the app's
/// MaterialApp (and the Settings window's) rebuilds for.
///
/// The section edits a copy of its own and hands it back whole: in the
/// Settings window, [value] trails each write by a round trip to the app.
abstract interface class AppearanceSettingsModel
    implements ValueListenable<AppAppearance> {
  /// Re-themes the app, then persists the theme; a no-op when nothing
  /// changed. Throws when the write fails, after the app has taken the
  /// change: the app shows what the section shows, and the next write
  /// carries it.
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode);
}

/// The Settings → Editing registry sections' model:
/// [EditorRegistryController] in the app.
abstract interface class EditorRegistryModel implements Listenable {
  /// The live registry.
  EditorRegistry get registry;

  /// Adds or replaces [editor]; persists first, throws on failure.
  Future<void> register(ExternalEditorDefinition editor);

  Future<void> remove(String id);

  Future<void> setDefault(String id);
}

/// The platform's application picker behind `Add Editor…` — null when the
/// user cancels. [ExternalFileOpener.pickEditor] in the app.
typedef EditorPicker =
    Future<ExternalEditorDefinition?> Function({required String dialogTitle});

/// The Settings → Backup section's model: [BookmarkBackupService] in the
/// app. Every mutating call throws on failure, leaving the durable state —
/// and so what the section renders — unchanged.
abstract interface class BackupSettingsModel implements Listenable {
  SyncAccount? get account;
  bool get syncing;
  bool get syncSecrets;
  Set<String> get notices;
  bool get passphraseUnverified;
  List<HostKeyConflict> get pinConflicts;
  Set<String> get trippedIds;
  String? get quarantinedPath;
  DateTime? get lastSyncAt;
  String? get lastSyncError;
  RetainedBackupAccount? get retainedAccount;
  bool get deleteSeparateOffered;

  Future<void> setSyncSecrets(bool enabled);

  Future<void> registerSeparate({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  });

  Future<void> loginAccount({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  });

  Future<void> backUpNow();

  Future<void> signOut();

  Future<void> deleteSeparateAccount({required String confirmedName});

  Future<BackupSwitchOutcome> switchToShared({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  });

  Future<void> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  });

  Future<void> deleteRetainedSeparateAccount({required String confirmedName});

  Future<void> declineRetainedDelete();
}
