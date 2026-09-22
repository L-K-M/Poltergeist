@TestOn('vm')
library;

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  SyncPair pair(SyncEndpoint left, SyncEndpoint right) => SyncPair(
    id: 'fav-1',
    name: 'p',
    left: left,
    right: right,
    rules: const SyncRuleSet(),
  );

  const identity = EmbeddedHostIdentity(
    host: 'Example.com',
    port: 22,
    username: 'alice',
    authMethod: AuthMethod.agent,
  );
  const otherIdentity = EmbeddedHostIdentity(
    host: 'other.example.com',
    port: 2222,
    username: 'bob',
    authMethod: AuthMethod.password,
  );

  group('syncPairId (05 §9)', () {
    test('stable across pane swaps — the digests sort', () {
      final a = syncPairId(
        pair(const LocalEndpoint('/a'), const LocalEndpoint('/b')),
      );
      final b = syncPairId(
        pair(const LocalEndpoint('/b'), const LocalEndpoint('/a')),
      );
      expect(a, b);
    });

    test('trailing separators and host case fold away', () {
      final plain = syncPairId(
        pair(
          const LocalEndpoint('/data'),
          const RemoteEndpoint(server: BookmarkServerRef(
            identity: identity,
          ), path: '/srv'),
        ),
      );
      final spelled = syncPairId(
        pair(
          const LocalEndpoint('/data/'),
          const RemoteEndpoint(server: BookmarkServerRef(
            identity: EmbeddedHostIdentity(
              host: 'example.COM',
              port: 22,
              username: 'alice',
              authMethod: AuthMethod.agent,
            ),
          ), path: '/srv/'),
        ),
      );
      expect(plain, spelled);
    });

    test('distinct endpoints produce distinct ids', () {
      final a = syncPairId(
        pair(
          const LocalEndpoint('/a'),
          const RemoteEndpoint(
            server: BookmarkServerRef(identity: identity),
            path: '/srv',
          ),
        ),
      );
      final b = syncPairId(
        pair(
          const LocalEndpoint('/a'),
          const RemoteEndpoint(
            server: BookmarkServerRef(identity: otherIdentity),
            path: '/srv',
          ),
        ),
      );
      expect(a, isNot(b));
    });

    test(
      'the sorted-digest construction defeats prefix-shaped aliasing',
      () {
        // 'local:/a' + 'local:/bc' vs 'local:/ab' + 'local:/c' — raw
        // concatenation would collide; per-side digests never do.
        final x = syncPairId(
          pair(const LocalEndpoint('/a'), const LocalEndpoint('/bc')),
        );
        final y = syncPairId(
          pair(const LocalEndpoint('/ab'), const LocalEndpoint('/c')),
        );
        expect(x, isNot(y));
      },
    );

    test(
      'known-insensitive sides case-fold their identity input',
      () {
        final folded = syncPairId(
          pair(const LocalEndpoint('/Data'), const LocalEndpoint('/x')),
          leftCaseInsensitive: true,
        );
        final lower = syncPairId(
          pair(const LocalEndpoint('/data'), const LocalEndpoint('/x')),
          leftCaseInsensitive: true,
        );
        expect(folded, lower);

        // …but a case-SENSITIVE side never folds — '/Data' and '/data'
        // are genuinely different roots there.
        final sensitive = syncPairId(
          pair(const LocalEndpoint('/Data'), const LocalEndpoint('/x')),
        );
        final sensitiveLower = syncPairId(
          pair(const LocalEndpoint('/data'), const LocalEndpoint('/x')),
        );
        expect(sensitive, isNot(sensitiveLower));
      },
    );

    test(
      'normalization-insensitive sides NFC-fold their identity input',
      () {
        // 'café' NFC vs NFD spellings of one root path.
        final nfc = syncPairId(
          pair(const LocalEndpoint('/caf\u00e9'), const LocalEndpoint('/x')),
          leftNormalizationInsensitive: true,
        );
        final nfd = syncPairId(
          pair(
            const LocalEndpoint('/cafe\u0301'),
            const LocalEndpoint('/x'),
          ),
          leftNormalizationInsensitive: true,
        );
        expect(nfc, nfd);

        final sensitive = syncPairId(
          pair(const LocalEndpoint('/caf\u00e9'), const LocalEndpoint('/x')),
        );
        final sensitiveNfd = syncPairId(
          pair(const LocalEndpoint('/cafe\u0301'), const LocalEndpoint('/x')),
        );
        expect(sensitive, isNot(sensitiveNfd));
      },
    );

    test('a serverConfigId ref keys distinctly from a resolved identity',
        () {
      final configured = syncPairId(
        pair(
          const LocalEndpoint('/a'),
          const RemoteEndpoint(
            server: BookmarkServerRef(serverConfigId: 'cfg-1'),
            path: '/srv',
          ),
        ),
      );
      final embedded = syncPairId(
        pair(
          const LocalEndpoint('/a'),
          const RemoteEndpoint(
            server: BookmarkServerRef(identity: identity),
            path: '/srv',
          ),
        ),
      );
      expect(configured, isNot(embedded));
    });
  });
}
