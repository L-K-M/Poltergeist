import 'package:poltergeist_core/poltergeist_core.dart';

/// Immutable navigation transitions from 02 §2.8, independent of I/O.
///
/// The pane controller supplies immutable, canonicalized location values and
/// listing policy. It must cancel superseded engine operations separately;
/// discarding their answers here does not stop filesystem work.
/// Equality is by identity; ignored answers return the same state.
final class ListingState<Location extends Object> {
  /// Starts from an accepted listing, or an empty launcher. An unlisted
  /// directory must be reached through [navigateTo] so its verbs stay off.
  /// Generations belong to this chain. Replacing a live pane's chain requires
  /// invalidating its old replies before reusing generation numbers.
  factory ListingState.ready({
    required Location location,
    required Iterable<RemoteFileEntry> entries,
    required Comparator<RemoteFileEntry> compare,
  }) => ListingState._(
    location: location,
    entries: _sortedSnapshot(entries, compare),
    issuedGeneration: 0,
    answeredGeneration: 0,
    error: null,
    snapshot: null,
  );

  const ListingState._({
    required this.location,
    required this.entries,
    required this.issuedGeneration,
    required this.answeredGeneration,
    required this.error,
    required this._snapshot,
  });

  /// The latest navigation target; rows may still belong to its predecessor.
  final Location location;
  final List<RemoteFileEntry> entries;
  final int issuedGeneration;
  final int answeredGeneration;
  final Object? error;

  // Only a pending state retains a snapshot, so navigation cannot build an
  // unbounded history chain. Stacked requests share the same settled state.
  final ListingState<Location>? _snapshot;

  bool get loading => issuedGeneration > answeredGeneration && error == null;
  bool get verbsEnabled => error == null && !loading;

  /// Retry uses this same transition: clear its error before showing busy UI.
  ListingState<Location> navigateTo(Location target) => ListingState._(
    location: target,
    entries: entries,
    issuedGeneration: issuedGeneration + 1,
    answeredGeneration: answeredGeneration,
    error: null,
    snapshot: loading ? _snapshot : this,
  );

  /// Accepts only the outstanding answer, without sorting stale payloads.
  ListingState<Location> acceptEntries(
    int generation,
    Iterable<RemoteFileEntry> result, {
    required Comparator<RemoteFileEntry> compare,
  }) {
    if (!_awaits(generation)) return this;

    return ListingState._(
      location: location,
      entries: _sortedSnapshot(result, compare),
      issuedGeneration: issuedGeneration,
      answeredGeneration: generation,
      error: null,
      snapshot: null,
    );
  }

  /// Keeps stale rows visible while disabling actions against the failed target.
  ListingState<Location> acceptError(int generation, Object failure) {
    if (!_awaits(generation)) return this;

    return ListingState._(
      location: location,
      entries: entries,
      issuedGeneration: issuedGeneration,
      answeredGeneration: generation,
      error: failure,
      snapshot: null,
    );
  }

  /// Restores the last settled view after the controller cancels pending I/O.
  /// Advancing both counters keeps every cancelled response stale.
  ListingState<Location> cancelNavigation() {
    final snapshot = _snapshot;
    if (!loading || snapshot == null) return this;

    final generation = issuedGeneration + 1;
    return ListingState._(
      location: snapshot.location,
      entries: snapshot.entries,
      issuedGeneration: generation,
      answeredGeneration: generation,
      error: snapshot.error,
      snapshot: null,
    );
  }

  // A second answer for an already settled generation is invalid too.
  bool _awaits(int generation) => loading && generation == issuedGeneration;

  static List<RemoteFileEntry> _sortedSnapshot(
    Iterable<RemoteFileEntry> entries,
    Comparator<RemoteFileEntry> compare,
  ) => List.unmodifiable(List<RemoteFileEntry>.of(entries)..sort(compare));
}
