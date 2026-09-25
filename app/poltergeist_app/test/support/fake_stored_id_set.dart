/// The preferences' collapse and pin writes, in memory: each change
/// applies to [stored] the way `AppPreferences` applies it to the value
/// the settings store holds at write time, and [writes] records the set
/// each change stored, in call order.
final class FakeStoredIdSet {
  FakeStoredIdSet([Iterable<String> stored = const []])
    : stored = Set.unmodifiable(stored);

  Set<String> stored;
  final writes = <Set<String>>[];

  /// Stands in for `AppPreferences.setSidebarGroupCollapsed`.
  Future<Set<String>> collapse(String key, {required bool collapsed}) =>
      _write(key, member: collapsed);

  /// Stands in for `AppPreferences.setSidebarServerPinned`.
  Future<Set<String>> pin(String serverId, {required bool pinned}) =>
      _write(serverId, member: pinned);

  Future<Set<String>> _write(String id, {required bool member}) {
    final next = Set<String>.of(stored);
    if (member) {
      next.add(id);
    } else {
      next.remove(id);
    }
    stored = Set.unmodifiable(next);
    writes.add(stored);
    return Future.value(stored);
  }
}
