// Ported from Séance app/seance_app/test/identity_audit_log_test.dart @ a9add15;
// see docs/PORTS.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/identity_audit_log.dart';
import 'package:posix/posix.dart' as posix;

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('poltergeist-audit-');
    file = File('${dir.path}/identity_reads.jsonl');
  });

  tearDown(() => dir.delete(recursive: true));

  IdentityReadEvent event(int n, {bool ok = true, String? error}) =>
      IdentityReadEvent(
        at: '2026-07-19T08:00:${n.toString().padLeft(2, '0')}.000Z',
        serverId: 'srv-$n',
        serverLabel: 'server $n',
        path: '/home/ada/.ssh/id_$n',
        viaBookmark: n.isEven,
        ok: ok,
        error: error,
      );

  test('records and reads back events in order, with all fields', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    await log.record(event(2, ok: false, error: 'EPERM'));

    final entries = await log.readAll();
    expect(entries, hasLength(2));
    expect(entries[0].serverId, 'srv-1');
    expect(entries[0].viaBookmark, isFalse);
    expect(entries[0].ok, isTrue);
    expect(entries[0].error, isNull);
    expect(entries[1].serverId, 'srv-2');
    expect(entries[1].path, '/home/ada/.ssh/id_2');
    expect(entries[1].viaBookmark, isTrue);
    expect(entries[1].ok, isFalse);
    expect(entries[1].error, 'EPERM');
  });

  test('an absent file reads as empty', () async {
    expect(await IdentityAuditLog(file).readAll(), isEmpty);
  });

  test('rotation keeps only the newest maxEntries', () async {
    final log = IdentityAuditLog(file, maxEntries: 5);
    for (var n = 0; n < 11; n++) {
      await log.record(event(n));
    }
    // 11 lines crossed 2 * 5, so the file was trimmed to the newest 5.
    final entries = await log.readAll();
    expect(entries, hasLength(5));
    expect(entries.first.serverId, 'srv-6');
    expect(entries.last.serverId, 'srv-10');
  });

  test('audit storage stays owner-only on desktop POSIX', () async {
    await file.create();
    posix.chmod(dir.path, _permissiveDirectoryPermissions);
    posix.chmod(file.path, _permissiveFilePermissions);

    // Three writes force the atomic-rotation path at maxEntries 1.
    final log = IdentityAuditLog(file, maxEntries: 1);
    for (var n = 0; n < 3; n++) {
      await log.record(event(n));
    }

    // Privacy belongs to the file, even under a traversable app directory.
    expect((await dir.stat()).mode & _permissionBits, _permissiveDirectoryMode);
    expect((await file.stat()).mode & _permissionBits, _ownerOnlyFileMode);
  }, skip: !Platform.isLinux && !Platform.isMacOS ? 'POSIX only' : false);

  test('malformed lines are skipped, not fatal', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    await file.writeAsString(
      'not json\n{"at": 7}\n',
      mode: FileMode.append,
      flush: true,
    );
    await log.record(event(2));

    final entries = await log.readAll();
    expect(entries.map((e) => e.serverId), ['srv-1', 'srv-2']);
  });

  // A hand edit can leave valid JSON whose field types no longer match —
  // that must skip like any other malformed line, not poison the trail.
  test('wrong-typed fields are skipped, not fatal', () async {
    final log = IdentityAuditLog(file);
    await log.record(event(1));
    await file.writeAsString(
      '{"at":"2026-07-19T08:00:03.000Z","serverId":"srv-3",'
      '"path":"/home/ada/.ssh/id_3","ok":"yes"}\n',
      mode: FileMode.append,
      flush: true,
    );
    await log.record(event(2));

    final entries = await log.readAll();
    expect(entries.map((e) => e.serverId), ['srv-1', 'srv-2']);
  });

  test('concurrent records are serialized without interleaving', () async {
    final log = IdentityAuditLog(file);
    await Future.wait([for (var n = 0; n < 20; n++) log.record(event(n))]);
    expect(await log.readAll(), hasLength(20));
  });
}

const _permissionBits = 0x1ff;
const _ownerOnlyFileMode = 0x180;
const _permissiveDirectoryMode = 0x1ed;
const _permissiveDirectoryPermissions = '755';
const _permissiveFilePermissions = '644';
