// D19's link-only update check (00 D19/D23, 07 §3.10, 01 §6): the
// controller owns the once-per-launch GitHub latest-release lookup and
// the banner's session state. The pinned contract is the request shape
// — one plain GET of the static endpoint, no query, no body, no
// install identifier — because 01 §6's "phones home for exactly one
// thing" claim is only true while nothing else rides along.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  final requests = <http.BaseRequest>[];

  http.Client clientWith(Object? body, {int status = 200}) =>
      http_testing.MockClient((request) async {
        requests.add(request);
        return http.Response(
          body is String ? body : jsonEncode(body),
          status,
        );
      });

  http.Client failingClient() => http_testing.MockClient((request) async {
    requests.add(request);
    throw const SocketException('offline');
  });

  Map<String, Object?> releaseJson(String tag) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
  };

  setUp(requests.clear);

  group('checkForUpdate', () {
    test('a newer release tag surfaces an UpdateInfo', () async {
      final controller = UpdateCheckController(
        checker: UpdateChecker(
          repo: poltergeistUpdateRepo,
          client: clientWith(releaseJson('v9.9.9')),
        ),
      );
      var notified = 0;
      controller.addListener(() => notified++);

      await controller.checkForUpdate('0.2.0');

      expect(controller.update, isNotNull);
      expect(controller.update!.latestVersion, '9.9.9');
      expect(notified, 1);
    });

    test(
      'the request is the pinned D19 shape: one GET, no query, no body',
      () async {
        final controller = UpdateCheckController(
          checker: UpdateChecker(
            repo: poltergeistUpdateRepo,
            client: clientWith(releaseJson('v9.9.9')),
          ),
        );
        await controller.checkForUpdate('0.2.0');

        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api.github.com/repos/L-K-M/Poltergeist/releases/latest',
        );
        expect(request.url.query, isEmpty);
        // A link-only check carries nothing to compare against server-
        // side — the version stays on the device (01 §6).
        expect((request as http.Request).body, isEmpty);
        expect(
          controller.update!.releasesUrl.toString(),
          'https://github.com/L-K-M/Poltergeist/releases/latest',
        );
      },
    );

    test('an up-to-date tag surfaces nothing', () async {
      final controller = UpdateCheckController(
        checker: UpdateChecker(
          repo: poltergeistUpdateRepo,
          client: clientWith(releaseJson('v0.2.0')),
        ),
      );
      await controller.checkForUpdate('0.2.0');
      expect(controller.update, isNull);
    });

    test('drafts, prereleases, and failures all surface nothing', () async {
      for (final body in [
        {...releaseJson('v9.9.9'), 'draft': true},
        {...releaseJson('v9.9.9'), 'prerelease': true},
        'not json',
      ]) {
        final controller = UpdateCheckController(
          checker: UpdateChecker(
            repo: poltergeistUpdateRepo,
            client: clientWith(body),
          ),
        );
        await controller.checkForUpdate('0.2.0');
        expect(controller.update, isNull, reason: 'body: $body');
      }
      final offline = UpdateCheckController(
        checker: UpdateChecker(
          repo: poltergeistUpdateRepo,
          client: failingClient(),
        ),
      );
      await offline.checkForUpdate('0.2.0');
      expect(offline.update, isNull);
      final rateLimited = UpdateCheckController(
        checker: UpdateChecker(
          repo: poltergeistUpdateRepo,
          client: clientWith('', status: 403),
        ),
      );
      await rateLimited.checkForUpdate('0.2.0');
      expect(rateLimited.update, isNull);
    });

    test('disabled at boot: no request ever leaves', () async {
      final controller = UpdateCheckController(
        enabled: false,
        checker: UpdateChecker(
          repo: poltergeistUpdateRepo,
          client: clientWith(releaseJson('v9.9.9')),
        ),
      );
      await controller.checkForUpdate('0.2.0');
      expect(controller.update, isNull);
      expect(requests, isEmpty);
    });
  });

  group('dismiss and the opt-out toggle', () {
    test('dismiss clears the banner for this session', () async {
      final controller = UpdateCheckController(
        checker: UpdateChecker(
          repo: poltergeistUpdateRepo,
          client: clientWith(releaseJson('v9.9.9')),
        ),
      );
      await controller.checkForUpdate('0.2.0');
      var notified = 0;
      controller.addListener(() => notified++);

      controller.dismiss();
      expect(controller.update, isNull);
      expect(notified, 1);
      // Dismissing nothing is a no-op, not a rebuild signal.
      controller.dismiss();
      expect(notified, 1);
    });

    test(
      'setEnabled(false) persists, clears a live banner, and skips '
      'later checks',
      () async {
        final saved = <bool>[];
        final controller = UpdateCheckController(
          checker: UpdateChecker(
            repo: poltergeistUpdateRepo,
            client: clientWith(releaseJson('v9.9.9')),
          ),
          onEnabledChanged: (value) async => saved.add(value),
        );
        await controller.checkForUpdate('0.2.0');
        expect(controller.update, isNotNull);

        await controller.setEnabled(false);
        expect(saved, [false]);
        expect(controller.enabled, isFalse);
        expect(controller.update, isNull);

        requests.clear();
        await controller.checkForUpdate('0.2.0');
        expect(requests, isEmpty);
      },
    );

    test('a failed persist reverts the toggle and rethrows', () async {
      final controller = UpdateCheckController(
        checker: UpdateChecker(repo: poltergeistUpdateRepo),
        onEnabledChanged: (_) async => throw StateError('disk full'),
      );
      await expectLater(
        controller.setEnabled(false),
        throwsA(isA<StateError>()),
      );
      expect(controller.enabled, isTrue);
    });
  });

  group('AppPreferences updates.checkEnabled', () {
    late Directory dir;
    late AppPreferences prefs;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('update_prefs_test');
      prefs = AppPreferences(
        store: SettingsStore(path: p.join(dir.path, 'settings.json')),
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('defaults on — the check is opt-out per D19/D23', () async {
      expect(await prefs.loadUpdateChecksEnabled(), isTrue);
    });

    test('the opt-out round-trips through a reopened store', () async {
      await prefs.saveUpdateChecksEnabled(false);
      final reopened = AppPreferences(
        store: SettingsStore(path: p.join(dir.path, 'settings.json')),
      );
      expect(await reopened.loadUpdateChecksEnabled(), isFalse);
    });
  });
}
