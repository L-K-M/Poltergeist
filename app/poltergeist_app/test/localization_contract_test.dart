import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

const _generatedDartSuffixes = {'.freezed.dart', '.g.dart', '.mocks.dart'};

// Technical literals are reviewed per file so an allowlist cannot hide UI copy.
const _allowedTechnicalLiterals = <String, Set<String>>{
  'lib/main.dart': {
    r"'${supportDirectory.path}${Platform.pathSeparator}settings.json'",
    r"'${supportDirectory.path}${Platform.pathSeparator}bookmarks.json'",
  },
  // The production engine session's store file names and wiring literals
  // (paths inside the app-support directory, the review pane-tab id) —
  // plus the empty identity fallbacks of the bookmark-to-config mapping.
  'lib/services/engine_session.dart': {
    "'host_keys.json'",
    "'incidents.json'",
    "'identity_reads.jsonl'",
    "'review'",
    r"'$supportDirectoryPath$separator$_pinStoreFileName'",
    r"'$supportDirectoryPath$separator$_incidentStoreFileName'",
    r"'$supportDirectoryPath$separator$_identityAuditLogFileName'",
    "'bookmark.id'",
    "'bookmark has no embedded server identity'",
  },
  // The import wiring's POSIX-shaped ssh_config path (the core import
  // normalizes on `/`). The bookmark store it writes is the caller's now:
  // one instance serves the import command and the Connections surface.
  'lib/services/ssh_config_import_setup.dart': {
    r"'$home/.ssh/config'",
    "'~'",
  },
  'lib/services/app_preferences.dart': {
    "'layout.paneRatio'",
    "'window.left'",
    "'window.top'",
    "'window.width'",
    "'window.height'",
  },
  'lib/services/atomic_file.dart': {r"'.poltergeist-${uuidV4()}.tmp'"},
  // Ported Séance contracts (see docs/PORTS.md): the exception messages are
  // frozen port text, kept byte-identical to the source. D20 localization
  // applies where the UI renders them (the prompt-UI slice), not here.
  'lib/services/secure_master_key.dart': {
    r"'Saved secrets are unavailable: the OS keyring is locked '",
    r"'or missing. Unlock the login keyring (or install gnome-keyring), '",
    r"'then retry.'",
    r"'poltergeist.vault.masterKey.v1'",
    r"'${e.code} — $msg'",
    r"'the vault master key'",
    r"'Could not save $what to the OS keyring (${_describe(e)}). Unlock '",
    r"'the login keyring or install gnome-keyring, then try again.'",
  },
  'lib/services/file_stores.dart': {
    "'-'",
    "''",
    "':'",
    "'.'",
    r"'${file.path}.corrupt-$stamp'",
    r"'$host:$port'",
  },
  'lib/services/settings_store.dart': {
    "'settings root'",
    "'settings key'",
    r"'$path.corrupt-$stamp'",
    "'.'",
    "'-'",
    "''",
    "':'",
  },
  'lib/theme/app_theme.dart': {
    "'JetBrains Mono'",
    "'SF Mono'",
    "'Menlo'",
    "'Consolas'",
    "'DejaVu Sans Mono'",
    "'monospace'",
  },
  // Ported Séance JSONL record shape (see docs/PORTS.md): the field names
  // and separators are the frozen on-disk format, not UI copy.
  'lib/services/identity_audit_log.dart': {
    "'at'",
    "'serverId'",
    "'serverLabel'",
    "'path'",
    "'viaBookmark'",
    "'ok'",
    "'error'",
    "''",
    "'\${jsonEncode(event.toJson())}\\n'",
    "'\${kept.join('\\n')}\\n'",
    "'\\n'",
  },
  // Exception texts and audit-record fields — machine-facing data the
  // dialog renders inside an ARB-authored sentence, never standalone UI
  // copy (the reader's wording mirrors Séance's).
  'lib/services/identity_file_reader.dart': {
    "'\$_causeMessage (\$path)'",
    "'Could not read identity file \$path: \$_causeMessage'",
  },
  'lib/services/prompt_coordinator.dart': {
    "'No identity-file reader is wired'",
    "'\${data.username}@\${data.host}'",
  },
  // Monospace rendering of machine data (fingerprints, endpoints,
  // transcripts) plus list joins — no authored copy.
  'lib/ui/connection_status_panel.dart': {"'\\n'", "'monospace'"},
  'lib/ui/prompts/credential_dialog.dart': {"''", "'monospace'"},
  // Monospace rendering of machine data (endpoints, identity paths) plus
  // null-fallbacks for optional labels — no authored copy.
  'lib/ui/import/ssh_config_import_dialog.dart': {
    "''",
    "'monospace'",
    r"'${row.host.effectiveHost}:${row.port}'",
  },
  'lib/ui/prompts/host_key_dialog.dart': {"'monospace'", "'\$type\\n\$value'"},
  'lib/ui/adaptive_shell.dart': {
    "'primary-pane'",
    "'secondary-pane'",
    "'pane-splitter'",
  },
  'lib/ui/layout/pane_allocation.dart': {
    "'width'",
    "'must be finite and non-negative'",
    "'ratio'",
    "'must be finite'",
  },
  // Registered commands render from the registry keyed by id — widget
  // plumbing, not authored copy. The pane ids and focus-node labels key
  // to the engine's paneTabId channel identity (03 §3.2).
  'lib/ui/workspace_shell.dart': {
    "'command.\${command.id}'",
    "'connectionEngine is ignored when engineSession is provided'",
    "'pane.left'",
    "'pane.right'",
    "'pane.left.listing'",
    "'pane.right.listing'",
  },
  // The workspace controller's debug assert message — a dev-facing
  // invariant, never rendered.
  'lib/services/workspace_controller.dart': {
    "'Workspace panes must be distinct PaneController instances.'",
    "'Active pane must be one of this workspace\\'s panes.'",
  },
  // The pane controller's machine data: the home anchor the engine
  // expands, the dotfile filter prefix, the root path, the taxonomy
  // operations, and the fallback summaries for non-VFS faults (rendered
  // under ARB sentences in the pane, never standalone copy).
  'lib/services/pane_controller.dart': {
    "'~'",
    "'.'",
    "'/'",
    "'connect'",
    "'open'",
    "'list'",
    "'The connection could not be opened.'",
    "'The local browser could not be opened.'",
    "'The folder could not be listed.'",
  },
  // The location type's value semantics: toString output for debugging
  // and the path-separator arithmetic (POSIX and Windows forms).
  'lib/services/pane_location.dart': {
    "''",
    "'\\\\'",
    "'\\\\\\\\'",
    "'/'",
    "':'",
    r"'$trimmed\\'",
    r"'$parent\\'",
    "'LocalPaneLocation(\$path)'",
    "'RemotePaneLocation(\$serverId, \$path)'",
  },
  // The pane-command registry ids (D21 plumbing) and the pane view's
  // widget keys plus path-separator arithmetic — machine data, never
  // authored copy.
  'lib/ui/panes/pane_commands.dart': {
    "'go.enclosing'",
    "'go.open'",
    "'view.refresh'",
    "'pane.focusLeft'",
    "'pane.focusRight'",
    "'pane.swapFocus'",
    r"'Duplicate shortcut activator $activator: later command wins'",
  },
  'lib/ui/panes/pane_view.dart': {
    "'pane.left'",
    "'pane.cancel'",
    "'pane.progress'",
    "'pane.footer'",
    "'pane.error.retry'",
    "'pane.banner'",
    "'pane.banner.cancel'",
    r"'${controller.paneTabId}.path'",
    "''",
    "'/'",
    "'\\\\'",
  },
  // Byte-unit table, the unevaluated dash, and the trailing-".0" trim
  // — technical formatting (02 §2.3 rendering rules).
  'lib/ui/panes/pane_format.dart': {
    "'B'",
    "'KB'",
    "'MB'",
    "'GB'",
    "'TB'",
    "'—'",
    "'.0'",
    r"'$bytes ${_byteUnits[0]}'",
    r"'$text ${_byteUnits[unit]}'",
  },
  // The app.dart entry is the engine-seam assert (the demo entries left
  // with the deleted surface).
  'lib/app.dart': {
    "'connectionEngine is a test seam; engineSession supplies its own '",
    "'lanes. Provide one, not both.'",
  },
  // The persisted probe settings keys and record field names: the on-disk
  // settings.json shape, not UI copy (03 §6's per-server device-local map).
  'lib/services/probe_settings_store.dart': {
    "'probe.enabled'",
    "'probe.servers'",
    "'host'",
    "'port'",
    "'exposure'",
    "'connected'",
  },
  // The on-disk bookmarks.json shape (keys and quarantine stamp), the
  // pinned model's envelope-id prefix, and the registered command id —
  // persisted format and widget plumbing, not UI copy.
  'lib/services/bookmark_store.dart': {
    "'version'",
    "'bookmarks'",
    "'id'",
    "'bookmark store root'",
    "'bookmark store version \$version'",
    "'bookmark:\$id'",
    r"'$path.corrupt-${_quarantineStamp(now)}'",
    "'-'",
    "':'",
    "'.'",
    "''",
  },
  'lib/ui/import/ssh_config_import_command.dart': {
    "'favorite.importSshConfig'",
  },
  // The composed indicator's empty label for the "neither truth" case: it
  // paints nothing, so there is no wording to author.
  // '' is the none-appearance's empty label. The two long literals are a
  // developer-facing debug assert message, never rendered to users.
  'lib/ui/server_state_indicator.dart': {
    "''",
    "'Probe truth must be painted by ProbeStatusDot/ServerStateIndicator; '",
    "'ServerStateGlyph has no probe paint.'",
  },
  // The Connections surface's widget keys plus the endpoint line — machine
  // data (username@host:port) rendered beside ARB-authored copy.
  'lib/ui/connections/connections_view.dart': {
    "'connections-retry'",
    r"'connection.${server.serverId}'",
    r"'connection.review.${server.serverId}'",
    r"'connection.open.${server.serverId}'",
    r"'${server.username}@${server.host}:${server.port}'",
  },
  'lib/ui/connections/connections_command.dart': {
    "'view.connections'",
  },
  // Debug diagnostics only (`toString` of two immutable rows); never
  // rendered, so there is no copy to author.
  'lib/services/connection_status_controller.dart': {
    r"'PaneFailure($paneTabId, $message)'",
    r"'ConnectionServer($serverId, $label, $status)'",
  },
};

void main() {
  test('rejects representative authored user-facing literals', () {
    const unlocalizedSources = <({String path, String source})>[
      (
        path: 'lib/ui/example.dart',
        source: "void fixture() { const Text('Disconnected'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source:
            "void fixture() { const SelectableText('Server disconnected'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source: "void fixture() { const TextSpan(text: 'Transfer failed'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source:
            "void fixture() { const InputDecoration(hintText: 'Remote path'); }",
      ),
      (
        path: 'lib/services/example.dart',
        source: "String failureSummary() => 'Connection failed';",
      ),
    ];

    for (final fixture in unlocalizedSources) {
      final offenders = _findDisallowedLiterals(
        path: fixture.path,
        source: fixture.source,
      );

      expect(
        offenders,
        isNotEmpty,
        reason: 'missed literal: ${fixture.source}',
      );
    }
  });

  test('detects user-facing literals nested in interpolation', () {
    const source = "void fixture() { Text('\${wrap('Disconnected')}'); }";

    final offenders = _findDisallowedLiterals(
      path: 'lib/ui/example.dart',
      source: source,
    );

    expect(
      offenders.map((literal) => literal.lexeme),
      contains("'Disconnected'"),
    );
  });

  test('does not let interpolation syntax hide following literals', () {
    const source = '''
void fixture(String path) {
  '\${path.replaceAll('//', '/')}';
  Text('After');
}
''';

    final offenders = _findDisallowedLiterals(
      path: 'lib/ui/example.dart',
      source: source,
    );

    expect(offenders.map((literal) => literal.lexeme), contains("'After'"));
  });

  test('limits technical exceptions to their reviewed file', () {
    const source = "const paneRatioKey = 'layout.paneRatio';";

    expect(
      _findDisallowedLiterals(
        path: 'lib/services/app_preferences.dart',
        source: source,
      ),
      isEmpty,
    );
    expect(
      _findDisallowedLiterals(path: 'lib/ui/example.dart', source: source),
      isNotEmpty,
    );
  });

  test('keeps every technical exception live', () {
    for (final entry in _allowedTechnicalLiterals.entries) {
      final literals = _scanStringLiterals(
        File(entry.key).readAsStringSync(),
      ).map((literal) => literal.lexeme);

      expect(literals, containsAll(entry.value), reason: entry.key);
    }
  });

  test('ignores directives, comments, and generated files', () {
    const source = """
import 'package:flutter/widgets.dart';
import 'default.dart'
    if (dart.library.io) 'native.dart';
// Text('Comment only')
/* SelectableText('Also a comment') */
""";

    expect(
      _findDisallowedLiterals(path: 'lib/example.dart', source: source),
      isEmpty,
    );
    expect(
      _findDisallowedLiterals(path: 'lib/example.g.dart', source: "'copy'"),
      isEmpty,
    );
  });

  test('ignores generated output for every locale', () {
    const source = "String get actionLabel => 'Copier';";

    expect(
      _findDisallowedLiterals(
        path: 'lib/l10n/app_localizations_fr.dart',
        source: source,
      ),
      isEmpty,
    );
  });

  test('rejects source with parser diagnostics', () {
    const malformedSource = "void fixture() { Text('Hidden');";

    expect(
      () => _scanStringLiterals(malformedSource),
      throwsA(isA<StateError>()),
    );
  });

  test('authors user-facing strings only in ARB', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final relativePath = entity.path.replaceAll('\\', '/');
      final violations = _findDisallowedLiterals(
        path: relativePath,
        source: entity.readAsStringSync(),
      );
      offenders.addAll(
        violations.map(
          (violation) => '$relativePath:${violation.line}: ${violation.lexeme}',
        ),
      );
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('generated localization exclusions are present', () {
    for (final path in _generatedLocalizationPaths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'generated localization output is missing: $path',
      );
    }
  });
}

List<({int line, String lexeme})> _findDisallowedLiterals({
  required String path,
  required String source,
}) {
  if (_isGeneratedPath(path)) return const [];

  final allowed = _allowedTechnicalLiterals[path] ?? const <String>{};
  return [
    for (final literal in _scanStringLiterals(source))
      if (!allowed.contains(literal.lexeme))
        (
          line: '\n'.allMatches(source.substring(0, literal.offset)).length + 1,
          lexeme: literal.lexeme,
        ),
  ];
}

bool _isGeneratedPath(String path) {
  if (path.startsWith(_generatedLocalizationPrefix)) return true;

  return _generatedDartSuffixes.any(path.endsWith);
}

Iterable<({int offset, String lexeme})> _scanStringLiterals(String source) {
  final collector = _StringLiteralCollector();
  final result = parseString(content: source, throwIfDiagnostics: false);
  // Malformed code must fail this gate instead of hiding literals.
  if (result.errors.isNotEmpty) {
    throw StateError('source has parse errors; refusing to scan it');
  }

  result.unit.accept(collector);
  return collector.literals;
}

final class _StringLiteralCollector extends RecursiveAstVisitor<void> {
  final literals = <({int offset, String lexeme})>[];

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _record(node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _record(node);
    super.visitStringInterpolation(node);
  }

  void _record(StringLiteral node) {
    if (_belongsToDirective(node)) return;

    literals.add((offset: node.offset, lexeme: node.toSource()));
  }
}

bool _belongsToDirective(AstNode node) {
  AstNode? ancestor = node.parent;
  while (ancestor != null) {
    if (ancestor is Directive) return true;
    ancestor = ancestor.parent;
  }

  return false;
}
