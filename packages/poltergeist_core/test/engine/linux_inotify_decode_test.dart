library;

import 'dart:convert';
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

    test('decodes move cookies verbatim', () {
      final bytes = BytesBuilder();
      _appendEvent(
        bytes,
        wd: 7,
        mask: inotifyMovedFrom,
        cookie: 412,
        name: 'a',
      );

      expect(decodeInotifyEvents(bytes.toBytes()).single.cookie, 412);
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

    test('move halves pair by cookie into dart:io\'s merged move', () {
      final matcher = InotifyMoveMatcher();
      final parked = matcher.match(
        mask: inotifyMovedFrom,
        cookie: 9,
        name: 'old',
        watchedPath: watched,
      );
      expect(parked, isNull, reason: 'the pair is incomplete');

      final completed = matcher.match(
        mask: inotifyMovedTo | inotifyIsDir,
        cookie: 9,
        name: 'new',
        watchedPath: watched,
      );

      expect(
        completed,
        isA<FileSystemMoveEvent>()
            .having((event) => event.path, 'path', p.join(watched, 'old'))
            .having(
              (event) => event.destination,
              'destination',
              p.join(watched, 'new'),
            ),
      );
      expect(matcher.flush(watched), isEmpty);
    });

    test('an unmatched moved-from flushes as a delete', () {
      final matcher = InotifyMoveMatcher();
      expect(
        matcher.match(
          mask: inotifyMovedFrom,
          cookie: 9,
          name: 'only',
          watchedPath: watched,
        ),
        isNull,
      );

      final flushed = matcher.flush(watched);
      expect(flushed.single, isA<FileSystemDeleteEvent>());
      expect(flushed.single.path, p.join(watched, 'only'));
    });

    test('a flushed half is consumed: no re-emission, no late pairing', () {
      final matcher = InotifyMoveMatcher();
      expect(
        matcher.match(
          mask: inotifyMovedFrom,
          cookie: 9,
          name: 'old',
          watchedPath: watched,
        ),
        isNull,
      );
      expect(matcher.flush(watched), hasLength(1));

      // A second flush must be empty — the phantom half is gone.
      expect(matcher.flush(watched), isEmpty);

      // A late opposite half must not resurrect the flushed one as a
      // move: the rename was already reported as delete(old).
      expect(
        matcher.match(
          mask: inotifyMovedTo,
          cookie: 9,
          name: 'new',
          watchedPath: watched,
        ),
        isNull,
      );
      final flushed = matcher.flush(watched);
      expect(flushed.single, isA<FileSystemCreateEvent>());
      expect(flushed.single.path, p.join(watched, 'new'));
    });

    test('an unmatched moved-to flushes as a create', () {
      final matcher = InotifyMoveMatcher();
      expect(
        matcher.match(
          mask: inotifyMovedTo,
          cookie: 9,
          name: 'only',
          watchedPath: watched,
        ),
        isNull,
      );

      final flushed = matcher.flush(watched);
      expect(flushed.single, isA<FileSystemCreateEvent>());
      expect(flushed.single.path, p.join(watched, 'only'));
    });

    test('cookie-less move halves map immediately', () {
      final matcher = InotifyMoveMatcher();
      final from = matcher.match(
        mask: inotifyMovedFrom,
        cookie: 0,
        name: 'from',
        watchedPath: watched,
      );
      final to = matcher.match(
        mask: inotifyMovedTo,
        cookie: 0,
        name: 'to',
        watchedPath: watched,
      );

      expect(from, isA<FileSystemDeleteEvent>());
      expect(to, isA<FileSystemCreateEvent>());
    });

    test('ignored is dropped: the loss already surfaced', () {
      expect(_map(inotifyIgnored, '', watched), isNull);
    });

    test('overflow is not mapped to an event — it is an error upstream', () {
      expect(_map(inotifyQOverflow, '', watched), isNull);
    });

    test('moves no longer map directly: pairing owns them', () {
      expect(_map(inotifyMovedFrom, 'a', watched), isNull);
      expect(_map(inotifyMovedTo, 'b', watched), isNull);
    });
  });
}

FileSystemEvent? _map(int mask, String name, String watchedPath) =>
    fileSystemEventFromInotify(mask: mask, name: name, watchedPath: watchedPath);

void _appendEvent(
  BytesBuilder bytes, {
  required int wd,
  required int mask,
  int cookie = 0,
  String name = '',
  List<int>? rawName,
}) {
  final nameBytes = Uint8List.fromList([
    ...(rawName ?? utf8.encode(name)),
    0,
  ]);
  // The kernel pads the name to a multiple of four bytes.
  final paddedLength = (nameBytes.length + 3) & ~3;

  final header = ByteData(inotifyEventHeaderBytes)
    ..setInt32(0, wd, Endian.host)
    ..setUint32(4, mask, Endian.host)
    ..setUint32(8, cookie, Endian.host)
    ..setUint32(12, paddedLength, Endian.host);
  bytes.add(header.buffer.asUint8List());

  bytes.add(nameBytes);
  bytes.add(Uint8List(paddedLength - nameBytes.length));
}
