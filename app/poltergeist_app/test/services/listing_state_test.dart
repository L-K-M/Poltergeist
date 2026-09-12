import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/listing_state.dart';

const _first = RemoteFileEntry(
  path: '/a/first',
  name: 'first',
  type: RemoteFileType.file,
);
const _last = RemoteFileEntry(
  path: '/a/last',
  name: 'last',
  type: RemoteFileType.file,
);
const _next = RemoteFileEntry(
  path: '/b/next',
  name: 'next',
  type: RemoteFileType.file,
);
const _denied = RemoteFileException(
  kind: RemoteFileErrorKind.permissionDenied,
  operation: 'list',
  path: '/b',
  message: 'Denied',
);

// Records keep endpoint identity in the test without implementing the
// future PaneLocation canonicalization or any filesystem operations.
typedef _Location = ({String? serverId, String path});
const _launcher = (serverId: null, path: '');
const _a = (serverId: null, path: '/a');
const _b = (serverId: 'server', path: '/b');
const _c = (serverId: 'server', path: '/c');

int _byName(RemoteFileEntry a, RemoteFileEntry b) => a.name.compareTo(b.name);

ListingState<_Location> _loaded() {
  final pending = _initial().navigateTo(_a);
  return pending.acceptEntries(pending.issuedGeneration, [
    _first,
    _last,
  ], compare: _byName);
}

ListingState<_Location> _initial() => ListingState<_Location>.ready(
  location: _launcher,
  entries: const [],
  compare: _byName,
);

void main() {
  test('ready state defensively snapshots an accepted listing', () {
    final source = [_last, _first];
    final state = ListingState<_Location>.ready(
      location: _a,
      entries: source,
      compare: _byName,
    );
    source.clear();

    expect(state.entries, [_first, _last]);
    expect(() => state.entries.clear(), throwsUnsupportedError);
    expect(state.loading, isFalse);
    expect(state.verbsEnabled, isTrue);
    expect(state.issuedGeneration, state.answeredGeneration);
  });

  test('issue is optimistic and preserves the immutable previous listing', () {
    final loaded = _loaded();
    final pending = loaded.navigateTo(_b);

    expect(pending.location, _b);
    expect(pending.entries, same(loaded.entries));
    expect(pending.issuedGeneration, loaded.issuedGeneration + 1);
    expect(pending.answeredGeneration, loaded.answeredGeneration);
    expect(pending.loading, isTrue);
    expect(pending.verbsEnabled, isFalse);
    expect(loaded.location, _a);
    expect(loaded.loading, isFalse);
  });

  test('accepted listing copies, sorts and freezes caller entries', () {
    final pending = _loaded().navigateTo(_b);
    final source = [_last, _first];
    final loaded = pending.acceptEntries(
      pending.issuedGeneration,
      source,
      compare: _byName,
    );

    expect(source, [_last, _first]);
    source.clear();
    expect(loaded.entries, [_first, _last]);
    expect(() => loaded.entries.clear(), throwsUnsupportedError);
    expect(() => loaded.entries[0] = _next, throwsUnsupportedError);
    expect(loaded.answeredGeneration, loaded.issuedGeneration);
    expect(loaded.error, isNull);
    expect(loaded.loading, isFalse);
    expect(loaded.verbsEnabled, isTrue);
  });

  test('error retains stale rows and disables verbs without loading', () {
    final initial = _loaded();
    final pending = initial.navigateTo(_b);
    final failed = pending.acceptError(pending.issuedGeneration, _denied);

    expect(failed.location, _b);
    expect(failed.entries, same(initial.entries));
    expect(failed.error, same(_denied));
    expect(failed.answeredGeneration, failed.issuedGeneration);
    expect(failed.loading, isFalse);
    expect(failed.verbsEnabled, isFalse);
  });

  test('superseded and unsolicited answers are complete no-ops', () {
    final first = _loaded().navigateTo(_b);
    final second = first.navigateTo(_c);
    for (final generation in [
      first.issuedGeneration,
      second.issuedGeneration + 1,
    ]) {
      expect(second.acceptError(generation, _denied), same(second));
      expect(
        second.acceptEntries(
          generation,
          _unreadableEntries(),
          compare: _byName,
        ),
        same(second),
      );
    }
  });

  test('cancel stacked navigations restores the last quiescent snapshot', () {
    final initial = _loaded();
    final first = initial.navigateTo(_b);
    final second = first.navigateTo(_c);
    final cancelled = second.cancelNavigation();

    expect(cancelled.location, initial.location);
    expect(cancelled.entries, same(initial.entries));
    expect(cancelled.error, isNull);
    expect(cancelled.issuedGeneration, second.issuedGeneration + 1);
    expect(cancelled.answeredGeneration, cancelled.issuedGeneration);
    expect(cancelled.loading, isFalse);
    expect(cancelled.verbsEnabled, isTrue);
    expect(
      cancelled.acceptError(first.issuedGeneration, _denied),
      same(cancelled),
    );
    expect(
      cancelled.acceptError(second.issuedGeneration, _denied),
      same(cancelled),
    );
  });

  test(
    'cancel a retry restores its error and keeps stale row verbs disabled',
    () {
      final pending = _loaded().navigateTo(_b);
      final failed = pending.acceptError(pending.issuedGeneration, _denied);
      final retry = failed.navigateTo(_b);

      expect(retry.error, isNull);
      expect(retry.loading, isTrue);
      final cancelled = retry.navigateTo(_c).cancelNavigation();
      expect(cancelled.location, failed.location);
      expect(cancelled.entries, same(failed.entries));
      expect(cancelled.error, same(_denied));
      expect(cancelled.loading, isFalse);
      expect(cancelled.verbsEnabled, isFalse);
    },
  );

  test(
    'a successful retry clears the error and replaces the cancel snapshot',
    () {
      final pending = _loaded().navigateTo(_b);
      final failed = pending.acceptError(pending.issuedGeneration, _denied);
      final retry = failed.navigateTo(_b);
      final loaded = retry.acceptEntries(retry.issuedGeneration, [
        _next,
      ], compare: _byName);
      final cancelled = loaded.navigateTo(_c).cancelNavigation();

      expect(cancelled.location, _b);
      expect(cancelled.entries, [_next]);
      expect(cancelled.error, isNull);
      expect(cancelled.verbsEnabled, isTrue);
    },
  );

  test('cancel is idle-safe and generations never rewind across retries', () {
    final initial = _loaded();
    expect(initial.cancelNavigation(), same(initial));
    final pending = initial.navigateTo(_b);
    final cancelled = pending.cancelNavigation();
    expect(cancelled.cancelNavigation(), same(cancelled));
    final retry = cancelled.navigateTo(_c);
    expect(retry.issuedGeneration, cancelled.issuedGeneration + 1);
    expect(retry.acceptError(pending.issuedGeneration, _denied), same(retry));
    expect(
      retry.acceptEntries(
        pending.issuedGeneration,
        _unreadableEntries(),
        compare: _byName,
      ),
      same(retry),
    );
    expect(retry.loading, isTrue);
  });

  test('terminal state refuses duplicate answers for the same generation', () {
    final loaded = _loaded();
    expect(loaded.acceptError(loaded.issuedGeneration, _denied), same(loaded));
    final pending = loaded.navigateTo(_b);
    final failed = pending.acceptError(pending.issuedGeneration, _denied);
    expect(
      failed.acceptEntries(failed.issuedGeneration, [_next], compare: _byName),
      same(failed),
    );
  });

  test('cancelling the first navigation restores the launcher', () {
    final initial = _initial();
    final cancelled = initial.navigateTo(_a).cancelNavigation();
    expect(cancelled.location, _launcher);
    expect(cancelled.entries, isEmpty);
    expect(cancelled.error, isNull);
    expect(cancelled.loading, isFalse);
  });
}

// Reject stale payloads before copying or sorting any of their rows.
Iterable<RemoteFileEntry> _unreadableEntries() sync* {
  fail('Stale listing was consumed');
}
