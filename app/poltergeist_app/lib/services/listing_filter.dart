/// 02 §2.5's Filter matcher (`view.filter`): a plain case-insensitive
/// substring of the decoded basename.
///
/// Deliberately separate from both sibling matchers:
/// - NOT the type-ahead fold (`typeAheadFold`), which additionally strips
///   diacritics — §2.5 specifies plain "case-insensitive substring" for
///   Filter and does not extend type-ahead's diacritic folding to it, so
///   `e` must not match `Étude` here even though it prefix-matches there.
/// - NOT Quick Select's `QuickSelectQuery`: that one treats `*` as a
///   whole-name glob, while in a filter `*` is an ordinary character.
///
/// Case-insensitivity rides Dart's full lowercase mapping rather than the
/// §2.3 simple case fold: that fold lives in poltergeist_core, which this
/// slice must not touch, and for containment the lowercase map is the
/// plain reading of "case-insensitive" — where the two disagree (long s
/// ſ, final sigma ς) the conservative answer is a miss, never a surprise
/// match.
final class ListingFilter {
  ListingFilter(String query) : foldedQuery = query.toLowerCase();

  /// The query under the same case mapping [matches] applies to names —
  /// callers that cache lowered basenames per listing scan them against
  /// this instead of re-lowercasing each name per keystroke.
  final String foldedQuery;

  /// Whether [name] contains the query as a case-insensitive substring.
  bool matches(String name) => name.toLowerCase().contains(foldedQuery);
}
