import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import 'dependency_graph.dart';

const _projectGeneratedDirectories = {
  '.dart_tool',
  'build',
  '.symlinks',
  'ephemeral',
  '.git',
};
const _nativePlatforms = {'android', 'ios', 'linux', 'macos', 'windows'};
const _coreDirectory = 'packages/poltergeist_core';
const _connectionDirectory = '$_coreDirectory/lib/src/connection';

enum _Area { packages, app }

/// Checks product code only; M0's tool/ harness is a sanctioned SSH consumer.
Future<List<String>> checkImports(String rootPath) async {
  final root = p.normalize(p.absolute(rootPath));
  final graph = await DependencyGraph.load(
    File(p.join(root, '.dart_tool/package_config.json')),
  );
  final violations = <String>[];
  var purePackageCount = 0;

  for (final area in _Area.values) {
    final directory = Directory(p.join(root, area.name));
    if (!await directory.exists()) {
      throw FileSystemException('Missing scan root', directory.path);
    }

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Link) {
        throw FileSystemException('Linked package', entity.path);
      }
      if (entity is! Directory) continue;

      final relative = _relative(entity.path, root);
      violations.addAll(await _checkPackage(entity, relative, graph, area));
      if (area == _Area.packages) purePackageCount++;
    }

    await for (final file in _sources(directory, root)) {
      violations.addAll(
        await _checkSource(file, _relative(file.path, root), graph, area),
      );
    }
  }

  if (purePackageCount == 0) {
    throw const FormatException('No pure-Dart packages found');
  }
  return violations;
}

Future<List<String>> _checkPackage(
  Directory directory,
  String relative,
  DependencyGraph graph,
  _Area area,
) async {
  final pubspec = await readPubspec(
    File(p.join(directory.path, 'pubspec.yaml')),
  );
  if (area == _Area.packages) {
    final name = pubspec['name'];
    if (name is! String) {
      throw FormatException('Missing package name: ${directory.path}');
    }
    graph.verifyRoot(name, directory);
  }

  // Overrides and unused declarations can add forbidden edges before an import
  // exists. App declarations need no Flutter resolution in the Dart CI job.
  final manifests = [pubspec];
  final overrides = File(p.join(directory.path, 'pubspec_overrides.yaml'));
  if (await overrides.exists()) manifests.add(await readPubspec(overrides));
  final violations = <String>[];

  for (final manifest in manifests) {
    final dependencies = dependencyNames(manifest, dependencySections).toSet();
    if (relative != _coreDirectory && dependencies.contains('dartssh2')) {
      violations.add('$relative: dartssh2 dependency outside poltergeist_core');
    }
    if (area != _Area.packages) continue;

    if (requiresFlutter(manifest) ||
        dependencySections.any((section) => hasFlutterSdk(manifest, section))) {
      violations.add(
        '$relative: Flutter/plugin declaration in a pure-Dart package',
      );
      continue;
    }
    for (final dependency in dependencies) {
      final forbidden = await graph.flutterDependency(dependency);
      if (forbidden != null) {
        violations.add('$relative: Flutter/plugin dependency $forbidden');
      }
    }
  }
  return violations;
}

Future<List<String>> _checkSource(
  File file,
  String relative,
  DependencyGraph graph,
  _Area area,
) async {
  final unit = parseString(
    content: await file.readAsString(),
    path: file.path,
  ).unit;
  final violations = <String>[];

  // Parse every branch, including inactive conditional exports. Literal decoding
  // catches escapes while comments and ordinary strings remain harmless.
  for (final directive in unit.directives.whereType<NamespaceDirective>()) {
    final literals = [
      directive.uri,
      ...directive.configurations.map((config) => config.uri),
    ];
    for (final literal in literals) {
      final text = literal.stringValue;
      if (text == null) {
        violations.add('$relative: non-constant import/export URI');
        continue;
      }
      final uri = Uri.parse(text);
      if (uri.scheme == 'package' && uri.pathSegments.isEmpty) {
        violations.add('$relative: invalid package URI $uri');
        continue;
      }
      final package = uri.scheme == 'package' ? uri.pathSegments.first : null;
      if (package == 'dartssh2' &&
          !p.posix.isWithin(_connectionDirectory, relative)) {
        violations.add(
          '$relative: dartssh2 import/export outside $_connectionDirectory',
        );
      }
      if (area != _Area.packages) continue;

      if (uri.scheme == 'dart' && (uri.path == 'ui' || uri.path == 'ui_web')) {
        violations.add('$relative: Flutter SDK import/export $uri');
        continue;
      }
      if (package == null) continue;
      final forbidden = await graph.flutterDependency(package);
      if (forbidden != null) {
        violations.add('$relative: Flutter/plugin import/export $forbidden');
      }
    }
  }
  return violations;
}

String _relative(String path, String root) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));

Stream<File> _sources(Directory directory, String root) async* {
  await for (final entity in directory.list(followLinks: false)) {
    if (_isGenerated(entity.path, root)) continue;
    if (entity is Link) {
      throw FileSystemException('Linked scan input', entity.path);
    }
    if (entity is Directory) {
      yield* _sources(entity, root);
      continue;
    }
    if (entity is File && p.extension(entity.path) == '.dart') yield entity;
  }
}

// Scope exclusions to output locations: lib/build and lib/.dart_tool are source
// paths, while Flutter and CocoaPods generate links inside platform projects.
bool _isGenerated(String path, String root) => switch (p.split(
  p.relative(path, from: root),
)) {
  ['packages' || 'app', _, final name] => _projectGeneratedDirectories.contains(
    name,
  ),
  ['app', _, 'ios' || 'macos', 'Pods' || '.symlinks'] => true,
  ['app', _, final platform, 'build'] => _nativePlatforms.contains(platform),
  ['app', _, 'android', 'app', 'build'] => true,
  ['app', _, 'ios' || 'macos', 'Flutter', 'ephemeral'] => true,
  ['app', _, 'linux' || 'windows', 'flutter', 'ephemeral'] => true,
  _ => false,
};
