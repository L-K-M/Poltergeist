import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/probe_controller.dart';
import 'package:poltergeist_app/services/probe_settings_store.dart';
import 'package:poltergeist_app/services/settings_store.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;
  late SettingsStore settings;
  late ProbeSettingsStore probe;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_probe_settings_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
    settings = SettingsStore(path: settingsFile.path);
    probe = ProbeSettingsStore(store: settings);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  /// Seeds raw settings.json contents before the store's first read.
  Future<void> seed(Map<String, Object?> contents) =>
      settingsFile.writeAsString(jsonEncode(contents));

  Future<Map<String, Object?>> readFile() async =>
      (jsonDecode(await settingsFile.readAsString()) as Map)
          .cast<String, Object?>();

  /// A second facade over the same file: proves facts survive a restart.
  ProbeSettingsStore reopened() =>
      ProbeSettingsStore(store: SettingsStore(path: settingsFile.path));

  Future<ProbeServerFacts> load(
    String serverId, {
    String host = 'sftp.example',
    int port = 22,
  }) => probe.loadServerFacts(serverId: serverId, host: host, port: port);

  test('global preference defaults to enabled on a fresh store', () async {
    expect(await probe.loadGlobalPreference(), ProbePreference.enabled);
  });

  test('only a persisted false disables probes', () async {
    await seed({'probe.enabled': false});
    expect(await reopened().loadGlobalPreference(), ProbePreference.disabled);

    // Anything that is not an explicit opt-out reads as the 02 §4 default.
    await seed({'probe.enabled': 'no'});
    expect(await reopened().loadGlobalPreference(), ProbePreference.enabled);
  });

  test('server facts default to unseen on a fresh store', () async {
    expect(
      await load('bookmark-a'),
      const ProbeServerFacts(
        exposure: FavoriteExposure.unseen,
        connected: FavoriteConnection.neverConnected,
      ),
    );
  });

  test('markSeen round-trips through the file and a fresh store', () async {
    await probe.markSeen(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );

    expect((await load('bookmark-a')).exposure, FavoriteExposure.seen);
    expect(
      (await reopened().loadServerFacts(
        serverId: 'bookmark-a',
        host: 'sftp.example',
        port: 22,
      )).exposure,
      FavoriteExposure.seen,
    );
    final servers = (await readFile())['probe.servers'] as Map;
    expect(servers['bookmark-a'], {
      'host': 'sftp.example',
      'port': 22,
      'exposure': 'seen',
      'connected': false,
    });
  });

  test('markConnected round-trips both facts through a fresh store', () async {
    await probe.markConnected(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );

    final facts = await reopened().loadServerFacts(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );
    expect(facts.exposure, FavoriteExposure.seen);
    expect(facts.connected, FavoriteConnection.connected);
  });

  test('concurrent mutations cannot clobber each other', () async {
    // Both operations read the servers map before either writes; without
    // internal serialization the second write clobbers the first record.
    final first = probe.markSeen(
      serverId: 'bookmark-a',
      host: 'a.example',
      port: 22,
    );
    final second = probe.markConnected(
      serverId: 'bookmark-b',
      host: 'b.example',
      port: 22,
    );

    await Future.wait([first, second]);

    expect(
      (await probe.loadServerFacts(
        serverId: 'bookmark-a',
        host: 'a.example',
        port: 22,
      )).exposure,
      FavoriteExposure.seen,
    );
    expect(
      (await probe.loadServerFacts(
        serverId: 'bookmark-b',
        host: 'b.example',
        port: 22,
      )).connected,
      FavoriteConnection.connected,
    );
  });

  test('markSeen preserves an already-recorded connection', () async {
    await probe.markConnected(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );
    await probe.markSeen(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );

    expect((await load('bookmark-a')).connected, FavoriteConnection.connected);
  });

  test('markSeen on a retargeted endpoint drops the old connection', () async {
    await probe.markConnected(
      serverId: 'bookmark-a',
      host: 'old.example',
      port: 22,
    );

    await probe.markSeen(serverId: 'bookmark-a', host: 'new.example', port: 22);

    // The connection fact belongs to the old endpoint; the retarget reset
    // (03 §3.4) must not let it survive the rebind.
    expect(
      (await probe.loadServerFacts(
        serverId: 'bookmark-a',
        host: 'new.example',
        port: 22,
      )).connected,
      FavoriteConnection.neverConnected,
    );
  });

  test(
    'retargeting resets exposure and history and persists the reset',
    () async {
      await probe.markConnected(
        serverId: 'bookmark-a',
        host: 'old.example',
        port: 22,
      );

      final facts = await probe.loadServerFacts(
        serverId: 'bookmark-a',
        host: 'new.example',
        port: 22,
      );

      expect(facts.exposure, FavoriteExposure.unseen);
      expect(facts.connected, FavoriteConnection.neverConnected);
      // The reset is durable: the record now binds the new endpoint.
      final servers = (await readFile())['probe.servers'] as Map;
      expect(servers['bookmark-a'], {
        'host': 'new.example',
        'port': 22,
        'exposure': 'unseen',
        'connected': false,
      });
      final reloaded = await reopened().loadServerFacts(
        serverId: 'bookmark-a',
        host: 'new.example',
        port: 22,
      );
      expect(reloaded.exposure, FavoriteExposure.unseen);
    },
  );

  test('a port change is a retarget', () async {
    await probe.markSeen(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );

    expect(
      (await probe.loadServerFacts(
        serverId: 'bookmark-a',
        host: 'sftp.example',
        port: 2222,
      )).exposure,
      FavoriteExposure.unseen,
    );
  });

  test('the host binding ignores case', () async {
    await probe.markSeen(
      serverId: 'bookmark-a',
      host: 'SFTP.EXAMPLE',
      port: 22,
    );

    expect(
      (await probe.loadServerFacts(
        serverId: 'bookmark-a',
        host: 'sftp.example',
        port: 22,
      )).exposure,
      FavoriteExposure.seen,
    );
  });

  test('removeServer drops the device-local record', () async {
    await probe.markSeen(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );
    await probe.removeServer('bookmark-a');

    expect((await load('bookmark-a')).exposure, FavoriteExposure.unseen);
    expect((await readFile())['probe.servers'], isEmpty);
  });

  test('malformed records read as unseen and are repaired', () async {
    await seed({
      'probe.servers': {
        'bookmark-a': {
          'host': 'sftp.example',
          'port': 'twenty-two',
          'exposure': 'seen',
          'connected': true,
        },
        'bookmark-b': 'not even a map',
      },
    });

    final facts = await reopened().loadServerFacts(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );

    expect(facts.exposure, FavoriteExposure.unseen);
    expect(facts.connected, FavoriteConnection.neverConnected);
    final servers = (await readFile())['probe.servers'] as Map;
    expect(servers['bookmark-a'], {
      'host': 'sftp.example',
      'port': 22,
      'exposure': 'unseen',
      'connected': false,
    });

    // A non-Map record is repaired too, not left to accumulate.
    expect(
      (await reopened().loadServerFacts(
        serverId: 'bookmark-b',
        host: 'other.example',
        port: 22,
      )).exposure,
      FavoriteExposure.unseen,
    );
    final repairedServers = (await readFile())['probe.servers'] as Map;
    expect(repairedServers['bookmark-b'], {
      'host': 'other.example',
      'port': 22,
      'exposure': 'unseen',
      'connected': false,
    });
  });

  test('invalid JSON reads as a fresh store', () async {
    await settingsFile.writeAsString('{not json');

    // SettingsStore quarantines the corrupt file and starts empty; the
    // probe facade sees the 02 §4 defaults, never the garbage.
    expect(
      (await reopened().loadServerFacts(
        serverId: 'bookmark-a',
        host: 'sftp.example',
        port: 22,
      )).exposure,
      FavoriteExposure.unseen,
    );
    expect(await reopened().loadGlobalPreference(), ProbePreference.enabled);
  });

  test('unknown exposure and connection values read as unseen', () async {
    await seed({
      'probe.servers': {
        'bookmark-a': {
          'host': 'sftp.example',
          'port': 22,
          'exposure': 'sometimes',
          'connected': 'yes',
        },
      },
    });

    final facts = await reopened().loadServerFacts(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );
    expect(facts.exposure, FavoriteExposure.unseen);
    expect(facts.connected, FavoriteConnection.neverConnected);
  });

  test('the file carries no probe results, only eligibility', () async {
    await probe.markConnected(
      serverId: 'bookmark-a',
      host: 'sftp.example',
      port: 22,
    );

    final servers = (await readFile())['probe.servers'] as Map;
    final record = servers['bookmark-a'] as Map;
    expect(
      record.keys,
      unorderedEquals(['host', 'port', 'exposure', 'connected']),
    );
  });
}
