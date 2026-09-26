/// OS drag-out (00 D14, 2026-09-25 amendment): the seam between a pane
/// row drag that leaves the Poltergeist window and the platform's
/// native drag session.
///
/// In-app drags stay Flutter `Draggable`s end to end. Only when the
/// pointer crosses the window edge does the pane hand the payload to a
/// [DragOutBackend], which starts a native session carrying local file
/// URLs (every desktop backend) or remote file promises (macOS). The
/// Dart side owns every decision (what to offer, where promises land,
/// what fails and why); a native backend is a thin adapter over the
/// channel protocol below.
///
/// ## Channel protocol: `poltergeist/dragout`
///
/// A `MethodChannel` named `poltergeist/dragout` using the
/// `StandardMethodCodec`, on the window's default binary messenger.
/// Coordinates are logical pixels of the Flutter view the drag left
/// (`viewId`), origin top-left
/// (the same space as `PointerEvent.position`; macOS's `FlutterView` is
/// flipped, so no conversion is needed there). Unknown keys must be
/// ignored by both sides, so either end can grow the protocol.
///
/// ### Dart → native
///
/// **`startDrag`** (arguments: a map)
///
/// | key                 | type                     | meaning |
/// |---------------------|--------------------------|---------|
/// | `sessionId`         | `String`                 | Dart-minted id; echoed on every callback for this session |
/// | `viewId`            | `int?`                   | the Flutter view the drag left (00 D39's workspace windows); absent means the main window's, view 0 |
/// | `position`          | `List<double>` [x, y]    | the pointer, already outside the view bounds; where the native side ends the embedder's press |
/// | `allowedOperations` | `List<String>`           | subset of `copy`, `link`; never `move` or `delete` (see below) |
/// | `items`             | `List<Map>`              | one entry per dragged root, in listing order (see below) |
/// | `image`             | `Uint8List?` (PNG)       | Dart-rendered drag image (glyph, name or "N items", count badge); null when rendering failed |
/// | `imageSize`         | `List<double>` [w, h]    | the image's logical size (the PNG is rendered at the view's device pixel ratio) |
/// | `imageAnchor`       | `List<double>` [dx, dy]  | the pointer's logical offset inside the image |
///
/// Item maps, discriminated by `kind`:
///
/// * `{kind: 'file', path: String, name: String, isDirectory: bool}`: a
///   local item, offered as a plain file URL (`public.file-url` /
///   `text/uri-list` / `CF_HDROP`). The destination picks copy or link
///   within `allowedOperations`. The native side never deletes the
///   source: on Linux it must not handle `drag-data-delete`.
/// * `{kind: 'promise', promiseId: String, name: String,
///   isDirectory: bool, size: int?}`: a remote item, offered as a file
///   promise (macOS `NSFilePromiseProvider`, file type from the name's
///   extension, `public.folder` when `isDirectory`, `public.data` when
///   unknown). `name` is what `fileNameForType` returns. Only sent
///   when the backend reports [DragOutSupport.localFilesAndPromises];
///   a session's items are either all `file` or all `promise`.
///
/// **Never move, never delete.** The owner's rule (00 D14's drag-out
/// amendment): no trash may take a drag-out's source, on any platform.
/// The Windows Recycle Bin, a Linux file manager's Trash, and the macOS
/// Dock Trash each accept a move, so a drag out of Poltergeist only
/// ever offers copy and link, and no drop elsewhere can move the source
/// either. Delete was never offered (D15: a trash drop would be a
/// delete outside the confirmed flow). Each native backend enforces
/// this itself, whatever the request says: it maps only the `copy` and
/// `link` names to the OS's operations (GTK actions, `NSDragOperation`
/// for both dragging contexts, `DROPEFFECT`), falls back to copy alone
/// when neither is present, and ignores `move`. Drags between
/// Poltergeist's own panes are in-app drags and still move; so does a
/// drag that leaves and comes back (the own-drag echo below), since
/// Dart lands it with the in-app verb rules.
///
/// Reply: `{started: true}` once the native session is running, or
/// `{started: false, reason: String, message: String?}` with `reason`
/// one of `noPointerEvent` (no recorded press to start from; on
/// Windows, the view does not hold the mouse capture, as in a pen or
/// touch drag), `buttonReleased` (the primary button is already up),
/// `busy` (a session is already running), `unsupportedItems`, or
/// `failed`. A missing implementation (`MissingPluginException`) reads
/// as `unsupported`. The reply must be sent before any modal loop starts
/// (Windows: reply, then post a message that runs the drag loop,
/// `SHDoDragDrop`, on the next message-loop turn) and must never wait on
/// Dart.
///
/// Before (or while) starting the session the native side MUST end the
/// embedder's own view of the press: the OS session swallows the real
/// button release, and an embedder that still believes the button is
/// down drops the next press. The synthetic release sits at `position`,
/// which is outside the view, never at the current pointer: it can reach
/// Flutter before the reply, and over a pane Flutter would read it as an
/// in-app drop of the items the session carries. Linux:
/// `gtk_main_do_event` a `GDK_BUTTON_RELEASE` copy of the recorded
/// press. macOS: `flutterViewController.mouseUp(with:)` a synthetic
/// `leftMouseUp`. Windows: send `WM_LBUTTONUP` (physical client pixels,
/// the view's DPI over 96) to the Flutter view's HWND before
/// `DoDragDrop`. A request without a well-formed `position` is refused
/// as `failed`. The Dart side also cancels the framework's gesture
/// itself (a synthetic `PointerCancelEvent` for the row's pointer) once
/// `started` arrives. Until the reply arrives it holds every in-app drop
/// of the payload, since the release may be the native side's own:
/// discarded if the session started, landed if it did not. So the
/// in-app drag never lands a drop alongside a native session.
///
/// **`promiseProgress`** (arguments: a map; fire-and-forget, reply
/// ignored): `{sessionId: String, promiseId: String,
/// completedBytes: int, totalBytes: int?}`. Sent while a promise is
/// being fulfilled, throttled by Dart to a few updates per second. On
/// macOS it drives the `NSProgress` published for the promised URL
/// (Finder's progress pie).
///
/// ### Native → Dart
///
/// **`fulfilPromise`** (arguments: a map): `{sessionId: String,
/// promiseId: String, destinationPath: String}`. The OS called in a
/// promise; `destinationPath` is the absolute path of the file or
/// folder to create (macOS: `url.path` of `writePromiseTo`). Dart
/// produces the item exactly there. The method's REPLY is the
/// completion: success replies `null`; failure replies an error
/// (`PlatformException` on the Dart side, `FlutterError` natively) whose
/// `code` is a [DragOutPromiseFailure] name (`cancelled`, `exists`,
/// `paused`, `renamed`, `ownDrop`, `unknown`, `unavailable`, `failed`)
/// and whose `message` is an English diagnostic for the native error's
/// description and logs; the user-facing report is Poltergeist's own
/// Alert or failed Transfers row. A reply can take minutes; the native
/// side keeps the completion handler until it arrives and never blocks
/// the main thread waiting (macOS: `writePromiseTo` runs on a private
/// `OperationQueue`, hops to the main queue to invoke the method, and
/// returns). Dart replies exactly once per request.
///
/// **`cancelPromise`** (arguments: a map): `{sessionId: String,
/// promiseId: String}`. The user or the receiver gave up (macOS: the
/// `NSProgress` cancellation handler). Dart cancels the backing queue
/// task; the pending `fulfilPromise` then replies `cancelled`. Reply:
/// `null`.
///
/// **`sessionEnded`** (arguments: a map): `{sessionId: String,
/// operation: 'copy' | 'move' | 'link' | 'none'}`. The OS session
/// ended: dropped (with the operation the destination chose), refused,
/// or cancelled (Esc). `move` is never offered, but it stays a name the
/// native side may report and Dart reads, so a target that claims one
/// anyway is still understood; nothing on either side acts on it, and
/// nothing deletes. Promises may still be fulfilled after this (macOS
/// calls `writePromiseTo` after the drag completes), so Dart keeps a
/// session's promises answerable for a while after it ends. Reply:
/// `null`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel both ends agree on (03 §7.1's `poltergeist/*` naming).
const String dragOutChannelName = 'poltergeist/dragout';

/// What a native session offers the destination: copy or link, never
/// move or delete. The owner's rule (00 D14's drag-out amendment): no
/// trash may take a drag-out's source, and every desktop trash accepts
/// a move (the Windows Recycle Bin, a Linux file manager's Trash, the
/// macOS Dock Trash), so no drop may move it. Nor is delete offered:
/// that would be a delete outside D15's confirmed `enqueueDelete`.
enum DragOutOffer { copy, link }

/// What the destination reported doing when the session ended. `move`
/// is read although it is never offered (a target may report one
/// anyway); it means nothing to the source, where nothing deletes.
enum DragOutOperation { copy, move, link }

/// What this platform's backend can start.
enum DragOutSupport {
  /// No OS drag-out: mobile, web, and tests without a backend.
  none,

  /// Local file URLs only (Linux GTK, Windows `CF_HDROP`). Remote rows
  /// show a hint instead and the drag continues in-app.
  localFiles,

  /// Local file URLs and remote file promises (macOS).
  localFilesAndPromises,
}

/// One dragged root as the native side sees it.
sealed class DragOutItem {
  const DragOutItem({required this.name, required this.isDirectory});

  /// The item's display and promised file name.
  final String name;

  final bool isDirectory;

  /// The item's `startDrag` map (see the library doc).
  Map<String, Object?> toChannel();
}

/// A local file or folder, offered as a plain file URL.
final class LocalDragOutItem extends DragOutItem {
  const LocalDragOutItem({
    required this.path,
    required super.name,
    required super.isDirectory,
  });

  /// Absolute local path.
  final String path;

  @override
  Map<String, Object?> toChannel() => {
    'kind': 'file',
    'path': path,
    'name': name,
    'isDirectory': isDirectory,
  };
}

/// A remote file or folder, offered as a file promise.
final class PromisedDragOutItem extends DragOutItem {
  const PromisedDragOutItem({
    required this.promiseId,
    required super.name,
    required super.isDirectory,
    this.size,
  });

  /// Session-scoped id the native side echoes in `fulfilPromise`.
  final String promiseId;

  /// The listing's size in bytes, when it reported one.
  final int? size;

  @override
  Map<String, Object?> toChannel() => {
    'kind': 'promise',
    'promiseId': promiseId,
    'name': name,
    'isDirectory': isDirectory,
    'size': size,
  };
}

/// The Dart-rendered drag image: PNG bytes at the view's device pixel
/// ratio, its logical [size], and where the pointer sits inside it.
final class DragOutImage {
  const DragOutImage({
    required this.png,
    required this.size,
    required this.anchor,
  });

  final Uint8List png;
  final Size size;
  final Offset anchor;
}

/// One `startDrag` request.
final class DragOutRequest {
  const DragOutRequest({
    required this.sessionId,
    required this.items,
    required this.position,
    required this.allowedOperations,
    this.image,
    this.viewId,
  });

  final String sessionId;
  final List<DragOutItem> items;

  /// The view the drag left; null for the main window's.
  final int? viewId;

  /// The pointer in the view's logical coordinates.
  final Offset position;

  final Set<DragOutOffer> allowedOperations;
  final DragOutImage? image;

  Map<String, Object?> toChannel() => {
    'sessionId': sessionId,
    'viewId': ?viewId,
    'position': [position.dx, position.dy],
    'allowedOperations': [
      for (final offer in DragOutOffer.values)
        if (allowedOperations.contains(offer)) offer.name,
    ],
    'items': [for (final item in items) item.toChannel()],
    'image': image?.png,
    'imageSize': image == null ? null : [image!.size.width, image!.size.height],
    'imageAnchor': image == null ? null : [image!.anchor.dx, image!.anchor.dy],
  };
}

/// Why a native session did not start. The in-app drag then simply
/// continues.
enum DragOutRefusal {
  unsupported,
  noPointerEvent,
  buttonReleased,
  busy,
  unsupportedItems,
  failed,
}

/// `startDrag`'s answer.
sealed class DragOutStartResult {
  const DragOutStartResult();
}

final class DragOutStarted extends DragOutStartResult {
  const DragOutStarted();
}

final class DragOutNotStarted extends DragOutStartResult {
  const DragOutNotStarted(this.reason, [this.message]);

  final DragOutRefusal reason;
  final String? message;
}

/// A native request to fulfil one promise.
final class DragOutPromiseRequest {
  const DragOutPromiseRequest({
    required this.sessionId,
    required this.promiseId,
    required this.destinationPath,
  });

  final String sessionId;
  final String promiseId;

  /// Absolute path of the file or folder to create.
  final String destinationPath;
}

/// The error codes a failed `fulfilPromise` reply carries.
enum DragOutPromiseFailure {
  /// The user or the receiver cancelled.
  cancelled,

  /// A file with the promised name already exists at the destination.
  exists,

  /// The transfer queue is paused (a folder promise rides the queue).
  paused,

  /// The receiver asked for a different name than the folder's own.
  renamed,

  /// The destination is `desktop_drop`'s staging folder: the drag came
  /// back into Poltergeist and is routed in-app instead.
  ownDrop,

  /// No such session or promise (expired, or never ours).
  unknown,

  /// Nothing can produce remote items right now (no queue).
  unavailable,

  /// The download failed; the message says why.
  failed,
}

/// A failed promise, as the delegate throws it and the channel replies.
final class DragOutPromiseException implements Exception {
  const DragOutPromiseException(this.failure, this.message);

  final DragOutPromiseFailure failure;
  final String message;

  @override
  String toString() => 'DragOutPromiseException(${failure.name}: $message)';
}

/// The Dart side of the native callbacks.
abstract interface class DragOutBackendDelegate {
  /// Produces the promised item at the request's destination and
  /// completes when it is there. Throws [DragOutPromiseException].
  Future<void> fulfilPromise(DragOutPromiseRequest request);

  /// The native side gave up on a promise.
  void cancelPromise(String sessionId, String promiseId);

  /// The native session ended; [operation] is null for none.
  void sessionEnded(String sessionId, DragOutOperation? operation);
}

/// A platform's native drag-out.
abstract interface class DragOutBackend {
  /// What [startDrag] can carry on this platform.
  DragOutSupport get support;

  /// Receives the native callbacks; null detaches.
  set delegate(DragOutBackendDelegate? delegate);

  /// Starts a native session for [request]. Never throws: a missing or
  /// failing native side answers [DragOutNotStarted].
  Future<DragOutStartResult> startDrag(DragOutRequest request);

  /// Reports a promise's byte progress (fire-and-forget).
  void reportProgress({
    required String sessionId,
    required String promiseId,
    required int completedBytes,
    int? totalBytes,
  });
}

/// The production backend over the `poltergeist/dragout` channel.
final class MethodChannelDragOutBackend implements DragOutBackend {
  MethodChannelDragOutBackend({
    required this.support,
    this._channel = const MethodChannel(dragOutChannelName),
  }) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;

  @override
  final DragOutSupport support;

  DragOutBackendDelegate? _delegate;

  @override
  set delegate(DragOutBackendDelegate? delegate) => _delegate = delegate;

  @override
  Future<DragOutStartResult> startDrag(DragOutRequest request) async {
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>(
        'startDrag',
        request.toChannel(),
      );
      if (reply?['started'] == true) return const DragOutStarted();
      final reason = reply?['reason'];
      return DragOutNotStarted(
        DragOutRefusal.values.firstWhere(
          (value) => value.name == reason,
          orElse: () => DragOutRefusal.failed,
        ),
        reply?['message'] as String?,
      );
    } on MissingPluginException {
      return const DragOutNotStarted(DragOutRefusal.unsupported);
    } on PlatformException catch (error) {
      return DragOutNotStarted(DragOutRefusal.failed, error.message);
    }
  }

  @override
  void reportProgress({
    required String sessionId,
    required String promiseId,
    required int completedBytes,
    int? totalBytes,
  }) {
    unawaited(
      _channel
          .invokeMethod<void>('promiseProgress', {
            'sessionId': sessionId,
            'promiseId': promiseId,
            'completedBytes': completedBytes,
            'totalBytes': totalBytes,
          })
          // Progress is advisory: a native side without the method (or
          // a torn-down session) must not surface as an error.
          .catchError((Object _) {}),
    );
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final delegate = _delegate;
    final arguments = call.arguments;
    if (arguments is! Map) {
      throw PlatformException(
        code: 'badArguments',
        message: '${call.method} expects a map',
      );
    }
    final sessionId = arguments['sessionId'];
    if (sessionId is! String) {
      throw PlatformException(
        code: 'badArguments',
        message: '${call.method} needs a sessionId',
      );
    }
    switch (call.method) {
      case 'fulfilPromise':
        final promiseId = arguments['promiseId'];
        final destination = arguments['destinationPath'];
        if (promiseId is! String || destination is! String) {
          throw PlatformException(
            code: 'badArguments',
            message: 'fulfilPromise needs promiseId and destinationPath',
          );
        }
        if (delegate == null) {
          throw PlatformException(
            code: DragOutPromiseFailure.unavailable.name,
            message: 'no drag-out delegate is attached',
          );
        }
        try {
          await delegate.fulfilPromise(
            DragOutPromiseRequest(
              sessionId: sessionId,
              promiseId: promiseId,
              destinationPath: destination,
            ),
          );
        } on DragOutPromiseException catch (error) {
          throw PlatformException(
            code: error.failure.name,
            message: error.message,
          );
        }
        return null;
      case 'cancelPromise':
        final promiseId = arguments['promiseId'];
        if (promiseId is String) delegate?.cancelPromise(sessionId, promiseId);
        return null;
      case 'sessionEnded':
        final operation = arguments['operation'];
        delegate?.sessionEnded(
          sessionId,
          DragOutOperation.values
              .where((value) => value.name == operation)
              .firstOrNull,
        );
        return null;
    }
    throw MissingPluginException('${call.method} is not a drag-out callback');
  }
}

/// The unsupported-platform backend: [startDrag] always answers
/// [DragOutRefusal.unsupported] and no callback ever arrives.
final class NoDragOutBackend implements DragOutBackend {
  const NoDragOutBackend();

  @override
  DragOutSupport get support => DragOutSupport.none;

  @override
  set delegate(DragOutBackendDelegate? delegate) {}

  @override
  Future<DragOutStartResult> startDrag(DragOutRequest request) async =>
      const DragOutNotStarted(DragOutRefusal.unsupported);

  @override
  void reportProgress({
    required String sessionId,
    required String promiseId,
    required int completedBytes,
    int? totalBytes,
  }) {}
}

/// One native backend shared by every workspace window (00 D39). The
/// channel has one handler and the OS runs one drag at a time, but each
/// window's shell owns a drag-out controller of its own, and each mints
/// its session ids from its own counter. So each window gets the backend
/// [forView] gives it: its requests carry its view id, its session ids
/// cross the channel prefixed with that id, and the callbacks for them
/// come back to its controller alone.
final class DragOutRouter {
  DragOutRouter(this._backend) {
    _backend.delegate = _Callbacks(this);
  }

  final DragOutBackend _backend;
  final _views = <int, _ViewDragOutBackend>{};

  /// The backend for the window whose view is [viewId].
  DragOutBackend forView(int viewId) =>
      _views[viewId] ??= _ViewDragOutBackend(this, viewId);

  static const _separator = '/';

  static String _wire(int viewId, String sessionId) =>
      '$viewId$_separator$sessionId';

  /// The view and window-local session id of a [wire] id, or null for an
  /// id this router did not mint.
  ({_ViewDragOutBackend view, String sessionId})? _route(String wire) {
    final split = wire.indexOf(_separator);
    if (split < 0) return null;
    final viewId = int.tryParse(wire.substring(0, split));
    final view = viewId == null ? null : _views[viewId];
    if (view == null) return null;
    return (view: view, sessionId: wire.substring(split + 1));
  }
}

final class _ViewDragOutBackend implements DragOutBackend {
  _ViewDragOutBackend(this._router, this._viewId);

  final DragOutRouter _router;
  final int _viewId;
  DragOutBackendDelegate? _delegate;

  @override
  DragOutSupport get support => _router._backend.support;

  /// A window's controller detaches as its window closes: the router lets
  /// the view go, so a late callback for one of its sessions reads as
  /// owned by no window.
  @override
  set delegate(DragOutBackendDelegate? delegate) {
    _delegate = delegate;
    if (delegate == null && identical(_router._views[_viewId], this)) {
      _router._views.remove(_viewId);
    }
  }

  @override
  Future<DragOutStartResult> startDrag(DragOutRequest request) =>
      _router._backend.startDrag(
        DragOutRequest(
          sessionId: DragOutRouter._wire(_viewId, request.sessionId),
          items: request.items,
          position: request.position,
          allowedOperations: request.allowedOperations,
          image: request.image,
          viewId: _viewId,
        ),
      );

  @override
  void reportProgress({
    required String sessionId,
    required String promiseId,
    required int completedBytes,
    int? totalBytes,
  }) => _router._backend.reportProgress(
    sessionId: DragOutRouter._wire(_viewId, sessionId),
    promiseId: promiseId,
    completedBytes: completedBytes,
    totalBytes: totalBytes,
  );
}

final class _Callbacks implements DragOutBackendDelegate {
  _Callbacks(this._router);

  final DragOutRouter _router;

  @override
  Future<void> fulfilPromise(DragOutPromiseRequest request) async {
    final route = _router._route(request.sessionId);
    final delegate = route?.view._delegate;
    if (route == null || delegate == null) {
      // The window closed, and its controller with it.
      throw const DragOutPromiseException(
        DragOutPromiseFailure.unknown,
        'no window owns this drag-out session',
      );
    }
    return delegate.fulfilPromise(
      DragOutPromiseRequest(
        sessionId: route.sessionId,
        promiseId: request.promiseId,
        destinationPath: request.destinationPath,
      ),
    );
  }

  @override
  void cancelPromise(String sessionId, String promiseId) {
    final route = _router._route(sessionId);
    route?.view._delegate?.cancelPromise(route.sessionId, promiseId);
  }

  @override
  void sessionEnded(String sessionId, DragOutOperation? operation) {
    final route = _router._route(sessionId);
    route?.view._delegate?.sessionEnded(route.sessionId, operation);
  }
}

/// The backend main.dart composes for this host: the channel on the
/// desktop platforms (promises on macOS only; Windows virtual files are
/// a follow-up), the no-op elsewhere. [platform] defaults to
/// `defaultTargetPlatform`, which tests override.
DragOutBackend platformDragOutBackend({TargetPlatform? platform}) {
  if (kIsWeb) return const NoDragOutBackend();
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.macOS => MethodChannelDragOutBackend(
      support: DragOutSupport.localFilesAndPromises,
    ),
    TargetPlatform.linux || TargetPlatform.windows =>
      MethodChannelDragOutBackend(support: DragOutSupport.localFiles),
    _ => const NoDragOutBackend(),
  };
}
