// Ported from Séance app/seance_app/lib/services/identity_audit_log.dart @ a9add15; see docs/PORTS.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';
import 'file_permissions.dart';

/// One identity-file read attempt (successful or not).
class IdentityReadEvent {
  /// UTC ISO-8601, so the raw file is readable without tooling.
  final String at;
  final String serverId;
  final String serverLabel;
  final String path;

  /// True when the read went through a scoped grant rather than the plain
  /// path. Poltergeist is unsandboxed at v1 (D23), so this stays false until
  /// grants exist — the field survives so the record shape is stable.
  final bool viaBookmark;
  final bool ok;
  final String? error;

  const IdentityReadEvent({
    required this.at,
    required this.serverId,
    required this.serverLabel,
    required this.path,
    required this.viaBookmark,
    required this.ok,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'at': at,
    'serverId': serverId,
    'serverLabel': serverLabel,
    'path': path,
    'viaBookmark': viaBookmark,
    'ok': ok,
    if (error != null) 'error': error,
  };

  static IdentityReadEvent? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final at = json['at'];
    final serverId = json['serverId'];
    final serverLabel = json['serverLabel'];
    final path = json['path'];
    final viaBookmark = json['viaBookmark'];
    final ok = json['ok'];
    final error = json['error'];
    if (at is! String || serverId is! String || path is! String) return null;
    if (serverLabel != null && serverLabel is! String) return null;
    if (viaBookmark != null && viaBookmark is! bool) return null;
    if (ok != null && ok is! bool) return null;
    if (error != null && error is! String) return null;

    return IdentityReadEvent(
      at: at,
      serverId: serverId,
      serverLabel: serverLabel as String? ?? '',
      path: path,
      viaBookmark: viaBookmark as bool? ?? false,
      ok: ok as bool? ?? false,
      error: error as String?,
    );
  }
}

/// Device-local, append-only JSONL audit trail of identity-file reads, so
/// unexpected key access is traceable (D18: identity-file reads audited).
/// One JSON object per line; the newest entry is last. Never synced — paths
/// and server labels stay on this device (no telemetry, D19).
class IdentityAuditLog {
  final File file;

  /// Entries kept after a rotation; the file may grow to twice this between
  /// rotations so appends stay cheap.
  final int maxEntries;

  Future<void> _tail = Future<void>.value();

  IdentityAuditLog(this.file, {this.maxEntries = 500});

  /// Append [event], rotating the file down to the newest [maxEntries] when
  /// it has grown past twice that. Writes are serialized so concurrent
  /// connects can't interleave lines.
  Future<void> record(IdentityReadEvent event) {
    final result = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await file.parent.create(recursive: true);
        // Create empty, restrict, then append path-bearing audit data.
        await file.create();
        restrictFileToOwner(file);
        await file.writeAsString(
          '${jsonEncode(event.toJson())}\n',
          mode: FileMode.append,
          flush: true,
        );
        await _rotateIfNeeded();
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  /// All decodable entries, oldest first. Malformed lines (a torn tail
  /// write, hand edits) are skipped rather than wedging the log.
  Future<List<IdentityReadEvent>> readAll() async {
    if (!await file.exists()) return const [];
    restrictFileToOwner(file);

    final entries = <IdentityReadEvent>[];
    for (final line in const LineSplitter().convert(
      await file.readAsString(),
    )) {
      if (line.trim().isEmpty) continue;
      try {
        final event = IdentityReadEvent.fromJson(jsonDecode(line));
        if (event != null) entries.add(event);
      } on FormatException {
        continue;
      }
    }
    return entries;
  }

  Future<void> _rotateIfNeeded() async {
    final lines = const LineSplitter().convert(await file.readAsString());
    if (lines.length <= maxEntries * 2) return;
    final kept = lines.sublist(lines.length - maxEntries);
    await writeStringAtomically(
      file,
      '${kept.join('\n')}\n',
      privacy: AtomicFilePrivacy.ownerOnly,
    );
  }
}
