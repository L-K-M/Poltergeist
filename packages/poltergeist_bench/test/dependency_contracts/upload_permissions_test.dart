import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:seance_core/src/ssh/remote_file_system.dart';
import 'package:test/test.dart';

const _target = '/uploads/gh';
const _serverMode = 0x81A4; // Regular file, 0644.
const _executableMode = 0x81ED; // Regular file, 0755.
const _content = [1, 2, 3];

void main() {
  test('new uploads use server permissions without requiring chmod', () async {
    final client = _UploadClient(denyModeChanges: true);
    final uploaded = await DartSshRemoteFileSystem(
      client,
    ).upload(_target, Stream.value(_content), length: _content.length);

    expect(uploaded.mode, _serverMode);
    expect(client.files[_target]!.bytes, _content);
    expect(client.modeRequests, isEmpty);
    expect(client.files.keys, [_target]);
    expect(client.renames, 1);
  });

  test('source mode preservation can fail after all bytes were sent', () async {
    final client = _UploadClient(denyModeChanges: true);

    await expectLater(
      DartSshRemoteFileSystem(client).upload(
        _target,
        Stream.value(_content),
        length: _content.length,
        preserveMode: _executableMode,
      ),
      throwsA(_deniedUpload),
    );

    expect(client.writtenBytes, _content.length);
    expect(client.modeRequests, [_executableMode]);
    expect(client.files, isEmpty);
    expect(client.removedPaths, [client.openedPath]);
    expect(client.renames, 0);
  });

  test(
    'replacement inherits destination permissions without source mode',
    () async {
      final client = _UploadClient();
      client.files[_target] = _StoredFile([9], _executableMode);

      final uploaded = await DartSshRemoteFileSystem(client).upload(
        _target,
        Stream.value(_content),
        length: _content.length,
        overwrite: true,
      );

      expect(uploaded.mode, _executableMode);
      expect(client.files[_target]!.bytes, _content);
      expect(client.modeRequests, [_executableMode]);
      expect(client.files.keys, [_target]);
    },
  );

  test(
    'denied destination permission preservation leaves original intact',
    () async {
      final client = _UploadClient(denyModeChanges: true);
      client.files[_target] = _StoredFile([9], _executableMode);

      await expectLater(
        DartSshRemoteFileSystem(client).upload(
          _target,
          Stream.value(_content),
          length: _content.length,
          overwrite: true,
        ),
        throwsA(_deniedUpload),
      );

      expect(client.files[_target]!.bytes, [9]);
      expect(client.files[_target]!.mode, _executableMode);
      expect(client.modeRequests, [_executableMode]);
      expect(client.files.keys, [_target]);
      expect(client.removedPaths, [client.openedPath]);
      expect(client.renames, 0);
    },
  );

  test('server defaults do not conceal denied content writes', () async {
    final client = _UploadClient(denyWrites: true);

    await expectLater(
      DartSshRemoteFileSystem(
        client,
      ).upload(_target, Stream.value(_content), length: _content.length),
      throwsA(_deniedUpload),
    );

    expect(client.writtenBytes, 0);
    expect(client.modeRequests, isEmpty);
    expect(client.files, isEmpty);
    expect(client.removedPaths, [client.openedPath]);
    expect(client.renames, 0);
  });
}

final _deniedUpload = isA<RemoteFileException>()
    .having((error) => error.kind, 'kind', RemoteFileErrorKind.permissionDenied)
    .having((error) => error.operation, 'operation', 'upload')
    .having((error) => error.path, 'path', _target)
    .having(
      (error) => error.message,
      'message',
      'Could not upload "$_target": Permission denied',
    );

class _StoredFile {
  _StoredFile(List<int> bytes, this.mode) : bytes = List.of(bytes);

  final List<int> bytes;
  int mode;
}

// ACL-managed storage may allow writing a new file while refusing chmod.
// Model those rights independently at the SFTP boundary, so these contracts
// exercise the pinned shared adapter rather than a fake upload method.
class _UploadClient implements SftpClient {
  _UploadClient({this.denyModeChanges = false, this.denyWrites = false});

  final bool denyModeChanges;
  final bool denyWrites;
  final files = <String, _StoredFile>{};
  final modeRequests = <int>[];
  final removedPaths = <String>[];
  String? openedPath;
  int writtenBytes = 0;
  int renames = 0;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final file = files[path];
    if (file == null) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }
    return SftpFileAttrs(
      size: file.bytes.length,
      mode: SftpFileMode.value(file.mode),
    );
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    expect(
      mode.flag,
      (SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.exclusive)
          .flag,
    );
    expect(path, startsWith('/uploads/'));
    expect(path, isNot(_target));
    if (files.containsKey(path)) {
      throw SftpStatusError(SftpStatusCode.failure, 'File exists');
    }
    openedPath = path;
    files[path] = _StoredFile([], _serverMode);
    return _UploadHandle(this, path);
  }

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    final mode = attrs.mode!.value;
    modeRequests.add(mode);
    if (denyModeChanges) _deny();
    // Like OpenSSH, the server accepts permission bits independently of the
    // file-type field supplied by the pinned adapter.
    files[path]!.mode = (files[path]!.mode & ~0xFFF) | (mode & 0xFFF);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    files[newPath] = files.remove(oldPath)!;
    renames++;
  }

  @override
  Future<void> remove(String filename) async {
    files.remove(filename);
    removedPaths.add(filename);
  }

  Never _deny() => throw SftpStatusError(
    SftpStatusCode.permissionDenied,
    'Permission denied',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UploadHandle extends SftpFile {
  _UploadHandle(this.owner, this.path) : super(owner, Uint8List(0));

  final _UploadClient owner;
  final String path;

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    if (owner.denyWrites) owner._deny();
    final bytes = owner.files[path]!.bytes;
    expect(offset, bytes.length);
    bytes.addAll(data);
    owner.writtenBytes += data.length;
  }

  @override
  Future<void> close() async {}
}
