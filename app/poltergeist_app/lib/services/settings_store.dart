import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

final class SettingsStore {
  SettingsStore({
    required String path,
    Future<void> Function(File target, String contents)? atomicWriter,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
  }) : // Keep the filesystem path immutable and private.
       // ignore: prefer_initializing_formals
       _file = File(path),
       _atomicWriter = atomicWriter ?? writeStringAtomically,
       _now = now ?? DateTime.now,
       // Keep the callback private while allowing test-only error injection.
       // ignore: prefer_initializing_formals
       _onError = onError;

  final File _file;
  // A single save command keeps fault injection from becoming a second VFS.
  final Future<void> Function(File target, String contents) _atomicWriter;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? _onError;
  final _values = <String, Object?>{};

  Future<void>? _loadFuture;
  Future<void> _writeTail = Future.value();

  Future<T?> get<T>(String key) async {
    await _ensureLoaded();
    final value = _values[key];
    return value is T ? value : null;
  }

  Future<void> set(String key, Object? value) async {
    await setAll({key: value});
  }

  Future<void> setAll(Map<String, Object?> updates) async {
    await _ensureLoaded();

    final operation = _writeTail.then((_) async {
      final previous = <String, Object?>{
        for (final key in updates.keys)
          if (_values.containsKey(key)) key: _values[key],
      };
      _values.addAll(updates);

      try {
        await _write();
      } catch (_) {
        for (final entry in updates.entries) {
          if (!identical(_values[entry.key], entry.value)) continue;
          if (previous.containsKey(entry.key)) {
            _values[entry.key] = previous[entry.key];
          } else {
            _values.remove(entry.key);
          }
        }
        rethrow;
      }
    });
    // The calling service owns write-error reporting; this only heals the queue.
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }

  Future<void> flush() async {
    await _ensureLoaded();
    await _writeTail;
  }

  Future<void> _ensureLoaded() {
    final activeLoad = _loadFuture;
    if (activeLoad != null) return activeLoad;

    final load = _load();
    _loadFuture = load;
    unawaited(
      load.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A transient filesystem failure must not poison later reads.
          if (identical(_loadFuture, load)) _loadFuture = null;
        },
      ),
    );
    return load;
  }

  Future<void> _load() async {
    late final String? contents;
    try {
      await _file.parent.create(recursive: true);
      if (await _file.exists()) {
        contents = await _file.readAsString();
      } else {
        contents = null;
      }
    } catch (error, stack) {
      _report(error, stack);
      rethrow;
    }

    if (contents == null) return;

    try {
      final decoded = jsonDecode(contents);
      if (decoded is! Map) throw const FormatException('settings root');
      for (final entry in decoded.entries) {
        if (entry.key is! String) throw const FormatException('settings key');
        _values[entry.key as String] = entry.value;
      }
    } catch (error, stack) {
      _values.clear();
      try {
        await _file.rename(_corruptPath(_file.path));
      } catch (quarantineError, quarantineStack) {
        _report(quarantineError, quarantineStack);
      }
      _report(error, stack);
    }
  }

  Future<void> _write() async {
    await _atomicWriter(_file, jsonEncode(_values));
  }

  String _corruptPath(String path) {
    final stamp = _formatTimestamp(_now().toUtc());
    return '$path.corrupt-$stamp';
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }
}

String _formatTimestamp(DateTime value) => value
    .toIso8601String()
    .replaceAll('-', '')
    .replaceAll(':', '')
    .replaceAll('.', '');
