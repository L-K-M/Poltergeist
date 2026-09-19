import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/uuid.dart';

/// The post-connect "Save as favorite…" bar (02 §2.7): rendered for a
/// live adhoc session, prefilled from the live connection — never from
/// the raw address string (which may have carried a stripped password).
///
/// The save writes through [store], the core [BookmarkStore] seam (the
/// file store in production, in-memory in tests): the promoted favorite
/// lands at the ungrouped tail through [BookmarkStore.sortKeyForInsert]
/// — the fractional-key contract the sidebar's ordering relies on — and
/// saves through [BookmarkStore.save] so the `updatedAt` stamp and the
/// change emission the sidebar reloads on both land (04 §2.1). A null
/// [store] means no persistence path is wired: the save reports through
/// [onNoStore], which the pane answers with the honest not-yet notice
/// (the #132 pattern) — never a fake write. A successful save hides the
/// bar (state is keyed to the adhoc id, so parent rebuilds cannot
/// resurrect it); a throwing store keeps it mounted with an inline
/// error so the save stays retryable.
class SaveFavoriteBar extends StatefulWidget {
  const SaveFavoriteBar({
    super.key,
    required this.bookmark,
    this.currentPath,
    required this.store,
    required this.onNoStore,
  });

  /// The live adhoc bookmark: endpoint identity and landing path source.
  final Bookmark bookmark;

  /// The tab's current remote path; the stored favorite captures this
  /// context instead of a form.
  final String? currentPath;

  final BookmarkStore? store;

  final VoidCallback onNoStore;

  @override
  State<SaveFavoriteBar> createState() => _SaveFavoriteBarState();
}

class _SaveFavoriteBarState extends State<SaveFavoriteBar> {
  late final TextEditingController _name = TextEditingController(
    text: _prefill(widget.bookmark),
  );
  bool _failed = false;
  bool _saving = false;
  bool _saved = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final store = widget.store;
    if (store == null) {
      widget.onNoStore();
      return;
    }
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      // The ungrouped tail key comes from the store — the one call site
      // that still minted a uuid sortKey (the #161 disclosed follow-up).
      final sortKey = await store.sortKeyForInsert();
      await store.save(
        _promotedFavorite(
          live: widget.bookmark,
          currentPath: widget.currentPath,
          label: _name.text.trim().isEmpty
              ? _prefill(widget.bookmark)
              : _name.text.trim(),
          sortKey: sortKey,
          now: DateTime.now(),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_saved) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: DecoratedBox(
        key: const ValueKey('saveFavorite.bar'),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A narrow pane must not overflow: the title and the
              // name/save cluster wrap onto separate runs instead of
              // forcing one Row wider than the pane.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 8,
                children: [
                  Text(
                    l10n.saveFavoriteTitle,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: TextField(
                          key: const ValueKey('saveFavorite.name'),
                          controller: _name,
                          decoration: InputDecoration(
                            labelText: l10n.saveFavoriteNameLabel,
                            isDense: true,
                          ),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _save(),
                        ),
                      ),
                      FilledButton(
                        key: const ValueKey('saveFavorite.save'),
                        onPressed: _saving ? null : _save,
                        child: Text(l10n.saveFavoriteSave),
                      ),
                    ],
                  ),
                ],
              ),
              if (_failed)
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 4),
                  child: Text(
                    l10n.saveFavoriteFailed,
                    key: const ValueKey('saveFavorite.error'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The prefill derives from the live authenticated session: the
/// endpoint with a non-default port, never the raw input string.
String _prefill(Bookmark live) {
  final identity = live.server?.identity;
  if (identity == null) return live.label;
  final username = identity.username;
  final host = identity.port == 22
      ? identity.host
      : '${identity.host}:${identity.port}';
  return username.isEmpty ? host : '$username@$host';
}

/// Promotes the live adhoc session to a stored favorite: a fresh id
/// (the adhoc id never enters the store), the live endpoint identity,
/// the captured context path, and the store-minted [sortKey]. Carries
/// no secret — bookmarks hold `secretRef`s into the vault, and the
/// adhoc identity never had a password to copy.
Bookmark _promotedFavorite({
  required Bookmark live,
  required String? currentPath,
  required String label,
  required String sortKey,
  required DateTime now,
}) {
  return Bookmark(
    id: uuidV4(),
    kind: BookmarkKind.remotePath,
    label: label,
    server: live.server,
    remotePath: currentPath ?? live.remotePath,
    sortKey: sortKey,
    createdAt: now,
    updatedAt: now,
  );
}
