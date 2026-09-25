import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/appearance_controller.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart'
    show BackupSwitchOutcome, RetainedBackupAccount;
import 'package:poltergeist_app/services/external_file_opener.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/services/settings_window/remote_settings.dart';
import 'package:poltergeist_app/services/settings_window/settings_window_host.dart';
import 'package:poltergeist_app/services/settings_window/settings_window_link.dart';
import 'package:poltergeist_app/services/sync_account_gate.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';
import 'package:poltergeist_app/ui/settings/general_settings.dart';
import 'package:poltergeist_app/ui/settings/preview_settings.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

// One engine in a test, so each end of the link gets a channel of its own
// and a relay between them stands in for the runners' forwarding.
const _appLink = MethodChannel('test/settings_link/app');
const _windowLink = MethodChannel('test/settings_link/window');
const _control = MethodChannel('test/settings_window');

HostKey _key(String host, String fingerprint) => HostKey(
  host: host,
  type: 'ssh-ed25519',
  fingerprintSha256: fingerprint,
  pinnedAt: 1,
);

final _conflict = HostKeyConflict(
  locator: 'files.example:22',
  local: _key('files.example', 'SHA256:local'),
  pulled: _key('files.example', 'SHA256:pulled'),
);

/// The Backup section's model with scripted state, recording each call.
final class _FakeBackup extends ChangeNotifier implements BackupSettingsModel {
  final List<String> calls = [];
  HostKeyConflict? resolved;
  bool? resolvedKeepLocal;
  Object? failWith;

  @override
  SyncAccount? account;
  @override
  bool syncing = false;
  @override
  bool syncSecrets = false;
  @override
  Set<String> notices = {};
  @override
  bool passphraseUnverified = false;
  @override
  List<HostKeyConflict> pinConflicts = [];
  @override
  Set<String> trippedIds = {};
  @override
  String? quarantinedPath;
  @override
  DateTime? lastSyncAt;
  @override
  String? lastSyncError;
  @override
  RetainedBackupAccount? retainedAccount;
  @override
  bool deleteSeparateOffered = false;

  Future<void> _record(String call) async {
    calls.add(call);
    final failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<void> setSyncSecrets(bool enabled) =>
      _record('setSyncSecrets($enabled)');

  @override
  Future<void> registerSeparate({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) => _record(
    'registerSeparate($baseUrl, $username, $password, '
    '$encryptionPassphrase)',
  );

  @override
  Future<void> loginAccount({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  }) => _record('loginAccount($baseUrl, $username, ${mode.name})');

  @override
  Future<void> backUpNow() => _record('backUpNow');

  @override
  Future<void> signOut() => _record('signOut');

  @override
  Future<void> deleteSeparateAccount({required String confirmedName}) =>
      _record('deleteSeparateAccount($confirmedName)');

  @override
  Future<BackupSwitchOutcome> switchToShared({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async {
    await _record('switchToShared($baseUrl)');
    return BackupSwitchOutcome(
      held: [_conflict],
      passphraseUnverified: true,
      passphraseWarning: 'check the passphrase',
    );
  }

  @override
  Future<void> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) async {
    await _record('resolvePinConflict');
    resolved = conflict;
    resolvedKeepLocal = keepLocal;
  }

  @override
  Future<void> deleteRetainedSeparateAccount({required String confirmedName}) =>
      _record('deleteRetainedSeparateAccount($confirmedName)');

  @override
  Future<void> declineRetainedDelete() => _record('declineRetainedDelete');
}

final class _FakeEditors extends ChangeNotifier implements EditorRegistryModel {
  @override
  EditorRegistry registry = EditorRegistry();

  final List<String> calls = [];

  @override
  Future<void> register(ExternalEditorDefinition editor) async {
    calls.add('register(${editor.displayName})');
    registry.put(editor);
    notifyListeners();
  }

  @override
  Future<void> remove(String id) async => calls.add('remove($id)');

  @override
  Future<void> setDefault(String id) async => calls.add('setDefault($id)');
}

/// The Settings window's link, end to end: [SettingsWindowHost] in the app,
/// [RemoteSettings] in the window, and the runner's relay between them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SettingsWindowHost host;
  late List<String> controlCalls;
  late _FakeBackup backup;
  late _FakeEditors editors;
  late bool checkForUpdates;
  late int threshold;
  late AppearanceController appearance;
  late List<AppAppearance> savedAppearances;
  Object? appearanceSaveFailure;

  void relay(MethodChannel from, MethodChannel to) {
    messenger.setMockMessageHandler(from.name, (message) {
      final reply = Completer<ByteData?>();
      ServicesBinding.instance.channelBuffers.push(
        to.name,
        message,
        reply.complete,
      );
      return reply.future;
    });
  }

  Future<void> nativeClosed() async {
    final reply = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      _control.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('closed')),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  SettingsWindowSources sources() => SettingsWindowSources(
    general: () => GeneralSettings(
      checkForUpdates: checkForUpdates,
      onCheckForUpdatesChanged: (enabled) async => checkForUpdates = enabled,
    ),
    editors: editors,
    previewDownloads: () => PreviewDownloadsSettings(
      available: true,
      capacityBytes: 512 << 20,
      thresholdBytes: threshold,
      onCapacityChanged: (_) async {},
      onThresholdChanged: (bytes) async => threshold = bytes,
      onClearCache: () async => 4096,
    ),
    backup: backup,
    gate: const SyncAccountGate(
      minimumSharedVersion: 'v9.9.9',
      sharedIncludesSeance56Fix: true,
    ),
    appearance: appearance,
  );

  setUp(() {
    backup = _FakeBackup();
    editors = _FakeEditors();
    checkForUpdates = true;
    threshold = 100 << 20;
    savedAppearances = [];
    appearanceSaveFailure = null;
    appearance = AppearanceController(
      save: (value) async {
        final failure = appearanceSaveFailure;
        if (failure != null) throw failure;
        savedAppearances.add(value);
      },
    );
    relay(_appLink, _windowLink);
    relay(_windowLink, _appLink);
    controlCalls = [];
    messenger.setMockMethodCallHandler(_control, (call) async {
      controlCalls.add(call.method);
      return null;
    });
    host = SettingsWindowHost(
      control: _control,
      link: _appLink,
      requestAppExit: () async => AppExitResponse.cancel,
    )..attach(sources());
  });

  tearDown(() {
    host.dispose();
    for (final channel in [_appLink, _windowLink]) {
      messenger.setMockMessageHandler(channel.name, null);
    }
    messenger.setMockMethodCallHandler(_control, null);
  });

  Future<RemoteSettings> openWindow([
    SettingsWindowTab tab = SettingsWindowTab.general,
  ]) async {
    expect(await host.open(tab), isTrue);
    final remote = await RemoteSettings.connect(link: _windowLink);
    addTearDown(remote.dispose);
    return remote;
  }

  test('hello brings every section and the tab asked for', () async {
    backup.account = const SyncAccount(
      baseUrl: 'https://sync.example',
      username: 'me',
      mode: SyncAccountMode.separate,
    );
    backup.pinConflicts = [_conflict];
    backup.lastSyncAt = DateTime.fromMillisecondsSinceEpoch(1234);

    final remote = await openWindow(SettingsWindowTab.sync);

    expect(controlCalls, ['open']);
    expect(host.connected, isTrue);
    expect(remote.page.value?.tab, SettingsWindowTab.sync);
    expect(remote.general?.checkForUpdates, isTrue);
    expect(remote.previewDownloads?.thresholdBytes, 100 << 20);
    expect(remote.gate.minimumSharedVersion, 'v9.9.9');
    expect(remote.gate.sharedIncludesSeance56Fix, isTrue);
    final mirrored = remote.backup!;
    expect(mirrored.account?.username, 'me');
    expect(mirrored.account?.mode, SyncAccountMode.separate);
    expect(mirrored.pinConflicts.single.locator, 'files.example:22');
    expect(
      mirrored.pinConflicts.single.pulled.fingerprintSha256,
      'SHA256:pulled',
    );
    expect(mirrored.lastSyncAt, DateTime.fromMillisecondsSinceEpoch(1234));
  });

  test('a section the app has no seam for is left out', () async {
    host.attach(const SettingsWindowSources());

    final remote = await openWindow();

    expect(remote.general, isNull);
    expect(remote.editors, isNull);
    expect(remote.previewDownloads, isNull);
    expect(remote.backup, isNull);
    // No Appearance tab, and the window draws the default theme.
    expect(remote.appearance, isNull);
    expect(remote.theme.value, AppAppearance.initial);
  });

  group('the theme', () {
    test('crosses in the first snapshot', () async {
      await appearance.setAppearance(
        ThemePresets.paper,
        ThemeModePreference.dark,
      );

      final remote = await openWindow(SettingsWindowTab.appearance);

      expect(remote.page.value?.tab, SettingsWindowTab.appearance);
      final expected = AppAppearance(
        palette: ThemePresets.paper,
        mode: ThemeModePreference.dark,
      );
      expect(remote.appearance?.value, expected);
      expect(remote.theme.value, expected);
    });

    test('set in the window, re-themes the app and the window', () async {
      final remote = await openWindow();
      expect(remote.theme.value, AppAppearance.initial);
      final palette = ThemePresets.bubblegum.copyWith(cornerScale: 0.35);

      await remote.appearance!.setAppearance(
        palette,
        ThemeModePreference.light,
      );

      final expected = AppAppearance(
        palette: palette,
        mode: ThemeModePreference.light,
      );
      expect(appearance.value, expected);
      expect(savedAppearances, [expected]);
      // The window's own theme follows through the snapshot that write
      // sent.
      await pumpEventQueue();
      expect(remote.theme.value, expected);
    });

    test('a snapshot that moves no theme leaves the window\'s alone', () async {
      final remote = await openWindow();
      var rethemed = 0;
      remote.theme.addListener(() => rethemed++);

      await remote.editors!.register(
        const ExternalEditorDefinition(
          id: 'linux.editor',
          displayName: 'Editor',
          platform: EditorHostPlatform.linux,
          launchTarget: '/usr/bin/editor',
        ),
      );
      await pumpEventQueue();

      expect(remote.editors!.registry.byId('linux.editor'), isNotNull);
      expect(rethemed, 0);
    });

    test(
      'a write the app could not save still re-themes, and says why',
      () async {
        final remote = await openWindow();
        appearanceSaveFailure = StateError('disk full');

        await expectLater(
          remote.appearance!.setAppearance(
            ThemePresets.vapor,
            ThemeModePreference.system,
          ),
          throwsA(
            isA<SettingsLinkException>().having(
              (e) => '$e',
              'message',
              contains('disk full'),
            ),
          ),
        );
        expect(appearance.value.palette, ThemePresets.vapor);
        await pumpEventQueue();
        expect(remote.theme.value.palette, ThemePresets.vapor);
      },
    );
  });

  test('writes from the window run on the app\'s models', () async {
    final remote = await openWindow();

    await remote.general!.onCheckForUpdatesChanged(false);
    await remote.previewDownloads!.onThresholdChanged(50 << 20);
    expect(await remote.previewDownloads!.onClearCache(), 4096);
    await remote.backup!.loginAccount(
      baseUrl: 'https://sync.example',
      username: 'me',
      password: 'pw',
      encryptionPassphrase: 'secret',
      mode: SyncAccountMode.shared,
    );

    expect(checkForUpdates, isFalse);
    expect(threshold, 50 << 20);
    expect(backup.calls, ['loginAccount(https://sync.example, me, shared)']);
  });

  test('a pin conflict crosses whole, both ways', () async {
    backup.pinConflicts = [_conflict];
    final remote = await openWindow();

    final outcome = await remote.backup!.switchToShared(
      baseUrl: 'https://sync.example',
      username: 'me',
      password: 'pw',
      encryptionPassphrase: 'secret',
    );
    await remote.backup!.resolvePinConflict(
      outcome.held.single,
      keepLocal: true,
    );

    expect(outcome.passphraseUnverified, isTrue);
    expect(outcome.passphraseWarning, 'check the passphrase');
    expect(backup.resolved?.locator, 'files.example:22');
    expect(backup.resolved?.local.fingerprintSha256, 'SHA256:local');
    expect(backup.resolved?.pulled.host, 'files.example');
    expect(backup.resolvedKeepLocal, isTrue);
  });

  test(
    'the enrollment errors the section words differently keep their type',
    () async {
      final remote = await openWindow();

      backup.failWith = KdfDowngradeException(
        const Argon2Params(
          memory: 1024,
          iterations: 1,
          parallelism: 1,
          hashLength: 32,
        ),
      );
      await expectLater(
        remote.backup!.registerSeparate(
          baseUrl: 'https://sync.example',
          username: 'me',
          password: 'pw',
          encryptionPassphrase: 'secret',
        ),
        throwsA(
          isA<KdfDowngradeException>().having(
            (e) => e.offered.memory,
            'offered.memory',
            1024,
          ),
        ),
      );

      backup.failWith = const RegistrationClosedException();
      await expectLater(
        remote.backup!.backUpNow(),
        throwsA(isA<RegistrationClosedException>()),
      );

      backup.failWith = StateError('disk full');
      await expectLater(
        remote.backup!.signOut(),
        throwsA(
          isA<SettingsLinkException>().having(
            (e) => '$e',
            'message',
            contains('disk full'),
          ),
        ),
      );
    },
  );

  test('the app sends a snapshot when a model changes', () async {
    final remote = await openWindow();
    final registry = remote.editors!;
    var notified = 0;
    registry.addListener(() => notified++);

    await registry.register(
      const ExternalEditorDefinition(
        id: 'linux.editor',
        displayName: 'Editor',
        platform: EditorHostPlatform.linux,
        launchTarget: '/usr/bin/editor',
      ),
    );
    await pumpEventQueue();

    expect(editors.calls, ['register(Editor)']);
    expect(registry.registry.byId('linux.editor')?.displayName, 'Editor');
    expect(notified, 1);
  });

  test('closing hides the screen; opening again shows a fresh one', () async {
    final remote = await openWindow();
    final first = remote.page.value!;

    await nativeClosed();
    await pumpEventQueue();
    expect(host.visible, isFalse);
    expect(remote.page.value, isNull);

    // Nothing is sent to a hidden window, and showing it carries the
    // settings as they are by then.
    checkForUpdates = false;
    backup.syncing = true;
    backup.notifyListeners();
    await pumpEventQueue();
    expect(remote.backup!.syncing, isFalse);

    expect(await host.open(SettingsWindowTab.editing), isTrue);

    final second = remote.page.value!;
    expect(second.tab, SettingsWindowTab.editing);
    expect(second.generation, isNot(first.generation));
    expect(remote.general?.checkForUpdates, isFalse);
    expect(remote.backup!.syncing, isTrue);
  });

  test('opening a showing window switches its tab', () async {
    final remote = await openWindow();
    final tabs = <SettingsWindowTab>[];
    final subscription = remote.tabRequests.listen(tabs.add);
    addTearDown(subscription.cancel);

    expect(await host.open(SettingsWindowTab.sync), isTrue);
    await pumpEventQueue();

    expect(tabs, [SettingsWindowTab.sync]);
  });

  test('a request to quit is the app\'s to answer', () async {
    final remote = await openWindow();

    expect(await remote.requestAppExit(), AppExitResponse.cancel);

    // With no app left to ask, quitting is not held up, and the window
    // says it lost the app.
    messenger.setMockMessageHandler(_windowLink.name, (_) async => null);
    expect(await remote.requestAppExit(), AppExitResponse.exit);
    expect(remote.lost, isTrue);
  });

  test(
    'a runner without the window reports it, for the dialog fallback',
    () async {
      messenger.setMockMethodCallHandler(_control, null);

      expect(await host.open(SettingsWindowTab.general), isFalse);
    },
  );

  test(
    'a runner that could not create the window reports it, for the dialog',
    () async {
      messenger.setMockMethodCallHandler(_control, (call) async {
        throw PlatformException(code: 'open_failed');
      });

      expect(await host.open(SettingsWindowTab.general), isFalse);
    },
  );

  test('a write after the app stops answering fails, and says so', () async {
    final remote = await openWindow();

    messenger.setMockMessageHandler(_windowLink.name, (_) async => null);

    await expectLater(
      remote.general!.onCheckForUpdatesChanged(false),
      throwsA(isA<SettingsLinkException>()),
    );
    expect(remote.lost, isTrue);
    expect(checkForUpdates, isTrue);
  });
}
