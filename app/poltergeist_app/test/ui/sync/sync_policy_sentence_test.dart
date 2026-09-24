// The Sync sheet's plan sentence (D32 §7): verbatim goldens for the
// option combinations the sheet can reach, so a copy regression (or an
// untruthful promise such as "older files are replaced") fails here.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/ui/sync/sync_policy_sentence.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

final _l10n = AppLocalizationsEn();

SyncPair _pair({
  SyncRuleSet rules = const SyncRuleSet(),
  SyncEndpoint left = const LocalEndpoint('/Users/me/site'),
  SyncEndpoint right = const LocalEndpoint('/Volumes/Backup/site-copy'),
}) => SyncPair(id: 'p', name: 'p', left: left, right: right, rules: rules);

const _remote = RemoteEndpoint(
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '127.0.0.1',
      port: 2222,
      username: 'demo',
      authMethod: AuthMethod.password,
    ),
  ),
  path: '/var/www/site',
);

String _text(SyncPair pair, [SyncPairState? state]) =>
    syncPolicySentenceText(_l10n, pair, state);

void main() {
  group('one-way', () {
    test('the default Update pair', () {
      expect(
        _text(_pair()),
        'Your local folder “site-copy” will be updated from your local '
        'folder “site”. Files that differ in size or modification date '
        'will be replaced with the version from “site”, even when the '
        'copy in “site-copy” is newer. Previous versions of replaced '
        'files are kept in .poltergeist-trash inside “site-copy”. No '
        'files will be deleted.',
      );
    });

    test('a remote destination names its kind', () {
      final clauses = syncPolicySentence(_l10n, _pair(right: _remote));
      expect(
        clauses.first.text,
        'Your remote folder “site” will be updated from your local folder '
        '“site”.',
      );
    });

    test('right to left swaps source and destination', () {
      final clauses = syncPolicySentence(
        _l10n,
        _pair(
          right: _remote,
          rules: const SyncRuleSet(direction: SyncDirection.rightToLeft),
        ),
      );
      expect(
        clauses.first.text,
        'Your local folder “site” will be updated from your remote folder '
        '“site”.',
      );
    });

    test('Mirror into the trash is a destructive clause', () {
      final clauses = syncPolicySentence(
        _l10n,
        _pair(rules: const SyncRuleSet(deletions: DeletionPolicy.trash)),
      );
      expect(
        clauses.last,
        const SyncPolicyClause(
          'Files in “site-copy” that aren’t in “site” will be deleted '
          '(moved to .poltergeist-trash).',
          tone: SyncPolicyTone.destructive,
        ),
      );
      expect(
        clauses.where((c) => c.text == 'No files will be deleted.'),
        isEmpty,
      );
    });

    test('permanent deletes without backups', () {
      expect(
        _text(
          _pair(
            rules: const SyncRuleSet(
              deletions: DeletionPolicy.permanent,
              backups: BackupPolicy.none,
            ),
          ),
        ),
        'Your local folder “site-copy” will be updated from your local '
        'folder “site”. Files that differ in size or modification date '
        'will be replaced with the version from “site”, even when the '
        'copy in “site-copy” is newer. Replaced files are overwritten '
        'without a backup. Files in “site-copy” that aren’t in “site” '
        'will be deleted permanently.',
      );
      final tones = syncPolicySentence(
        _l10n,
        _pair(
          rules: const SyncRuleSet(
            deletions: DeletionPolicy.permanent,
            backups: BackupPolicy.none,
          ),
        ),
      ).map((c) => c.tone);
      expect(
        tones.where((tone) => tone == SyncPolicyTone.destructive),
        hasLength(2),
      );
    });

    test('an out-of-root trash path is named', () {
      final clauses = syncPolicySentence(
        _l10n,
        _pair(
          rules: const SyncRuleSet(
            deletions: DeletionPolicy.trash,
            trashPathRight: '/srv/trash',
          ),
        ),
      );
      expect(
        clauses[2].text,
        'Previous versions of replaced files are kept in /srv/trash.',
      );
      expect(clauses[3].text, contains('(moved to /srv/trash)'));
    });

    test('size only and checksum', () {
      expect(
        syncPolicySentence(
          _l10n,
          _pair(rules: const SyncRuleSet(comparison: ComparisonMode.sizeOnly)),
        )[1].text,
        'Files that differ in size will be replaced with the version from '
        '“site”. Files of the same size are left alone, even when their '
        'dates differ.',
      );
      expect(
        syncPolicySentence(
          _l10n,
          _pair(
            rules: const SyncRuleSet(comparison: ComparisonMode.contentHash),
          ),
        )[1].text,
        'Files whose size or contents differ will be replaced with the '
        'version from “site”. Contents are compared by checksum, which '
        'reads every file of matching size on both sides.',
      );
    });

    test('a flagged clock states the size-only fallback', () {
      final clauses = syncPolicySentence(
        _l10n,
        _pair(),
        SyncPairState(mtimeUnreliableRight: true),
      );
      expect(clauses[1].text, startsWith('Files that differ in size will'));
      expect(
        clauses[2].text,
        'Modification dates proved unreliable for this pair, so only '
        'sizes are compared.',
      );
      // A checksum pair never downgrades — hashes ignore clocks.
      expect(
        syncPolicySentence(
          _l10n,
          _pair(
            rules: const SyncRuleSet(comparison: ComparisonMode.contentHash),
          ),
          SyncPairState(mtimeUnreliableLeft: true),
        ).map((c) => c.text),
        isNot(contains(startsWith('Modification dates proved'))),
      );
    });

    test('filters append their own clauses', () {
      final clauses = syncPolicySentence(
        _l10n,
        _pair(
          rules: const SyncRuleSet(
            includeHidden: false,
            excludeGlobs: ['*.log', 'build/', 'node_modules/'],
          ),
        ),
      );
      expect(clauses[clauses.length - 2].text, 'Hidden files are left out.');
      expect(clauses.last.text, 'Items matching 3 rules are left out.');
    });
  });

  group('both ways (Additive)', () {
    const additive = SyncRuleSet(direction: SyncDirection.bidirectional);

    test('conflicts need a decision by default', () {
      expect(
        _text(_pair(rules: additive, right: _remote)),
        'Your local folder “site” and your remote folder “site” will each '
        'receive the files only the other one has. Files count as '
        'different when their size or modification date differs. Files '
        'that differ are held as conflicts for you to decide; nothing is '
        'replaced automatically. No files will be deleted.',
      );
    });

    test('newer wins replaces and keeps backups', () {
      expect(
        _text(
          _pair(
            rules: const SyncRuleSet(
              direction: SyncDirection.bidirectional,
              conflictDefault: ConflictDefault.newerWins,
            ),
          ),
        ),
        'Your local folder “site” and your local folder “site-copy” will '
        'each receive the files only the other one has. Files count as '
        'different when their size or modification date differs. When a '
        'file differs, the newer copy replaces the older one. Previous '
        'versions of replaced files are kept in each side’s sync trash. '
        'No files will be deleted.',
      );
    });

    test('newer wins degrades to ask on an untrusted clock', () {
      const newer = SyncRuleSet(
        direction: SyncDirection.bidirectional,
        conflictDefault: ConflictDefault.newerWins,
        preserveMtime: false,
      );
      expect(
        syncPolicySentence(_l10n, _pair(rules: newer))[2].text,
        startsWith('Files that differ are held as conflicts'),
      );
      expect(
        syncPolicySentence(
          _l10n,
          _pair(
            rules: const SyncRuleSet(
              direction: SyncDirection.bidirectional,
              conflictDefault: ConflictDefault.newerWins,
            ),
          ),
          SyncPairState(mtimeUnreliableLeft: true),
        ).map((c) => c.text),
        containsAll([
          'Files count as different only when their size differs.',
          'Modification dates proved unreliable for this pair, so only '
              'sizes are compared.',
          'Files that differ are held as conflicts for you to decide; '
              'nothing is replaced automatically.',
        ]),
      );
    });

    test('keep right and skip', () {
      expect(
        syncPolicySentence(
          _l10n,
          _pair(
            rules: const SyncRuleSet(
              direction: SyncDirection.bidirectional,
              conflictDefault: ConflictDefault.keepRight,
            ),
          ),
        )[2].text,
        'When a file differs, the version from “site-copy” replaces the '
        'other copy.',
      );
      final skip = syncPolicySentence(
        _l10n,
        _pair(
          rules: const SyncRuleSet(
            direction: SyncDirection.bidirectional,
            conflictDefault: ConflictDefault.skip,
          ),
        ),
      ).map((c) => c.text);
      expect(skip, contains('Files that differ are left alone.'));
      // Nothing is replaced, so no backup clause either.
      expect(skip, isNot(contains(contains('Previous versions'))));
    });
  });

  test('no combination ever claims only older files are replaced', () {
    for (final direction in SyncDirection.values) {
      for (final comparison in ComparisonMode.values) {
        for (final conflict in ConflictDefault.values) {
          final text = _text(
            _pair(
              rules: SyncRuleSet(
                direction: direction,
                comparison: comparison,
                conflictDefault: conflict,
              ),
            ),
          );
          expect(text.toLowerCase(), isNot(contains('older files')));
        }
      }
    }
  });
}
