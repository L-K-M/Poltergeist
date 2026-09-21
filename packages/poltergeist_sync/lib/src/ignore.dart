// Exclude rules (05 §3): gitignore-style, evaluated in a fixed order —
// per-pair rules first, then the includeHidden:false `.*`, then the app
// defaults so a `!` re-include can never resurrect them — plus the
// effective trash root, which the engine always excludes regardless of
// rules (05 §6's trashPathLeft/trashPathRight comment).

/// gitignore-style exclude rules with the engine's fixed ordering:
/// per-pair `excludeGlobs`, then the `.*` hidden pattern when
/// includeHidden is false, then [appDefaults] — evaluated in list order,
/// last match wins, and a negated match only un-ignores paths no later
/// pattern re-excludes. Because the app defaults sit last, no per-pair
/// `!` can re-include them (05 §3) — and because the `.*` hidden pattern
/// also sits after the per-pair rules, no `!` can re-include a hidden
/// file while includeHidden is false either.
///
/// Supported pattern syntax: `*` and `?` (never crossing `/`), `**`
/// (leading `**/`, trailing `/**`, or bare), a trailing `/` for
/// directory-only, a leading `/` or mid-pattern `/` to anchor at the
/// root, `!` negation, and `\!`/`\#` escapes. gitignore's character
/// classes (`[...]`) and other backslash escapes are NOT supported —
/// they match literally.
final class SyncIgnoreRules {
  SyncIgnoreRules({
    List<String> excludeGlobs = const [],
    bool includeHidden = true,
    String? trashRelativePath,
  }) : _patterns = [
         for (final glob in excludeGlobs) _IgnorePattern.parse(glob),
         if (!includeHidden) _IgnorePattern.parse('.*'),
         for (final glob in appDefaults) _IgnorePattern.parse(glob),
       ],
       _excludedPrefixes = trashRelativePath == null
           ? const []
           : [trashRelativePath] {
    if (trashRelativePath != null &&
        (trashRelativePath.isEmpty ||
            trashRelativePath.contains('\\') ||
            trashRelativePath.startsWith('/') ||
            trashRelativePath.endsWith('/') ||
            trashRelativePath.split('/').any(
              (s) => s.isEmpty || s == '.' || s == '..',
            ))) {
      throw ArgumentError.value(
        trashRelativePath,
        'trashRelativePath',
        'must be a /-separated relative path with no leading or trailing '
            'separator and no . or .. segments',
      );
    }
  }

  /// Compiled-in patterns (always excluded; never surfaced as
  /// user-editable globs): `.DS_Store`, `Thumbs.db`, `desktop.ini`,
  /// `.poltergeist*` (in-root trash default AND temp siblings
  /// `.poltergeist-*.tmp`), `*.poltergeist-*` (overwrite backups —
  /// user-named destinations named that lose their backups to the next
  /// overwrite of the real name, accepted per 03 §2.2).
  static const List<String> appDefaults = [
    '.DS_Store',
    'Thumbs.db',
    'desktop.ini',
    '.poltergeist*',
    '*.poltergeist-*',
  ];

  final List<_IgnorePattern> _patterns;
  final List<String> _excludedPrefixes;

  /// Whether [relativePath] ('/'-separated, no leading or trailing
  /// separator) is excluded. An entry under an excluded directory is
  /// excluded even though its own pattern check would pass — git's
  /// excluded-directory pruning, applied on lookup so callers that never
  /// walked the parent still get the right answer.
  bool isExcluded(String relativePath, {required bool isDirectory}) {
    var path = relativePath;
    while (true) {
      final slash = path.lastIndexOf('/');
      if (slash < 0) break;
      path = path.substring(0, slash);
      if (_isExcludedHere(path, isDirectory: true)) return true;
    }
    return _isExcludedHere(relativePath, isDirectory: isDirectory);
  }

  bool _isExcludedHere(String relativePath, {required bool isDirectory}) {
    for (final prefix in _excludedPrefixes) {
      if (relativePath == prefix ||
          relativePath.startsWith('$prefix/')) {
        return true;
      }
    }
    final basename = relativePath.substring(relativePath.lastIndexOf('/') + 1);
    var excluded = false;
    var matched = false;
    for (final pattern in _patterns) {
      if (pattern.matches(relativePath, basename, isDirectory)) {
        matched = true;
        excluded = !pattern.negated;
      }
    }
    return matched && excluded;
  }
}

final class _IgnorePattern {
  _IgnorePattern._(this.negated, this.dirOnly, this._anchored, this._regex);

  factory _IgnorePattern.parse(String raw) {
    var pattern = raw.trim();
    var negated = false;
    var escaped = false;
    if (pattern.startsWith('!')) {
      negated = true;
      pattern = pattern.substring(1);
    } else if (pattern.startsWith(r'\!') || pattern.startsWith(r'\#')) {
      escaped = true;
      pattern = pattern.substring(1);
    }
    if (!escaped && (pattern.startsWith('#') || pattern.isEmpty)) {
      return _IgnorePattern._(false, false, true, RegExp('a^')); // never matches
    }
    var dirOnly = false;
    if (pattern.endsWith('/')) {
      dirOnly = true;
      pattern = pattern.substring(0, pattern.length - 1);
    }
    // gitignore: a separator anywhere but trailing anchors the pattern to
    // the root; slash-free patterns float against every basename.
    final anchored = pattern.contains('/');
    if (pattern.startsWith('/')) pattern = pattern.substring(1);
    return _IgnorePattern._(
      negated,
      dirOnly,
      anchored,
      RegExp('^${_translate(pattern)}\$'),
    );
  }

  final bool negated;
  final bool dirOnly;
  final bool _anchored;
  final RegExp _regex;

  bool matches(String relativePath, String basename, bool isDirectory) {
    if (dirOnly && !isDirectory) return false;
    return _regex.hasMatch(_anchored ? relativePath : basename);
  }

  /// `*`/`?` never cross `/`; `**` crosses (leading `**/` = zero or more
  /// directories, trailing `/**` = everything inside, bare `**` =
  /// everything).
  static String _translate(String pattern) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < pattern.length) {
      if (pattern.startsWith('**/', i)) {
        buffer.write('(?:[^/]+/)*');
        i += 3;
      } else if (pattern.startsWith('**', i) && i + 2 == pattern.length) {
        buffer.write('.*');
        i += 2;
      } else {
        final c = pattern.codeUnitAt(i);
        buffer.write(
          switch (c) {
            0x2A /* * */ => '[^/]*',
            0x3F /* ? */ => '[^/]',
            _ => RegExp.escape(pattern[i]),
          },
        );
        i++;
      }
    }
    return buffer.toString();
  }
}
