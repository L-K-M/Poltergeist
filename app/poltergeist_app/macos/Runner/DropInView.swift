import Cocoa
import FlutterMacOS

/// Files dropped from other apps onto an extra workspace window (00 D39):
/// a drop destination laid over the window's Flutter view that reports its
/// drags on `poltergeist/dropin`, each tagged with the view's id (the
/// protocol is the library doc of lib/services/window_drop_in.dart).
/// desktop_drop lays the same kind of overlay over the main window's view
/// only, and says nothing of which view a drag is over.
///
/// It takes what desktop_drop takes: file URLs, the legacy filename list,
/// and file promises, which it receives into the same staging folder
/// (`Drops` in the temporary directory) so a promise of Poltergeist's own
/// drag-out still reads as its own (`desktopDropStagingDirectory` in
/// lib/services/drag_out_controller.dart). It offers the source a copy: a
/// drop from another app carries no move the app could honour (00 D14).
///
/// Mouse events are not this view's: AppKit hands the ones it receives up
/// the responder chain to the Flutter view beneath, as desktop_drop's
/// overlay does.
final class DropInView: NSView {
  private let channel: FlutterMethodChannel
  private let viewId: Int64

  /// Where promise receivers write, off the main thread.
  private lazy var promiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    return queue
  }()

  init(frame: NSRect, channel: FlutterMethodChannel, viewId: Int64) {
    self.channel = channel
    self.viewId = viewId
    super.init(frame: frame)
    autoresizingMask = [.width, .height]
    var types = NSFilePromiseReceiver.readableDraggedTypes.map {
      NSPasteboard.PasteboardType($0)
    }
    types.append(.fileURL)
    types.append(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    registerForDraggedTypes(types)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    send("entered", position: sender.draggingLocation)
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    send("updated", position: sender.draggingLocation)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    send("exited", position: nil)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let location = sender.draggingLocation
    let pasteboard = sender.draggingPasteboard
    let urls = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    let legacy = (pasteboard.propertyList(
      forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]) ?? []

    // Real file URLs when the source offers any; promises only otherwise.
    if !urls.isEmpty || !legacy.isEmpty {
      var paths: [String] = []
      for path in urls.map(\.path) + legacy where !paths.contains(path) {
        paths.append(path)
      }
      send("dropped", position: location, paths: paths)
      return true
    }
    let receivers = (pasteboard.readObjects(
      forClasses: [NSFilePromiseReceiver.self], options: nil)
      as? [NSFilePromiseReceiver]) ?? []
    guard !receivers.isEmpty else {
      send("dropped", position: location, paths: [])
      return true
    }
    let destination = Self.stagingFolder()
    let group = DispatchGroup()
    let lock = NSLock()
    var received: [String] = []
    for receiver in receivers {
      group.enter()
      receiver.receivePromisedFiles(
        atDestination: destination, options: [:], operationQueue: promiseQueue
      ) { url, error in
        defer { group.leave() }
        guard error == nil else { return }
        lock.lock()
        received.append(url.path)
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      self?.send("dropped", position: location, paths: received)
    }
    return true
  }

  /// A fresh folder for one drop's promises, in desktop_drop's staging
  /// folder, so two drops never collide.
  private static func stagingFolder() -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS'Z'"
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("Drops", isDirectory: true)
      .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
    try? FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: nil)
    return folder
  }

  /// [position] is in window coordinates, AppKit's bottom-left origin;
  /// Dart reads the view's logical pixels from the top left.
  private func send(_ method: String, position: NSPoint?, paths: [String]? = nil) {
    var arguments: [String: Any] = ["viewId": NSNumber(value: viewId)]
    if let position {
      let local = convert(position, from: nil)
      let y = isFlipped ? local.y : bounds.height - local.y
      arguments["position"] = [Double(local.x), Double(y)]
    }
    if let paths {
      arguments["paths"] = paths
    }
    channel.invokeMethod(method, arguments: arguments)
  }
}
