/// 04 §3.2's crypto seam: the one object that turns [EncryptedRecord] blobs
/// into [DecryptedRecord] payloads and back, keyed by the Séance session
/// vault key. [BookmarkCoordinator] — and only it — touches this seam; the
/// record store itself stays deliberately opaque so corrupt, unknown, or
/// not-for-us ciphertext survives untouched.
library;

import 'package:seance_core/seance_core.dart';

/// The one crypto consumer the task permits: Séance's own [RecordCodec]
/// (AES-256-GCM + HKDF-SHA256, `{kind, data}` payloads, unknown kind names
/// preserved as [RecordKind.unknown]).
///
/// [open] is deliberately throw-only: a decrypt or JSON failure surfaces,
/// and the caller decides whether that means "not for our vault key,
/// preserve" or "tripwire". Nothing here retries, re-keys, or mutates.
final class RecordCrypto {
  const RecordCrypto(this._codec);

  final RecordCodec _codec;

  /// Decrypt and unwrap `{'kind': ..., 'data': ...}`. Throws on any
  /// failure — no fallback decode, no defaults.
  Future<DecryptedRecord> open(EncryptedRecord record) =>
      _codec.decrypt(record);

  /// Wrap and encrypt a [DecryptedRecord] for this vault key.
  Future<EncryptedRecord> seal(DecryptedRecord record) =>
      _codec.encrypt(record);
}
