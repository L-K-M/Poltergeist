import 'dart:async';

import 'package:seance_core/seance_core.dart';

/// A [RemoteFileSystem] that can hash a file's content where the bytes
/// live, returning the committed entry with `contentSha256` set.
///
/// The engine-bridged filesystem implements it: its digest runs inside
/// the engine isolate beside the socket (D7/D8), so a digest-only read
/// never streams the whole file across the isolate port just to discard
/// it on the far side.
abstract interface class ContentDigestSource {
  Future<RemoteFileEntry> contentDigest(String path);
}

/// The committed entry of [path] with its streamed SHA-256 — the digest
/// authority the managed checkout's snapshot repair and sync's content
/// comparison share (06 §3.3, 05 §4). Uses [ContentDigestSource] when
/// [fs] offers it; otherwise streams the file into a discarding sink with
/// hashing on, exactly as both callers did before the bridge existed.
Future<RemoteFileEntry> remoteContentDigest(RemoteFileSystem fs, String path) {
  if (fs is ContentDigestSource) {
    return (fs as ContentDigestSource).contentDigest(path);
  }
  return fs.download(path, _DiscardingSink(), computeHash: true);
}

/// Discards everything written to it — the hash rides the stream.
final class _DiscardingSink implements StreamSink<List<int>> {
  final Completer<void> _done = Completer<void>();

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
