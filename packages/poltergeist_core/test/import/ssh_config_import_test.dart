import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// In-memory file source: `files` maps path→text; `dirs` maps
/// directory→listing in any order (the service sorts glob results
/// itself).
class _FakeSource implements SshConfigFileSource {
  final Map<String, String> files;
  final Map<String, List<String>> dirs;

  _FakeSource({this.files = const {}, this.dirs = const {}});

  @override
  Future<String?> readText(String path) async => files[path];

  @override
  Future<List<String>?> listLexical(String directory) async => dirs[directory];
}

const _home = '/home/tester';
const _configPath = '$_home/.ssh/config';

SshConfigImportService _service(_FakeSource source) {
  var next = 0;
  return SshConfigImportService(
    homeDirectory: _home,
    source: source,
    mintId: () => 'id-${next++}',
  );
}

/// An existing bookmark carrying one embedded identity.
Bookmark _existingBookmark(
  String label, {
  required String host,
  int port = 22,
  String user = 'alice',
}) {
  return Bookmark(
    id: 'existing-$label',
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: host,
        port: port,
        username: user,
        authMethod: AuthMethod.password,
      ),
    ),
    sortKey: '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

Future<SshConfigImportPreview> _load(
  String text, {
  _FakeSource? source,
  List<Bookmark> existing = const [],
}) {
  final src =
      source ??
      _FakeSource(files: {_configPath: text});
  return _service(src).loadPreview(
    configPath: _configPath,
    existingBookmarks: existing,
  );
}

void main() {
  test('imports hosts through the pinned importer', () async {
    final preview = await _load('''
Host web-01
  HostName web.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519

Host nas
''');

    expect(preview.rows, hasLength(2));
    final web = preview.rows.first;
    expect(web.host.alias, 'web-01');
    expect(web.host.effectiveHost, 'web.example.com');
    expect(web.sourcePath, _configPath);
    expect(web.importByDefault, isTrue);
    expect(web.limitations, isEmpty);

    final nas = preview.rows[1];
    expect(nas.host.effectiveHost, 'nas');
    expect(nas.port, 22);
    expect(nas.username, '');
  });

  test('IdentityFile maps to reference-style key auth, verbatim path',
      () async {
    final now = DateTime.utc(2026, 9, 8);
    final preview = await _load('''
Host keyed
  HostName keyed.example.com
  IdentityFile ~/.ssh/id_ed25519

Host passworded
  HostName p.example.com

Host blankKey
  HostName b.example.com
  IdentityFile
''');

    final keyed = preview.rows[0].toBookmark(now: now);
    final identity = keyed.server!.identity!;
    expect(keyed.kind, BookmarkKind.remotePath);
    expect(identity.authMethod, AuthMethod.privateKey);
    // Reference-style: the path travels verbatim ('~' survives, 04 §2.1);
    // no key material is read at import time.
    expect(identity.identityFilePath, '~/.ssh/id_ed25519');
    expect(identity.host, 'keyed.example.com');
    expect(identity.port, 22);
    expect(identity.username, '');

    expect(
      preview.rows[1].toBookmark(now: now).server!.identity!.authMethod,
      AuthMethod.password,
    );
    expect(
      preview.rows[2].toBookmark(now: now).server!.identity!.authMethod,
      AuthMethod.password,
    );
    expect(
      preview.rows[2].toBookmark(now: now).server!.identity!.identityFilePath,
      isNull,
    );
  });

  test('imported bookmarks round-trip through the 04 §2.1 decode contract',
      () async {
    final now = DateTime.utc(2026, 9, 8);
    final preview = await _load('''
Host keyed
  HostName keyed.example.com
  Port 2200
  User alice
  IdentityFile ~/.ssh/id_ed25519
''');

    final bookmark = preview.rows.single.toBookmark(now: now);
    final decoded = Bookmark.fromJson(
      bookmark.toJson(),
      recordId: 'bookmark:${bookmark.id}',
    );
    expect(decoded.server!.identity!.identityFilePath, '~/.ssh/id_ed25519');
    expect(decoded.server!.identity!.port, 2200);
    expect(decoded.server!.identity!.username, 'alice');
    expect(decoded.server!.identity!.authMethod, AuthMethod.privateKey);
    expect(decoded.label, 'keyed');
  });

  test('dedupes against existing bookmarks by host+port+username', () async {
    final preview = await _load(
      'Host dup\n  HostName web.example.com\n  Port 2222\n  User deploy\n'
      'Host other-port\n  HostName web.example.com\n  Port 23\n  User deploy\n'
      'Host other-user\n  HostName web.example.com\n  Port 2222\n  User bob\n'
      'Host other-host\n  HostName other.example.com\n  Port 2222\n  User deploy\n',
      existing: [_existingBookmark('Prod web', host: 'web.example.com', port: 2222, user: 'deploy')],
    );

    expect(preview.rows[0].matchesExistingBookmark, isTrue);
    expect(preview.rows[0].existingBookmarkLabel, 'Prod web');
    expect(preview.rows[0].importByDefault, isFalse);

    expect(preview.rows[1].matchesExistingBookmark, isFalse);
    expect(preview.rows[2].matchesExistingBookmark, isFalse);
    expect(preview.rows[3].matchesExistingBookmark, isFalse);
  });

  test('dedupe ignores host case, not username case', () async {
    final preview = await _load(
      'Host same-host\n  HostName github.com\n  User deploy\n'
      'Host same-user\n  HostName GitHub.com\n  User Deploy\n',
      existing: [
        _existingBookmark(
          'Prod GitHub',
          host: 'GitHub.com',
          port: 22,
          user: 'deploy',
        ),
      ],
    );

    // SSH hostnames resolve case-insensitively, so the hosts are the
    // same endpoint; usernames stay verbatim (case sensitivity there is
    // platform-dependent).
    expect(preview.rows[0].matchesExistingBookmark, isTrue);
    expect(preview.rows[1].matchesExistingBookmark, isFalse);
  });

  test('dedupe sees workspace and sync endpoint identities too', () async {
    final now = DateTime.utc(2026, 9, 8);
    final sync = SavedSyncSpec(
      source: BookmarkLocation(
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'nas.local',
            username: 'alice',
            authMethod: AuthMethod.password,
          ),
        ),
        path: '/vol1',
      ),
      destination: const BookmarkLocation(path: '~/backup'),
    );
    final workspace = Bookmark(
      id: 'w',
      kind: BookmarkKind.workspace,
      label: 'Work pair',
      left: BookmarkLocation(
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'nas.local',
            username: 'alice',
            authMethod: AuthMethod.password,
          ),
        ),
        path: '/vol1',
      ),
      right: const BookmarkLocation(path: '~/mirror'),
      sync: sync,
      sortKey: '',
      createdAt: now,
      updatedAt: now,
    );

    final preview = await _load(
      'Host nas\n  HostName nas.local\n  User alice\n',
      existing: [workspace],
    );

    expect(preview.rows.single.matchesExistingBookmark, isTrue);
    expect(preview.rows.single.existingBookmarkLabel, 'Work pair');
  });

  test('serverConfigId references cannot be deduped against', () async {
    final now = DateTime.utc(2026, 9, 8);
    final shared = Bookmark(
      id: 's',
      kind: BookmarkKind.remotePath,
      label: 'Seance catalog entry',
      server: const BookmarkServerRef(serverConfigId: 'seance-1'),
      sortKey: '',
      createdAt: now,
      updatedAt: now,
    );

    final preview = await _load(
      'Host web\n  HostName web.example.com\n',
      existing: [shared],
    );

    // Séance catalog refs carry no endpoint in Poltergeist (04 §2.2), so
    // no duplicate is claimed.
    expect(preview.rows.single.matchesExistingBookmark, isFalse);
  });

  test('a second row for the same endpoint starts skipped', () async {
    final preview = await _load('''
Host primary
  HostName web.example.com
  User deploy

Host alias-two
  HostName web.example.com
  User deploy
''');

    expect(preview.rows[0].matchesEarlierImportRow, isFalse);
    expect(preview.rows[0].importByDefault, isTrue);
    expect(preview.rows[1].matchesEarlierImportRow, isTrue);
    expect(preview.rows[1].earlierImportRowAlias, 'primary');
    expect(preview.rows[1].importByDefault, isFalse);
  });

  test('badges every row when the config uses Match blocks', () async {
    final preview = await _load('''
Match host *.internal
  Port 2222

Host web
  HostName web.example.com

Host nas
''');

    expect(preview.rows, hasLength(2));
    for (final row in preview.rows) {
      expect(row.limitations, contains(SshConfigImportLimitation.matchBlock));
    }
  });

  test('badges per-host ProxyJump and global ProxyJump defaults', () async {
    final preview = await _load('''
ProxyJump bastion.example.com

Host jumped
  HostName j.example.com
  ProxyJump hop.example.com

Host direct
  HostName d.example.com
''');

    expect(preview.rows, hasLength(2));
    expect(
      preview.rows[0].limitations,
      contains(SshConfigImportLimitation.proxyJump),
    );
    // The global default reaches every row.
    expect(
      preview.rows[1].limitations,
      contains(SshConfigImportLimitation.proxyJump),
    );
  });

  test('badges per-host and global ProxyCommand', () async {
    final preview = await _load('''
Host tunneled
  HostName t.example.com
  ProxyCommand nc %h %p

Host plain
  HostName p.example.com

Host *
  ProxyCommand /usr/bin/corkscrew proxy 8080 %h %p
''');

    expect(
      preview.rows[0].limitations,
      contains(SshConfigImportLimitation.proxyCommand),
    );
    // The wildcard block matches every connection, so every row is badged.
    expect(
      preview.rows[1].limitations,
      contains(SshConfigImportLimitation.proxyCommand),
    );
    // The wildcard block itself contributes no row.
    expect(preview.rows, hasLength(2));
  });

  test('a top-level Include between hosts lands in first-obtained position',
      () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Include $_home/.ssh/config.d/tail.conf

Host last
''',
        '$_home/.ssh/config.d/tail.conf': 'Host from-include\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['from-include', 'last'],
    );
    expect(preview.rows.first.sourcePath, '$_home/.ssh/config.d/tail.conf');
    expect(preview.notices, isEmpty);
  });

  test('Include before hosts lands its hosts first', () async {
    final source = _FakeSource(files: {
      _configPath: '''
Include $_home/.ssh/config.d/head.conf

Host main
''',
      '$_home/.ssh/config.d/head.conf': 'Host early\n',
    });

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['early', 'main'],
    );
  });

  test('Include globs expand in lexical order', () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/*.conf\n',
        '$dir/b.conf': 'Host bravo\n',
        '$dir/a.conf': 'Host alpha\n',
        '$dir/c.txt': 'Host ignored-suffix\n',
      },
      dirs: {
        dir: ['$dir/b.conf', '$dir/a.conf', '$dir/c.txt', '$dir/z-no-ext'],
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['alpha', 'bravo'],
    );
  });

  test('relative and quoted Include arguments resolve', () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Include work.conf "my configs/main.conf" other.conf
''',
        '$_home/.ssh/work.conf': 'Host work\n',
        '$_home/.ssh/my configs/main.conf': 'Host quoted\n',
        '$_home/.ssh/other.conf': 'Host other\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['work', 'quoted', 'other'],
    );
  });

  test('Include with ~ expansion and nesting', () async {
    final source = _FakeSource(files: {
      _configPath: 'Include ~/.ssh/outer.conf\n',
      '$_home/.ssh/outer.conf': 'Host outer\n\nInclude ~/.ssh/inner.conf\n',
      '$_home/.ssh/inner.conf': 'Host inner\n',
    });

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['outer', 'inner'],
    );
  });

  test('missing, glob-empty, and unresolvable includes are noted, not fatal',
      () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: '''
Include $_home/.ssh/missing.conf
Include $dir/*.conf
Include ~otheruser/keys.conf
''',
      },
      dirs: {dir: const []},
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows, isEmpty);
    // The empty glob is silently nothing (ssh's behavior); only the
    // literal missing file and the unresolvable user path are noted.
    expect(preview.notices, hasLength(2));
    expect(preview.notices[0].note, SshConfigIncludeNote.unreadable);
    expect(preview.notices[0].path, '$_home/.ssh/missing.conf');
    expect(preview.notices[1].note, SshConfigIncludeNote.unreadable);
    expect(preview.notices[1].path, '~otheruser/keys.conf');
  });

  test('multi-component include globs are noted unsupported, not silent',
      () async {
    final source = _FakeSource(
      files: {
        _configPath: 'Include $_home/.ssh/conf.d/*/*.conf\n',
        '$_home/.ssh/conf.d/a/x.conf': 'Host nested\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows, isEmpty);
    // ssh's glob(3) would expand across components; this resolver
    // cannot, so the whole token must surface as unreadable rather
    // than silently matching nothing.
    expect(preview.notices, hasLength(1));
    expect(preview.notices.single.note, SshConfigIncludeNote.unreadable);
    expect(preview.notices.single.path, '$_home/.ssh/conf.d/*/*.conf');
  });

  test('brace include globs are noted unsupported, not silent', () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/{a,b}*.conf\n',
        '$dir/alpha.conf': 'Host alpha\n',
        '$dir/beta.conf': 'Host beta\n',
      },
      dirs: {
        dir: ['$dir/alpha.conf', '$dir/beta.conf'],
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    // ssh's Include globs run with GLOB_BRACE, so `{a,b}*.conf` expands
    // to two patterns; this subset cannot expand braces, so the token
    // must surface as a note instead of silently matching nothing.
    expect(preview.rows, isEmpty);
    expect(preview.notices, hasLength(1));
    expect(preview.notices.single.note, SshConfigIncludeNote.unreadable);
    expect(preview.notices.single.path, '$dir/{a,b}*.conf');
  });

  test('a brace in an include directory is noted, not silent', () async {
    final source = _FakeSource(
      files: {
        _configPath: 'Include $_home/.ssh/conf{1,2}/*.conf\n',
        '$_home/.ssh/conf1/a.conf': 'Host one\n',
        '$_home/.ssh/conf2/b.conf': 'Host two\n',
      },
      dirs: {
        '$_home/.ssh/conf1': ['$_home/.ssh/conf1/a.conf'],
        '$_home/.ssh/conf2': ['$_home/.ssh/conf2/b.conf'],
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows, isEmpty);
    expect(preview.notices, hasLength(1));
    expect(preview.notices.single.note, SshConfigIncludeNote.unreadable);
    expect(preview.notices.single.path, '$_home/.ssh/conf{1,2}/*.conf');
  });

  test('an include cycle is detected per branch; diamonds parse twice',
      () async {
    final source = _FakeSource(files: {
      _configPath: '''
Include $_home/.ssh/a.conf
Include $_home/.ssh/b.conf
''',
      '$_home/.ssh/a.conf': 'Host from-a\n\nInclude $_home/.ssh/shared.conf\n',
      '$_home/.ssh/b.conf': 'Host from-b\n\nInclude $_home/.ssh/shared.conf\n',
      '$_home/.ssh/shared.conf': 'Host shared-host\n',
    });

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['from-a', 'shared-host', 'from-b', 'shared-host'],
      reason: 'shared.conf parses once per branch, like ssh',
    );
    // A diamond is legal ssh — re-parsing a shared target must not
    // emit a spurious cycle or unreadable notice.
    expect(preview.notices, isEmpty);

    // A self-including file cycles instead.
    final cycling = _FakeSource(files: {
      _configPath: 'Include $_home/.ssh/self.conf\n',
      '$_home/.ssh/self.conf': 'Include $_home/.ssh/self.conf\n',
    });
    final cyclePreview =
        await _service(cycling).loadPreview(configPath: _configPath);
    expect(cyclePreview.rows, isEmpty);
    expect(
      cyclePreview.notices.single.note,
      SshConfigIncludeNote.cycle,
    );
  });

  test('nesting beyond the depth cap is noted, not fatal', () async {
    // The cap is 16 (lib's _maximumIncludeDepth); 20 links make the
    // depth check — not a missing l20.conf — the thing that fires.
    final files = <String, String>{_configPath: 'Include $_home/.ssh/l0.conf\n'};
    for (var i = 0; i < 20; i++) {
      files['$_home/.ssh/l$i.conf'] = 'Include $_home/.ssh/l${i + 1}.conf\n';
    }
    final preview = await _service(_FakeSource(files: files))
        .loadPreview(configPath: _configPath);

    expect(preview.rows, isEmpty);
    expect(
      preview.notices.map((n) => n.note),
      contains(SshConfigIncludeNote.depthExceeded),
    );
  });

  test('an Include inside a Host block badges the host, resolves after it',
      () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Host hostwithinclude
  Include $_home/.ssh/extra.conf

Host clean
''',
        '$_home/.ssh/extra.conf': 'Host from-include\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    // The enclosing block stays whole (its own row is complete), the
    // include's hosts import after the file's own, and the badge still
    // warns that the block's include directives are lost.
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['hostwithinclude', 'clean', 'from-include'],
    );
    expect(
      preview.rows[0].limitations,
      contains(SshConfigImportLimitation.hostInclude),
    );
    expect(preview.rows[1].limitations, isEmpty);
    expect(preview.rows[2].limitations, isEmpty);
  });

  test('Include inside a Match block is not resolved and badges everything',
      () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Match host *.internal
  Include $_home/.ssh/internal.conf

Host web
''',
        '$_home/.ssh/internal.conf': 'Host never-imported\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows, hasLength(1));
    expect(preview.rows.single.host.alias, 'web');
    expect(
      preview.rows.single.limitations,
      contains(SshConfigImportLimitation.matchBlock),
    );
  });

  test('an absolute include resolves without a home directory', () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Include /etc/ssh/shared.conf
Include ~/home-only.conf
Include relative.conf
''',
        '/etc/ssh/shared.conf': 'Host absolute\n',
      },
    );
    final service = SshConfigImportService(
      homeDirectory: '',
      source: source,
      mintId: () => 'id',
    );

    final preview = await service.loadPreview(configPath: _configPath);
    // Absolute paths need no home; only `~`-relative and bare-relative
    // tokens (which ssh anchors to ~/.ssh) are noted unreadable.
    expect(preview.rows.map((r) => r.host.alias).toList(), ['absolute']);
    expect(
      preview.notices.map((n) => n.note),
      everyElement(SshConfigIncludeNote.unreadable),
    );
    expect(preview.notices.map((n) => n.path).toList(), [
      '~/home-only.conf',
      'relative.conf',
    ]);
  });

  test('a duplicate alias merges its limitations across blocks', () async {
    final preview = await _load('''
Host web
  ProxyCommand nc %h %p

Host web
  HostName second.example.com
''');

    // ssh merges same-pattern blocks; the badge follows the alias into
    // both rows rather than only the block that carried the directive.
    for (final row in preview.rows) {
      expect(
        row.limitations,
        contains(SshConfigImportLimitation.proxyCommand),
      );
    }
  });

  test('ports outside 1–65535 make the row unimportable', () async {
    final preview = await _load('''
Host zero
  Port 0

Host huge
  Port 70000

Host fine
  Port 65535
''');

    expect(preview.rows[0].importable, isFalse);
    expect(preview.rows[0].importByDefault, isFalse);
    expect(
      preview.rows[0].limitations,
      contains(SshConfigImportLimitation.invalidPort),
    );
    expect(() => preview.rows[0].toBookmark(now: DateTime.utc(2026, 9, 8)),
        throwsStateError);

    expect(preview.rows[1].importable, isFalse);
    expect(preview.rows[2].importable, isTrue);
    expect(preview.rows[2].port, 65535);
  });

  test('a missing root config fails the load', () async {
    await expectLater(
      _service(_FakeSource()).loadPreview(configPath: _configPath),
      throwsA(isA<SshConfigUnreadableException>()),
    );
  });

  test('glob classes treat backslash literally instead of throwing',
      () async {
    final dir = '$_home/.ssh/config.d';
    // POSIX glob classes have no escapes: `[ab\]` is the class
    // {a, b, backslash} closed by that `]`. A naive regex translation
    // reads `\]` as an escaped bracket and throws FormatException.
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/[ab\\]?.conf\n',
        '$dir/a1.conf': 'Host a-one\n',
        '$dir/z1.conf': 'Host z-one\n',
      },
      dirs: {
        dir: ['$dir/a1.conf', '$dir/z1.conf'],
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows.map((r) => r.host.alias).toList(), ['a-one']);
  });

  test('glob classes treat ^ as a literal, not regex negation', () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/[^a].conf\n',
        '$dir/a.conf': 'Host alpha\n',
        '$dir/b.conf': 'Host bravo\n',
      },
      dirs: {
        dir: ['$dir/a.conf', '$dir/b.conf'],
      },
    );

    // In glob, `[^a]` matches the character ^ or a — not "anything but
    // a". Only alpha therefore matches; regex negation would pick bravo.
    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows.map((r) => r.host.alias).toList(), ['alpha']);
  });

  test('empty glob classes match nothing', () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/[!].conf\n',
        '$dir/b.conf': 'Host bravo\n',
      },
      dirs: {
        dir: ['$dir/b.conf'],
      },
    );

    // `[!]` (and `[]`) match nothing in glob; the regex translation
    // `[^]` would match any character.
    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows, isEmpty);
  });

  test('a leading ] in a glob class is a literal member', () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/[]x].conf\nInclude $dir/[!]x].conf\n',
        '$dir/x.conf': 'Host ex\n',
        '$dir/y.conf': 'Host why\n',
        '$dir/].conf': 'Host literal-bracket\n',
      },
      dirs: {
        dir: ['$dir/x.conf', '$dir/y.conf', '$dir/].conf'],
      },
    );

    // glob(3): a `]` right after `[` or `[!` belongs to the class, so
    // `[]x].conf` is "one of ] or x, then .conf" — matching ].conf and
    // x.conf — and `[!]x].conf` is "not ] and not x, then .conf",
    // matching only y.conf. Lexical order puts ].conf before x.conf.
    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['literal-bracket', 'ex', 'why'],
    );
  });

  test('a reversed character range fails closed instead of throwing',
      () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/[z-a].conf\n',
        '$dir/a.conf': 'Host alpha\n',
      },
      dirs: {
        dir: ['$dir/a.conf'],
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows, isEmpty);
  });

  test("globs never match dotfiles unless the pattern leads with a dot",
      () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/*.conf\n',
        '$dir/visible.conf': 'Host visible\n',
        '$dir/.hidden.conf': 'Host hidden\n',
        '$dir/.#backup.conf': 'Host backup\n',
      },
      dirs: {
        dir: [
          '$dir/.#backup.conf',
          '$dir/.hidden.conf',
          '$dir/visible.conf',
        ],
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows.map((r) => r.host.alias).toList(), ['visible']);
  });

  test('a leading-dot glob pattern does match dotfiles', () async {
    final dir = '$_home/.ssh/config.d';
    final source = _FakeSource(
      files: {
        _configPath: 'Include $dir/.*.conf\n',
        '$dir/.hidden.conf': 'Host hidden\n',
        '$dir/visible.conf': 'Host visible\n',
      },
      dirs: {
        dir: ['$dir/.hidden.conf', '$dir/visible.conf'],
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(preview.rows.map((r) => r.host.alias).toList(), ['hidden']);
  });

  test('block-less proxy defaults in a host-deferred include stay scoped',
      () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Host hostwithinclude
  Include $_home/.ssh/extra.conf

Host clean
''',
        // The pre-block ProxyJump applies (in ssh) to the enclosing host
        // only — it must not badge every row as a global default.
        '$_home/.ssh/extra.conf':
            'ProxyJump bastion.example.com\n\nHost extra\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['hostwithinclude', 'clean', 'extra'],
    );
    for (final row in preview.rows) {
      expect(
        row.limitations,
        isNot(contains(SshConfigImportLimitation.proxyJump)),
      );
    }
    // The enclosing host still wears the hostInclude badge for the lost
    // directive.
    expect(
      preview.rows[0].limitations,
      contains(SshConfigImportLimitation.hostInclude),
    );
  });

  test('a file included from a wildcard block promotes its proxy defaults',
      () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Host *
  Include $_home/.ssh/proxy.conf

Host web
  HostName web.example.com
''',
        '$_home/.ssh/proxy.conf':
            'ProxyJump bastion.example.com\n\nHost extra\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    // ssh processes Include in place, so a file pulled in by `Host *`
    // behaves like the wildcard block's own directives: its block-less
    // proxy default applies to every connection and must badge every
    // row (the wildcard block's own lines already do, per _scanUnsupported).
    // Row order itself stays main-file-first for host-context includes —
    // the documented chunking deviation in _Resolver.resolveFile; "in
    // place" here governs directive scope, not row order.
    expect(
      preview.rows.map((r) => r.host.alias).toList(),
      ['web', 'extra'],
    );
    for (final row in preview.rows) {
      expect(
        row.limitations,
        contains(SshConfigImportLimitation.proxyJump),
      );
    }
  });

  test('multi-pattern Host blocks surface one row per the pin', () async {
    final preview = await _load('''
Host alpha beta
  ProxyCommand nc %h %p
''');

    // The pinned importer keeps only the first concrete pattern as the
    // alias (one row); the badge follows that row.
    expect(preview.rows.map((r) => r.host.alias).toList(), ['alpha']);
    expect(
      preview.rows.single.limitations,
      contains(SshConfigImportLimitation.proxyCommand),
    );
  });

  test('Host * connection defaults badge every row', () async {
    final preview = await _load('''
Host *
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519

Host web
  HostName web.example.com
''');

    // The pinned importer drops the wildcard block, so none of these
    // defaults reach the row — ssh would connect as deploy@…:2222 with
    // that key; the badge keeps the preview honest (D22).
    expect(preview.rows, hasLength(1));
    expect(
      preview.rows.single.limitations,
      contains(SshConfigImportLimitation.wildcardDefaults),
    );
    expect(preview.rows.single.username, '');
    expect(preview.rows.single.host.identityFile, isNull);
  });

  test('top-level connection defaults badge every row', () async {
    final preview = await _load('''
User deploy
Port 2222

Host web
  HostName web.example.com
''');

    // Options before the first block apply to every connection in ssh;
    // the pinned importer drops them, so the badge must carry the loss.
    expect(preview.rows, hasLength(1));
    expect(
      preview.rows.single.limitations,
      contains(SshConfigImportLimitation.wildcardDefaults),
    );
  });

  test('host-block defaults never badge; the pin applies them', () async {
    final preview = await _load('''
Host web
  HostName web.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
''');

    expect(preview.rows, hasLength(1));
    expect(
      preview.rows.single.limitations,
      isNot(contains(SshConfigImportLimitation.wildcardDefaults)),
    );
    expect(preview.rows.single.username, 'deploy');
    expect(preview.rows.single.port, 2222);
    expect(preview.rows.single.host.identityFile, '~/.ssh/id_ed25519');
  });

  test('deferred-include defaults stay scoped, like proxy defaults',
      () async {
    final source = _FakeSource(
      files: {
        _configPath: '''
Host hostwithinclude
  HostName web.example.com
  Include $_home/.ssh/defaults.conf

Host clean
  HostName clean.example.com
''',
        '$_home/.ssh/defaults.conf': 'User deploy\nPort 2222\n',
      },
    );

    final preview = await _service(source).loadPreview(configPath: _configPath);
    // ssh scopes a host-deferred include's block-less options to the
    // enclosing host; the hostInclude badge already covers the loss, so
    // no row may carry the global-defaults badge.
    for (final row in preview.rows) {
      expect(
        row.limitations,
        isNot(contains(SshConfigImportLimitation.wildcardDefaults)),
      );
    }
    expect(
      preview.rows[0].limitations,
      contains(SshConfigImportLimitation.hostInclude),
    );
  });
}
