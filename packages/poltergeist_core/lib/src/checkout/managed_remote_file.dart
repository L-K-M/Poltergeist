import 'package:seance_core/seance_core.dart';

// Ported from Séance
// app/seance_app/lib/services/managed_remote_file.dart @ 2e6d1f1
// with the Poltergeist extensions 06 §3.4/§3.5 require (persisted
// [needsReconcile] and [displaced]); see docs/PORTS.md.

/// A durable, device-local checkout of a remote file.
///
/// [localPath] is a checkout-root-relative identity, not an arbitrary or
/// absolute filesystem path. [dirty] and [missing] are runtime observations;
/// they are deliberately recomputed rather than persisted.
class ManagedRemoteFile {
  final String id;
  final String serverId;
  final String editSessionId;
  final String remotePath;
  final String localPath;
  final RemoteFileEntry remoteSnapshot;
  final String baselineSha256;
  final bool dirty;
  final bool missing;

  /// 06 §3.4's degraded-snapshot mark: set when a post-upload remote
  /// re-stat failed and [remoteSnapshot] was synthesized locally
  /// (size+digest only, no server mtime). A record carrying it is
  /// repaired by the remote re-stat/hash pass at the next reconciliation
  /// — never by local rehashing, which would silently bless a drifted
  /// remote baseline. Persisted so a crash cannot launder the
  /// synthesized snapshot into an authoritative one.
  final bool needsReconcile;

  /// 06 §3.5's re-keyed-occupant mark: a remote rename delivered an
  /// arrival onto this record's [remotePath], so the record was displaced
  /// rather than overwritten. A displaced record keeps its original
  /// [remotePath] as the display target (its upload still CAS-guards
  /// that path) but no longer occupies the live (serverId, remotePath)
  /// slot — §3.7's review surface lists it as a recovered edit.
  final bool displaced;

  const ManagedRemoteFile({
    required this.id,
    required this.serverId,
    required this.editSessionId,
    required this.remotePath,
    required this.localPath,
    required this.remoteSnapshot,
    required this.baselineSha256,
    this.dirty = false,
    this.missing = false,
    this.needsReconcile = false,
    this.displaced = false,
  });

  factory ManagedRemoteFile.fromJson(Map<String, dynamic> json) {
    final snapshotJson = _requiredMap(json, 'remoteSnapshot');
    final result = ManagedRemoteFile(
      id: _requiredString(json, 'id'),
      serverId: _requiredString(json, 'serverId'),
      editSessionId: _requiredString(json, 'editSessionId'),
      remotePath: _requiredString(json, 'remotePath'),
      localPath: _requiredString(json, 'localPath'),
      remoteSnapshot: remoteFileEntryFromJson(snapshotJson),
      baselineSha256: _requiredString(json, 'baselineSha256').toLowerCase(),
      needsReconcile: json['needsReconcile'] == true,
      displaced: json['displaced'] == true,
    );
    result.validate();
    return result;
  }

  /// Validates model-level invariants. Store-specific path validation happens
  /// in `ManagedRemoteFileStore`.
  void validate() {
    for (final field in <(String, String)>[
      ('id', id),
      ('serverId', serverId),
      ('editSessionId', editSessionId),
      ('remotePath', remotePath),
      ('localPath', localPath),
      ('remoteSnapshot.path', remoteSnapshot.path),
      ('remoteSnapshot.name', remoteSnapshot.name),
    ]) {
      if (field.$2.isEmpty) {
        throw FormatException('${field.$1} must not be empty');
      }
    }
    if (remotePath != remoteSnapshot.path) {
      throw const FormatException('remotePath must match remoteSnapshot.path');
    }
    if (!remotePath.startsWith('/') || remotePath.contains('\u0000')) {
      throw const FormatException('remotePath must be an absolute POSIX path');
    }
    if (remoteSnapshot.type != RemoteFileType.file) {
      throw const FormatException('Only regular files can be managed edits');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(baselineSha256)) {
      throw const FormatException(
        'baselineSha256 must be a lowercase SHA-256 digest',
      );
    }
    if (remoteSnapshot.size case final size? when size < 0) {
      throw const FormatException('remoteSnapshot.size must not be negative');
    }
    if (remoteSnapshot.mode case final mode? when mode < 0) {
      throw const FormatException('remoteSnapshot.mode must not be negative');
    }
    if (remoteSnapshot.contentSha256 case final digest?
        when !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException(
        'remoteSnapshot.contentSha256 must be a lowercase SHA-256 digest',
      );
    }
    if (dirty && missing) {
      throw const FormatException('A missing checkout cannot also be dirty');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'serverId': serverId,
    'editSessionId': editSessionId,
    'remotePath': remotePath,
    'localPath': localPath,
    'remoteSnapshot': remoteFileEntryToJson(remoteSnapshot),
    'baselineSha256': baselineSha256,
    if (needsReconcile) 'needsReconcile': true,
    if (displaced) 'displaced': true,
  };

  ManagedRemoteFile copyWith({
    String? id,
    String? serverId,
    String? editSessionId,
    String? remotePath,
    String? localPath,
    RemoteFileEntry? remoteSnapshot,
    String? baselineSha256,
    bool? dirty,
    bool? missing,
    bool? needsReconcile,
    bool? displaced,
  }) => ManagedRemoteFile(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    editSessionId: editSessionId ?? this.editSessionId,
    remotePath: remotePath ?? this.remotePath,
    localPath: localPath ?? this.localPath,
    remoteSnapshot: remoteSnapshot ?? this.remoteSnapshot,
    baselineSha256: baselineSha256 ?? this.baselineSha256,
    dirty: dirty ?? this.dirty,
    missing: missing ?? this.missing,
    needsReconcile: needsReconcile ?? this.needsReconcile,
    displaced: displaced ?? this.displaced,
  );
}

/// Shared `RemoteFileEntry` JSON shape — the managed-checkout index and the
/// managed-checkout journal spec both carry a snapshot, and the digests
/// inside it are the D7 conflict authority neither side may drop.
Map<String, dynamic> remoteFileEntryToJson(RemoteFileEntry entry) => {
  'path': entry.path,
  'name': entry.name,
  'type': entry.type.name,
  'size': entry.size,
  'uid': entry.uid,
  'gid': entry.gid,
  'accessedAt': entry.accessedAt?.toUtc().toIso8601String(),
  'modifiedAt': entry.modifiedAt?.toUtc().toIso8601String(),
  'mode': entry.mode,
  'contentSha256': entry.contentSha256,
};

RemoteFileEntry remoteFileEntryFromJson(Map<String, dynamic> json) {
  final typeName = _requiredString(json, 'type');
  final type = RemoteFileType.values.where((value) => value.name == typeName);
  if (type.isEmpty) {
    throw FormatException('Unknown remote file type: $typeName');
  }

  final size = _optionalInt(json, 'size');
  final mode = _optionalInt(json, 'mode');
  final contentSha256 = json['contentSha256'];
  if (contentSha256 != null &&
      (contentSha256 is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(contentSha256))) {
    throw const FormatException('contentSha256 must be a SHA-256 digest');
  }
  DateTime? timestamp(String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('$key must be a string or null');
    }
    final parsed = DateTime.tryParse(value)?.toUtc();
    if (parsed == null) throw FormatException('$key is not a valid timestamp');
    return parsed;
  }

  return RemoteFileEntry(
    path: _requiredString(json, 'path'),
    name: _requiredString(json, 'name'),
    type: type.first,
    size: size,
    uid: _optionalInt(json, 'uid'),
    gid: _optionalInt(json, 'gid'),
    accessedAt: timestamp('accessedAt'),
    modifiedAt: timestamp('modifiedAt'),
    mode: mode,
    contentSha256: contentSha256 as String?,
  );
}

/// The metadata-level twin of [RemoteFileEntry]-equality the checkout
/// preflight uses (Séance's `_sameSnapshot`): content authority stays
/// with `expectedTarget.contentSha256` inside the upload CAS — this
/// compare is the cheap early-out, never the verdict.
bool sameRemoteSnapshot(RemoteFileEntry a, RemoteFileEntry b) =>
    a.size == b.size && a.modifiedAt == b.modifiedAt && a.mode == b.mode;

RemoteFileEntry copyRemoteEntry(RemoteFileEntry entry, String path) =>
    RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: entry.type,
      size: entry.size,
      uid: entry.uid,
      gid: entry.gid,
      accessedAt: entry.accessedAt,
      modifiedAt: entry.modifiedAt,
      mode: entry.mode,
      contentSha256: entry.contentSha256,
    );

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return value.cast<String, dynamic>();
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) throw FormatException('$key must be an integer or null');
  return value;
}
