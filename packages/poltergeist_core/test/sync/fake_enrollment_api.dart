import 'dart:convert';

import 'package:poltergeist_core/poltergeist_core.dart';

/// A SyncEnrollmentApi fake standing in for the Séance sync server's account
/// endpoints: register stores the KDF salt/params and verifier, prelogin
/// hands them back, login checks the verifier and mints a bearer token, and
/// pull/push serve the seeded record set — mirroring FakeSyncApi's seq and
/// LWW model, so the coordinator can run rounds over the same seam.
final class FakeEnrollmentApi implements SyncEnrollmentApi {
  /// Server-held records; seed through [seed]/[seedWithSeq] so seqs mint.
  final Map<String, EncryptedRecord> records = {};

  final _accounts = <String, _FakeAccount>{};
  var _seq = 0;
  var _tokenCounter = 0;

  /// The session token the last register/login produced, like
  /// HttpSyncClient's public field.
  @override
  String? token;

  /// When true, register fails with 403 `registration_closed` (04 §4.3).
  bool registrationClosed = false;

  /// Prelogin answers with these params instead of the account's stored
  /// ones — the KDF-downgrade fixture (04 §4.5's meetsMinimum refusal).
  Argon2Params? preloginParamsOverride;

  var registerCalls = 0;
  var preloginCalls = 0;
  var loginCalls = 0;
  var pullCalls = 0;
  var pushCalls = 0;

  /// When set, the next [pull] throws it — the 401 dead-account fixture.
  Object? nextPullError;

  /// Every `since` cursor a [pull] was called with — enrollment must always
  /// pull full (`since = 0`), never a delta.
  final pullCursors = <int>[];

  bool seed(EncryptedRecord record) {
    final existing = records[record.id];
    if (existing != null) {
      final winner = Lww.resolve(existing, record);
      if (!identical(winner, record)) return false;
    }
    _seq++;
    records[record.id] = record.withSeq(_seq);
    return true;
  }

  void seedWithSeq(EncryptedRecord record, int seq) {
    records[record.id] = record.withSeq(seq);
    if (seq > _seq) _seq = seq;
  }

  @override
  Future<void> register(RegisterRequest request) async {
    registerCalls++;
    if (registrationClosed) {
      throw const ApiError(
          code: 'registration_closed', message: 'Registration is disabled');
    }
    if (_accounts.containsKey(request.username)) {
      throw const ApiError(
          code: 'account_exists', message: 'Username already registered');
    }
    _accounts[request.username] = _FakeAccount(
      salt: base64.decode(request.argonSalt),
      params: request.argonParams,
      authVerifier: request.authVerifier,
    );
    token = 'token-${++_tokenCounter}';
  }

  @override
  Future<PreloginResponse> prelogin(String username) async {
    preloginCalls++;
    final account = _accounts[username];
    if (account == null) {
      throw const ApiError(code: 'no_account', message: 'No such account');
    }
    return PreloginResponse(
      argonSalt: base64.encode(account.salt),
      argonParams: preloginParamsOverride ?? account.params,
    );
  }

  @override
  Future<void> login(LoginRequest request) async {
    loginCalls++;
    final account = _accounts[request.username];
    if (account == null || account.authVerifier != request.authVerifier) {
      throw const ApiError(
          code: 'invalid_credentials', message: 'Invalid credentials');
    }
    token = 'token-${++_tokenCounter}';
  }

  /// Register an account the way a prior enrollment would have: the verifier
  /// is derived from [password] over a fresh salt, so a later [login] with
  /// the same password authenticates. Returns the salt so a test can derive
  /// the account's real vault key for sealing fixture records.
  Future<List<int>> addAccount({
    required String username,
    required String password,
    Argon2Params params = const Argon2Params(),
  }) async {
    final salt = secureRandomBytes(16);
    final keys = await VaultCrypto.deriveKeys(
        passphrase: password, salt: salt, params: params);
    _accounts[username] = _FakeAccount(
      salt: salt,
      params: params,
      authVerifier: base64.encode(keys.authVerifier),
    );
    return salt;
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    pullCalls++;
    pullCursors.add(since);
    final error = nextPullError;
    if (error != null) {
      nextPullError = null;
      throw error;
    }
    final list = records.values
        .where((r) => (r.seq ?? 0) > since)
        .toList()
      ..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    return PullResponse(records: list, latestSeq: _seq);
  }

  @override
  Future<PushResponse> push(List<EncryptedRecord> pushed) async {
    pushCalls++;
    final results = <PushResult>[];
    for (final incoming in pushed) {
      final existing = records[incoming.id];
      if (existing != null) {
        final winner = Lww.resolve(existing, incoming);
        if (!identical(winner, incoming)) {
          results.add(PushResult(
              id: incoming.id, seq: existing.seq ?? 0, accepted: false));
          continue;
        }
      }
      _seq++;
      records[incoming.id] = incoming.withSeq(_seq);
      results.add(PushResult(id: incoming.id, seq: _seq, accepted: true));
    }
    return PushResponse(results: results, latestSeq: _seq);
  }
}

final class _FakeAccount {
  const _FakeAccount({
    required this.salt,
    required this.params,
    required this.authVerifier,
  });

  final List<int> salt;
  final Argon2Params params;
  final String authVerifier;
}
