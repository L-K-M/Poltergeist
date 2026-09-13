library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/src/engine/linux_inotify_watch_backend.dart';
import 'package:test/test.dart';

/// The decoder and mapper behind the Linux inotify backend are pure, so
/// their error and mapping contracts are pinned on every platform; only
/// the descriptor plumbing below them is Linux-only.
void main() {
  group('decodeInotifyEvents', () {
    test('decodes a packed batch with names', () {
      final bytes = BytesBuilder();
      _appendEvent(
        bytes,
        wd: 7,
        mask: inotifyCreate | inotifyIsDir,
        name: 'new-dir',
      );
      _appendEvent(bytes, wd: 7, mask: inotifyDelete, name: 'gone.txt');

      final records = decodeInotifyEvents(bytes.toBytes());

      expect(records, hasLength(2));
      expect(records[0].wd, 7);
      expect(records[0].mask, inotifyCreate | inotifyIsDir);
      expect(records[0].name, 'new-dir');
      expect(records[1].wd, 7);
      expect(records[1].name, 'gone.txt');
    });

    test('decodes an unnamed event (empty name)', () {
      final bytes = BytesBuilder();
      _appendEvent(bytes, wd: 3, mask: inotifyQOverflow, name: '');

      final records = decodeInotifyEvents(bytes.toBytes());

      expect(records.single.wd, 3);
      expect(records.single.mask, inotifyQOverflow);
      expect(records.single.name, isEmpty);
    });

    test('decodes the kernel overflow shape: descriptor -1', () {
      final bytes = BytesBuilder();
      _appendEvent(bytes, wd: -1, mask: inotifyQOverflow, name: '');

      final record = decodeInotifyEvents(bytes.toBytes()).single;

      expect(record.wd, -1);
      expect(record.mask, inotifyQOverflow);
    });

    test('replaces malformed UTF-8 names instead of failing', () {
      final bytes = BytesBuilder();
      _appendEvent(bytes, wd: 1, mask: inotifyCreate, rawName: [0xff, 0xfe]);

      final record = decodeInotifyEvents(bytes.toBytes()).single;

      expect(record.name, contains('\u{FFFD}'));
    });

    test('a truncated header is a deterministic error', () {
      final bytes = Uint8List.fromList(List.filled(inotifyEventHeaderBytes - 1, 0));

      expect(
        () => decodeInotifyEvents(bytes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('truncated inotify event header'),
          ),
        ),
      );
    });

    test('a name length overrunning the batch is a deterministic error', () {
      final bytes = BytesBuilder();
      _appendEvent(bytes, wd: 1, mask: inotifyCreate, name: 'x');
      final corrupted = bytes.toBytes();
      // Claim a name far longer than the batch holds.
      ByteData.sublistView(
        corrupted,
      ).setUint32(inotifyEventHeaderBytes - 4, 1 << 20, Endian.host);

      expect(
        () => decodeInotifyEvents(corrupted),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('truncated inotify event name'),
          ),
        ),
      );
    });
  });

  group('fileSystemEventFromInotify', () {
    const watched = '/fixture/watched';

    test('create names the child path and keeps the directory bit', () {
      final event = _map(inotifyCreate | inotifyIsDir, 'sub', watched);

      expect(event, isA<FileSystemCreateEvent>());
      expect(event!.path, p.join(watched, 'sub'));
      expect(event.isDirectory, isTrue);
    });

    test('delete names the child path', () {
      final event = _map(inotifyDelete, 'gone.txt', watched);

      expect(event, isA<FileSystemDeleteEvent>());
      expect(event!.path, p.join(watched, 'gone.txt'));
    });

    test('modify and attrib map to modify with a truthful content bit', () {
      final content = _map(inotifyModify, 'f', watched)!;
      final attributes = _map(inotifyAttrib, 'f', watched)!;

      expect(content, isA<FileSystemModifyEvent>());
      expect((content as FileSystemModifyEvent).contentChanged, isTrue);
      expect((attributes as FileSystemModifyEvent).contentChanged, isFalse);
    });

    test('move halves map to move events with an unknown destination', () {
      final from = _map(inotifyMovedFrom, 'a', watched)!;
      final to = _map(inotifyMovedTo, 'b', watched)!;

      expect(
        from,
        isA<FileSystemMoveEvent>()
            .having((event) => event.path, 'path', p.join(watched, 'a'))
            .having((event) => event.destination, 'destination', isNull),
      );
      expect(
        to,
        isA<FileSystemMoveEvent>()
            .having((event) => event.path, 'path', p.join(watched, 'b')),
      );
    });

    test('self and unmount events name the watched path as a delete', () {
      for (final mask in [inotifyDeleteSelf, inotifyMoveSelf, inotifyUnmount]) {
        final event = _map(mask, '', watched);

        expect(
          event,
          isA<FileSystemDeleteEvent>()
              .having((event) => event.path, 'path', watched),
          reason: 'mask 0x${mask.toRadixString(16)}',
        );
      }
    });

    test('ignored is dropped: the loss already surfaced', () {
      expect(_map(inotifyIgnored, '', watched), isNull);
    });

    test('overflow is not mapped to an event — it is an error upstream', () {
      expect(_map(inotifyQOverflow, '', watched), isNull);
    });
  });
}

FileSystemEvent? _map(int mask, String name, String watchedPath) =>
    fileSystemEventFromInotify(mask: mask, name: name, watchedPath: watchedPath);

void _appendEvent(
  BytesBuilder bytes, {
  required int wd,
  required int mask,
  String name = '',
  List<int>? rawName,
}) {
  final nameBytes = Uint8List.fromList([
    ...(rawName ?? name.codeUnits),
    0,
  ]);
  // The kernel pads the name to a multiple of four bytes.
  final paddedLength = (nameBytes.length + 3) & ~3;

  final header = ByteData(inotifyEventHeaderBytes)
    ..setInt32(0, wd, Endian.host)
    ..setUint32(4, mask, Endian.host)
    ..setUint32(8, 0, Endian.host)
    ..setUint32(12, paddedLength, Endian.host);
  bytes.add(header.buffer.asUint8List());

  bytes.add(nameBytes);
  bytes.add(Uint8List(paddedLength - nameBytes.length));
}
