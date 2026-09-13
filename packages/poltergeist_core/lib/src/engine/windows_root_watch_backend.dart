import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'local_directory_watcher.dart'
    show DartIoWatchBackend, LocalWatchBackend;

/// A separator and case form used only for path comparison on the host.
const String _slash = '/';
const String _backslash = '\\';

/// The Windows rename-loss adapter behind the [LocalWatchBackend] seam
/// (03 §7.5; STATUS item 16). Native CI evidence (PR #91): a watched
/// directory's REMOVAL surfaces through dart:io's own watch on Windows,
/// but its RENAME-AWAY does not — the target watch's handle silently
/// follows the renamed directory and no event, error, or close ever
/// fires, so the loss is invisible. This backend additionally watches
/// the target's PARENT, non-recursively, and maps a parent event naming
/// the target (a rename's old name, or a removal) into the uniform
/// root-loss shape (a delete event carrying the watched path) that
/// [LocalDirectoryWatcher] already turns into an immediate `lost`. The
/// parent's handle sees the child's name leave it; the adapter is
/// event-based, local-only, and adds no recursive watch.
///
/// Residual gap (pre-existing, not introduced here): renaming an ANCESTOR
/// above the parent stays silent on every platform through dart:io — the
/// parent's own handle follows the renamed ancestor exactly as the
/// target's follows a renamed target — and no recursive ancestor watch is
/// added; the consumer's rescan (answering `notFound`) is the backstop.
/// This closure claim is scoped to a direct rename/removal of the watched
/// name.
///
/// The synthesized loss event carries `isDirectory: false` on purpose:
/// the SDK's own decoder constructs every Windows delete event — and the
/// Linux/macOS delete-self shape this replicates — with `false`, and
/// `FileSystemDeleteEvent.isDirectory` is documented as always false; the
/// consumer (the watcher's root match) keys on the path only.
///
/// Selection: the production path uses this backend on Windows only
/// ([EngineHost]'s default); Linux and macOS keep the plain dart:io
/// watch, whose native delete-self loss needs no adapter.
final class WindowsRootWatchBackend implements LocalWatchBackend {
  /// [raw] is the underlying per-directory watch primitive (the plain
  /// dart:io watch in production); tests inject deterministic fakes.
  const WindowsRootWatchBackend({LocalWatchBackend? raw})
    : _raw = raw ?? const DartIoWatchBackend();

  final LocalWatchBackend _raw;

  @override
  Stream<FileSystemEvent> watch(String directory) {
    final parent = _parentOf(directory);
    if (parent == null) return _raw.watch(directory);
    return _watchWithParent(directory, parent);
  }

  /// The watched directory's parent, or null when there is none: a volume
  /// root (`/`, `C:\`, a UNC share root) or a non-absolute path, which the
  /// engine never produces (03 §7.5 canonicalizes before the backend is
  /// touched). A volume root cannot be removed or renamed within its own
  /// volume, and its unmounting surfaces through the target watch's own
  /// error path — a parent watch there is impossible, not merely skipped.
  String? _parentOf(String directory) {
    if (!p.isAbsolute(directory)) return null;
    final parent = p.dirname(directory);
    if (_comparable(parent) == _comparable(directory)) return null;
    return parent;
  }

  /// One merged event stream over both watches. The target watch is the
  /// ordinary-change half, relayed untouched; the parent watch is the
  /// loss detector, strictly filtered to the target's name.
  Stream<FileSystemEvent> _watchWithParent(String directory, String parent) {
    return Stream<FileSystemEvent>.multi((controller) {
      // Routing gate: once cancellation, a loss, or an end-of-stream
      // happened, nothing is relayed any more — no late event can arm a
      // debounce or invalidate a rebinding after release.
      var routing = true;
      StreamSubscription<FileSystemEvent>? targetSubscription;
      StreamSubscription<FileSystemEvent>? parentSubscription;

      // ONE truthful release for BOTH underlying watches: every
      // cancellation is issued before any is awaited, so a failing link
      // cannot skip its sibling, and the first teardown path to run
      // caches its completion — every later release (an explicit cancel,
      // a second end-of-stream) returns that same future instead of
      // issuing duplicate cancellations or acking early. An acknowledged
      // cancellation therefore always means the in-flight teardown
      // completed: both OS watches are really gone, not merely scheduled
      // to go. Per-link errors are contained: signal routing is already
      // dead above, and the watcher's epoch never rests on cancel
      // completion.
      Future<void>? pendingRelease;

      Future<void> release() {
        final inFlight = pendingRelease;
        if (inFlight != null) return inFlight;
        final target = targetSubscription;
        final parentSubscription0 = parentSubscription;
        targetSubscription = null;
        parentSubscription = null;
        if (target == null && parentSubscription0 == null) {
          return Future<void>.value();
        }
        final issued = [
          if (target != null) target.cancel(),
          if (parentSubscription0 != null) parentSubscription0.cancel(),
        ];
        return pendingRelease =
            Future.wait(issued).then((_) {}, onError: (Object _) {});
      }

      void relay(FileSystemEvent event) {
        if (routing) controller.add(event);
      }

      void relayError(Object error, StackTrace stackTrace) {
        // A backend error on either watch ends the merge: the target's
        // own stream erroring is the existing lost shape (overflow,
        // unexpected closure), and the loss detector failing is itself a
        // loss of monitoring — never silently degraded to target-only.
        if (routing) controller.addError(error, stackTrace);
      }

      void endStream() {
        if (!routing) return;
        routing = false;
        controller.close();
        unawaited(release());
      }

      // Delivery note: a backend ERROR crosses immediately and drives
      // lost without waiting the release; a backend CLOSE (end-of-stream)
      // settles with it — the Stream.multi close flush runs the
      // consumer's cancellation first, and that cancellation is the
      // truthful release. The verified Windows loss shapes are
      // error- and event-driven, so the lost signal is prompt there; a
      // backend whose cancellation never settles delays a close-driven
      // lost under the same cancel-must-settle contract stop and dispose
      // already require.

      // The parent is the loss detector: its events are its own direct
      // children, so every event that does not name the watched directory
      // is a sibling's business — dropped here, before the watcher's
      // debounce could ever be armed by a foreign event. Deeper matches
      // are descendants, not the target, and drop the same way.
      void onParentEvent(FileSystemEvent event) {
        if (!routing) return;
        if (_comparable(event.path) != _comparable(directory)) return;
        final isLoss =
            event is FileSystemDeleteEvent || event is FileSystemMoveEvent;
        // Create/modify naming the target stay dropped: the target's own
        // watch reports those, and a duplicate would double-arm the
        // debounce. A move whose SOURCE is the target is a rename-away —
        // including a same-name replacement racing a deletion, which
        // arrives after the delete below has already fired the loss.
        if (!isLoss) return;
        controller.add(FileSystemDeleteEvent(directory, false));
      }

      // Cancellation ownership is installed BEFORE any setup can fail:
      // a setup failure starts the teardown itself, and the consumer's
      // cancel must still await that in-flight release.
      controller.onCancel = () {
        routing = false;
        return release();
      };

      // Both watches are armed inside one guarded setup: a synchronous
      // refusal at watch/listen time must release whatever was acquired
      // and fail the merged stream loud. It must never escape the body —
      // a throw out of a Stream.multi body bypasses the stream entirely
      // as an unhandled zone error no consumer sees.
      try {
        // The target watch first: its events are the ordinary-change
        // half.
        targetSubscription = _raw.watch(directory).listen(
          relay,
          onError: relayError,
          onDone: endStream,
        );
        // The parent watch second: the loss detector.
        parentSubscription = _raw.watch(parent).listen(
          onParentEvent,
          onError: relayError,
          onDone: endStream,
        );
      } on Object catch (error, stackTrace) {
        routing = false;
        unawaited(release());
        controller.addError(error, stackTrace);
        controller.close();
        return;
      }
    });
  }
}

/// Comparison form only: separators unified and — on Windows, where paths
/// are case-insensitive — case folded. dart:io joins parent-watch event
/// paths with the parent string exactly as the watch was opened (the
/// SDK's `fullPathOf`), so a lexical comparison against the watched path
/// is exact modulo the platform's separator and case rendering.
String _comparable(String path) {
  var normalized = path.replaceAll(_backslash, _slash);
  while (normalized.length > 1 && normalized.endsWith(_slash)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
