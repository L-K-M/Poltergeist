/// Platform-agnostic core for Poltergeist.
///
/// Scaffold: the real modules (connections, transfers, sync engine, bookmark
/// model) land per the plan in `docs/plan/`. What lives here today is the
/// product identity, exported so every layer — UI, packaging, tests — names
/// the product from one place.
library;

/// The user-facing product name.
///
/// Deliberately plain ASCII: macOS codesign rejects accented file names in
/// bundle paths (Séance ships as ASCII `Seance.app` and renames after
/// signing for exactly this reason). Poltergeist avoids the whole dance by
/// keeping the name ASCII — `product_name_test.dart` guards the invariant.
const String productName = 'Poltergeist';

/// One-line description used by packaging metadata and about screens.
const String productTagline = 'The ghost that moves your files.';

/// Home of the source repository, referenced by packaging metadata.
const String productHomepage = 'https://github.com/L-K-M/Poltergeist';
