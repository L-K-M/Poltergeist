import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// One promise's ids and name, carried in its provider's `userInfo`: the
/// ids `fulfilPromise` echoes to Dart and the name `fileNameForType`
/// answers.
private struct PromiseInfo {
  let sessionId: String
  let promiseId: String
  let name: String
  let size: Int64?

  var key: PromiseKey { PromiseKey(sessionId: sessionId, promiseId: promiseId) }
}

private struct PromiseKey: Hashable {
  let sessionId: String
  let promiseId: String
}

/// One `startDrag` item, parsed.
private enum DragOutItem {
  case file(path: String, name: String, isDirectory: Bool)
  case promise(PromiseInfo, isDirectory: Bool)

  var name: String {
    switch self {
    case .file(_, let name, _): return name
    case .promise(let info, _): return info.name
    }
  }
}

/// The running native session.
private struct ActiveSession {
  let id: String
  let operations: NSDragOperation
}

/// The macOS side of `poltergeist/dragout` (00 D14's 2026-09-25
/// amendment; the protocol is the library doc of
/// lib/services/os_drag_out.dart). Dart decides what to drag and where
/// promises land. This class only turns a `startDrag` request into an
/// AppKit dragging session and relays the session's callbacks.
///
/// * AppKit starts a drag from a mouse event, and by the time Dart asks
///   (the pointer has already left the window) that event is gone. The
///   view that received it is often not Flutter's either: desktop_drop
///   lays a full-size overlay over the FlutterView, and
///   macos_window_utils forwards toolbar clicks from views of its own. A
///   local event monitor keeps this window's latest primary press and
///   drag, whichever view they hit.
/// * The session swallows the real mouse-up, so Flutter's embedder would
///   still believe the button is down and drop the next click. A
///   synthetic mouse-up reaches the FlutterViewController first.
/// * Platform and UI threads are merged, so Dart runs on the main
///   thread and nothing here may wait for it. A promise's write hops from
///   the provider's private queue to the main queue, invokes
///   `fulfilPromise`, and returns; Dart's reply completes the promise
///   whenever it arrives, which can be minutes later.
/// * Delete is never offered (D15): a Dock-Trash drop would be a delete
///   outside the confirmed flow. Nothing here removes a file; a
///   destination that moves a local file moves it itself.
final class DragOutChannel: NSObject {
  private static let channelName = "poltergeist/dragout"

  /// Past this many local items, the rest show their type's icon:
  /// NSWorkspace reads each file's own icon from disk, on the main
  /// thread, and a pile only ever shows its top few anyway.
  private static let fileIconLimit = 16

  private static let iconSize: CGFloat = 32
  private static let labelGap: CGFloat = 4
  private static let labelMaxWidth: CGFloat = 240
  private static let labelFontSize: CGFloat = 12
  private static let labelPadding = NSSize(width: 6, height: 2)
  private static let labelRadius: CGFloat = 4

  /// How long an ended session's promise providers stay retained: the
  /// OS may call a promise in after the drop, and the Dart side keeps
  /// promises answerable this long (`sessionRetention`).
  private static let providerRetention: TimeInterval = 300

  /// Failure codes that are not errors to the receiver: the user gave up,
  /// or the drag came back into Poltergeist and lands in-app. They
  /// complete as a user cancel, which AppKit apps do not report.
  private static let quietFailures: Set<String> = ["cancelled", "ownDrop"]

  private static let errorDomain = "com.lkm.poltergeist.dragout"

  private let channel: FlutterMethodChannel
  private weak var flutterViewController: FlutterViewController?
  private var eventMonitor: Any?

  private var lastDown: NSEvent?
  private var lastDragged: NSEvent?
  private var activeSession: ActiveSession?

  /// Main-thread state for promises: the providers of recent sessions
  /// (the drag pasteboard may drop them before a late call) and the
  /// progress published for each promise being written.
  private var retainedProviders: [String: [NSFilePromiseProvider]] = [:]
  private var publishedProgress: [PromiseKey: Progress] = [:]

  /// Where AppKit calls the promise delegate. It only ever hops to the
  /// main queue, so it never holds a thread for the length of a write.
  private let promiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.lkm.poltergeist.dragout.promises"
    queue.qualityOfService = .userInitiated
    return queue
  }()

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    channel = FlutterMethodChannel(
      name: DragOutChannel.channelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged]
    ) { [weak self] event in
      self?.record(event)
      return event
    }
  }

  deinit {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
  }

  private func record(_ event: NSEvent) {
    guard let window = flutterViewController?.view.window,
          event.window === window else { return }
    switch event.type {
    case .leftMouseDown:
      lastDown = event
      lastDragged = nil
      // A press only arrives once any AppKit session is over, so a
      // session whose end never came must not refuse later drags as busy.
      if let lost = activeSession {
        activeSession = nil
        releaseProvidersLater(lost.id)
      }
    case .leftMouseDragged:
      lastDragged = event
    default:
      break
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startDrag":
      result(startDrag(call.arguments))
    case "promiseProgress":
      updateProgress(call.arguments)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - startDrag

  private func startDrag(_ arguments: Any?) -> [String: Any] {
    guard let args = arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String,
          let rawItems = args["items"] as? [[String: Any]],
          !rawItems.isEmpty else {
      return Self.refusal("failed", "startDrag needs a sessionId and items")
    }
    if activeSession != nil {
      return Self.refusal("busy", nil)
    }

    var items: [DragOutItem] = []
    for raw in rawItems {
      guard let item = Self.parseItem(raw, sessionId: sessionId) else {
        return Self.refusal("unsupportedItems", nil)
      }
      items.append(item)
    }

    // The newest drag event puts AppKit's reference point where the
    // pointer is now; the press alone would leave the image behind at
    // the row the drag began on.
    guard let event = lastDragged ?? lastDown else {
      return Self.refusal("noPointerEvent", nil)
    }
    guard (NSEvent.pressedMouseButtons & 1) != 0 else {
      return Self.refusal("buttonReleased", nil)
    }
    guard let controller = flutterViewController,
          let window = controller.view.window else {
      return Self.refusal("failed", "the Flutter view is not in a window")
    }
    let view = controller.view

    let carriesPromises = items.contains { item in
      if case .promise = item { return true }
      return false
    }
    // Promises can only ever be copies. Local files offer what Dart
    // allowed, and the destination picks (Finder's rules).
    let operations: NSDragOperation = carriesPromises
      ? .copy
      : Self.dragOperations(args["allowedOperations"])

    // The image's top-left corner hangs at Dart's anchor from the
    // pointer, where the in-app avatar was: the drag does not jump at
    // the window edge. The frame is placed from the same event AppKit
    // gets, so the offset holds for the whole session.
    let pointer = view.convert(event.locationInWindow, from: nil)
    let anchor = Self.point(args["imageAnchor"]) ?? .zero
    var draggingItems: [NSDraggingItem] = []
    var providers: [NSFilePromiseProvider] = []
    for (index, item) in items.enumerated() {
      let writer: NSPasteboardWriting
      let icon: NSImage
      switch item {
      case .file(let path, let name, let isDirectory):
        writer = NSURL(fileURLWithPath: path, isDirectory: isDirectory)
        icon = index < Self.fileIconLimit
          ? NSWorkspace.shared.icon(forFile: path)
          : NSWorkspace.shared.icon(for: Self.contentType(name: name, isDirectory: isDirectory))
      case .promise(let info, let isDirectory):
        let type = Self.contentType(name: info.name, isDirectory: isDirectory)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = info
        providers.append(provider)
        writer = provider
        icon = NSWorkspace.shared.icon(for: type)
      }
      draggingItems.append(
        Self.draggingItem(writer: writer, icon: icon, name: item.name, in: view,
                          pointer: pointer, anchor: anchor)
      )
    }

    // AppKit may ask for the operation mask as soon as the session
    // begins, so the session is recorded first.
    activeSession = ActiveSession(id: sessionId, operations: operations)
    if !providers.isEmpty {
      retainedProviders[sessionId] = providers
    }
    endFlutterPress(controller, window: window)
    let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
    if draggingItems.count > 1 {
      // Finder's look for several items: a pile under AppKit's count
      // badge.
      session.draggingFormation = .pile
    }
    return ["started": true]
  }

  private static func parseItem(_ raw: [String: Any], sessionId: String) -> DragOutItem? {
    let isDirectory = (raw["isDirectory"] as? Bool) ?? false
    let name = raw["name"] as? String
    switch raw["kind"] as? String {
    case "file":
      guard let path = raw["path"] as? String, !path.isEmpty else { return nil }
      return .file(
        path: path,
        name: name ?? (path as NSString).lastPathComponent,
        isDirectory: isDirectory
      )
    case "promise":
      guard let promiseId = raw["promiseId"] as? String,
            let name, !name.isEmpty else { return nil }
      let size = (raw["size"] as? NSNumber)?.int64Value
      return .promise(
        PromiseInfo(sessionId: sessionId, promiseId: promiseId, name: name, size: size),
        isDirectory: isDirectory
      )
    default:
      return nil
    }
  }

  /// Ends the embedder's view of the press: the session takes the real
  /// mouse-up, and an embedder that still believes the button is down
  /// drops the next click. Sent straight to the controller so no
  /// overlay view can intercept it.
  private func endFlutterPress(_ controller: FlutterViewController, window: NSWindow) {
    guard let release = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: window.mouseLocationOutsideOfEventStream,
      modifierFlags: NSEvent.modifierFlags,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 0
    ) else { return }
    controller.mouseUp(with: release)
  }

  /// A Finder-style item: the file's icon with its name beside it. The
  /// two components are centered on one row, so the layout reads the same
  /// whichever way AppKit orients the item's coordinates.
  private static func draggingItem(
    writer: NSPasteboardWriting,
    icon: NSImage,
    name: String,
    in view: NSView,
    pointer: NSPoint,
    anchor: CGPoint
  ) -> NSDraggingItem {
    let label = labelImage(name)
    let size = NSSize(
      width: iconSize + labelGap + label.size.width,
      height: max(iconSize, label.size.height)
    )
    let origin = NSPoint(
      x: pointer.x - anchor.x,
      y: view.isFlipped ? pointer.y - anchor.y : pointer.y + anchor.y - size.height
    )
    let item = NSDraggingItem(pasteboardWriter: writer)
    item.draggingFrame = NSRect(origin: origin, size: size)
    item.imageComponentsProvider = {
      let iconComponent = NSDraggingImageComponent(key: .icon)
      iconComponent.contents = icon
      iconComponent.frame = NSRect(
        x: 0,
        y: (size.height - Self.iconSize) / 2,
        width: Self.iconSize,
        height: Self.iconSize
      )
      let labelComponent = NSDraggingImageComponent(key: .label)
      labelComponent.contents = label
      labelComponent.frame = NSRect(
        x: Self.iconSize + Self.labelGap,
        y: (size.height - label.size.height) / 2,
        width: label.size.width,
        height: label.size.height
      )
      return [iconComponent, labelComponent]
    }
    return item
  }

  /// The name on the selection highlight, as Finder draws a dragged
  /// item's label, truncated in the middle past `labelMaxWidth`.
  private static func labelImage(_ name: String) -> NSImage {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    let text = NSAttributedString(
      string: name.components(separatedBy: .newlines).joined(separator: " "),
      attributes: [
        .font: NSFont.systemFont(ofSize: labelFontSize),
        .foregroundColor: NSColor.alternateSelectedControlTextColor,
        .paragraphStyle: paragraph,
      ]
    )
    let measured = text.size()
    let textSize = NSSize(
      width: min(ceil(measured.width), labelMaxWidth),
      height: ceil(measured.height)
    )
    let size = NSSize(
      width: textSize.width + 2 * labelPadding.width,
      height: textSize.height + 2 * labelPadding.height
    )
    return NSImage(size: size, flipped: false) { bounds in
      NSColor.selectedContentBackgroundColor.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: Self.labelRadius, yRadius: Self.labelRadius)
        .fill()
      text.draw(in: NSRect(
        origin: NSPoint(x: Self.labelPadding.width, y: Self.labelPadding.height),
        size: textSize
      ))
      return true
    }
  }

  /// The promised or dragged item's type: `public.folder` for a folder,
  /// else from the name's extension, else `public.data`.
  private static func contentType(name: String, isDirectory: Bool) -> UTType {
    if isDirectory { return .folder }
    let pathExtension = (name as NSString).pathExtension
    if pathExtension.isEmpty { return .data }
    return UTType(filenameExtension: pathExtension) ?? .data
  }

  /// `allowedOperations` as AppKit's mask. Only copy, move, and link
  /// exist here: never delete (D15), never generic.
  private static func dragOperations(_ value: Any?) -> NSDragOperation {
    var operations: NSDragOperation = []
    for name in (value as? [String]) ?? [] {
      switch name {
      case "copy": operations.insert(.copy)
      case "move": operations.insert(.move)
      case "link": operations.insert(.link)
      default: break
      }
    }
    return operations.isEmpty ? .copy : operations
  }

  /// An `[x, y]` list of numbers.
  private static func point(_ value: Any?) -> CGPoint? {
    guard let pair = value as? [NSNumber], pair.count == 2 else { return nil }
    return CGPoint(x: pair[0].doubleValue, y: pair[1].doubleValue)
  }

  private static func refusal(_ reason: String, _ message: String?) -> [String: Any] {
    var reply: [String: Any] = ["started": false, "reason": reason]
    if let message {
      reply["message"] = message
    }
    return reply
  }

  // MARK: - Promises (main thread)

  private func updateProgress(_ arguments: Any?) {
    guard let update = arguments as? [String: Any],
          let sessionId = update["sessionId"] as? String,
          let promiseId = update["promiseId"] as? String,
          let completed = (update["completedBytes"] as? NSNumber)?.int64Value,
          let progress = publishedProgress[PromiseKey(sessionId: sessionId, promiseId: promiseId)]
    else { return }
    if let total = (update["totalBytes"] as? NSNumber)?.int64Value, total >= 0 {
      progress.totalUnitCount = total
    }
    progress.completedUnitCount = completed
  }

  /// Publishes the promise's progress for the receiver (Finder's pie),
  /// asks Dart to produce the item at `url`, and completes the promise
  /// with Dart's reply. Returns at once; nothing waits.
  private func fulfil(
    _ info: PromiseInfo,
    at url: URL,
    provider: NSFilePromiseProvider,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let progress = Progress(parent: nil, userInfo: nil)
    progress.kind = .file
    progress.fileOperationKind = .downloading
    progress.fileURL = url
    progress.totalUnitCount = info.size ?? -1
    progress.isCancellable = true
    progress.isPausable = false
    let channel = self.channel
    progress.cancellationHandler = {
      // Any thread: the channel is main-thread only.
      DispatchQueue.main.async {
        channel.invokeMethod("cancelPromise", arguments: [
          "sessionId": info.sessionId,
          "promiseId": info.promiseId,
        ])
      }
    }
    progress.publish()
    publishedProgress[info.key] = progress

    channel.invokeMethod("fulfilPromise", arguments: [
      "sessionId": info.sessionId,
      "promiseId": info.promiseId,
      "destinationPath": url.path,
    ]) { [weak self] reply in
      // The provider outlives the write even if the drag pasteboard
      // has already let it go.
      withExtendedLifetime(provider) {}
      progress.unpublish()
      if self?.publishedProgress[info.key] === progress {
        self?.publishedProgress.removeValue(forKey: info.key)
      }
      completionHandler(Self.completionError(reply))
    }
  }

  /// `fulfilPromise`'s reply as the promise's completion: nil on
  /// success. Poltergeist reports its own failures (an Alert or a failed
  /// Transfers row); the error text is for the receiver and the logs.
  private static func completionError(_ reply: Any?) -> Error? {
    if let error = reply as? FlutterError {
      if quietFailures.contains(error.code) {
        return CocoaError(.userCancelled)
      }
      return NSError(domain: errorDomain, code: 1, userInfo: [
        NSLocalizedDescriptionKey: error.message ?? error.code,
      ])
    }
    if let marker = reply as? NSObject, marker === FlutterMethodNotImplemented {
      return NSError(domain: errorDomain, code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Poltergeist is not ready to produce the item.",
      ])
    }
    return nil
  }

  private func releaseProvidersLater(_ sessionId: String) {
    guard retainedProviders[sessionId] != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.providerRetention) { [weak self] in
      self?.retainedProviders.removeValue(forKey: sessionId)
    }
  }

  private static func operationName(_ operation: NSDragOperation) -> String {
    if operation.contains(.move) { return "move" }
    if operation.contains(.link) { return "link" }
    if operation.contains(.copy) { return "copy" }
    return "none"
  }
}

extension DragOutChannel: NSDraggingSource {
  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    // The same inside the app: a drag back over Poltergeist lands on
    // desktop_drop, which answers copy, and Dart routes it in-app.
    activeSession?.operations ?? []
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    guard let ended = activeSession else { return }
    activeSession = nil
    // Promises may still be called in after this; their providers stay
    // retained and Dart keeps them answerable.
    channel.invokeMethod("sessionEnded", arguments: [
      "sessionId": ended.id,
      "operation": Self.operationName(operation),
    ])
    releaseProvidersLater(ended.id)
  }
}

extension DragOutChannel: NSFilePromiseProviderDelegate {
  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    fileNameForType fileType: String
  ) -> String {
    // Unreachable without the info: every provider is built with it, and
    // writePromiseTo then fails such a promise before anything is written.
    (filePromiseProvider.userInfo as? PromiseInfo)?.name ?? "Untitled"
  }

  func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
    promiseQueue
  }

  /// Runs on `promiseQueue`. Hops to the main queue, where Dart and all
  /// of this class's state live, and returns without waiting.
  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let info = filePromiseProvider.userInfo as? PromiseInfo else {
      completionHandler(NSError(domain: Self.errorDomain, code: 3, userInfo: [
        NSLocalizedDescriptionKey: "The promise is not one of Poltergeist's.",
      ]))
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        completionHandler(CocoaError(.userCancelled))
        return
      }
      self.fulfil(info, at: url, provider: filePromiseProvider,
                  completionHandler: completionHandler)
    }
  }
}
