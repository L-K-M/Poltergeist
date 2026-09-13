import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'local_watch_backend.dart';

/// The Linux half of the watch seam (03 §7.5): one non-recursive inotify
/// watch per shown directory, able to see the whole kernel event stream —
/// including `IN_Q_OVERFLOW`, which dart:io's Linux implementation drops
/// (it carries watch descriptor -1 and matches no watched path there).
///
/// # Why a helper isolate
///
/// The Dart event loop cannot wait on foreign file descriptors, and a
/// blocking `read()`/`poll()` on the engine isolate would freeze the whole
/// engine. The inotify descriptor is therefore polled — without timeouts,
/// so without spinning or filesystem polling — inside a small helper
/// isolate that only forwards decoded events. The engine isolate never
/// blocks.
///
/// # Cancellation
///
/// `cancel()` writes one byte to a stop pipe and closes its write end; the
/// helper's `poll()` wakes on the byte or the hangup, so teardown never
/// waits for filesystem activity. The helper's drain is bounded to
/// [maxReadBatchesPerPoll] read batches before `poll()` is re-armed —
/// sustained event pressure would otherwise keep every `read()` returning
/// data, EAGAIN would never arrive, and the stop pipe would never be
/// revisited, holding cancellation pending for as long as producers run.
/// With the bound, stop latency is capped at one drain's decode/send work
/// regardless of filesystem behavior. The cancel future completes only
/// after the helper acknowledged (its poll loop has exited) and this
/// isolate has closed the inotify descriptor, both pipe descriptors, and
/// the read buffer — an acknowledged release means the OS watch is really
/// gone.
///
/// # Resource ownership
///
/// Everything process-level is owned here in the consuming isolate and
/// released on every path: each failed setup step releases what earlier
/// steps created; overflow and read errors deliver the loss first, then
/// tear down; explicit and repeated cancels run the same memoized release.
/// An unsupervised engine-isolate death (raw `Isolate.kill`) bypasses all
/// Dart cleanup and would leak one descriptor set plus a parked helper
/// until process exit — a process exit releases them, but no Dart-level
/// kill claim is made beyond that.
final class LinuxInotifyWatchBackend implements LocalWatchBackend {
  const LinuxInotifyWatchBackend();

  @override
  Stream<FileSystemEvent> watch(String directory) =>
      _LinuxInotifyWatch(directory).stream;
}

// -- inotify interface constants (linux/inotify.h, man 7 inotify) ----------

/// Events the watch subscribes to. `IN_Q_OVERFLOW`, `IN_IGNORED` and
/// `IN_UNMOUNT` are delivered regardless of the mask.
const int watchedEventMask =
    inotifyAttrib |
    inotifyCreate |
    inotifyDelete |
    inotifyDeleteSelf |
    inotifyModify |
    inotifyMovedFrom |
    inotifyMovedTo |
    inotifyMoveSelf;

const int inotifyAttrib = 0x00000004;
const int inotifyCreate = 0x00000100;
const int inotifyDelete = 0x00000200;
const int inotifyDeleteSelf = 0x00000400;
const int inotifyModify = 0x00000002;
const int inotifyMovedFrom = 0x00000040;
const int inotifyMovedTo = 0x00000080;
const int inotifyMoveSelf = 0x00000800;
const int inotifyUnmount = 0x00002000;
const int inotifyQOverflow = 0x00004000;
const int inotifyIgnored = 0x00008000;
const int inotifyIsDir = 0x40000000;

/// `inotify_init1` flags (O_NONBLOCK / O_CLOEXEC) — the descriptor must
/// never block the helper across a missed drain.
const int inotifyNonBlock = 0x800;
const int inotifyCloseOnExec = 0x80000;

/// fcntl `O_CLOEXEC` (same value inotify_init1's IN_CLOEXEC shares); used
/// for the stop pipe so the descriptors never leak into exec'd children.
const int oCloseOnExec = 0x80000;

// -- poll interface constants (man 2 poll) ---------------------------------

const int pollIn = 0x0001;
const int pollError = 0x0008;
const int pollHup = 0x0010;
const int pollNval = 0x0020;
const int pollWaitForever = -1;

// -- errno values relevant here (linux/errno.h) ----------------------------

const int errnoAccess = 13;
const int errnoAgain = 11;
const int errnoBadFd = 9;
const int errnoInterrupt = 4;
const int errnoInvalid = 22;
const int errnoNoEntity = 2;

String _errnoName(int code) => switch (code) {
  errnoAccess => 'EACCES',
  errnoAgain => 'EAGAIN',
  errnoBadFd => 'EBADF',
  errnoInterrupt => 'EINTR',
  errnoInvalid => 'EINVAL',
  errnoNoEntity => 'ENOENT',
  _ => 'errno $code',
};

// -- pure decoding (no FFI; unit-tested on every platform) -----------------

/// `struct inotify_event`'s fixed part: `wd`, `mask`, `cookie`, `len`.
const int inotifyEventHeaderBytes = 16;

/// One decoded inotify event: the raw kernel fields plus the name (NUL
/// padding stripped, malformed UTF-8 replaced — the same decoding stance
/// the plan takes for listing entries).
final class InotifyEventRecord {
  final int wd;
  final int mask;
  final int cookie;
  final String name;

  const InotifyEventRecord(this.wd, this.mask, this.cookie, this.name);
}

/// Decodes one `read()` batch. The kernel guarantees whole events per
/// read, so a truncated header or name is a backend error, not a partial
/// decode.
List<InotifyEventRecord> decodeInotifyEvents(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final records = <InotifyEventRecord>[];
  var offset = 0;
  while (offset < bytes.length) {
    if (bytes.length - offset < inotifyEventHeaderBytes) {
      throw FormatException('truncated inotify event header at $offset');
    }
    final wd = data.getInt32(offset, Endian.host);
    final mask = data.getUint32(offset + 4, Endian.host);
    final cookie = data.getUint32(offset + 8, Endian.host);
    final nameLength = data.getUint32(offset + 12, Endian.host);
    final nameStart = offset + inotifyEventHeaderBytes;
    final nameEnd = nameStart + nameLength;
    if (nameEnd > bytes.length) {
      throw FormatException('truncated inotify event name at $offset');
    }

    records.add(
      InotifyEventRecord(
        wd,
        mask,
        cookie,
        _decodeName(bytes, nameStart, nameEnd),
      ),
    );
    offset = nameEnd;
  }
  return records;
}

String _decodeName(Uint8List bytes, int start, int end) {
  var length = end - start;
  while (length > 0 && bytes[start + length - 1] == 0) {
    length--;
  }
  if (length == 0) return '';
  return utf8.decode(bytes.sublist(start, start + length), allowMalformed: true);
}

/// Maps one non-move event record to the dart:io event shape the watch
/// adapter is built on. Returns null for `IN_IGNORED` (the watch was
/// removed; its loss already surfaced) and for combinations with no
/// mapped bits. Move halves go through [InotifyMoveMatcher] instead —
/// pairing needs state dart:io keeps per chunk.
///
/// `IN_Q_OVERFLOW` never reaches here: the backend turns it into a stream
/// error before mapping, because dropped events are a loss, not a change.
FileSystemEvent? fileSystemEventFromInotify({
  required int mask,
  required String name,
  required String watchedPath,
}) {
  if (mask & inotifyIgnored != 0) return null;

  final isDirectory = mask & inotifyIsDir != 0;

  // The watched directory was removed, moved away, or its filesystem
  // unmounted: dart:io's Linux loss shape — one delete naming the watched
  // path — which the adapter reports as an immediate lost.
  if (mask & (inotifyDeleteSelf | inotifyMoveSelf | inotifyUnmount) != 0) {
    return FileSystemDeleteEvent(watchedPath, true);
  }

  final path = name.isEmpty ? watchedPath : p.join(watchedPath, name);

  if (mask & inotifyCreate != 0) return FileSystemCreateEvent(path, isDirectory);
  if (mask & inotifyDelete != 0) return FileSystemDeleteEvent(path, isDirectory);
  if (mask & (inotifyModify | inotifyAttrib) != 0) {
    return FileSystemModifyEvent(
      path,
      isDirectory,
      mask & inotifyModify != 0,
    );
  }
  return null;
}

/// Pairs `IN_MOVED_FROM`/`IN_MOVED_TO` halves by cookie exactly as
/// dart:io's Linux watcher does (`_WatchedPath.addEvent`): a matched pair
/// becomes one [FileSystemMoveEvent] naming the source with its
/// destination; an unpaired half is flushed as a create (moved-to) or
/// delete (moved-from) once the read batch ends. This state machine is
/// the reason the raw stream is decoded instead of consumed event-wise.
final class InotifyMoveMatcher {
  /// Most recently encountered move halves by cookie.
  final _unmatched = <int, ({int mask, String name})>{};

  /// Feeds one move-shaped record; returns the completed move event when
  /// this record pairs an earlier half, null otherwise (parked, or a
  /// non-move mask passed through untouched).
  FileSystemEvent? match({
    required int mask,
    required int cookie,
    required String name,
    required String watchedPath,
  }) {
    if (mask & (inotifyMovedFrom | inotifyMovedTo) == 0) return null;

    if (cookie > 0) {
      final linked = _unmatched.remove(cookie);
      if (linked == null) {
        _unmatched[cookie] = (mask: mask, name: name);
        return null;
      }
      return FileSystemMoveEvent(
        _pathOf(linked.name, watchedPath),
        mask & inotifyIsDir != 0,
        _pathOf(name, watchedPath),
      );
    }
    return _unpaired(mask, name, watchedPath);
  }

  /// Emits every still-unmatched half as dart:io's flush does: a parked
  /// moved-to becomes a create, a moved-from a delete — and the parked
  /// entries are consumed, so a flushed half can neither re-emit on a
  /// later batch nor pair with a late opposite half. Called when a read
  /// batch ends, so a rename split across reads still refreshes.
  List<FileSystemEvent> flush(String watchedPath) {
    final flushed = [
      for (final (:mask, :name) in _unmatched.values)
        _unpaired(mask, name, watchedPath)!,
    ];
    _unmatched.clear();
    return flushed;
  }

  FileSystemEvent? _unpaired(int mask, String name, String watchedPath) {
    final path = _pathOf(name, watchedPath);
    if (mask & inotifyMovedTo != 0) {
      return FileSystemCreateEvent(path, mask & inotifyIsDir != 0);
    }
    return FileSystemDeleteEvent(path, mask & inotifyIsDir != 0);
  }

  static String _pathOf(String name, String watchedPath) =>
      name.isEmpty ? watchedPath : p.join(watchedPath, name);
}

// -- the FFI bridge ---------------------------------------------------------

/// One oversized read per drain step: the kernel queue holds at most
/// `max_queued_events` records and each event is well under 300 bytes, so
/// a full overflow queue drains in a few dozen reads.
const int readBufferBytes = 64 * 1024;

/// Read batches per drain step before the loop re-arms `poll`. Without
/// this bound, sustained input keeps every `read()` returning data and
/// EAGAIN never arrives — the helper would never revisit the stop pipe,
/// and cancellation would wait for filesystem quiescence. The bound caps
/// stop latency at one drain's decode/send work while leaving throughput
/// unchanged: `poll` with a readable inotify descriptor returns
/// immediately, so re-arming costs one extra syscall per megabyte.
const int maxReadBatchesPerPoll = 16;

/// The stop-pipe byte. The write end's close (hangup) is a second,
/// redundant wakeup for the same purpose.
const int stopCommandByte = 0;

/// Sentinel acknowledging the helper's poll loop has exited; its isolate
/// exit fires the exit port as a backstop.
const String helperStoppedMessage = 'stopped';

final DynamicLibrary _libc = DynamicLibrary.process();

// Late finals: symbol lookup happens on first use, always inside this
// file's Linux-only paths; nothing here loads on other platforms.
final _inotifyInit1 = _libc.lookupFunction<Int32 Function(Int32),
    int Function(int)>('inotify_init1');
final _inotifyAddWatch = _libc
    .lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Uint32),
        int Function(int, Pointer<Uint8>, int)>('inotify_add_watch');
final _pipe = _libc.lookupFunction<Int32 Function(Pointer<Int32>, Int32),
    int Function(Pointer<Int32>, int)>('pipe2');
final _poll = _libc.lookupFunction<
    Int32 Function(Pointer<_PollFd>, UnsignedLong, Int32),
    int Function(Pointer<_PollFd>, int, int)>('poll');
final _read = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('read');
final _write = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      '__errno_location',
    );

int _errno() => _errnoLocation().value;

final class _PollFd extends Struct {
  @Int32()
  external int fd;

  @Int16()
  external int events;

  @Int16()
  external int revents;
}

/// The helper's spawn message. The buffer address crosses as an int —
/// pointers are not isolate messages.
final class _HelperConfig {
  final int inotifyFd;
  final int stopPipeRead;
  final int bufferAddress;
  final SendPort toMain;

  const _HelperConfig(this.inotifyFd, this.stopPipeRead, this.bufferAddress,
      this.toMain);
}

/// The helper isolate's entry: wait on {inotify, stop pipe}, drain the
/// inotify queue whenever it is readable, exit when the stop pipe speaks.
/// Owns exactly one allocation — its `pollfd` array — freed on every exit.
void _inotifyHelperMain(_HelperConfig config) {
  final pollFds = calloc<_PollFd>(2);
  try {
    pollFds[0]
      ..fd = config.inotifyFd
      ..events = pollIn
      ..revents = 0;
    pollFds[1]
      ..fd = config.stopPipeRead
      ..events = pollIn
      ..revents = 0;
    _runHelperLoop(config, pollFds);
  } finally {
    calloc.free(pollFds);
    config.toMain.send(helperStoppedMessage);
  }
}

void _runHelperLoop(_HelperConfig config, Pointer<_PollFd> pollFds) {
  final buffer = Pointer<Uint8>.fromAddress(config.bufferAddress);
  while (true) {
    final ready = _poll(pollFds, 2, pollWaitForever);
    if (ready < 0) {
      final code = _errno();
      if (code == errnoInterrupt) continue;
      config.toMain.send([_syscallError('poll', code), null]);
      return;
    }

    // The stop pipe wins: once teardown began, events that raced it are
    // dead regardless, and the consumer has been told already.
    if (pollFds[1].revents != 0) return;

    final inotifyEvents = pollFds[0].revents;
    if (inotifyEvents & pollIn != 0) {
      if (_drainInotify(config, buffer)) return;
    } else if (inotifyEvents & (pollError | pollHup | pollNval) != 0) {
      config.toMain
          .send([_syscallError('the inotify descriptor failed', 0), null]);
      return;
    }
  }
}

/// Drains a bounded number of batches, then returns so the poll loop —
/// which checks the stop pipe first — is re-armed even while producers
/// keep the queue non-empty. Returns true only when a fatal read error
/// ended the helper (the error was already forwarded).
bool _drainInotify(_HelperConfig config, Pointer<Uint8> buffer) {
  for (var batch = 0; batch < maxReadBatchesPerPoll; batch++) {
    final count = _read(config.inotifyFd, buffer, readBufferBytes);
    if (count < 0) {
      final code = _errno();
      if (code == errnoAgain) return false;
      if (code == errnoInterrupt) {
        batch--;
        continue;
      }
      config.toMain.send([_syscallError('read', code), null]);
      return true;
    }
    if (count == 0) return false;
    config.toMain.send(decodeInotifyEvents(buffer.asTypedList(count)));
  }
  return false;
}

/// A two-element failure report `[error, stack]` matching the isolate
/// error-port shape, so the consumer decodes both the same way.
FileSystemException _syscallError(String call, int code) =>
    FileSystemException('$call (${_errnoName(code)}).');

final class _LinuxInotifyWatch {
  _LinuxInotifyWatch(this._path)
    : assert(p.isAbsolute(_path), 'The watch path must be absolute.') {
    _events = StreamController<FileSystemEvent>(
      onListen: _start,
      onCancel: _cancel,
    );
  }

  static const int _invalidFd = -1;

  final String _path;
  late final StreamController<FileSystemEvent> _events;

  int _inotifyFd = _invalidFd;
  int _stopPipeRead = _invalidFd;
  int _stopPipeWrite = _invalidFd;
  Pointer<Uint8>? _readBuffer;
  ReceivePort? _fromHelper;
  ReceivePort? _helperExit;

  /// Completed when the helper's poll loop can no longer touch the
  /// descriptors: its stopped ack, its error report, its isolate exit, or
  /// a setup failure before it ever started.
  final Completer<void> _helperDone = Completer<void>();

  bool _failed = false;
  Future<void>? _releaseFuture;
  final InotifyMoveMatcher _moves = InotifyMoveMatcher();

  Stream<FileSystemEvent> get stream => _events.stream;

  void _start() {
    try {
      _install();
    } on Object catch (error) {
      // Nothing later can be trusted, and a consumer cancel must not wait
      // for a helper that never started.
      _signalHelperDone();
      _fail(error);
    }
  }

  void _install() {
    final fd = _inotifyInit1(inotifyNonBlock | inotifyCloseOnExec);
    if (fd < 0) {
      throw _osError('inotify_init1 failed', _errno());
    }
    _inotifyFd = fd;

    final nativePath = _path.toNativeUtf8();
    try {
      final watchDescriptor = _inotifyAddWatch(
        _inotifyFd,
        nativePath.cast<Uint8>(),
        watchedEventMask,
      );
      if (watchDescriptor < 0) {
        final code = _errno();
        _closeInotify();
        throw _osError('inotify_add_watch failed', code);
      }
    } finally {
      malloc.free(nativePath);
    }

    final pipeFds = calloc<Int32>(2);
    try {
      if (_pipe(pipeFds, oCloseOnExec) != 0) {
        final code = _errno();
        _closeInotify();
        throw _osError('pipe failed', code);
      }
      _stopPipeRead = pipeFds[0];
      _stopPipeWrite = pipeFds[1];
    } finally {
      calloc.free(pipeFds);
    }

    _readBuffer = calloc<Uint8>(readBufferBytes);

    _fromHelper = ReceivePort('inotify events')..listen(_onHelperMessage);
    // Serves as both the spawn error port and the exit port: normal exit
    // delivers null; an uncaught helper error delivers [error, stack].
    // Either way the helper can no longer touch the descriptors — but an
    // error shape must also fail the watch, or it would stay silently
    // installed while delivering nothing.
    _helperExit = ReceivePort('inotify helper exit')
      ..listen((message) {
        _signalHelperDone();
        if (message case [final Object error, final Object? stack]) {
          _fail(error, stack is StackTrace ? stack : null);
        }
      });

    unawaited(
      Isolate.spawn(
        _inotifyHelperMain,
        _HelperConfig(
          _inotifyFd,
          _stopPipeRead,
          _readBuffer!.address,
          _fromHelper!.sendPort,
        ),
        errorsAreFatal: true,
        onError: _helperExit!.sendPort,
        onExit: _helperExit!.sendPort,
      ).then<void>(
        (_) {},
        onError: (Object error) {
          _signalHelperDone();
          _fail(error);
        },
      ),
    );
  }

  void _onHelperMessage(Object? message) {
    if (message case final List<InotifyEventRecord> records) {
      _dispatch(records);
      return;
    }
    if (message == helperStoppedMessage) {
      _signalHelperDone();
      return;
    }
    if (message case [final Object error, final Object? stack]) {
      _signalHelperDone();
      _fail(error, stack is StackTrace ? stack : null);
    }
  }

  void _dispatch(List<InotifyEventRecord> records) {
    for (final record in records) {
      if (_failed || _releaseFuture != null) return;

      // The kernel overran the queue: earlier events were dropped without
      // ever being queued. Surface the loss instead of a stale listing.
      if (record.mask & inotifyQOverflow != 0) {
        _fail(
          FileSystemException(
            'The kernel event queue overflowed; directory events were '
            'dropped.',
            _path,
          ),
        );
        return;
      }

      final event = _moves.match(
        mask: record.mask,
        cookie: record.cookie,
        name: record.name,
        watchedPath: _path,
      );
      final mapped = event ??
          fileSystemEventFromInotify(
            mask: record.mask,
            name: record.name,
            watchedPath: _path,
          );
      if (mapped != null) _events.add(mapped);

      // dart:io's Linux loss shape (addEvent's delete-self branch): the
      // root-loss delete is emitted by the mapping above, then unmatched
      // moves flush, then the stream closes (the adapter collapses the
      // done into the same lost). The kernel has already removed the
      // watch.
      if (record.mask &
            (inotifyDeleteSelf | inotifyMoveSelf | inotifyUnmount) !=
          0) {
        for (final event in _moves.flush(_path)) {
          if (_failed || _releaseFuture != null) return;
          _events.add(event);
        }
        _endStream();
        return;
      }
    }

    // A rename split across two reads still refreshes: unmatched halves
    // become dart:io's flush events once the batch ends.
    for (final event in _moves.flush(_path)) {
      if (_failed || _releaseFuture != null) return;
      _events.add(event);
    }
  }

  Future<void> _cancel() => _releaseFuture ??= _release();

  Future<void> _release() async {
    _wakeHelper();
    await _helperDone.future;

    // The helper is out of the descriptor's way; this isolate owns the
    // final release.
    _fromHelper?.close();
    _helperExit?.close();
    _closeInotify();
    _closeStopPipe(_stopPipeRead);
    _stopPipeRead = _invalidFd;
    final buffer = _readBuffer;
    if (buffer != null) calloc.free(buffer);
    _readBuffer = null;
  }

  /// Two independent wakeups for one poll: the command byte and the write
  /// end's hangup. A partial write cannot happen against a 64 KiB pipe
  /// buffer for a single byte, and the result is irrelevant — the close
  /// below completes the wakeup either way.
  void _wakeHelper() {
    if (_stopPipeWrite == _invalidFd) return;
    final byte = calloc<Uint8>(1);
    byte.value = stopCommandByte;
    _write(_stopPipeWrite, byte, 1);
    calloc.free(byte);
    _closeStopPipe(_stopPipeWrite);
    _stopPipeWrite = _invalidFd;
  }

  void _signalHelperDone() {
    if (!_helperDone.isCompleted) _helperDone.complete();
  }

  /// The consumer hears the loss first; teardown follows, and only then
  /// does the stream close (the adapter's done path is a stale epoch).
  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_failed) return;
    _failed = true;
    _events.addError(error, stackTrace);
    _releaseThenClose();
  }

  /// Root loss already surfaced as the terminal delete event: release,
  /// then close the stream without a redundant error.
  void _endStream() {
    if (_failed) return;
    _failed = true;
    _releaseThenClose();
  }

  void _releaseThenClose() {
    _releaseFuture ??= _release();
    unawaited(
      _releaseFuture!.then<void>(
        (_) => _events.close(),
        onError: (Object error, StackTrace stack) {
          _events.addError(error, stack);
          return _events.close();
        },
      ),
    );
  }

  void _closeInotify() {
    if (_inotifyFd == _invalidFd) return;
    _close(_inotifyFd);
    _inotifyFd = _invalidFd;
  }

  void _closeStopPipe(int fd) {
    if (fd == _invalidFd) return;
    _close(fd);
  }
}

FileSystemException _osError(String message, int code) => FileSystemException(
  '$message (${_errnoName(code)}).',
);
