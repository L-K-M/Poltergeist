import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/editor_syntax.dart';

// Ported from Séance
// app/seance_app/test/editor_syntax_test.dart @ 2e6d1f1 — extended with
// the 06 §7 additions' detection and tokenizer smoke tests (css, ruby,
// perl, lua, the Apache dot-config mappings, env-aware shebangs).

List<SyntaxToken> _ofType(List<SyntaxToken> tokens, SyntaxTokenType type) =>
    tokens.where((token) => token.type == type).toList();

String _slice(String text, SyntaxToken token) =>
    text.substring(token.start, token.end);

void main() {
  group('language detection', () {
    test('resolves well-known extensions', () {
      expect(syntaxLanguageFor('/srv/deploy.py')?.id, 'python');
      expect(syntaxLanguageFor('/etc/nginx/nginx.conf')?.id, 'ini');
      expect(syntaxLanguageFor('/tmp/data.json')?.id, 'json');
      expect(syntaxLanguageFor('compose.yaml')?.id, 'yaml');
      expect(syntaxLanguageFor('main.go')?.id, 'c-family');
      expect(syntaxLanguageFor('query.sql')?.id, 'sql');
      expect(syntaxLanguageFor('notes.xyz'), isNull);
      expect(syntaxLanguageFor('README'), isNull);
    });

    test('resolves well-known basenames before extensions', () {
      expect(syntaxLanguageFor('/app/Dockerfile')?.id, 'dockerfile');
      expect(syntaxLanguageFor('Dockerfile.prod')?.id, 'dockerfile');
      expect(syntaxLanguageFor('/home/user/.bashrc')?.id, 'shell');
      expect(syntaxLanguageFor('/home/user/.ssh/config')?.id, 'ini');
      expect(syntaxLanguageFor('/etc/ssh/sshd_config')?.id, 'ini');
      expect(syntaxLanguageFor('Makefile')?.id, 'shell');
    });

    test('falls back to the shebang line', () {
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/deploy',
          firstLine: '#!/usr/bin/env bash',
        )?.id,
        'shell',
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/python3',
        )?.id,
        'python',
      );
      expect(
        syntaxLanguageFor('/usr/local/bin/x', firstLine: 'not a shebang'),
        isNull,
      );
    });

    // 06 §7's additions — detection coverage for the new families.
    test('§7: css covers .css/.scss/.less', () {
      expect(syntaxLanguageFor('site.css')?.id, 'css');
      expect(syntaxLanguageFor('theme.scss')?.id, 'css');
      expect(syntaxLanguageFor('legacy.less')?.id, 'css');
    });

    test('§7: ruby covers extensions, convention basenames, shebangs', () {
      expect(syntaxLanguageFor('app.rb')?.id, 'ruby');
      expect(syntaxLanguageFor('tasks.rake')?.id, 'ruby');
      expect(syntaxLanguageFor('my.gemspec')?.id, 'ruby');
      expect(syntaxLanguageFor('Gemfile')?.id, 'ruby');
      expect(syntaxLanguageFor('Rakefile')?.id, 'ruby');
      expect(syntaxLanguageFor('config.ru')?.id, 'ruby');
      // Directly and after env (06 §7).
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/ruby',
        )?.id,
        'ruby',
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/env ruby',
        )?.id,
        'ruby',
      );
    });

    test('§7: perl covers .pl/.pm and shebangs', () {
      expect(syntaxLanguageFor('script.pl')?.id, 'perl');
      expect(syntaxLanguageFor('Module.pm')?.id, 'perl');
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/perl',
        )?.id,
        'perl',
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/env perl',
        )?.id,
        'perl',
      );
    });

    test('§7: lua covers .lua and the pinned interpreter spellings', () {
      expect(syntaxLanguageFor('init.lua')?.id, 'lua');
      for (final interpreter in [
        'lua',
        'luajit',
        'lua5.1',
        'lua5.2',
        'lua5.3',
        'lua5.4',
      ]) {
        expect(
          syntaxLanguageFor(
            '/usr/local/bin/tool',
            firstLine: '#!/usr/bin/$interpreter',
          )?.id,
          'lua',
          reason: interpreter,
        );
        expect(
          syntaxLanguageFor(
            '/usr/local/bin/tool',
            firstLine: '#!/usr/bin/env $interpreter',
          )?.id,
          'lua',
          reason: 'env $interpreter',
        );
      }
      // No over-capture: spellings that merely start with "lua" are not
      // claimed (06 §7).
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/lua5.5',
        ),
        isNull,
      );
      expect(
        syntaxLanguageFor(
          '/usr/local/bin/tool',
          firstLine: '#!/usr/bin/luabridge',
        ),
        isNull,
      );
    });

    test('§7: Apache dot-configs map to ini', () {
      expect(syntaxLanguageFor('/srv/www/.htaccess')?.id, 'ini');
      expect(syntaxLanguageFor('/srv/www/.htpasswd')?.id, 'ini');
    });
  });

  group('tokenizer', () {
    test('shell: comments, keywords, strings, numbers, variables', () {
      const text = '# note\necho "hi" 42 \$HOME\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.shell);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(comments, hasLength(1));
      expect(_slice(text, comments.single), '# note');
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('echo'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('"hi"'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        contains('42'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('\$HOME'),
      );
    });

    test('shell: a hash inside a word is not a comment', () {
      final tokens = tokenizeSyntax('path/foo#bar\n', SyntaxLanguages.shell);
      expect(_ofType(tokens, SyntaxTokenType.comment), isEmpty);
    });

    test(
      'python: hash comments need no boundary; triple quotes span lines',
      () {
        const text = 'x=1# c\n"""doc\nstring"""\n';
        final tokens = tokenizeSyntax(text, SyntaxLanguages.python);
        final comments = _ofType(tokens, SyntaxTokenType.comment);
        expect(comments.map((t) => _slice(text, t)), contains('# c'));
        final strings = _ofType(tokens, SyntaxTokenType.string);
        expect(strings, hasLength(1));
        expect(_slice(text, strings.single), '"""doc\nstring"""');
      },
    );

    test('javascript: block comments and template strings', () {
      const text = '/* a\nb */ const x = `tpl\nline`; // end\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.javascript);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(comments.map((t) => _slice(text, t)), contains('/* a\nb */'));
      expect(comments.map((t) => _slice(text, t)), contains('// end'));
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('`tpl\nline`'),
      );
    });

    test('strings: escapes are honored and unterminated stops at newline', () {
      const text = '"a\\"b" "open\nnext';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.json);
      final strings = _ofType(tokens, SyntaxTokenType.string);
      expect(_slice(text, strings.first), '"a\\"b"');
      expect(_slice(text, strings.last), '"open');
    });

    test('numbers: hex, decimals, exponents', () {
      const text = 'a = 0xFF; b = 3.14e-2; c = 10_000';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.cFamily);
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        containsAll(['0xFF', '3.14e-2', '10_000']),
      );
    });

    test('yaml: keys are meta unless consumed by another token', () {
      const text = 'name: test\n# port: none\nport: 8080\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.yaml);
      final meta = _ofType(tokens, SyntaxTokenType.meta);
      expect(meta.map((t) => _slice(text, t)), ['name', 'port']);
      expect(
        _ofType(tokens, SyntaxTokenType.number).map((t) => _slice(text, t)),
        contains('8080'),
      );
    });

    test('ini: sections, comments, booleans', () {
      const text = '[core]\n; note\nenabled = TRUE\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.ini);
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('[core]'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('; note'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('TRUE'),
      );
    });

    test('dockerfile: instructions are case-insensitive keywords', () {
      const text = 'FROM debian:stable\nrun apt-get update\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.dockerfile);
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['FROM', 'run']),
      );
    });

    // 06 §7's additions — one tokenizer smoke test per new family.
    test('§7 css: block comments, property meta, at-rule keywords', () {
      const text = '/* note */\n@media screen {\n  color: red;\n}\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.css);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('/* note */'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.meta).map((t) => _slice(text, t)),
        contains('color'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('media'),
      );
    });

    test('§7 ruby: bounded hash comments, keywords, strings', () {
      const text = '# note\ndef greet\n  puts "hi"\nend\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.ruby);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('# note'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['def', 'end', 'puts']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('"hi"'),
      );
      // The boundary flag: `x#y` is not a comment start.
      expect(
        _ofType(
          tokenizeSyntax('x#y\n', SyntaxLanguages.ruby),
          SyntaxTokenType.comment,
        ),
        isEmpty,
      );
    });

    test('§7 perl: # glued to a sigil or delimiter is not a comment', () {
      // The last index of an array, `#` as a quote or regex delimiter, and
      // `#` inside a regex: each used to grey out the rest of its line
      // (ported from Séance's fix of the same rule).
      for (final line in [
        r'for my $i (0..$#list) { print $i }',
        r's#/usr#/opt#;',
        r'my @w = qw#a b#;',
        r'$line =~ s/#.*//;',
      ]) {
        final tokens = tokenizeSyntax('$line\n', SyntaxLanguages.perl);
        expect(
          _ofType(tokens, SyntaxTokenType.comment),
          isEmpty,
          reason: line,
        );
      }
    });

    test('§7 perl: hash comments after whitespace, keywords, strings', () {
      const text = 'my \$x = 1; # tail\nsub f { print "hi" }\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.perl);
      expect(
        _ofType(tokens, SyntaxTokenType.comment).map((t) => _slice(text, t)),
        contains('# tail'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        containsAll(['my', 'sub', 'print']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('"hi"'),
      );
    });

    test('§7 lua: --[[ ]] spans lines, [[ ]] strings, -- line comments', () {
      // The pins 06 §7 requires: a spanning --[[ ]] comment and a plain
      // [[ ]] string, proving the block-comment rule wins over both the
      // -- line rule and the [[ string rule.
      const text =
          '--[[ block\ncomment ]]\nlocal s = [[ multi\nline ]]\n'
          '-- tail\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.lua);
      final comments = _ofType(tokens, SyntaxTokenType.comment);
      expect(
        comments.map((t) => _slice(text, t)),
        containsAll(['--[[ block\ncomment ]]', '-- tail']),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.string).map((t) => _slice(text, t)),
        contains('[[ multi\nline ]]'),
      );
      expect(
        _ofType(tokens, SyntaxTokenType.keyword).map((t) => _slice(text, t)),
        contains('local'),
      );
    });

    test('tokens are ordered and never overlap', () {
      const text =
          'if [ -f "\$HOME/.bashrc" ]; then # load\n  source '
          '"\$HOME/.bashrc" 2>/dev/null\nfi\n';
      final tokens = tokenizeSyntax(text, SyntaxLanguages.shell);
      for (var i = 1; i < tokens.length; i++) {
        expect(tokens[i].start, greaterThanOrEqualTo(tokens[i - 1].end));
      }
    });
  });

  group('search', () {
    test('is case-insensitive by default and reports exact ranges', () {
      final matches = findSearchMatches('Beta beta BETA', 'beta');
      expect(matches, hasLength(3));
      expect(matches.first, const TextRange(start: 0, end: 4));
      expect(matches.last, const TextRange(start: 10, end: 14));
      expect(
        findSearchMatches('Beta beta BETA', 'beta', caseSensitive: true),
        hasLength(1),
      );
    });

    test('caps the match count at the limit', () {
      final text = 'a' * 50;
      expect(findSearchMatches(text, 'a', limit: 10), hasLength(10));
    });

    test('an empty query has no matches', () {
      expect(findSearchMatches('anything', ''), isEmpty);
    });
  });

  group('span building', () {
    test('search hits overlay token colors without splitting order', () {
      const text = 'abcdef';
      final spans = buildHighlightedSpans(
        text: text,
        tokens: const [SyntaxToken(0, 4, SyntaxTokenType.string)],
        matches: const [TextRange(start: 2, end: 6)],
        activeMatchIndex: 0,
        theme: EditorSyntaxTheme.dark,
      );
      final texts = spans.map((s) => (s as TextSpan).text).toList();
      expect(texts, ['ab', 'cd', 'ef']);
      final styles = spans.map((s) => (s as TextSpan).style).toList();
      expect(styles[0]?.color, EditorSyntaxTheme.dark.string);
      expect(styles[0]?.backgroundColor, isNull);
      expect(
        styles[1]?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
      expect(
        styles[2]?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
      expect(styles[2]?.color, EditorSyntaxTheme.dark.activeMatchForeground);
    });

    test('inactive matches use the plain hit colors', () {
      final spans = buildHighlightedSpans(
        text: 'xx yy',
        tokens: const [],
        matches: const [
          TextRange(start: 0, end: 2),
          TextRange(start: 3, end: 5),
        ],
        activeMatchIndex: 1,
        theme: EditorSyntaxTheme.dark,
      );
      final styles = spans.map((s) => (s as TextSpan).style).toList();
      expect(
        styles.first?.backgroundColor,
        EditorSyntaxTheme.dark.matchBackground,
      );
      expect(
        styles.last?.backgroundColor,
        EditorSyntaxTheme.dark.activeMatchBackground,
      );
    });

    test('reassembles the exact source text', () {
      const text = '# c\nkey: "value" 42\n';
      final spans = buildHighlightedSpans(
        text: text,
        tokens: tokenizeSyntax(text, SyntaxLanguages.yaml),
        matches: findSearchMatches(text, 'e'),
        activeMatchIndex: 0,
        theme: EditorSyntaxTheme.light,
      );
      expect(spans.map((s) => (s as TextSpan).text).join(), text);
    });
  });
}
