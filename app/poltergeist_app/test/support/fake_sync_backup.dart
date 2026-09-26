// In-memory bindings for the Settings → Backup seams: widget tests cannot
// touch the filesystem or keystore, and service tests want scriptable
// transports rather than an HTTP server. The record store mirrors
// PersistentLocalRecordStore's semantics (dirty set, displaced winners,
// both cursors) minus persistence; the transport mirrors the Séance
// server's shape (token on register/login, seq assignment on push,
// `since` filtering on pull) so the real enrollment/coordinator drivers
// run end-to-end against it.
import 'dart:async';

import 'package:poltergeist_app/services/sync_credentials.dart';
import 'package:poltergeist_app/services/sync_transport.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'fake_bookmark_store.dart';

/// A [SyncRecordStore] mirroring [PersistentLocalRecordStore]'s rules:
/// LWW on put, displaced pulled winners behind dirty rivals, monotone
/// cursors — only the atomic file write is absent.
final class InMemorySyncRecordStore implements SyncRecordStore {
  @override
  Future<EncryptedRecord?> settlePush(
    EncryptedRecord sent,
    PushResult result,
  ) async {
    if (result.id != sent.id) {
      throw ArgumentError('push result must identify the sent record');
    }
    if (!identical(_records[sent.id], sent) || !_dirty.contains(sent.id)) {
      return null;
    }
    if (result.accepted) {
      await markSynced(sent.id, result.seq);
      return null;
    }
    return restoreDisplaced(sent.id);
  }

  final _records = <String, EncryptedRecord>{};
  final _dirty = <String>{};
  final _displaced = <String, EncryptedRecord>{};
  var _highWaterSeq = 0;
  var _lastAppliedSeq = 0;

  @override
  Future<List<EncryptedRecord>> allRecords() async =>
      List.unmodifiable(_records.values);

  @override
  Future<EncryptedRecord?> getRecord(String id) async => _records[id];

  @override
  Future<void> putLocal(EncryptedRecord record) async {
    final existing = _records[record.id];
    if (existing != null &&
        !_dirty.contains(record.id) &&
        identical(Lww.resolve(existing, record), existing)) {
      _displaced[record.id] = existing;
    }
    _records[record.id] = record;
    _dirty.add(record.id);
  }

  @override
  Future<void> putRemote(EncryptedRecord record) async {
    final existing = _records[record.id];
    if (existing != null && !identical(Lww.resolve(existing, record), record)) {
      if (_dirty.contains(record.id)) _displaced[record.id] = record;
      return;
    }
    _records[record.id] = record;
    _dirty.remove(record.id);
    _displaced.remove(record.id);
  }

  @override
  Future<List<EncryptedRecord>> dirtyRecords() async =>
      List.unmodifiable(_dirty.map((id) => _records[id]!));

  @override
  Future<void> markSynced(String id, int seq) async {
    final record = _records[id];
    if (record != null) _records[id] = record.withSeq(seq);
    _dirty.remove(id);
    _displaced.remove(id);
  }

  @override
  Future<int> highWaterSeq() async => _highWaterSeq;

  @override
  Future<void> setHighWaterSeq(int seq) async {
    if (seq > _highWaterSeq) _highWaterSeq = seq;
  }

  @override
  Future<int> lastAppliedSeq() async => _lastAppliedSeq;

  @override
  Future<void> setLastAppliedSeq(int seq) async {
    if (seq > _lastAppliedSeq) _lastAppliedSeq = seq;
  }

  @override
  Future<void> resetSyncCursors() async {
    _highWaterSeq = 0;
    _lastAppliedSeq = 0;
  }

  @override
  Future<EncryptedRecord?> restoreDisplaced(String id) async {
    final restored = _displaced.remove(id);
    if (restored != null) {
      _records[id] = restored;
      _dirty.remove(id);
    }
    return restored;
  }

  @override
  Future<List<EncryptedRecord>> displacedRecords() async =>
      List.unmodifiable(_displaced.values);
}

/// The keystore seam, in memory.
final class FakeSyncCredentialStore implements SyncCredentialStore {
  String? token;
  List<int>? vaultKey;

  @override
  Future<void> writeToken(String token) async => this.token = token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> deleteToken() async => token = null;

  @override
  Future<void> writeVaultKey(List<int> vaultKey) async =>
      this.vaultKey = List.of(vaultKey);
}

/// §4.4's parked-token slot, in memory.
final class FakeRetainedSyncTokenStore implements RetainedSyncTokenStore {
  String? token;

  @override
  Future<void> write(String token) async => this.token = token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> clear() async => token = null;
}

/// Durable enrollment state, in memory — [deviceId] is fixed so a test's
/// sealed records carry a known author.
final class FakeSyncEnrollmentState implements SyncEnrollmentState {
  FakeSyncEnrollmentState({this.id = 'test-device'});

  final String id;
  bool unverified = false;
  final raised = <String>{};
  SyncAccount? enrolled;

  @override
  Future<String> deviceId() async => id;

  @override
  Future<bool> passphraseUnverified() async => unverified;

  @override
  Future<void> setPassphraseUnverified(bool value) async =>
      unverified = value;

  @override
  Future<Set<String>> notices() async => Set.of(raised);

  @override
  Future<void> setNotice(String notice, bool active) async {
    if (active) {
      raised.add(notice);
    } else {
      raised.remove(notice);
    }
  }

  @override
  Future<SyncAccount?> account() async => enrolled;

  @override
  Future<void> setAccount(SyncAccount? account) async => enrolled = account;
}

/// One fake server the [fakeTransportFactory] hands a transport into: the
/// scripted KDF parameters, the registration gate, the stored records, and
/// the call log the assertions read.
final class FakeSyncServer {
  /// prelogin's answer. The default is the minimum the enrollment KDF
  /// gate accepts (§4.5 refuses weaker); a below-minimum script exercises
  /// the refusal path.
  Argon2Params argonParams = const Argon2Params();
  String argonSalt = 'AAAAAAAAAAAAAAAAAAAAAA=='; // 16 zero bytes

  /// When true, register() throws the 403 → RegistrationClosedException.
  bool registrationClosed = false;

  /// When true, pull/push/login throw the 401 the coordinator reports as
  /// `authFailed` — the dead-account notice path.
  bool unauthorized = false;

  /// The records pull() serves — pre-seeded for the trial-decrypt and the
  /// §4.4 quarantine tests.
  final records = <EncryptedRecord>[];

  /// What each transport observed.
  final pullSinces = <int>[];
  final pushed = <EncryptedRecord>[];
  var deleteAccountCalls = 0;
  var loginCalls = 0;
  var registerCalls = 0;
  var seq = 0;
}

/// Builds transports bound to one [FakeSyncServer]; the [seen] transports
/// list records construction order (baseUrl/token) for the switch test.
SyncTransportFactory fakeTransportFactory(
  FakeSyncServer server,
  List<FakeSyncTransport> seen,
) =>
    (baseUrl, {token}) {
      final transport =
          FakeSyncTransport(server, baseUrl: baseUrl, token: token);
      seen.add(transport);
      return transport;
    };

/// A [SyncTransport] over [FakeSyncServer] — assign the seq the real
/// server would and honor the scripted gates.
final class FakeSyncTransport implements SyncTransport {
  FakeSyncTransport(this.server, {required this.baseUrl, String? token})
      : // The seeded session token lands on the private slot.
        // ignore: prefer_initializing_formals
        _token = token;

  final FakeSyncServer server;
  final String baseUrl;
  String? _token;
  var closed = false;

  @override
  String? get token => _token;

  void _requireAuth() {
    if (server.unauthorized) {
      throw const ApiError(code: 'unauthorized', message: 'unauthorized');
    }
  }

  @override
  Future<void> register(RegisterRequest request) async {
    server.registerCalls++;
    if (server.registrationClosed) {
      throw const ApiError(
          code: 'registration_closed', message: 'registration closed');
    }
    _token = 'token-${request.username}';
  }

  @override
  Future<PreloginResponse> prelogin(String username) async =>
      PreloginResponse(
          argonSalt: server.argonSalt, argonParams: server.argonParams);

  @override
  Future<void> login(LoginRequest request) async {
    server.loginCalls++;
    _requireAuth();
    _token = 'token-${request.username}';
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    _requireAuth();
    server.pullSinces.add(since);
    // The server's own delta semantics: only records newer than the
    // cursor — an unfiltered repeat would keep every round "progressing".
    // A seq-less seed would silently compare as 0 and vanish from every
    // delta pull — fail loudly so tests must stamp an explicit seq.
    final fresh = [
      for (final record in server.records)
        if ((record.seq ?? (throw StateError(
                'seeded record ${record.id} has no seq')))
            >
            since)
          record,
    ];
    return PullResponse(records: fresh, latestSeq: server.seq);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    _requireAuth();
    server.pushed.addAll(records);
    final results = [
      for (final record in records)
        PushResult(id: record.id, seq: ++server.seq, accepted: true),
    ];
    return PushResponse(results: results, latestSeq: server.seq);
  }

  @override
  Future<void> deleteAccount() async {
    _requireAuth();
    server.deleteAccountCalls++;
  }

  @override
  void close() => closed = true;
}

/// A [SyncTrackingBookmarkStore] over [FakeBookmarkStore]'s local-edit
/// surface plus the materialized-tuple map the recovery paths read.
final class FakeSyncTrackingBookmarkStore
    implements SyncTrackingBookmarkStore {
  FakeSyncTrackingBookmarkStore([List<Bookmark> bookmarks = const []])
      : _inner = FakeBookmarkStore(bookmarks);

  final FakeBookmarkStore _inner;

  /// Exposed for the same scripted-reseed use the inner store documents.
  FakeBookmarkStore get inner => _inner;

  final tuples = <String, BookmarkSyncTuple>{};

  @override
  Stream<BookmarkStoreChange> get changes => _inner.changes;

  @override
  Future<List<Bookmark>> load() => _inner.load();

  @override
  Future<Bookmark?> byId(String id) => _inner.byId(id);

  @override
  Future<List<BookmarkGroupSection>> sections() => _inner.sections();

  @override
  Future<List<String>> groupNames() => _inner.groupNames();

  @override
  Future<String> sortKeyForInsert(
          {String? group, String? beforeId, String? afterId}) =>
      _inner.sortKeyForInsert(
          group: group, beforeId: beforeId, afterId: afterId);

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) =>
      _inner.upsertAll(bookmarks);

  @override
  Future<Bookmark> save(Bookmark bookmark) => _inner.save(bookmark);

  @override
  Future<bool> remove(String id) => _inner.remove(id);

  @override
  Future<Bookmark> moveToGroup(String id, String? group,
          {String? beforeId, String? afterId}) =>
      _inner.moveToGroup(id, group, beforeId: beforeId, afterId: afterId);

  @override
  Future<Bookmark> reorder(String id, {String? beforeId, String? afterId}) =>
      _inner.reorder(id, beforeId: beforeId, afterId: afterId);

  @override
  Future<void> applySynced(Iterable<Bookmark> bookmarks) =>
      _inner.applySynced(bookmarks);

  @override
  Future<void> removeSynced(String id) => _inner.removeSynced(id);

  @override
  Future<BookmarkSyncTuple?> syncTupleOf(String id) async => tuples[id];

  @override
  Future<Map<String, BookmarkSyncTuple>> syncTuples() async => Map.of(tuples);

  @override
  Future<void> applySyncedRecords(
      Iterable<({Bookmark bookmark, BookmarkSyncTuple winner})> rows) async {
    final list = rows.toList();
    await _inner.applySynced(list.map((row) => row.bookmark));
    for (final row in list) {
      tuples[row.bookmark.id] = row.winner;
    }
  }

  @override
  Future<void> removeSyncedRecord(
      String id, BookmarkSyncTuple tombstone) async {
    await _inner.removeSynced(id);
    tuples[id] = tombstone;
  }

  /// Closes the inner store's change lane like [FakeBookmarkStore.close].
  Future<void> close() => _inner.close();
}

/// A [SyncTrackingServerStore] in memory: rows keyed by id plus the
/// materialized-tuple map the apply/recovery paths read.
final class FakeSyncTrackingServerStore
    implements SyncTrackingServerStore {
  FakeSyncTrackingServerStore([List<ServerConfig> servers = const []])
      : _servers = {for (final server in servers) server.id: server};

  final Map<String, ServerConfig> _servers;
  final tuples = <String, ServerSyncTuple>{};

  List<ServerConfig> get rows =>
      _servers.values.toList()
        ..sort((a, b) {
          final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
          return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
        });

  @override
  Future<List<ServerConfig>> load() async => List.unmodifiable(rows);

  @override
  Future<ServerConfig?> byId(String id) async => _servers[id];

  @override
  Future<ServerConfig> save(ServerConfig server) async {
    _servers[server.id] = server;
    tuples[server.id] = ServerSyncTuple(
      updatedAt: server.updatedAt,
      deviceId: 'test-device',
      deleted: false,
    );
    return server;
  }

  @override
  Future<bool> remove(String id) async {
    if (_servers.remove(id) == null) return false;
    tuples[id] = const ServerSyncTuple(
      updatedAt: 1,
      deviceId: 'test-device',
      deleted: true,
    );
    return true;
  }

  @override
  Future<ServerSyncTuple?> syncTupleOf(String id) async => tuples[id];

  @override
  Future<Map<String, ServerSyncTuple>> syncTuples() async => Map.of(tuples);

  @override
  Future<void> applySyncedRecord(
      ServerConfig server, ServerSyncTuple winner) async {
    _servers[server.id] = server;
    tuples[server.id] = winner;
  }

  @override
  Future<void> removeSyncedRecord(
      String id, ServerSyncTuple tombstone) async {
    _servers.remove(id);
    tuples[id] = tombstone;
  }
}
