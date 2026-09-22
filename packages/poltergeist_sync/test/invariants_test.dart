@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:test/test.dart';

/// The 05 §11 / 08 §3.3 static invariants, walked over this package's own
/// AST (never a substring scan): the sync engine is pure Dart over
/// RemoteFileSystem — no Flutter, no dartssh2, no dart:io Process (the
/// previewable-engine property dies the day code can exec rsync), and
/// dart:io only inside the short, commented allowlist below (journal.dart
/// gets filesystem access when it lands; nothing else does).
void main() {
  const allowedDartIo = <String>{
    // journal.dart — crash-safe JSONL appends (05 §11/§8). Fails closed:
    // any other file importing dart:io breaks this test.
    'journal.dart',
  };

  List<String> violations(Directory libDir) {
    final violations = <String>[];
    final files =
        libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final result = parseString(
        content: file.readAsStringSync(),
        path: file.path,
      );
      expect(
        result.errors,
        isEmpty,
        reason: '${file.path} must parse cleanly',
      );
      final visitor = _InvariantVisitor(
        file.path,
        allowedDartIo.contains(file.uri.pathSegments.last),
      );
      result.unit.visitChildren(visitor);
      violations.addAll(visitor.violations);
    }
    return violations;
  }

  test('no banned imports or Process references in lib/', () async {
    // Resolve through the package URI — `dart test` does not guarantee a
    // package-root working directory.
    final libUri = await Isolate.resolvePackageUri(
      Uri.parse('package:poltergeist_sync/poltergeist_sync.dart'),
    );
    final libDir = Directory.fromUri(libUri!.resolve('.'));
    expect(libDir.existsSync(), isTrue);
    expect(violations(libDir), isEmpty);
  });
}

final class _InvariantVisitor extends RecursiveAstVisitor<void> {
  _InvariantVisitor(this._path, this._dartIoAllowed);

  final String _path;
  final bool _dartIoAllowed;
  final List<String> violations = [];

  static const _bannedPrefixes = [
    'dart:ffi',
    'dart:ui',
    'dart:ui_web',
    'package:flutter/',
    'package:dartssh2/',
  ];

  @override
  void visitImportDirective(ImportDirective node) {
    _checkDirectiveUris(node, 'import');
    super.visitImportDirective(node);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    // `export 'dart:ffi'` leaks a banned API through the public surface
    // just as surely as an import does.
    _checkDirectiveUris(node, 'export');
    super.visitExportDirective(node);
  }

  /// Checks the directive's own URI plus every configured URI —
  /// `if (dart.library.io) 'dart:io'` bypasses a URI-only scan.
  void _checkDirectiveUris(NamespaceDirective node, String kind) {
    void check(String? uri) {
      if (uri == null) return;
      final banned =
          uri == 'dart:io' && !_dartIoAllowed ||
          _bannedPrefixes.any(uri.startsWith);
      if (banned) {
        violations.add('$_path: banned $kind $uri (05 §11)');
      }
    }

    check(node.uri.stringValue);
    for (final configuration in node.configurations) {
      check(configuration.uri.stringValue);
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // dart:io's Process API under ANY alias — the engine must never gain
    // the ability to exec rsync (05 §2's previewable contract).
    if (node.name == 'Process') {
      violations.add('$_path: Process reference (05 §11)');
    }
    super.visitSimpleIdentifier(node);
  }
}
