import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

/// The local half of the one VFS (D3): a second *implementation* of
/// `seance_core`'s pinned `RemoteFileSystem` contract over `dart:io` —
/// never a wrapper, never a second interface. Panes, the transfer queue,
/// and the sync engine treat local and remote filesystems identically.
///
/// Error taxonomy, message shapes, and the download/upload integrity
/// protocols mirror the pinned dartssh2 adapter so callers cannot tell
/// which implementation they are talking to except by latency: every
/// failure surfaces as a typed `RemoteFileException` shaped
/// `Could not <op> "<path>": <detail>` (03 §2.2's funnel). Like the
/// adapter, precondition failures (a bad permissions range, a missing
/// name argument, an unsafe destination name) throw raw
/// `RangeError`/`ArgumentError`/`FormatException` synchronously instead.
///
/// Deletion here is the raw VFS primitive — one entry, no recursion, a
/// non-empty directory fails with Séance's wording. The trash/confirm
/// decision (D15) belongs to the caller, above this seam.
class LocalFileSystem implements RemoteFileSystem {
  /// Creates a local filesystem.
  ///
  /// [environment] backs `~` expansion in [canonicalize] (defaults to
  /// `Platform.environment`) and is the inherited base for the `chmod`/
  /// `chown` subprocesses (`PATH` survives; `LC_ALL: C` pins their stderr
  /// to deterministic English). Injecting both makes subprocess-exit
  /// mapping and home resolution testable (a test may prepend a fake
  /// `chmod` directory to `PATH`).
  LocalFileSystem({Map<String, String>? environment, bool? isMacOS})
    : _environment = environment ?? Platform.environment,
      _isMacOS = isMacOS ?? Platform.isMacOS;

  final Map<String, String> _environment;
  final bool _isMacOS;
  final Random _random = Random.secure();

  // Temp/backup siblings: `.poltergeist-` everywhere Séance uses
  // `.seance-` — the one deliberate rename 03 §2.2 ships for this
  // adapter (Séance-side sweeps matching `.seance-` never see these;
  // Poltergeist's own ignore rules exclude `.poltergeist*` per D15).
  // NAME_MAX 255 is the floor across the supported platform matrix;
  // overshooting it fails the operation rather than truncating into a
  // collision.
  static const String _transferPrefix = '.poltergeist-';
  static const String _tempSuffix = '.tmp';
  static const String _backupSuffix = '.backup';
  static const int _randomSuffixLength = 8;
  static const int _maxFileNameBytes = 255;
  static const int _maxTempAttempts = 5;
  static const int _maxUint32 = 0xFFFFFFFF;

  // POSIX errnos (OSError.errorCode on every non-Windows host).
  static const int _enoent = 2;
  static const int _eperm = 1;
  static const int _eacces = 13;
  static const int _eexist = 17;
  static const int _enotdir = 20;
  static const int _enotempty = 39;

  // Windows GetLastError values (OSError.errorCode carries these there,
  // never POSIX errnos).
  static const int _winFileNotFound = 2;
  static const int _winPathNotFound = 3;
  static const int _winAccessDenied = 5;
  static const int _winSharingViolation = 32;
  static const int _winPrivilegeNotHeld = 1314;
  static const int _winAlreadyExists = 183;
  static const int _winDirNotEmpty = 145;

  @override
  Future<String> canonicalize(String path) => _guard('resolve', path, () async {
    final expanded = expandHomePath(
      path,
      environment: _environment,
      isMacOS: _isMacOS,
    );
    final absolute = _normalizedAbsolute(expanded);
    try {
      return await Directory(expanded).resolveSymbolicLinks();
    } on FileSystemException catch (error) {
      // A missing path is not an error here (matches the realpath use
      // for home resolution): ENOENT/ENOTDIR fall back to the lexical
      // form. On Windows the codes are Win32: ERROR_FILE_NOT_FOUND (2,
      // numerically ENOENT) and ERROR_PATH_NOT_FOUND (3) — both must
      // take the same fallback.
      final code = error.osError?.errorCode;
      if (code == _enoent ||
          code == _enotdir ||
          code == _winFileNotFound ||
          code == _winPathNotFound) {
        return absolute;
      }
      rethrow;
    }
  });

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) => _guard(
    'list',
    path,
    () async {
      final entries = <RemoteFileEntry>[];
      await for (final entity in Directory(path).list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == '.' || name == '..') continue;
        // followLinks: false reports a symlink as a Link instance, so
        // link detection needs no extra syscall — and links are never
        // statted (a stat would follow and report the target's identity
        // as the link's own).
        if (entity is Link) {
          entries.add(
            RemoteFileEntry(
              path: entity.path,
              name: name,
              type: RemoteFileType.symbolicLink,
            ),
          );
          continue;
        }
        final stat = await FileStat.stat(entity.path);
        if (stat.type == FileSystemEntityType.notFound) continue;
        entries.add(_entryFromStat(entity.path, name, stat));
      }
      return entries;
    },
  );

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) =>
      _guard('inspect', path, () async {
        if (!followLinks) {
          final type = await FileSystemEntity.type(path, followLinks: false);
          if (type == FileSystemEntityType.notFound) {
            throw _notFound('inspect', path);
          }
          if (type == FileSystemEntityType.link) {
            return RemoteFileEntry(
              path: path,
              name: p.basename(path),
              type: RemoteFileType.symbolicLink,
            );
          }
        }
        // FileStat.stat follows links — the requested behavior for
        // followLinks: true, and the identity for an already-unlinked
        // non-link path.
        final stat = await FileStat.stat(path);
        if (stat.type == FileSystemEntityType.notFound) {
          throw _notFound('inspect', path);
        }
        return _entryFromStat(path, p.basename(path), stat);
      });

  @override
  Future<void> setMode(String path, int permissions) {
    RangeError.checkValueInInterval(permissions, 0, 0xFFF, 'permissions');
    if (Platform.isWindows) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'change permissions for',
        path: path,
        message:
            'Could not change permissions for "$path": '
            'not supported on Windows',
      );
    }
    return _guard('change permissions for', path, () async {
      final before = await _lstatNonLink(path, 'permissions');
      final result = await _runUtility(
        'chmod',
        [permissions.toRadixString(8), path],
      );
      _throwForUtilityExit(result, 'change permissions for', path);
      await _verifySameType(path, before, 'permissions');
    });
  }

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) {
    if (accessedAt == null && modifiedAt == null) {
      throw ArgumentError(
        'at least one of accessedAt or modifiedAt must be given',
      );
    }
    return _guard('change timestamps for', path, () async {
      final before = await _lstatNonLink(path, 'timestamps');
      // dart:io cannot set a directory's timestamps at all (its
      // implementation opens the path for writing, which POSIX refuses
      // with EISDIR and Windows with ERROR_ACCESS_DENIED); the sync
      // engine never needs it (05 §4 compares directories by existence
      // only).
      if (before == FileSystemEntityType.directory) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.unsupported,
          operation: 'change timestamps for',
          path: path,
          message:
              'Could not change timestamps for "$path": '
              'directory timestamps are not supported',
        );
      }
      if (modifiedAt != null) {
        await File(path).setLastModified(modifiedAt);
      }
      if (accessedAt != null) {
        await File(path).setLastAccessed(accessedAt);
      }
      await _verifySameType(path, before, 'timestamps');
    });
  }

  @override
  Future<void> setOwner(String path, {int? uid, int? gid}) {
    if (uid == null && gid == null) {
      throw ArgumentError('at least one of uid or gid must be given');
    }
    if (uid != null) {
      RangeError.checkValueInInterval(uid, 0, _maxUint32, 'uid');
    }
    if (gid != null) {
      RangeError.checkValueInInterval(gid, 0, _maxUint32, 'gid');
    }
    if (Platform.isWindows) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'change owner for',
        path: path,
        message: 'Could not change owner for "$path": not supported on Windows',
      );
    }
    return _guard('change owner for', path, () async {
      // A bare chown dereferences a symlink and changes the target's
      // owner — an attribute write must never escape its tree that way.
      final before = await _lstatNonLink(path, 'ownership');
      final spec = uid == null
          ? ':$gid'
          : gid == null
          ? '$uid'
          : '$uid:$gid';
      final result = await _runUtility('chown', [spec, path]);
      _throwForUtilityExit(result, 'change owner for', path);
      await _verifySameType(path, before, 'ownership');
    });
  }

  @override
  Future<String> readSymbolicLink(String path) =>
      _guard('read symbolic link', path, () => Link(path).target());

  @override
  Future<void> createSymbolicLink(String linkPath, String targetPath) =>
      _guard('create symbolic link', linkPath, () async {
        if (await FileSystemEntity.type(linkPath, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw _conflictExists('create symbolic link', linkPath);
        }
        try {
          await Link(linkPath).create(targetPath);
        } on FileSystemException catch (error) {
          // Windows needs Developer Mode or elevation for symlink
          // creation; the raw OS error would read as a bare access
          // denial without the hint.
          final code = error.osError?.errorCode;
          if (Platform.isWindows &&
              (code == _winAccessDenied || code == _winPrivilegeNotHeld)) {
            throw RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'create symbolic link',
              path: linkPath,
              message:
                  'Could not create symbolic link "$linkPath": creating '
                  'symbolic links on Windows requires Developer Mode or '
                  'administrator privileges',
              cause: error,
            );
          }
          // A create racing an external one throws the plain EEXIST
          // form (the typed PathNotFoundException sibling never
          // appears), closing the preflight gap through the funnel.
          if (code == _eexist || code == _winAlreadyExists) {
            throw _conflictExists('create symbolic link', linkPath);
          }
          rethrow;
        }
      });

  @override
  Future<void> createDirectory(String path) => _guard(
    'create directory',
    path,
    () async {
      // dart:io's create() is a silent no-op on an existing directory;
      // the contract (and the funnel's EEXIST→conflict rule) calls that
      // a conflict instead.
      // dart:io's create() is a silent no-op when a *directory* takes
      // the path mid-race (undetectable without O_EXCL semantics); a
      // racing *file* throws the plain EEXIST form, which becomes the
      // typed conflict here instead of the funnel's generic shape.
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw _conflictExists('create directory', path);
      }
      try {
        await Directory(path).create(recursive: false);
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (code == _eexist || code == _winAlreadyExists) {
          throw _conflictExists('create directory', path);
        }
        rethrow;
      }
    },
  );

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) => _guard('rename', oldPath, () async {
    // dart:io's renames are type-checked per class (File.rename refuses
    // a directory with EISDIR, Directory.rename a file with ENOTDIR),
    // so dispatch on the source's own type; the nofollow stat never
    // follows a link.
    final sourceType = await FileSystemEntity.type(oldPath, followLinks: false);
    if (sourceType == FileSystemEntityType.notFound) {
      throw _notFound('rename', oldPath);
    }
    if (_isCaseOnlyVariant(oldPath, newPath) &&
        !await _isDistinctEntry(oldPath, newPath)) {
      // Same entry, different case (or a not-yet-existing name that
      // differs only by case): a direct rename would collide with
      // itself on a case-insensitive volume, so go through a unique
      // sibling (D26's two-step).
      await _renameCaseOnly(sourceType, oldPath, newPath);
      return;
    }
    final destinationType = await FileSystemEntity.type(
      newPath,
      followLinks: false,
    );
    if (destinationType != FileSystemEntityType.notFound && !overwrite) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'rename',
        path: newPath,
        message:
            'A local item named "${p.basename(newPath)}" already exists.',
      );
    }
    await _renameInPlace(sourceType, oldPath, newPath, overwrite: overwrite);
  });

  /// Whether [newPath] names [oldPath] with a different case — or would,
  /// once the rename lands, on a case-insensitive volume. On a
  /// case-sensitive host a same-lowercase pair can still be two distinct
  /// entries; the caller resolves that with [_isDistinctEntry].
  bool _isCaseOnlyVariant(String oldPath, String newPath) =>
      oldPath != newPath &&
      oldPath.toLowerCase() == newPath.toLowerCase();

  /// Whether two same-lowercase paths are different entries (only
  /// possible on a case-sensitive volume). Missing paths canonicalize
  /// lexically, so a missing destination never counts as distinct.
  Future<bool> _isDistinctEntry(String oldPath, String newPath) async {
    final oldReal = await _tryResolve(oldPath);
    final newReal = await _tryResolve(newPath);
    return oldReal != null && newReal != null && oldReal != newReal;
  }

  Future<String?> _tryResolve(String path) async {
    try {
      return await Directory(path).resolveSymbolicLinks();
    } on Object {
      return null;
    }
  }

  /// Renames via a unique sibling so a case-only rename works on
  /// case-insensitive filesystems (D26), where old and new name collide.
  Future<void> _renameCaseOnly(
    FileSystemEntityType sourceType,
    String oldPath,
    String newPath,
  ) async {
    final sibling = await _uniqueSiblingPath(oldPath);
    await _renameInPlace(sourceType, oldPath, sibling, overwrite: false);
    try {
      // Same preflight as the main path: an entry that took the target
      // name between the two steps must conflict, not be silently
      // replaced — POSIX rename(2) would clobber it.
      if (await FileSystemEntity.type(newPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'rename',
          path: newPath,
          message:
              'A local item named "${p.basename(newPath)}" already exists.',
        );
      }
      await _renameInPlace(sourceType, sibling, newPath, overwrite: false);
    } on Object {
      // Restore the original name rather than stranding the entry under
      // a hidden temp name; if even that fails, the temp keeps the data.
      try {
        await _renameInPlace(sourceType, sibling, oldPath, overwrite: false);
      } on Object {
        // Best effort only — the rethrow below carries the real failure.
      }
      rethrow;
    }
  }

  Future<void> _renameInPlace(
    FileSystemEntityType sourceType,
    String oldPath,
    String newPath, {
    required bool overwrite,
  }) async {
    final entity = switch (sourceType) {
      FileSystemEntityType.directory => Directory(oldPath),
      FileSystemEntityType.link => Link(oldPath),
      _ => File(oldPath),
    };
    try {
      await entity.rename(newPath);
    } on FileSystemException {
      // POSIX rename replaces an existing target atomically; Windows
      // cannot, so an overwrite of a regular file falls back to the
      // backup-rename dance — never delete-then-rename, which strands
      // the user with neither file when the second step fails.
      // Directories and links rethrow: the dance is a regular-file
      // protocol and would coerce them through File.
      if (!overwrite ||
          !Platform.isWindows ||
          sourceType != FileSystemEntityType.file) {
        rethrow;
      }
      await _replaceLocalFile(File(oldPath), File(newPath), 'rename');
    }
  }

  @override
  Future<void> delete(RemoteFileEntry entry) => _guard(
    'delete',
    entry.path,
    () async {
      try {
        switch (entry.type) {
          // Directory.delete(recursive: false) refuses a non-empty
          // directory; recursion stays app-level by contract.
          case RemoteFileType.directory:
            await Directory(entry.path).delete(recursive: false);
          case RemoteFileType.symbolicLink:
            await Link(entry.path).delete();
          default:
            await File(entry.path).delete();
        }
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        final nonEmpty = code == _enotempty ||
            code == _eexist ||
            code == _winDirNotEmpty ||
            code == _winAlreadyExists;
        if (nonEmpty) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.other,
            operation: 'delete',
            path: entry.path,
            message:
                'Could not delete "${entry.path}": '
                'Only an empty directory can be deleted.',
            cause: error,
          );
        }
        rethrow;
      }
    },
  );

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) => _guard(
    'download',
    path,
    () async {
      cancellation?.throwIfCancelled();
      final pathType = await FileSystemEntity.type(path, followLinks: false);
      if (pathType == FileSystemEntityType.notFound) {
        throw _notFound('download', path);
      }
      if (pathType != FileSystemEntityType.file) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.unsupported,
          operation: 'download',
          path: path,
          message: 'Only regular local files can be downloaded.',
        );
      }
      final initial = await FileStat.stat(path);
      // FileStat.size is non-nullable — a size is always reported.
      final length = initial.size;
      var transferred = 0;
      final digestSink = computeHash ? _DigestSink() : null;
      final hashInput = digestSink == null
          ? null
          : sha256.startChunkedConversion(digestSink);
      await destination.addStream(
        _cancelWhenRequested(File(path).openRead(), cancellation).map((chunk) {
          hashInput?.add(chunk);
          transferred += chunk.length;
          onProgress?.call(transferred, length);
          return chunk;
        }),
      );
      hashInput?.close();
      cancellation?.throwIfCancelled();
      if (transferred != length) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'download',
          path: path,
          message:
              'The local file changed while it was downloading '
              '($transferred of $length bytes received).',
        );
      }
      final finalStat = await FileStat.stat(path);
      if (!_sameSnapshot(initial, finalStat)) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'download',
          path: path,
          message: 'The local file changed while it was downloading.',
        );
      }
      return _copyEntryWithDigest(
        _entryFromStat(path, p.basename(path), finalStat),
        digestSink?.value.toString(),
      );
    },
    cancellation: cancellation,
  );

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) {
    // The leaf of an upload destination is remote-derived input (a name
    // from the other pane's listing); validate it before it touches the
    // disk — the lexical half of the traversal defense, thrown raw like
    // every other precondition failure.
    _validateLocalName(p.basename(path));
    return _guard(
      'upload',
      path,
      () async {
        final existing = await _statOrNull(path);
        if (existing != null && !overwrite) {
          throw _conflictExists('upload', path);
        }
        if (expectedTarget != null &&
            (existing == null ||
                !await _matchesExpectedTarget(existing, expectedTarget, path))) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.conflict,
            operation: 'upload',
            path: path,
            message:
                '"${p.basename(path)}" changed on disk before the upload started.',
          );
        }

        cancellation?.throwIfCancelled();
        final tempPath = await _createExclusiveTemp(path);
        final temp = File(tempPath);
        try {
          final sink = temp.openWrite(mode: FileMode.append);
          var transferred = 0;
          final digestSink = computeHash ? _DigestSink() : null;
          final hashInput = digestSink == null
              ? null
              : sha256.startChunkedConversion(digestSink);
          try {
            await for (final chunk
                in _cancelWhenRequested(content, cancellation)) {
              cancellation?.throwIfCancelled();
              if (chunk.isEmpty) continue;
              hashInput?.add(chunk);
              sink.add(chunk);
              transferred += chunk.length;
              onProgress?.call(transferred, length);
            }
            hashInput?.close();
            cancellation?.throwIfCancelled();
            await sink.flush();
          } finally {
            await sink.close();
          }
          if (length != null && transferred != length) {
            throw RemoteFileException(
              kind: RemoteFileErrorKind.other,
              operation: 'upload',
              path: path,
              message: 'Upload ended after $transferred of $length bytes.',
            );
          }

          final mode = preserveMode ?? existing?.mode;
          if (mode != null && !Platform.isWindows) {
            final result = await _runUtility('chmod', [
              (mode & 0xFFF).toRadixString(8),
              tempPath,
            ]);
            _throwForUtilityExit(result, 'upload', tempPath);
          }

          final latest = await _statOrNull(path);
          if (!overwrite && latest != null) {
            throw RemoteFileException(
              kind: RemoteFileErrorKind.conflict,
              operation: 'upload',
              path: path,
              message:
                  'A local item named "${p.basename(path)}" was created '
                  'while the upload was running.',
            );
          }
          if (expectedTarget != null &&
              (latest == null ||
                  !await _matchesExpectedTarget(latest, expectedTarget, path))) {
            throw RemoteFileException(
              kind: RemoteFileErrorKind.conflict,
              operation: 'upload',
              path: path,
              message:
                  '"${p.basename(path)}" changed on disk while the upload '
                  'was running.',
            );
          }
          await _replaceLocalFile(temp, File(path), 'upload');

          final uploaded = await stat(path, followLinks: false);
          return digestSink == null
              ? uploaded
              : _copyEntryWithDigest(uploaded, digestSink.value.toString());
        } catch (_) {
          // The temp never survives a failed upload — commit or cleanup.
          try {
            if (await temp.exists()) await temp.delete();
          } on Object {
            // Cleanup must not mask the original failure.
          }
          rethrow;
        }
      },
      cancellation: cancellation,
    );
  }

  /// The refuse-symlinks-first check shared by every attribute write:
  /// chmod/chown/setLastModified all dereference, so a write aimed at a
  /// synced tree must never land on a link's target instead.
  Future<FileSystemEntityType> _lstatNonLink(
    String path,
    String subject,
  ) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw _notFound('change $subject for', path);
    }
    if (type == FileSystemEntityType.link) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'change $subject for',
        path: path,
        message: 'Symbolic link $subject cannot be changed safely.',
      );
    }
    return type;
  }

  /// Post-write half of the refuse-first check: a path swapped to a
  /// symlink between the check and the write had its change applied
  /// through the link — fail loudly (never `conflict`: this is a safety
  /// violation, not "both sides changed", and conflict resolution must
  /// never auto-accept it), carrying where the write actually landed.
  Future<void> _verifySameType(
    String path,
    FileSystemEntityType before,
    String subject,
  ) async {
    final after = await FileSystemEntity.type(path, followLinks: false);
    if (after == before) return;
    var landed = path;
    try {
      landed = await Directory(path).resolveSymbolicLinks();
    } on Object {
      // The type changed again mid-check; report the raw path.
    }
    throw LocalPathTypeChangedException(
      path: path,
      targetPath: landed,
      operation: 'change $subject for',
    );
  }

  /// Runs chmod/chown with `--` (a path starting with `-` must never
  /// parse as an option) and `LC_ALL=C` over the inherited environment
  /// (so stderr stays deterministic English — chmod localizes via
  /// strerror — and `PATH` survives).
  Future<ProcessResult> _runUtility(String name, List<String> arguments) {
    return Process.run(name, [
      '--',
      ...arguments,
    ], environment: {..._environment, 'LC_ALL': 'C'});
  }

  /// Maps a non-zero chmod/chown exit to the typed taxonomy from the
  /// trailing strerror segment after the final `': '` in the last stderr
  /// line — never a substring match across the whole line, since the
  /// user-controlled path is embedded in that same line and a file
  /// legally named e.g. `Operation not permitted` would otherwise
  /// misclassify by matching its own name.
  void _throwForUtilityExit(
    ProcessResult result,
    String operation,
    String path,
  ) {
    if (result.exitCode == 0) return;
    final stderrText = result.stderr is String ? result.stderr as String : '';
    // trimRight strips a CRLF line ending (Windows-hosted coreutils)
    // before the trailing-segment match below.
    final lines = stderrText
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.isNotEmpty)
        .toList();
    final lastLine = lines.isEmpty ? '' : lines.last;
    final separator = lastLine.lastIndexOf(': ');
    final detail = separator < 0
        ? (lastLine.isEmpty ? 'exit code ${result.exitCode}' : lastLine)
        : lastLine.substring(separator + 2);
    final kind = switch (detail) {
      'Operation not permitted' || 'Permission denied' =>
        RemoteFileErrorKind.permissionDenied,
      'No such file or directory' => RemoteFileErrorKind.notFound,
      _ => RemoteFileErrorKind.other,
    };
    throw RemoteFileException(
      kind: kind,
      operation: operation,
      path: path,
      message: _message(operation, path, detail),
    );
  }

  Future<String> _createExclusiveTemp(String path) async {
    // dart:io's opened-for-writing File.open/FileMode.write creates or
    // truncates unconditionally; File.create(exclusive: true) is the
    // only primitive that refuses an existing path. On the rare
    // collision, regenerate the random suffix and retry.
    for (var attempt = 0; attempt < _maxTempAttempts; attempt++) {
      final tempPath = _siblingPath(path, _tempSuffix);
      try {
        await File(tempPath).create(exclusive: true);
        return tempPath;
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (code != _eexist && code != _winAlreadyExists) rethrow;
      }
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'upload',
      path: path,
      message: 'Could not allocate a temporary file next to "$path".',
    );
  }

  /// `<dir>/.poltergeist-<8 hex><suffix>` — the pinned adapter's
  /// `.seance-upload-<8 hex>.tmp` shape with Poltergeist's prefix.
  String _siblingPath(String path, String suffix) {
    final name = _transferPrefix + _randomHexString() + suffix;
    return p.join(p.dirname(path), name);
  }

  /// A collision-proof sibling for the case-only rename two-step.
  /// Check-then-use by design: a creator racing into the name surfaces
  /// as the rename's own typed failure (the window is the same advisory
  /// preflight gap 03 §2.2 documents for rename).
  Future<String> _uniqueSiblingPath(String path) async {
    for (var attempt = 0; attempt < _maxTempAttempts; attempt++) {
      final sibling = _siblingPath(path, _tempSuffix);
      if (await FileSystemEntity.type(sibling, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return sibling;
      }
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'rename',
      path: path,
      message: 'Could not allocate a temporary name next to "$path".',
    );
  }

  String _randomHexString() => List.generate(
    _randomSuffixLength,
    (_) => _random.nextInt(16).toRadixString(16),
  ).join();

  /// The backup-rename dance: refuse links/non-regular targets (the
  /// check itself must not follow links — a symlink to a regular file
  /// would pass a stat-based test and silently swap the user's link for
  /// a plain file), park the target under a suffixed backup whose name
  /// still embeds the target's own, move the part in, restore on
  /// failure, and delete the backup only after success. Never
  /// delete-then-rename. (03 §2.3's spec; the public port with Séance's
  /// tests rides its own PR — this in-class implementation is what the
  /// port will replace.)
  Future<void> _replaceLocalFile(
    File part,
    File target,
    String operation,
  ) async {
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.link ||
        (targetType != FileSystemEntityType.file &&
            targetType != FileSystemEntityType.notFound)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: operation,
        path: target.path,
        message:
            'Could not replace "${target.path}": refusing to replace a '
            'non-regular local file',
      );
    }
    if (targetType == FileSystemEntityType.notFound) {
      await part.rename(target.path);
      return;
    }
    final backupPath = p.join(
      p.dirname(target.path),
      p.basename(target.path) + _transferPrefix + _randomHexString() + _backupSuffix,
    );
    if (_utf8ByteLength(p.basename(backupPath)) > _maxFileNameBytes) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: operation,
        path: target.path,
        message:
            'Could not replace "${target.path}": the backup name would '
            'exceed the filesystem file-name limit',
      );
    }
    final backup = File(backupPath);
    await target.rename(backup.path);
    try {
      await part.rename(target.path);
    } on Object {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    try {
      await backup.delete();
    } on FileSystemException {
      // Replacement succeeded; a stale backup is safer than deleting
      // the new destination or claiming the transfer failed after
      // commit.
    }
  }

  Future<RemoteFileEntry?> _statOrNull(String path) async {
    try {
      return await stat(path, followLinks: false);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
  }

  /// The pinned adapter's expected-target check: a snapshot mismatch is
  /// an instant conflict; a matching snapshot with a declared digest
  /// re-reads the content so a same-size-same-mtime swap still fails.
  Future<bool> _matchesExpectedTarget(
    RemoteFileEntry current,
    RemoteFileEntry expected,
    String path,
  ) async {
    if (current.type != expected.type ||
        current.size != expected.size ||
        current.modifiedAt != expected.modifiedAt ||
        current.mode != expected.mode) {
      return false;
    }
    final expectedDigest = expected.contentSha256;
    if (expectedDigest == null) return true;
    return await _localContentSha256(path) == expectedDigest;
  }

  Future<String> _localContentSha256(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  RemoteFileEntry _entryFromStat(String path, String name, FileStat stat) =>
      RemoteFileEntry(
        path: path,
        name: name,
        type: switch (stat.type) {
          FileSystemEntityType.file => RemoteFileType.file,
          FileSystemEntityType.directory => RemoteFileType.directory,
          FileSystemEntityType.link => RemoteFileType.symbolicLink,
          _ => RemoteFileType.other,
        },
        // dart:io's FileStat carries no uid/gid; callers treat them as
        // optional (03 §2.2). mode is synthetic on Windows — populated
        // best-effort, never authoritative there.
        size: stat.size,
        accessedAt: stat.accessed.toUtc(),
        modifiedAt: stat.modified.toUtc(),
        mode: stat.mode,
      );

  static RemoteFileEntry _copyEntryWithDigest(
    RemoteFileEntry entry,
    String? digest,
  ) => RemoteFileEntry(
    path: entry.path,
    name: entry.name,
    type: entry.type,
    size: entry.size,
    uid: entry.uid,
    gid: entry.gid,
    accessedAt: entry.accessedAt,
    modifiedAt: entry.modifiedAt,
    mode: entry.mode,
    contentSha256: digest,
  );

  /// Snapshot identity for the transfer integrity checks: type, size,
  /// mtime, mode — the same tuple the pinned adapter compares.
  static bool _sameSnapshot(FileStat a, FileStat b) =>
      a.type == b.type &&
      a.size == b.size &&
      a.modified == b.modified &&
      a.mode == b.mode;

  String _normalizedAbsolute(String path) {
    final context = p.context;
    final absolute = context.isAbsolute(path)
        ? path
        : context.join(Directory.current.path, path);
    return context.normalize(absolute);
  }

  static RemoteFileException _notFound(String operation, String path) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: operation,
        path: path,
        message: _message(operation, path, 'No such file or directory'),
      );

  static RemoteFileException _conflictExists(String operation, String path) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: operation,
        path: path,
        message: 'A local item named "${p.basename(path)}" already exists.',
      );

  static String _message(String operation, String? path, String detail) {
    final target = path == null ? '' : ' "$path"';
    return 'Could not $operation$target: $detail';
  }

  /// The funnel: every failure surfaces typed, with the pinned
  /// adapter's message shape. [cancellation] classifies a rethrown
  /// internal cancellation token (its exception type is private to the
  /// pinned library) as `cancelled` — the completion contract 09 §3.3
  /// pins.
  Future<T> _guard<T>(
    String operation,
    String? path,
    Future<T> Function() action, {
    RemoteTransferCancellation? cancellation,
  }) async {
    try {
      return await action();
    } on RemoteFileException {
      rethrow;
    } on FileSystemException catch (error) {
      throw RemoteFileException(
        kind: _errorKind(error),
        operation: operation,
        path: path,
        message: _message(operation, path, _detailFor(error)),
        cause: error,
      );
    } on ProcessException catch (error) {
      // The utility binary itself could not be launched.
      throw RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: operation,
        path: path,
        message: _message(operation, path, error.message),
        cause: error,
      );
    } catch (error) {
      if (cancellation?.isCancelled ?? false) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: operation,
          path: path,
          message: 'Transfer cancelled.',
          cause: error,
        );
      }
      throw RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: operation,
        path: path,
        message: _message(operation, path, error.toString()),
        cause: error,
      );
    }
  }

  static RemoteFileErrorKind _errorKind(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (error is PathNotFoundException || code == _enoent) {
      return RemoteFileErrorKind.notFound;
    }
    if (Platform.isWindows) {
      return switch (code) {
        _winFileNotFound || _winPathNotFound => RemoteFileErrorKind.notFound,
        _winAlreadyExists => RemoteFileErrorKind.conflict,
        _winAccessDenied => RemoteFileErrorKind.permissionDenied,
        _ => RemoteFileErrorKind.other,
      };
    }
    return switch (code) {
      _eexist => RemoteFileErrorKind.conflict,
      _eacces || _eperm => RemoteFileErrorKind.permissionDenied,
      _ => RemoteFileErrorKind.other,
    };
  }

  static String _detailFor(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (Platform.isWindows && code == _winSharingViolation) {
      // A lock, not a permission denial.
      return 'file is in use by another process';
    }
    return error.osError?.message ?? error.message;
  }
}

/// An attribute write (setMode/setOwner/setTimes) whose path was swapped
/// to a different type — almost always a symlink — between the
/// refuse-links-first check and the write itself. The change already
/// landed through the swapped-in link on [targetPath], potentially
/// outside the caller's tree entirely: a safety violation, deliberately
/// not `conflict`, so automated conflict resolution can never
/// auto-accept it (03 §2.2).
///
/// At the current pin `RemoteFileErrorKind` carries no `pathTypeChanged`
/// member, so distinctness rides the subtype; `on RemoteFileException`
/// handlers still catch it.
class LocalPathTypeChangedException extends RemoteFileException {
  /// The dereferenced path the write actually landed on.
  final String targetPath;

  LocalPathTypeChangedException({
    required this.targetPath,
    required super.path,
    required super.operation,
  }) : super(
         kind: RemoteFileErrorKind.other,
         message:
             'Could not $operation "$path": the item changed type while '
             'being changed, and the write landed on "$targetPath"',
       );
}

/// The lexical half of the local path safety rules (03 §2.3's spec; the
/// public port with Séance's tests rides its own PR). No empty
/// component, no `.`/`..`, no separators — `\` is rejected everywhere
/// on purpose: it is legal POSIX filename data, but a component carrying
/// one is overwhelmingly an escaping bug, and it is the path separator
/// on a Windows destination.
void _validatePathComponent(String component) {
  if (component.isEmpty ||
      component == '.' ||
      component == '..' ||
      component.contains('/') ||
      component.contains(r'\') ||
      component.contains('\x00')) {
    throw FormatException('"$component" is not a safe path component.');
  }
}

/// [_validatePathComponent] plus the Windows destination hazards:
/// forbidden characters, a trailing dot or space (Win32 silently strips
/// them into a name the next listing won't match), and reserved device
/// names matched by base name — the segment before the first dot — so
/// `NUL.txt` and `Com1.tar.gz` are as invalid as the bare names. The
/// checks are destination-aware and apply on every platform: a clean
/// boundary error beats a confusing mid-transfer failure on the host
/// whose filesystem cares (09 §3.5).
void _validateLocalName(String name) {
  _validatePathComponent(name);
  final RegExp windowsForbidden = RegExp(r'[:*?"<>|\x00-\x1f\x7f]');
  if (windowsForbidden.hasMatch(name) ||
      name.endsWith('.') ||
      name.endsWith(' ')) {
    throw FormatException('"$name" is not a safe local file name.');
  }
  final base = name.split('.').first;
  final RegExp reserved = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9]|conin\$|conout\$)$',
    caseSensitive: false,
  );
  if (reserved.hasMatch(base)) {
    throw FormatException('"$name" is not a safe local file name.');
  }
}

/// UTF-8 byte count without transcoding: 1 per ASCII unit, 2/3 per BMP
/// unit, 4 across a surrogate pair. A lone surrogate counts 3 — what
/// Dart's UTF-8 encoder emits (U+FFFD) for it — so the NAME_MAX guard
/// never under-counts.
int _utf8ByteLength(String value) {
  var total = 0;
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit < 0x80) {
      total += 1;
    } else if (unit < 0x800) {
      total += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < units.length &&
        units[i + 1] >= 0xDC00 &&
        units[i + 1] <= 0xDFFF) {
      total += 4;
      i++;
    } else {
      total += 3;
    }
  }
  return total;
}

/// Racer with the same semantics as the pinned adapter's: check before
/// every pull, race the pull against cancellation, and never let
/// cancellation cleanup escape after completion.
Stream<T> _cancelWhenRequested<T>(
  Stream<T> source,
  RemoteTransferCancellation? cancellation,
) async* {
  final iterator = StreamIterator<T>(source);
  try {
    while (true) {
      cancellation?.throwIfCancelled();
      final hasNext = cancellation == null
          ? await iterator.moveNext()
          : await Future.any([
              iterator.moveNext(),
              cancellation.whenCancelled.then<bool>((_) {
                cancellation.throwIfCancelled();
                return false;
              }),
            ]);
      if (!hasNext) return;
      yield iterator.current;
    }
  } finally {
    unawaited(iterator.cancel().catchError((_) {}));
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('Digest is not complete'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
