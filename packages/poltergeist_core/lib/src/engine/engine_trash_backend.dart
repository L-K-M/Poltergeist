import '../transfer/trash_service.dart';
import 'engine_client.dart';

/// The D15 local trash (03 §7.3) for a transfer queue running on the UI
/// isolate: every availability probe and every move runs engine-side,
/// where the engine's [LocalTrashService] spawns `gio trash` (Linux) or
/// rides the `poltergeist/trash` channel relay (macOS/Windows) — D8
/// keeps process spawns off the UI isolate. Wrap it with
/// `LocalTrashService.withBackend` for the queue.
///
/// Failures keep the trash layer's own taxonomy: a refused move is a
/// [TrashException] exactly as it would be in-process, and a dead engine
/// reads as unavailable (the confirm-then-permanent fallback), never as
/// a silent unlink.
final class EngineTrashBackend implements LocalTrashBackend {
  EngineTrashBackend(this._client);

  final EngineClient _client;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _client.localTrashAvailable();
    } on Object {
      // An unreachable engine cannot trash anything: unavailable routes
      // the caller to the confirmed-permanent path, never to a guess.
      return false;
    }
  }

  @override
  Future<String?> trash(String path) async {
    try {
      return await _client.moveToLocalTrash(path);
    } on TrashException {
      rethrow;
    } on Object catch (error) {
      throw TrashException(
        kind: TrashErrorKind.unavailable,
        path: path,
        message: 'The OS trash is unavailable right now: $error',
        cause: error,
      );
    }
  }
}
