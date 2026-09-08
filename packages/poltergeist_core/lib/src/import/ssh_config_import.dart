/// ssh_config import with preview + dedupe (D22; 07 §3.3).
///
/// Séance's `SshConfigImporter` — consumed through the git pin, never a
/// local copy — parses host blocks. What the pinned importer silently
/// discards is exactly what this module makes loud instead:
///
/// - a plain, top-level `Include` is resolved read-only at import time
///   (the same local-file trust already granted to `~/.ssh/config`
///   itself and any `IdentityFile` it references, D22), with OpenSSH's
///   recursion cap and cycle leniency;
/// - constructs the importer ignores (`ProxyCommand`, `ProxyJump`,
///   `Match` blocks, `Include` inside a host or match block) surface as
///   per-row limitations so the preview can badge "won't behave as in
///   ssh" instead of silently importing bookmarks that fail to connect
///   the way the user's real ssh does.
///
/// The module is pure: all filesystem access crosses the injected
/// [SshConfigFileSource] seam, implemented by the app with `dart:io`.
library;

import 'package:seance_core/seance_core.dart';

const int _defaultSshPort = 22;
const int _minimumSshPort = 1;
const int _maximumSshPort = 65535;

/// OpenSSH's own `Include` nesting cap; beyond it ssh refuses the whole
/// config, while import records an unresolved-include note and keeps the
/// preview usable.
const int _maximumIncludeDepth = 16;

/// Relative `Include` tokens resolve against `~/.ssh` (ssh_config(5)),
/// never the process cwd.
const String _relativeIncludeBase = '.ssh';

/// The starting path of an imported bookmark. An ssh config names no
/// remote directory; the pane home-canonicalizes on connect (03 §3.2's
/// recovery contract), so the stored value only needs to be a valid
/// absolute remote path (04 §2.1 refuses relatives at decode).
const String _importedRemotePath = '/';

/// Why an imported host won't behave as `ssh` would (D22's badge).
enum SshConfigImportLimitation {
  /// A `ProxyJump` applies to this host. D10 defers jump execution to a
  /// post-1.0 fast-follow, so the bookmark would connect directly, not
  /// through the jump.
  proxyJump,

  /// A `ProxyCommand` applies to this host (its own block, a wildcard
  /// `Host *` block, or a top-level default); Poltergeist never executes
  /// one.
  proxyCommand,

  /// The resolved config contains `Match` blocks. Poltergeist ignores
  /// them, and without evaluating their criteria any host could connect
  /// with different settings than ssh would use — so every row is badged,
  /// erring loud rather than silently wrong (D22's own bias).
  matchBlock,

  /// An `Include` inside this host's own block is not resolved; ssh would
  /// apply its directives to this host. Only top-level includes resolve.
  hostInclude,

  /// The block's `Port` is outside 1–65535; the bookmark model refuses
  /// such ports (04 §2.1 — they would mint malformed `hostkey:` ids) and
  /// the row cannot be imported at all.
  invalidPort,

  /// Connection defaults — `Port`, `User`, `HostName`, `IdentityFile` —
  /// set before the first block or inside a wildcard `Host *` block.
  /// ssh applies them to every connection; the pinned importer drops
  /// both shapes (a top-level directive lands in no host block, and a
  /// wildcard-only block is deliberately not a host), so the imported
  /// bookmark will not inherit them.
  wildcardDefaults,
}

/// How a top-level `Include` came to be left unresolved. Informational —
/// the preview stays usable — unlike [SshConfigImportLimitation].
enum SshConfigIncludeNote { cycle, depthExceeded, unreadable }

/// One unresolved-include note: what happened and to which path.
class SshConfigUnresolvedInclude {
  final SshConfigIncludeNote note;
  final String path;

  const SshConfigUnresolvedInclude(this.note, this.path);
}

/// The read-only local-file seam for import time, implemented by the app
/// layer (`dart:io`) so this pure package stays IO-free and testable.
abstract class SshConfigFileSource {
  /// Reads [path]'s text; null when the file is missing or unreadable.
  /// Missing `Include` targets are noted and skipped (ssh's own leniency
  /// toward missing targets); a missing root config fails the load with
  /// [SshConfigUnreadableException].
  Future<String?> readText(String path);

  /// Lexically ordered full paths of the regular files directly inside
  /// [directory] (symlinks to files follow); null when it can't be
  /// listed. `Include` globs expand over this listing in lexical order,
  /// matching ssh.
  Future<List<String>?> listLexical(String directory);
}

/// The root config could not be read; the preview cannot load.
class SshConfigUnreadableException implements Exception {
  final String path;

  const SshConfigUnreadableException(this.path);

  @override
  String toString() => 'SshConfigUnreadableException($path)';
}

/// One preview row: the pinned importer's host plus dedupe verdict,
/// limitations, and the default import/skip choice the preview starts from.
class SshConfigImportRow {
  /// Becomes the imported bookmark's id, so the choice the user made is
  /// bound to the row it was made about.
  final String id;

  /// The host block as parsed by Séance's pinned importer.
  final ImportedHost host;

  /// The file the host block was parsed from — the root config or one of
  /// its resolved top-level includes.
  final String sourcePath;

  /// Dedupe verdict against the caller's existing bookmarks by
  /// host+port+username (D22); [existingBookmarkLabel] names the match.
  final bool matchesExistingBookmark;
  final String? existingBookmarkLabel;

  /// A prior row in this same import already offers the same
  /// host+port+username; ssh's first-obtained-wins keeps the earlier row,
  /// so this one starts skipped. [earlierImportRowAlias] names it.
  final bool matchesEarlierImportRow;
  final String? earlierImportRowAlias;

  final List<SshConfigImportLimitation> limitations;

  bool get importByDefault =>
      !matchesExistingBookmark &&
      !matchesEarlierImportRow &&
      importable;

  /// False only for rows that can never produce a valid bookmark.
  bool get importable =>
      !limitations.contains(SshConfigImportLimitation.invalidPort);

  /// The dedupe key's username half; ssh configs may omit `User`, and the
  /// credential prompt resolves it at connect time.
  String get username => host.user ?? '';

  /// The dedupe key's port half — 22 unless the block names another.
  int get port => host.port ?? _defaultSshPort;

  const SshConfigImportRow({
    required this.id,
    required this.host,
    required this.sourcePath,
    this.matchesExistingBookmark = false,
    this.existingBookmarkLabel,
    this.matchesEarlierImportRow = false,
    this.earlierImportRowAlias,
    this.limitations = const [],
  });

  /// Builds the bookmark this row imports: a `remotePath` bookmark over
  /// an embedded identity (no second server model, 07 §3.3).
  /// `IdentityFile` becomes reference-style key auth — the path is stored
  /// verbatim ('~'-relative stays '~'-relative, 04 §2.1) and key material
  /// is only ever read at connect time through the audited reader (D18).
  ///
  /// [sortKey] defaults to the bookmark's own id — unique and non-blank
  /// (04 §2.1's decoder refuses blank), so rows keep deterministic order
  /// until M5's `BookmarkStore` re-keys them on first manual reorder
  /// (`sortKeyBetween`, 04 §2.5).
  Bookmark toBookmark({required DateTime now, String? sortKey}) {
    if (!importable) {
      throw StateError(
        'Row "${host.alias}" has an invalid port and cannot be imported',
      );
    }
    final keyPath = host.identityFile;
    final hasKey = keyPath != null && keyPath.trim().isNotEmpty;

    return Bookmark(
      id: id,
      kind: BookmarkKind.remotePath,
      label: host.alias,
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: host.effectiveHost,
          port: port,
          username: username,
          authMethod: hasKey ? AuthMethod.privateKey : AuthMethod.password,
          identityFilePath: hasKey ? keyPath : null,
        ),
      ),
      remotePath: _importedRemotePath,
      sortKey: sortKey ?? id,
      createdAt: now,
      updatedAt: now,
    );
  }
}

/// The loaded preview: rows in ssh's first-obtained order plus any
/// unresolved-include notes.
class SshConfigImportPreview {
  final List<SshConfigImportRow> rows;
  final List<SshConfigUnresolvedInclude> notices;

  const SshConfigImportPreview({required this.rows, required this.notices});
}

/// Loads `~/.ssh/config` previews: top-level include resolution (globs,
/// lexical order, relative-to-`~/.ssh`, ssh's depth cap), unsupported-
/// directive limitations, and host+port+username dedupe.
class SshConfigImportService {
  /// The user's real home; `~`-relative includes and identity paths hang
  /// off it. Empty disables `~` expansion (each such include is noted
  /// unreadable).
  final String homeDirectory;

  final SshConfigFileSource source;

  /// Mints row ids; the app passes its uuid v4 minter.
  final String Function() mintId;

  const SshConfigImportService({
    required this.homeDirectory,
    required this.source,
    required this.mintId,
  });

  /// Resolves [configPath] (absolute; the caller expands `~`), parses it
  /// through the pinned importer, and dedupes against
  /// [existingBookmarks]. Throws [SshConfigUnreadableException] when the
  /// root config cannot be read.
  Future<SshConfigImportPreview> loadPreview({
    required String configPath,
    Iterable<Bookmark> existingBookmarks = const [],
  }) async {
    final rootPath = _normalizeAbsolutePath(configPath);
    final text = await source.readText(rootPath);
    if (text == null) throw SshConfigUnreadableException(rootPath);

    final resolver = _Resolver(this);
    await resolver.resolveFile(
      path: rootPath,
      text: text,
      depth: 0,
      // Path-local: sibling branches re-read shared targets (ssh has no
      // global include memory either — it detects loops by depth, and a
      // diamond include is legal, just parsed twice).
      ancestors: {rootPath},
    );

    return _buildPreview(resolver, _existingEndpoints(existingBookmarks));
  }

  /// Canonical dedupe key (D22): host \0 port \0 username, built the
  /// same way for preview rows and existing bookmarks so the two sides
  /// can never drift apart. NUL can't appear in an ssh config token.
  /// The host lowercases — ssh hostnames resolve case-insensitively —
  /// while the username stays verbatim (its case sensitivity is
  /// platform-dependent).
  static String _endpointKey(String host, int port, String username) =>
      '${host.toLowerCase()}\u0000$port\u0000$username';

  SshConfigImportPreview _buildPreview(
    _Resolver resolver,
    Map<String, String> existingEndpoints,
  ) {
    final rows = <SshConfigImportRow>[];
    final firstByEndpoint = <String, String>{};

    for (final parsed in resolver.hosts) {
      final limitations = {
        ...resolver.globalLimitations,
        ...?resolver.hostLimitations[parsed.host.alias],
        if (parsed.host.proxyJump != null)
          SshConfigImportLimitation.proxyJump,
      };
      final parsedPort = parsed.host.port;
      if (parsedPort != null &&
          (parsedPort < _minimumSshPort || parsedPort > _maximumSshPort)) {
        limitations.add(SshConfigImportLimitation.invalidPort);
      }

      // Host+port+username — the host lowercased because DNS/ssh
      // resolution is case-insensitive; the username stays verbatim.
      final endpoint = _endpointKey(
        parsed.host.effectiveHost,
        parsed.host.port ?? _defaultSshPort,
        parsed.host.user ?? '',
      );
      final existingLabel = existingEndpoints[endpoint];
      final earlierAlias = firstByEndpoint[endpoint];

      rows.add(
        SshConfigImportRow(
          id: mintId(),
          host: parsed.host,
          sourcePath: parsed.sourcePath,
          matchesExistingBookmark: existingLabel != null,
          existingBookmarkLabel: existingLabel,
          matchesEarlierImportRow: earlierAlias != null,
          earlierImportRowAlias: earlierAlias,
          limitations: List.unmodifiable(limitations),
        ),
      );
      firstByEndpoint.putIfAbsent(endpoint, () => parsed.host.alias);
    }

    return SshConfigImportPreview(
      rows: List.unmodifiable(rows),
      notices: List.unmodifiable(resolver.notices),
    );
  }

  /// Existing endpoints keyed by host+port+username. Only embedded
  /// identities are comparable: a `serverConfigId` reference resolves its
  /// host/port/username from Séance's catalog at connect time (04 §2.2),
  /// so Poltergeist holds no endpoint to dedupe against.
  static Map<String, String> _existingEndpoints(Iterable<Bookmark> bookmarks) {
    final endpoints = <String, String>{};
    for (final bookmark in bookmarks) {
      for (final ref in _serverRefs(bookmark)) {
        final identity = ref.identity;
        if (identity == null) continue;
        endpoints[_endpointKey(
          identity.host,
          identity.port,
          identity.username,
        )] = bookmark.label;
      }
    }
    return endpoints;
  }

  /// Every server reference a bookmark carries — its own plus each
  /// workspace/sync endpoint — so dedupe sees all stored endpoints.
  static Iterable<BookmarkServerRef> _serverRefs(Bookmark bookmark) sync* {
    final server = bookmark.server;
    if (server != null) yield server;
    final left = bookmark.left?.server;
    if (left != null) yield left;
    final right = bookmark.right?.server;
    if (right != null) yield right;
    final source = bookmark.sync?.source.server;
    if (source != null) yield source;
    final destination = bookmark.sync?.destination.server;
    if (destination != null) yield destination;
  }
}

/// One host block parsed out of one file.
class _ParsedHost {
  final ImportedHost host;
  final String sourcePath;

  const _ParsedHost(this.host, this.sourcePath);
}

/// Walks the resolved config accumulating hosts, limitations, and
/// unresolved-include notices.
///
/// Per file, top-level `Include` lines cut the text into chunks so hosts
/// from included files land exactly where ssh would first-obtain them:
///
/// ```text
/// Include x.conf  ┐ chunk 0 (empty)    x's hosts land here
/// Host a          ┘ chunk 1
/// Include y.conf  ┐ chunk 2 (Host a)   y's hosts land after a
/// Host b          ┘ chunk 3
/// ```
///
/// Host/match context never crosses a cut (each cut sits in top-level
/// context, and `Include` does not itself change context), so each chunk
/// is scanned with a fresh context.
class _Resolver {
  final SshConfigImportService service;

  /// Hosts in first-obtained order across the whole resolved config.
  final List<_ParsedHost> hosts = [];

  /// Limitations applying to every row: Match blocks, top-level
  /// ProxyCommand/ProxyJump defaults, and wildcard-block defaults.
  final Set<SshConfigImportLimitation> globalLimitations = {};

  /// Per-alias limitations from the alias's own host block.
  final Map<String, Set<SshConfigImportLimitation>> hostLimitations = {};

  final List<SshConfigUnresolvedInclude> notices = [];

  _Resolver(this.service);

  Future<void> resolveFile({
    required String path,
    required String text,
    required int depth,
    required Set<String> ancestors,
    bool promoteTopLevelDefaults = true,
  }) async {
    // Host-context includes resolve after the file's own hosts: cutting
    // the text there would fragment the enclosing host block across
    // chunks (the pinned parser starts each chunk host-less and would
    // silently drop the block's post-include directives), and the
    // hostInclude badge already tells the user the block's own include
    // directives are lost. Only ssh's positional first-obtained order
    // deviates, and only when the same alias appears on both sides.
    //
    // deferredContext: a file pulled in from inside a Host block has its
    // block-less directives scoped to that host by ssh, so they must not
    // promote to global limitations (the hostInclude badge covers the
    // loss); Match blocks inside it still apply globally, as in ssh.
    final deferredIncludes = <(String args, bool deferredContext)>[];
    final chunks = _splitAtTopLevelIncludes(text, deferredIncludes);

    for (final chunk in chunks) {
      hosts.addAll(
        SshConfigImporter.parse(chunk.text)
            .map((host) => _ParsedHost(host, path)),
      );
      _scanUnsupported(chunk, promoteTopLevelDefaults);
      for (final args in chunk.includeArgsAfter) {
        await _resolveInclude(
          args: args,
          depth: depth,
          ancestors: ancestors,
          promoteTopLevelDefaults: promoteTopLevelDefaults,
        );
      }
    }
    for (final (args, deferredContext) in deferredIncludes) {
      await _resolveInclude(
        args: args,
        depth: depth,
        ancestors: ancestors,
        promoteTopLevelDefaults: !deferredContext && promoteTopLevelDefaults,
      );
    }
  }

  /// Cuts [text] so each chunk's [lines] are the text between top-level
  /// include lines and [includeArgsAfter] is the include that closed the
  /// chunk (its targets resolve between this chunk and the next). An
  /// include inside a host block does not cut — its raw line stays in the
  /// chunk (the pinned parser ignores it harmlessly inside a directives
  /// map) and its arguments land in [deferredIncludes] instead.
  List<_Chunk> _splitAtTopLevelIncludes(
    String text,
    List<(String, bool)> deferredIncludes,
  ) {
    final chunks = <_Chunk>[];
    var lines = <String>[];
    _BlockContext context = const _BlockContextTop();

    for (final raw in text.split('\n')) {
      final line = _stripComment(raw).trim();
      final key = _directiveKey(line)?.toLowerCase();

      if (key == 'include') {
        // Raw value: the include tokenizer is itself quote-aware, so a
        // quoted path with spaces must survive to it unstripped.
        final args = _rawDirectiveValue(line);
        if (context is _BlockContextTop) {
          chunks.add(_Chunk(List.of(lines), [args]));
          lines = [];
        } else if (context is _BlockContextHost) {
          // The line stays in the chunk text: the pinned parser ignores
          // it harmlessly as a directive, while the scan sees it and
          // badges the enclosing host (hostInclude). deferredContext
          // keeps the included file's block-less directives scoped to
          // that host, as ssh does.
          lines.add(raw);
          deferredIncludes.add((args, true));
        } else if (context is _BlockContextWildcard) {
          // ssh processes Include in place, so a file pulled in by
          // `Host *` behaves like the block's own directives: matching
          // every connection, and therefore promoting its block-less
          // proxy defaults to global limitations (the mirror image of
          // _scanUnsupported's wildcard case below).
          lines.add(raw);
          deferredIncludes.add((args, false));
        }
        // Inside a Match block the include stays unresolved: D22's badge
        // case, already covered by the matchBlock limitation on every row.
      } else {
        lines.add(raw);
        context = _advanceContext(context, key, line);
      }
    }
    chunks.add(_Chunk(lines, const []));
    return chunks;
  }

  /// Feeds the unsupported-directive scan for one chunk.
  void _scanUnsupported(_Chunk chunk, bool promoteTopLevelDefaults) {
    _BlockContext context = const _BlockContextTop();

    for (final raw in chunk.lines) {
      final line = _stripComment(raw).trim();
      if (line.isEmpty) continue;
      final key = _directiveKey(line)?.toLowerCase();
      if (key == null) continue;

      switch (key) {
        case 'host':
          context = _advanceContext(context, key, line);
        case 'match':
          // Match criteria evaluation is out of scope (that would
          // reimplement ssh semantics); any Match block badges every row.
          globalLimitations.add(SshConfigImportLimitation.matchBlock);
          context = _advanceContext(context, key, line);
        case 'proxycommand':
        case 'proxyjump':
          final limitation = key == 'proxycommand'
              ? SshConfigImportLimitation.proxyCommand
              : SshConfigImportLimitation.proxyJump;
          switch (context) {
            case _BlockContextTop():
              // Options before the first block apply to every connection —
              // unless this file arrived through a host-context include,
              // where ssh scopes them to the enclosing host (whose
              // hostInclude badge already covers the loss).
              if (promoteTopLevelDefaults) {
                globalLimitations.add(limitation);
              }
            case _BlockContextHost(alias: final alias):
              // Host-block ProxyJump arrives via ImportedHost.proxyJump;
              // the scan still covers ProxyCommand there.
              if (key == 'proxycommand') {
                _hostLimitations(alias).add(limitation);
              }
            case _BlockContextWildcard():
              // A wildcard block matches every connection, so its
              // behavior-affecting directives are global for preview
              // honesty even though the pinned importer drops the block.
              globalLimitations.add(limitation);
            case _BlockContextMatch():
              break; // the matchBlock badge already covers the row
          }
        case 'include':
          if (context case _BlockContextHost(alias: final alias)) {
            _hostLimitations(alias).add(SshConfigImportLimitation.hostInclude);
          }
          // Top-level includes resolve (the chunker cut them out); a
          // Match-block include is covered by the matchBlock badge.
        case 'port':
        case 'user':
        case 'hostname':
        case 'identityfile':
          // Connection defaults the pinned importer drops: top-level
          // directives land in no host block and a wildcard-only block
          // is deliberately not a host, yet ssh applies both to every
          // connection — the badge keeps that loss visible (D22).
          switch (context) {
            case _BlockContextTop():
              if (promoteTopLevelDefaults) {
                globalLimitations.add(
                  SshConfigImportLimitation.wildcardDefaults,
                );
              }
            case _BlockContextWildcard():
              globalLimitations.add(
                SshConfigImportLimitation.wildcardDefaults,
              );
            case _BlockContextHost():
            case _BlockContextMatch():
              break; // the pin applies host-block values; Match covers all
          }
        default:
          break;
      }
    }
  }

  Set<SshConfigImportLimitation> _hostLimitations(String alias) =>
      hostLimitations.putIfAbsent(alias, () => {});

  Future<void> _resolveInclude({
    required String args,
    required int depth,
    required Set<String> ancestors,
    required bool promoteTopLevelDefaults,
  }) async {
    if (depth >= _maximumIncludeDepth) {
      notices.add(
        SshConfigUnresolvedInclude(SshConfigIncludeNote.depthExceeded, args),
      );
      return;
    }

    for (final token in _tokenizeWhitespace(args)) {
      final targets = await _expandToken(token);
      for (final target in targets) {
        if (ancestors.contains(target)) {
          notices.add(
            SshConfigUnresolvedInclude(SshConfigIncludeNote.cycle, target),
          );
          continue;
        }

        final text = await service.source.readText(target);
        if (text == null) {
          // ssh ignores missing include targets; the note keeps the
          // preview honest about what was not read.
          notices.add(
            SshConfigUnresolvedInclude(
              SshConfigIncludeNote.unreadable,
              target,
            ),
          );
          continue;
        }

        await resolveFile(
          path: target,
          text: text,
          depth: depth + 1,
          ancestors: {...ancestors, target},
          promoteTopLevelDefaults: promoteTopLevelDefaults,
        );
      }
    }
  }

  /// Resolves one include token to concrete target path(s): a literal
  /// path yields itself (or nothing, noted unreadable, when it cannot be
  /// resolved); a glob metacharacter path expands against the parent
  /// directory's lexical listing. Glob expansion is silent when nothing
  /// matches — ssh's own behavior for a no-match glob — so only the
  /// literal paths above carry notes.
  Future<List<String>> _expandToken(String token) async {
    final home = service.homeDirectory;

    void noteUnreadable() => notices.add(
      SshConfigUnresolvedInclude(SshConfigIncludeNote.unreadable, token),
    );

    // `~otheruser` needs the passwd database; there is no home to
    // resolve it against here.
    if (token.startsWith('~') && token != '~' && !token.startsWith('~/')) {
      noteUnreadable();
      return const [];
    }
    // Only `~`-relative and bare-relative tokens need a home (ssh
    // anchors the latter to ~/.ssh); absolute paths resolve without one.
    final needsHome = token.startsWith('~') || !token.startsWith('/');
    if (home.isEmpty && needsHome) {
      noteUnreadable();
      return const [];
    }

    var path = expandHomePath(token, environment: {'HOME': home});
    if (!path.startsWith('/')) {
      path = '$home/$_relativeIncludeBase/$path';
    }
    path = _normalizeAbsolutePath(path);

    // ssh's Include globs run with GLOB_BRACE, so `{a,b}` expands; this
    // subset cannot expand braces, so such a token must surface as a
    // note instead of silently matching nothing (or matching the
    // literal braces ssh would never try).
    if (path.contains('{') || path.contains('}')) {
      noteUnreadable();
      return const [];
    }

    if (!_hasGlobMetacharacter(path)) return [path];

    final slash = path.lastIndexOf('/');
    final directory = slash == 0 ? '/' : path.substring(0, slash);
    final pattern = path.substring(slash + 1);
    if (_hasGlobMetacharacter(directory)) {
      // Multi-component globs (conf.d/*/*.conf) would need recursive
      // directory expansion, which this single-listing seam cannot do;
      // ssh's glob(3) would expand them, so the gap must surface as a
      // note instead of silently matching nothing.
      noteUnreadable();
      return const [];
    }
    final listing = await service.source.listLexical(directory);
    if (listing == null) return const [];
    // Sort here too: lexical order is ssh's rule, and the source's own
    // ordering must not decide preview order.
    final matches = [
      for (final entry in listing)
        if (_globMatch(pattern, entry.substring(entry.lastIndexOf('/') + 1)))
          entry,
    ]..sort();
    return matches;
  }

  static bool _hasGlobMetacharacter(String path) =>
      path.contains('*') || path.contains('?') || path.contains('[');

  /// POSIX-glob subset for one path component: `*`/`?` never cross `/`
  /// (they match a single component by construction), `[...]`/`[!...]`
  /// are character classes, and a leading dot never matches unless the
  /// pattern names it — glob(3)'s common subset. Both arguments are
  /// single path components by construction — [_expandToken] splits the
  /// pattern at the last `/` and matches basenames from one directory
  /// listing — so the leading-dot rule needs no per-component walk.
  /// Bracket classes have
  /// no escapes (`\` is literal) and `^` is not negation, so the class
  /// body is re-escaped for the regex translation; malformed classes
  /// (empty, reversed ranges) match nothing rather than throwing, and a
  /// `]` first in the class is a literal member, as in glob(3).
  static bool _globMatch(String pattern, String name) {
    // glob(3) never matches a leading dot unless the pattern starts
    // with one: `*.conf` skips `.hidden.conf` and `.#backup.conf`.
    if (name.startsWith('.') && !pattern.startsWith('.')) return false;

    final regex = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      final c = pattern[i];
      if (c == '*') {
        regex.write('[^/]*');
      } else if (c == '?') {
        regex.write('[^/]');
      } else if (c == '[') {
        // glob(3): a `]` first in the class (or right after `!`) is a
        // literal member, so the closing-bracket scan must start past
        // it — `[]x]` is the class {],x}, and `[!]x]` is "not ] or x".
        var start = i + 1;
        if (start < pattern.length && pattern[start] == '!') start++;
        if (start < pattern.length && pattern[start] == ']') start++;
        final end = pattern.indexOf(']', start);
        if (end < 0) {
          regex.write(RegExp.escape(c));
        } else {
          var klass = pattern.substring(i + 1, end);
          final negated = klass.startsWith('!');
          if (negated) klass = klass.substring(1);
          // Regex metacharacters are literals inside a glob class.
          klass = klass.replaceAll('\\', '\\\\');
          // A leading `]` is a literal member; escape it after the
          // backslash pass so the escape itself survives intact.
          if (klass.startsWith(']')) klass = '\\]${klass.substring(1)}';
          if (klass.startsWith('^')) klass = '\\^${klass.substring(1)}';
          // `[]` and `[!]` match nothing in glob — the regex `[^]`
          // would match any character instead.
          if (klass.isEmpty) return false;
          regex.write('[${negated ? '^' : ''}$klass]');
          i = end;
        }
      } else {
        regex.write(RegExp.escape(c));
      }
      i++;
    }
    regex.write(r'$');
    try {
      return RegExp(regex.toString()).hasMatch(name);
    } on FormatException {
      // Malformed class (e.g. a reversed range [z-a]): fail closed —
      // glob(3) would not have matched either.
      return false;
    }
  }
}

/// Collapses `.`/`..`/duplicate separators so cycle detection compares
/// the same textual path ssh would re-read.
String _normalizeAbsolutePath(String path) {
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) {
        parts.removeLast();
      }
      continue;
    }
    parts.add(part);
  }
  return '/${parts.join('/')}';
}

class _Chunk {
  final List<String> lines;
  final List<String> includeArgsAfter;

  const _Chunk(this.lines, this.includeArgsAfter);

  String get text => lines.join('\n');
}

/// Where a line sits: before any block, in a named `Host` block, in a
/// wildcard-only `Host` block, or in a `Match` block.
sealed class _BlockContext {
  const _BlockContext();

  factory _BlockContext.fromHostLine(String value) {
    final alias = _tokenizeHostPatterns(value)
        .firstWhere(_isConcretePattern, orElse: () => '');
    return alias.isEmpty
        ? const _BlockContextWildcard()
        : _BlockContextHost(alias);
  }
}

class _BlockContextTop extends _BlockContext {
  const _BlockContextTop();
}

class _BlockContextHost extends _BlockContext {
  final String alias;

  const _BlockContextHost(this.alias);
}

class _BlockContextWildcard extends _BlockContext {
  const _BlockContextWildcard();
}

class _BlockContextMatch extends _BlockContext {
  const _BlockContextMatch();
}

/// The context after a `host`/`match` line; every other key keeps it.
_BlockContext _advanceContext(
  _BlockContext context,
  String? key,
  String line,
) {
  switch (key?.toLowerCase()) {
    case 'host':
      return _BlockContext.fromHostLine(_directiveValue(line));
    case 'match':
      return const _BlockContextMatch();
    default:
      return context;
  }
}

// ─── Line-level helpers ────────────────────────────────────────────────
//
// These mirror (deliberately, and only for line shape) the pinned
// importer's own rules — comment-at-`#`, `Key value` or `Key=value`,
// quote stripping — so a line the pin drops is dropped here too. No host
// parsing lives in this file; hosts only ever come from
// `SshConfigImporter.parse`.

/// Strips from the first `#`, matching the pinned importer's comment rule.
String _stripComment(String line) {
  final idx = line.indexOf('#');
  return idx >= 0 ? line.substring(0, idx) : line;
}

/// The directive key of a `Key value` / `Key=value` line; null when the
/// line has no key (or is empty).
String? _directiveKey(String line) {
  final eq = line.indexOf('=');
  final sp = line.indexOf(RegExp(r'\s'));
  int cut;
  if (eq >= 0 && (sp < 0 || eq < sp)) {
    cut = eq;
  } else if (sp >= 0) {
    cut = sp;
  } else {
    return line.isEmpty ? null : line;
  }
  final key = line.substring(0, cut).trim();
  return key.isEmpty ? null : key;
}

/// The value side of a directive line (quotes stripped, like the pin).
String _directiveValue(String line) =>
    _rawDirectiveValue(line).replaceAll('"', '');

/// The value side of a directive line with quotes intact.
String _rawDirectiveValue(String line) {
  final eq = line.indexOf('=');
  final sp = line.indexOf(RegExp(r'\s'));
  int cut;
  if (eq >= 0 && (sp < 0 || eq < sp)) {
    cut = eq;
  } else if (sp >= 0) {
    cut = sp;
  } else {
    return '';
  }
  return line.substring(cut + 1).trim();
}

/// Host patterns split on every whitespace run, mirroring the pinned
/// importer's own `split(RegExp(r'\s+'))` rule: a carriage return,
/// vertical tab, or form feed between patterns separates them there, so
/// the scan must key per-host badges by the same tokens or the badge is
/// silently dropped. Quote stripping already happened in
/// [_directiveValue], exactly as the pin strips quotes before
/// tokenizing.
List<String> _tokenizeHostPatterns(String value) =>
    value.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

/// Whitespace-separated tokens for include arguments, double-quote
/// aware (paths may carry spaces). Only space and tab separate — the
/// include tokenizer owns its own quote rule, deliberately distinct
/// from the pin-mirroring [_tokenizeHostPatterns].
List<String> _tokenizeWhitespace(String value) {
  final tokens = <String>[];
  final current = StringBuffer();
  var inQuotes = false;

  for (final c in value.split('')) {
    if (c == '"') {
      inQuotes = !inQuotes;
    } else if ((c == ' ' || c == '\t') && !inQuotes) {
      if (current.isNotEmpty) tokens.add(current.toString());
      current.clear();
    } else {
      current.write(c);
    }
  }
  if (current.isNotEmpty) tokens.add(current.toString());
  return tokens;
}

/// Mirrors the pinned importer's wildcard test so an alias exists here
/// exactly when a row exists there.
bool _isConcretePattern(String pattern) =>
    !pattern.contains('*') &&
    !pattern.contains('?') &&
    !pattern.startsWith('!');
