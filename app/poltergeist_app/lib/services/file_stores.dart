// Ported from Séance app/seance_app/lib/services/file_stores.dart @ e11206a; see docs/PORTS.md.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'atomic_file.dart';

/// Moves a corrupt store file aside so a bad file cannot wedge startup.
/// UTC-stamped per this repo's atomic-file port (a repeated corruption never
/// overwrites the previous evidence); best-effort like the Séance source —
/// if it cannot be moved, the caller still starts empty.
Future<void> _quarantineCorruptFile(File file) async {
  try {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll('.', '');
    await file.rename('${file.path}.corrupt-$stamp');
  } catch (_) {
    // Best effort: if we can't move it aside, the caller still starts empty.
  }
}

/// JSON-file [VaultStore] holding only opaque, already-encrypted blobs
/// (base64). [SecretVault] seals/opens; this just persists bytes.
class FileVaultStore implements VaultStore {
  final File file;
  final Map<String, String> _blobs = {}; // id -> base64
  bool _loaded = false;

  FileVaultStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final map = jsonDecode(await file.readAsString()) as Map;
        map.forEach((k, v) => _blobs[k as String] = v as String);
      } catch (_) {
        _blobs.clear();
        await _quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    await writeStringAtomically(file, jsonEncode(_blobs));
  }

  @override
  Future<Uint8List?> getSecretBlob(String id) async {
    await _load();
    final b64 = _blobs[id];
    return b64 == null ? null : base64.decode(b64);
  }

  @override
  Future<void> putSecretBlob(String id, Uint8List blob) async {
    await _load();
    _blobs[id] = base64.encode(blob);
    await _flush();
  }

  @override
  Future<void> deleteSecret(String id) async {
    await _load();
    _blobs.remove(id);
    await _flush();
  }
}

/// JSON-file [HostKeyStore] for pinned TOFU keys.
class FileHostKeyStore implements HostKeyStore {
  final File file;
  final Map<String, HostKey> _keys = {};
  bool _loaded = false;

  FileHostKeyStore(this.file);

  Future<void> _load() async {
    if (_loaded) return;
    if (await file.exists()) {
      try {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final j in list) {
          final k = HostKey.fromJson((j as Map).cast<String, dynamic>());
          _keys[k.locator] = k;
        }
      } catch (_) {
        _keys.clear();
        await _quarantineCorruptFile(file);
      }
    }
    _loaded = true;
  }

  Future<void> _flush() async {
    await writeStringAtomically(
        file, jsonEncode(_keys.values.map((k) => k.toJson()).toList()));
  }

  @override
  Future<List<HostKey>> all() async {
    await _load();
    return _keys.values.toList();
  }

  @override
  Future<HostKey?> get(String host, int port) async {
    await _load();
    return _keys['$host:$port'];
  }

  @override
  Future<void> put(HostKey key) async {
    await _load();
    _keys[key.locator] = key;
    await _flush();
  }
}
