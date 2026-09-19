import 'package:poltergeist_core/poltergeist_core.dart';

/// A SyncApi fake standing in for the Séance sync server: server-side merge
/// is the same [Lww.resolve] both ends share (04 §3.2 pins the server's
/// tie-break identical to the client's), and accepted pushes mint a
/// monotonically increasing `seq` like `pushRecords` in seance_sync_server.
final class FakeSyncApi implements SyncApi {
  final Map<String, EncryptedRecord> records = {};
  var _seq = 0;

  /// When set, the next [pull] throws it (the cursor-rejected signal that
  /// triggers the full-resync fallback).
  Object? nextPullError;

  /// When set, the next [push] throws it (transport failure — no results).
  Object? nextPushError;

  var pullCalls = 0;
  var pushCalls = 0;

  /// Seed a record the way the server would store an incoming push: LWW
  /// against what is already held, seq assigned on a win, ignored on a loss.
  /// Returns whether the seed won.
  bool seed(EncryptedRecord record) {
    final existing = records[record.id];
    if (existing != null &&
        !identical(Lww.resolve(existing, record), record)) {
      return false;
    }
    _seq++;
    records[record.id] = record.withSeq(_seq);
    return true;
  }

  /// Place a record with an explicit seq — fixtures that need to control
  /// cursor positions rather than merge semantics.
  void seedWithSeq(EncryptedRecord record, int seq) {
    records[record.id] = record.withSeq(seq);
    if (seq > _seq) _seq = seq;
  }

  @override
  Future<PullResponse> pull({required int since}) async {
    pullCalls++;
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
    final error = nextPushError;
    if (error != null) {
      nextPushError = null;
      throw error;
    }
    final results = <PushResult>[];
    for (final incoming in pushed) {
      final existing = records[incoming.id];
      if (existing != null &&
          !identical(Lww.resolve(existing, incoming), incoming)) {
        results.add(
            PushResult(id: incoming.id, seq: existing.seq ?? 0, accepted: false));
        continue;
      }
      _seq++;
      records[incoming.id] = incoming.withSeq(_seq);
      results.add(PushResult(id: incoming.id, seq: _seq, accepted: true));
    }
    return PushResponse(results: results, latestSeq: _seq);
  }
}
