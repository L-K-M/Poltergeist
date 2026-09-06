import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// Pins the pinned Séance rev's bookmark decode contract (04 §2.1) through
// this package's barrel: consumers must never import seance_core directly,
// so a pin that drops or renames a bookmark symbol must fail here, not in
// the app layer. The upstream suite owns exhaustive coverage; these tests
// pin the contract Poltergeist's connect flow and sidebar will rely on.

const _bookmarkId = '5f0c2a7e-3c1b-4b8e-9a51-2f6f0e7d1c22';
const _recordId = 'bookmark:$_bookmarkId';
final _createdAt = DateTime.utc(2026, 9, 7, 8, 30);
final _updatedAt = DateTime.utc(2026, 9, 7, 9, 31);

Map<String, dynamic> _baseJson(BookmarkKind kind) => {
      'id': _bookmarkId,
      'kind': kind.name,
      'label': 'Work',
      'sortKey': 'hm',
      'createdAt': _createdAt.toIso8601String(),
      'updatedAt': _updatedAt.toIso8601String(),
    };

void main() {
  test('round-trips a savedSync bookmark through the barrel', () {
    final bookmark = Bookmark(
      id: _bookmarkId,
      kind: BookmarkKind.savedSync,
      label: 'Deploy',
      sync: SavedSyncSpec(
        source: const BookmarkLocation(path: '~/site'),
        destination: const BookmarkLocation(
          server: BookmarkServerRef(
            identity: EmbeddedHostIdentity(
              host: 'nas.local',
              username: 'alice',
              authMethod: AuthMethod.privateKey,
            ),
          ),
          path: '/srv/site',
        ),
        ignoreRules: ['.git/**'],
        rules: const {'direction': 'leftToRight'},
      ),
      sortKey: 'd',
      createdAt: _createdAt,
      updatedAt: _updatedAt,
    );

    final decoded =
        Bookmark.fromJson(bookmark.toJson(), recordId: _recordId);

    expect(decoded.toJson(), bookmark.toJson());
    expect(decoded.sync!.rules, {'direction': 'leftToRight'});
    expect(decoded.sync!.rulesVersion, 1);
  });

  test('retains unknown rules keys verbatim for older-device re-saves', () {
    final decoded = Bookmark.fromJson({
      ..._baseJson(BookmarkKind.savedSync),
      'sync': {
        'source': {'path': '~/site'},
        'destination': {'path': '/srv/site'},
        'rules': {'direction': 'leftToRight', 'future': {'enabled': true}},
      },
    }, recordId: _recordId);

    // Unknown keys survive decode -> re-encode, so an older device's re-save
    // cannot strip a newer device's sync settings (04 §2.1).
    expect(
      decoded.sync!.rules['future'],
      {'enabled': true},
    );
    expect(
      Bookmark.fromJson(decoded.toJson(), recordId: _recordId).sync!.rules,
      decoded.sync!.rules,
    );
  });

  test('binds the payload id to the envelope record id', () {
    final json = {
      ..._baseJson(BookmarkKind.localFolder),
      'localPath': '~/Downloads',
    };

    expect(
      () => Bookmark.fromJson(json, recordId: 'bookmark:someone-else'),
      throwsFormatException,
    );
  });

  test('rejects an out-of-range embedded identity port at decode', () {
    // An out-of-range port would otherwise fail only at connect time and
    // mint a malformed hostkey:<host:port> id (04 §2.1).
    final json = {
      ..._baseJson(BookmarkKind.remotePath),
      'server': {
        'identity': {
          'host': 'nas.local',
          'port': 65536,
          'username': 'alice',
          'authMethod': 'password',
        },
      },
      'remotePath': '/srv/backups',
    };

    expect(
      () => Bookmark.fromJson(json, recordId: _recordId),
      throwsFormatException,
    );
  });

  test('refuses an unknown kind instead of decoding by guesswork', () {
    // Unknown kinds stay skip-preserved at the coordinator (04 §3.2); decode
    // itself must refuse so the record is never activated on a guess.
    final json = {
      ..._baseJson(BookmarkKind.localFolder),
      'kind': 'volume',
      'localPath': '~/Downloads',
    };

    expect(
      () => Bookmark.fromJson(json, recordId: _recordId),
      throwsFormatException,
    );
  });

  test('rejects a blank label rather than activating an unnamed bookmark', () {
    final json = {
      ..._baseJson(BookmarkKind.localFolder),
      'label': '   ',
      'localPath': '~/Downloads',
    };

    expect(
      () => Bookmark.fromJson(json, recordId: _recordId),
      throwsFormatException,
    );
  });

  test('the vault plumbing surfaces through the same barrel', () async {
    // The app-layer ports (file stores, MasterKeyManager) reach SecretVault
    // and friends only through this barrel; pin that the pinned rev keeps
    // them exported and dartssh2-free.
    final store = InMemoryVaultStore();
    final vault = SecretVault(store, List.filled(32, 1));
    final secret = Secret(
      id: 'secret-1',
      kind: SecretKind.password,
      value: 'hunter2',
    );

    await vault.putSecret(secret);
    expect((await vault.getSecret('secret-1'))!.value, 'hunter2');

    final sealed = await store.getSecretBlob('secret-1');
    expect(sealed, isNotNull);
    // The blob is opaque ciphertext: never the plaintext, never ASCII JSON.
    expect(String.fromCharCodes(sealed!), isNot(contains('hunter2')));

    await vault.deleteSecret('secret-1');
    expect(await vault.getSecret('secret-1'), isNull);
  });
}
