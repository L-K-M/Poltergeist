// D26 fast-path spike (07 §3.10, 00 D26): measures the native copy
// mechanisms a local↔local copy could take against the production
// streamed copy — Linux FICLONE(2)/copy_file_range(2) here; the APFS
// clonefile(2) and Windows CopyFileEx legs are recorded from source
// research in the task's audit file since this spike runs on Linux.
//
// The production path under test is the one the transfer queue actually
// exercises (03 §4.5): LocalFileSystem.download streams openRead()
// chunks into a bounded sink feeding upload's openWrite() with a flush
// per chunk — the numbers below reproduce that shape exactly
// (`streamed`) plus the same shape without the per-chunk flush
// (`streamed-buf`) to price the flush's cost, `File.copy` (dart:io's
// own path), `ficlone`, and `copy_file_range`.
//
// Progress/cancel semantics matter as much as speed: a mechanism that
// cannot report bytes or abort mid-copy fails D26's adoption bar even
// when faster. FICLONE is whole-file atomic — no progress, no cancel —
// while chunked copy_file_range keeps both (the loop checks a
// cancellation token and reports per chunk), so only the chunked kernel
// copy is adoption-eligible.
//
// Usage (host-only, never CI):  dart run benchmark/local_copy_fastpath.dart
//     [--dir <path>]... [--sizes <mib>[,<mib>...]] [--reps <n>]
//
// --dir may repeat to cover several filesystems (e.g. an ext4 volume and
// /dev/shm tmpfs). Each mechanism's rows record the destination
// filesystem type so the audit can attribute EOPNOTSUPP vs real numbers.
//
// Exit codes: 0 measured (unsupported mechanisms print `unsupported`,
// never fail); 2 usage; 1 measurement failure.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// --- libc bindings -------------------------------------------------------

final class _LibC {
  _LibC(DynamicLibrary lib)
    : open = lib.lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, Int32),
        int Function(Pointer<Utf8>, int, int)
      >('open'),
      close = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
      ),
      ioctl = lib.lookupFunction<
        Int32 Function(Int32, UnsignedLong, Int32),
        int Function(int, int, int)
      >('ioctl'),
      copyFileRange = lib.lookupFunction<
        Int64 Function(Int32, Pointer<Void>, Int32, Pointer<Void>, Int64, Uint32),
        int Function(int, Pointer<Void>, int, Pointer<Void>, int, int)
      >('copy_file_range'),
      strerror = lib.lookupFunction<
        Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)
      >('strerror');

  final int Function(Pointer<Utf8>, int, int) open;
  final int Function(int) close;
  final int Function(int, int, int) ioctl;
  final int Function(int, Pointer<Void>, int, Pointer<Void>, int, int)
  copyFileRange;
  final Pointer<Utf8> Function(int) strerror;
}

// Linux ioctl request: _IOW(0x94, 9, int) — btrfs/xfs/bcachefs/tmpfs
// reflink clone. ext4 answers EOPNOTSUPP; the spike reports that rather
// than treating it as a failure.
const int _ficloneRequest = 0x40049409;
const int _oRdonly = 0;
const int _oWronly = 1;
const int _oCreat = 0x40;
const int _oExcl = 0x80;
const int _eopnotsupp = 95;

// copy_file_range is chunked at 128 MiB: between chunks the loop could
// consult a cancellation token and report progress, so the adoption
// candidate preserves the streamed copy's semantics (a single-syscall
// variant would not — measured separately for reference).
const int _cfrChunkBytes = 128 * 1024 * 1024;
const int _cfrSingleShotBytes = 1 << 62;

String _fsTypeOf(String path) {
  // stat -f -c %T — a drive-level fact; the process spawn is fine in a
  // spike collector (it is not the UI isolate).
  final result = Process.runSync('stat', ['-f', '-c', '%T', path]);
  return result.exitCode == 0
      ? '${result.stdout}'.trim()
      : 'unknown(${result.exitCode})';
}

String _errnoName(_LibC libc) =>
    libc.strerror(_errno()).toDartString();

int _errno() {
  // dart:ffi has no errno accessor; read it through libc's
  // __errno_location on Linux (glibc/musl both provide it). The process
  // handle resolves symbols from the already-loaded libc regardless of
  // its on-disk soname.
  final loc = DynamicLibrary.process().lookupFunction<
    Pointer<Int32> Function(),
    Pointer<Int32> Function()
  >('__errno_location');
  return loc().value;
}

typedef _Mechanism =
    Future<void> Function(File src, File dst, void Function(int) onBytes);

Future<void> _streamed(File src, File dst, void Function(int) onBytes) =>
    _streamCopy(src, dst, onBytes, flushPerChunk: true);

Future<void> _streamedBuffered(
  File src,
  File dst,
  void Function(int) onBytes,
) => _streamCopy(src, dst, onBytes, flushPerChunk: false);

/// The production streamed copy's shape (LocalFileSystem.download →
/// bounded sink → upload): chunked read, per-chunk progress accounting,
/// and — in [flushPerChunk] mode — the upload path's flush-per-write.
Future<void> _streamCopy(
  File src,
  File dst,
  void Function(int) onBytes, {
  required bool flushPerChunk,
}) async {
  final sink = dst.openWrite();
  try {
    await for (final chunk in src.openRead()) {
      sink.add(chunk);
      if (flushPerChunk) await sink.flush();
      onBytes(chunk.length);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
}

Future<void> _dartCopy(File src, File dst, void Function(int) onBytes) async {
  await src.copy(dst.path);
  onBytes(await src.length());
}

/// ioctl(FICLONE): whole-file reflink. Atomic — no progress, no cancel —
/// so a capability probe plus timing, never an adoption candidate.
Future<void> _ficlone(File src, File dst, void Function(int) onBytes) =>
    _kernelCopy(src, dst, onBytes, chunkBytes: _cfrSingleShotBytes, ficlone: true);

/// copy_file_range chunked at 128 MiB: between chunks the production
/// loop can report progress and check cancellation — the adoption
/// candidate that keeps D26's semantics.
Future<void> _cfrChunked(File src, File dst, void Function(int) onBytes) =>
    _kernelCopy(src, dst, onBytes, chunkBytes: _cfrChunkBytes, ficlone: false);

/// copy_file_range in one syscall: the reference point for what
/// chunking costs (and the shape a "copy without progress" would take).
Future<void> _cfrSingle(File src, File dst, void Function(int) onBytes) =>
    _kernelCopy(src, dst, onBytes, chunkBytes: _cfrSingleShotBytes, ficlone: false);

final _libc = _LibC(DynamicLibrary.process());

Future<void> _kernelCopy(
  File src,
  File dst,
  void Function(int) onBytes, {
  required int chunkBytes,
  required bool ficlone,
}) async {
  final srcPath = src.path.toNativeUtf8();
  final dstPath = dst.path.toNativeUtf8();
  final srcFd = _libc.open(srcPath.cast(), _oRdonly, 0);
  if (srcFd < 0) {
    calloc.free(srcPath);
    calloc.free(dstPath);
    throw StateError('open(${src.path}): ${_errnoName(_libc)}');
  }
  var dstFd = -1;
  try {
    dstFd = _libc.open(dstPath.cast(), _oWronly | _oCreat | _oExcl, 0x1A4);
    if (dstFd < 0) {
      throw StateError('open(${dst.path}): ${_errnoName(_libc)}');
    }
    final length = await src.length();
    if (ficlone) {
      if (_libc.ioctl(dstFd, _ficloneRequest, srcFd) != 0) {
        throw _KernelCopyUnsupported(_errno());
      }
      onBytes(length);
      return;
    }
    var remaining = length;
    while (remaining > 0) {
      final chunk = remaining < chunkBytes ? remaining : chunkBytes;
      final copied = _libc.copyFileRange(
        srcFd,
        nullptr,
        dstFd,
        nullptr,
        chunk,
        0,
      );
      if (copied < 0) {
        final errnoCode = _errno();
        // EXDEV (18): cross-device pair; ENOSYS (38): syscall absent on
        // this kernel — capability results like EOPNOTSUPP, not copy
        // errors. Anything else is a real failure.
        if (errnoCode == _eopnotsupp || errnoCode == 18 || errnoCode == 38) {
          throw _KernelCopyUnsupported(errnoCode);
        }
        throw StateError(
          'copy_file_range: errno $errnoCode (${_errnoName(_libc)})',
        );
      }
      if (copied == 0) {
        throw StateError('copy_file_range stalled at $remaining bytes left');
      }
      remaining -= copied;
      onBytes(copied);
    }
  } finally {
    if (dstFd >= 0) _libc.close(dstFd);
    _libc.close(srcFd);
    calloc.free(srcPath);
    calloc.free(dstPath);
  }
}

final class _KernelCopyUnsupported implements Exception {
  const _KernelCopyUnsupported(this.errnoCode);
  final int errnoCode;
  @override
  String toString() =>
      errnoCode == _eopnotsupp
          ? 'EOPNOTSUPP'
          : 'errno $errnoCode (${_errnoName(_libc)})';
}

/// Deterministic content: position-dependent bytes so a truncated or
/// offset clone fails the tail check, not just the length check.
Future<void> _fill(File file, int bytes) async {
  final sink = file.openWrite();
  const blockSize = 1 << 20;
  var offset = 0;
  var remaining = bytes;
  while (remaining > 0) {
    final n = remaining < blockSize ? remaining : blockSize;
    // Position-dependent bytes keyed on the absolute file offset, so a
    // truncated or offset clone fails the tail check, not just the
    // length check.
    final block = List<int>.generate(
      n,
      (i) => ((offset + i) * 31 + ((offset + i) >> 8)) & 0xFF,
    );
    sink.add(block);
    await sink.flush();
    remaining -= n;
    offset += n;
  }
  await sink.close();
}

Future<bool> _verify(File src, File dst) async {
  if (await src.length() != await dst.length()) return false;
  // Sample head and tail blocks — enough to catch a bad clone/copy
  // without re-reading both files.
  for (final offset in [0, (await src.length()) - 65536]) {
    final start = offset < 0 ? 0 : offset;
    final a = await src.openRead(start, start + 65536).fold<List<int>>(
      [],
      (acc, c) => acc..addAll(c),
    );
    final b = await dst.openRead(start, start + 65536).fold<List<int>>(
      [],
      (acc, c) => acc..addAll(c),
    );
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
  }
  return true;
}

String _median(List<double> values) {
  if (values.isEmpty) return '—';
  final sorted = [...values]..sort();
  final mid = sorted[sorted.length ~/ 2];
  return sorted.length.isOdd
      ? mid.toStringAsFixed(1)
      : ((sorted[sorted.length ~/ 2 - 1] + mid) / 2).toStringAsFixed(1);
}

Future<int> main(List<String> args) async {
  var dirs = <String>[Directory.systemTemp.path];
  var sizesMiB = <int>[1, 64, 256];
  var reps = 3;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dir':
        if (++i >= args.length) {
          stderr.writeln('--dir needs a value');
          exitCode = 2;
          return 2;
        }
        dirs = [args[i]];
        while (i + 1 < args.length && !args[i + 1].startsWith('--')) {
          dirs.add(args[++i]);
        }
      case '--sizes':
        if (++i >= args.length) {
          stderr.writeln('--sizes needs a value');
          exitCode = 2;
          return 2;
        }
        final sizes = [
          for (final s in args[i].split(',')) int.tryParse(s),
        ];
        if (sizes.any((s) => s == null)) {
          stderr.writeln('--sizes needs comma-separated integers');
          exitCode = 2;
          return 2;
        }
        sizesMiB = [for (final s in sizes) s!];
      case '--reps':
        if (++i >= args.length) {
          stderr.writeln('--reps needs a value');
          exitCode = 2;
          return 2;
        }
        final parsedReps = int.tryParse(args[i]);
        if (parsedReps == null) {
          stderr.writeln('--reps needs an integer');
          exitCode = 2;
          return 2;
        }
        reps = parsedReps;
      default:
        stderr.writeln('unknown argument ${args[i]}');
        exitCode = 2;
        return 2;
    }
  }

  if (!Platform.isLinux) {
    stdout.writeln('D26 fast-path spike: this collector measures the '
        'Linux mechanisms (FICLONE, copy_file_range); run it on a Linux '
        'host. APFS clonefile/CopyFileEx are source-research legs.');
    return 0;
  }

  final mechanisms = <String, _Mechanism>{
    'streamed': _streamed,
    'streamed-buf': _streamedBuffered,
    'dart-copy': _dartCopy,
    'ficlone': _ficlone,
    'cfr-chunked': _cfrChunked,
    'cfr-single': _cfrSingle,
  };

  for (final dirPath in dirs) {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      stderr.writeln('skip $dirPath: directory missing');
      continue;
    }
    final fsType = _fsTypeOf(dirPath);
    stdout.writeln('# $dirPath ($fsType)');
    for (final mib in sizesMiB) {
      final bytes = mib * 1024 * 1024;
      stdout.writeln('## $mib MiB');
      for (final entry in mechanisms.entries) {
        final name = entry.key;
        final mechanism = entry.value;
        final throughputs = <double>[];
        String? failure;
        for (var rep = 0; rep < reps; rep++) {
          final src = File(p.join(dirPath, 'd26-spike-src-$mib.bin'));
          final dst = File(
            p.join(dirPath, 'd26-spike-dst-$name-$rep.bin'),
          );
          try {
            if (!await src.exists() || await src.length() != bytes) {
              await _fill(src, bytes);
            }
            if (await dst.exists()) await dst.delete();
            final watch = Stopwatch()..start();
            var reported = 0;
            await mechanism(src, dst, (n) => reported += n);
            watch.stop();
            if (reported != bytes || !await _verify(src, dst)) {
              failure = 'corrupt copy ($reported/$bytes bytes reported)';
              break;
            }
            throughputs.add(bytes / watch.elapsedMicroseconds);
          } on _KernelCopyUnsupported catch (error) {
            failure = 'unsupported: $error';
            break;
          } on Object catch (error) {
            failure = 'error: $error';
            break;
          } finally {
            if (await dst.exists()) await dst.delete();
          }
        }
        if (failure != null) {
          stdout.writeln('$name: $failure');
        } else {
          stdout.writeln(
            '$name: median ${_median(throughputs)} MB/s '
            '(${throughputs.map((t) => t.toStringAsFixed(1)).join(', ')})',
          );
        }
        // Keep the source for the next mechanism; delete once per size.
      }
      final src = File(p.join(dirPath, 'd26-spike-src-$mib.bin'));
      if (await src.exists()) await src.delete();
    }
  }
  return 0;
}
