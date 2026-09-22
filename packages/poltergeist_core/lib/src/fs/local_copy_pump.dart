import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:seance_core/seance_core.dart';

/// D26's native fast-path seam (00 D26, 07 §3.10): the mechanism that
/// moves bytes for a local→local file copy. The default is the
/// production streamed loop ([streamedLocalCopyPump]); on Linux the
/// platform pump is `copy_file_range(2)` chunked at
/// [_copyFileRangeChunkBytes] — measured ~10× the streamed path on this
/// tree's host (overlayfs; FICLONE answers EOPNOTSUPP there and on
/// tmpfs, so the clone ioctl never reached adoption).
///
/// The pump contract keeps D26's semantics load-bearing: [onBytes]
/// reports after every chunk so progress stays live, and
/// [cancellation] is consulted between chunks so a cancel or pause
/// unwinds the copy mid-file. A pump that cannot apply — the mechanism
/// missing on this kernel or this filesystem pair — returns `false`
/// *before committing to its mechanism* and the caller falls back to
/// the streamed pump over a truncated destination. A pump that starts
/// copying and then hits a real error throws it like any other failure.
///
/// The destination is the caller's already-created exclusive temp file;
/// the pump opens it O_WRONLY (truncating any partial bytes a declined
/// first attempt left) and never commits it — commit is the caller's
/// temp→destination rename.
typedef LocalCopyPump =
    Future<bool> Function(
      String sourcePath,
      String destinationPath, {
      required int length,
      required RemoteTransferCancellation? cancellation,
      required void Function(int bytes) onBytes,
    });

/// The kernel-copy chunk size: large enough that the syscall overhead
/// is noise, small enough that a cancellation check or progress event
/// lands every few milliseconds on fast storage and stays sub-second on
/// rotational/network media. The streamed pump's 64 KiB chunks come
/// from dart:io's `openRead` blocks — unchanged there.
const int _copyFileRangeChunkBytes = 16 * 1024 * 1024;

/// Linux `copy_file_range(2)` decline set: every errno that means "this
/// mechanism cannot serve this file pair" rather than "the copy
/// failed". A decline is answered by the streamed fallback, never by a
/// red item.
const _copyFileRangeDeclineErrnos = {
  1, // EPERM
  9, // EBADF (kernel too old to know the fd pair's ops)
  18, // EXDEV — cross-filesystem copy
  22, // EINVAL — fs/files don't support the call
  38, // ENOSYS — kernel predates the syscall
  95, // EOPNOTSUPP — fs knows the call and refuses (e.g. FICLONE-only fs)
};

/// The streamed pump — identical chunk shape to the production pipe
/// (`openRead` → `openWrite` + flush per chunk), so the fallback copies
/// exactly the bytes the pre-fast-path queue moved. Always returns
/// true; a failure throws as [FileSystemException] and is mapped by the
/// caller's `_guard`.
Future<bool> streamedLocalCopyPump(
  String sourcePath,
  String destinationPath, {
  required int length,
  required RemoteTransferCancellation? cancellation,
  required void Function(int bytes) onBytes,
}) async {
  final sink = File(destinationPath).openWrite();
  try {
    var transferred = 0;
    await for (final chunk in File(sourcePath).openRead()) {
      cancellation?.throwIfCancelled();
      sink.add(chunk);
      // Await each chunk's drain: IOSink.add alone never applies
      // backpressure, and a fast source would buffer the whole file.
      await sink.flush();
      transferred += chunk.length;
      onBytes(chunk.length);
    }
    await sink.flush();
    if (transferred != length) {
      throw FileSystemException(
        'file changed while copying ($transferred of $length bytes read)',
        sourcePath,
      );
    }
  } finally {
    await sink.close();
  }
  return true;
}

/// The pump for this platform: `copy_file_range` on Linux, the streamed
/// pump everywhere else (APFS `clonefile` and Windows `CopyFileEx` stay
/// v1.x per the M9 spike's audit record — clonefile is atomic and
/// carries no progress/cancel, and CopyFileEx's callback semantics are
/// recorded there without a Windows host to measure).
LocalCopyPump platformLocalCopyPump() =>
    Platform.isLinux ? _copyFileRangePump : streamedLocalCopyPump;

// -- Linux copy_file_range bindings ---------------------------------------

final class _LinuxCopyBindings {
  _LinuxCopyBindings(DynamicLibrary libc)
    : open = libc.lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Int32),
        int Function(Pointer<Utf8>, int, int)
      >('open'),
      close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
      ),
      copyFileRange = libc.lookupFunction<
        Int64 Function(
          Int32,
          Pointer<Void>,
          Int32,
          Pointer<Void>,
          Int64,
          Uint32,
        ),
        int Function(int, Pointer<Void>, int, Pointer<Void>, int, int)
      >('copy_file_range'),
      errnoLocation = libc.lookupFunction<
        Pointer<Int32> Function(),
        Pointer<Int32> Function()
      >('__errno_location');

  final int Function(Pointer<Utf8>, int, int) open;
  final int Function(int) close;
  final int Function(int, Pointer<Void>, int, Pointer<Void>, int, int)
  copyFileRange;
  final Pointer<Int32> Function() errnoLocation;

  int get errno => errnoLocation().value;
}

_LinuxCopyBindings? _bindings;

_LinuxCopyBindings _linuxCopyBindings() =>
    _bindings ??= _LinuxCopyBindings(DynamicLibrary.open('libc.so.6'));

const int _oRdonly = 0;
const int _oWronly = 1;
const int _oCreat = 0x40;
const int _oTrunc = 0x200;

/// `copy_file_range(2)` with NULL offsets (the call advances both file
/// positions itself), chunked so cancellation and progress keep their
/// per-chunk cadence. Returns false on any decline errno — the caller
/// re-runs the streamed pump over a truncated temp; a mid-copy decline
/// is still safe because the temp is private and starts over.
Future<bool> _copyFileRangePump(
  String sourcePath,
  String destinationPath, {
  required int length,
  required RemoteTransferCancellation? cancellation,
  required void Function(int bytes) onBytes,
}) async {
  final libc = _linuxCopyBindings();
  final nativeSource = sourcePath.toNativeUtf8();
  final nativeDestination = destinationPath.toNativeUtf8();
  var sourceFd = -1;
  var destinationFd = -1;
  try {
    sourceFd = libc.open(nativeSource.cast(), _oRdonly, 0);
    if (sourceFd < 0) {
      throw FileSystemException(
        'open failed (errno ${libc.errno})',
        sourcePath,
      );
    }
    // O_TRUNC: a declined first attempt may have left partial bytes in
    // the temp; the pump always restarts the file from byte zero.
    destinationFd = libc.open(
      nativeDestination.cast(),
      _oWronly | _oCreat | _oTrunc,
      0x1A4, // 0644
    );
    if (destinationFd < 0) {
      throw FileSystemException(
        'open failed (errno ${libc.errno})',
        destinationPath,
      );
    }
    var remaining = length;
    while (remaining > 0) {
      cancellation?.throwIfCancelled();
      final chunk = remaining < _copyFileRangeChunkBytes
          ? remaining
          : _copyFileRangeChunkBytes;
      final copied = libc.copyFileRange(
        sourceFd,
        nullptr,
        destinationFd,
        nullptr,
        chunk,
        0,
      );
      if (copied < 0) {
        if (_copyFileRangeDeclineErrnos.contains(libc.errno)) {
          return false;
        }
        throw FileSystemException(
          'copy_file_range failed (errno ${libc.errno})',
          destinationPath,
        );
      }
      if (copied == 0) {
        throw FileSystemException(
          'copy_file_range stalled with $remaining of $length bytes left',
          destinationPath,
        );
      }
      remaining -= copied;
      onBytes(copied);
      // Yield once per chunk: the syscall runs synchronously on this
      // isolate, so between-chunk is also where queued microtasks (a
      // cancel landing mid-copy) get to run before the next chunk.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    if (destinationFd >= 0) libc.close(destinationFd);
    if (sourceFd >= 0) libc.close(sourceFd);
    calloc.free(nativeSource);
    calloc.free(nativeDestination);
  }
  return true;
}
