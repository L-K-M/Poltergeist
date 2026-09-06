import 'dart:io';

import 'package:package_config/package_config.dart';
import 'package:yaml/yaml.dart';

const dependencySections = [
  'dependencies',
  'dev_dependencies',
  'dependency_overrides',
];

// SDK packages are absent from pure-Dart resolution. Classify their imports
// directly so the diagnostic identifies a boundary violation, not setup work.
const _flutterSdkPackages = {
  'flutter',
  'flutter_test',
  'flutter_driver',
  'flutter_localizations',
  'flutter_web_plugins',
  'integration_test',
  'sky_engine',
  'flutter_gpu',
};

/// Uses pub's resolved revisions, including path/git overrides, without network I/O.
class DependencyGraph {
  DependencyGraph._(this._config);

  final PackageConfig _config;
  final _pubspecs = <String, Map<String, Object?>>{};

  static Future<DependencyGraph> load(File config) async =>
      DependencyGraph._(await loadPackageConfigUri(config.uri));

  Future<String?> flutterDependency(String name) async {
    final pending = <List<String>>[
      [name],
    ];
    final visited = <String>{};

    // Only runtime edges propagate: upstream Flutter tests do not infect a
    // pure-Dart library. The visited set also permits dependency cycles.
    for (var index = 0; index < pending.length; index++) {
      final trail = pending[index];
      final current = trail.last;
      if (!visited.add(current)) continue;
      if (_flutterSdkPackages.contains(current)) return trail.join(' -> ');

      final pubspec = await _pubspec(current);
      if (requiresFlutter(pubspec)) return trail.join(' -> ');

      for (final dependency in dependencyNames(pubspec, ['dependencies'])) {
        pending.add([...trail, dependency]);
      }
    }
    return null;
  }

  void verifyRoot(String name, Directory root) {
    final package = _config[name];
    if (package == null || package.root != root.uri) {
      throw FormatException(
        'Unresolved or stale package $name; run dart pub get',
      );
    }
  }

  Future<Map<String, Object?>> _pubspec(String name) async {
    final cached = _pubspecs[name];
    if (cached != null) return cached;

    final package = _config[name];
    if (package == null) {
      throw FormatException('Unresolved dependency $name; run dart pub get');
    }

    final pubspec = await readPubspec(
      File.fromUri(package.root.resolve('pubspec.yaml')),
    );
    if (pubspec['name'] != name) {
      throw FormatException('Package metadata mismatch for $name');
    }
    _pubspecs[name] = pubspec;
    return pubspec;
  }
}

Future<Map<String, Object?>> readPubspec(File file) async {
  final yaml = loadYaml(await file.readAsString());
  if (yaml is! Map) throw FormatException('Expected YAML map: ${file.path}');
  return yaml.cast<String, Object?>();
}

Iterable<String> dependencyNames(
  Map<String, Object?> pubspec,
  List<String> sections,
) sync* {
  for (final section in sections) {
    yield* _map(pubspec[section], section).keys;
  }
}

bool requiresFlutter(Map<String, Object?> pubspec) {
  if (_map(pubspec['flutter'], 'flutter').containsKey('plugin')) return true;
  if (_map(pubspec['environment'], 'environment').containsKey('flutter')) {
    return true;
  }

  for (final value in _map(pubspec['dependencies'], 'dependencies').values) {
    if (value is Map && value['sdk'] == 'flutter') return true;
  }
  return false;
}

bool hasFlutterSdk(Map<String, Object?> pubspec, String section) => _map(
  pubspec[section],
  section,
).values.any((value) => value is Map && value['sdk'] == 'flutter');

Map<String, Object?> _map(Object? value, String field) {
  if (value == null) return {};
  if (value is! Map) throw FormatException('Expected YAML map for $field');
  return value.cast<String, Object?>();
}
