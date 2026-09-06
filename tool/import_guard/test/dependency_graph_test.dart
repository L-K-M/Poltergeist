// This repository tool is not a published package.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:package_config/package_config.dart' show PackageConfigError;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart' show YamlException;

import '../lib/dependency_graph.dart';

void main() {
  late _Fixture fixture;

  setUp(() async => fixture = await _Fixture.create());
  tearDown(() async => fixture.root.delete(recursive: true));

  test('reports the runtime path to a transitive plugin', () async {
    await fixture.package('bridge', 'dependencies: {adapter: any}');
    await fixture.package('adapter', 'dependencies: {native_paths: any}');
    await fixture.package('native_paths', 'flutter: {plugin: {platforms: {}}}');

    final graph = await fixture.graph();

    expect(
      await graph.flutterDependency('bridge'),
      'bridge -> adapter -> native_paths',
    );
  });

  test('reports the runtime path to a transitive SDK dependency', () async {
    await fixture.package('bridge', 'dependencies: {adapter: any}');
    await fixture.package('adapter', 'dependencies: {flutter: {sdk: flutter}}');

    final graph = await fixture.graph();

    expect(await graph.flutterDependency('bridge'), 'bridge -> adapter');
  });

  test('terminates on a pure-Dart dependency cycle', () async {
    await fixture.package('first', 'dependencies: {second: any}');
    await fixture.package('second', 'dependencies: {first: any}');

    final graph = await fixture.graph();

    expect(await graph.flutterDependency('first'), isNull);
  });

  test('finds a Flutter dependency beyond a cycle', () async {
    await fixture.package('first', 'dependencies: {second: any}');
    await fixture.package(
      'second',
      'dependencies: {first: any, framework: any}',
    );
    await fixture.package('framework', 'environment: {flutter: ">=3.0.0"}');

    final graph = await fixture.graph();

    expect(
      await graph.flutterDependency('first'),
      'first -> second -> framework',
    );
  });

  test('ignores external Flutter test dependencies', () async {
    await fixture.package('library', '''
dependencies: {neutral: any}
dev_dependencies: {flutter_test: {sdk: flutter}, missing_test_helper: any}
''');
    await fixture.package('neutral', '');

    final graph = await fixture.graph();

    // Pub does not resolve another package's test dependencies for consumers.
    expect(await graph.flutterDependency('library'), isNull);
  });

  test('ignores external dependency overrides', () async {
    await fixture.package('library', '''
dependencies: {neutral: any}
dependency_overrides: {flutter: {sdk: flutter}}
''');
    await fixture.package('neutral', '');

    final graph = await fixture.graph();

    expect(await graph.flutterDependency('library'), isNull);
  });

  test('resolves relative package roots with escaped spaces', () async {
    final package = await fixture.package('neutral', '');

    final graph = await fixture.graph();

    graph.verifyRoot('neutral', package);
    expect(await graph.flutterDependency('neutral'), isNull);
  });

  test('rejects an unresolved requested package', () async {
    final graph = await fixture.graph();

    await expectLater(
      graph.flutterDependency('missing'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unresolved dependency missing'),
        ),
      ),
    );
  });

  test('rejects an unresolved runtime dependency', () async {
    await fixture.package('bridge', 'dependencies: {missing: any}');

    final graph = await fixture.graph();

    await expectLater(
      graph.flutterDependency('bridge'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a missing resolved pubspec', () async {
    final package = await fixture.package('library', '');
    await File(p.join(package.path, 'pubspec.yaml')).delete();

    final graph = await fixture.graph();

    await expectLater(
      graph.flutterDependency('library'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('rejects a mismatched resolved package name', () async {
    final package = await fixture.package('library', '');
    await File(
      p.join(package.path, 'pubspec.yaml'),
    ).writeAsString('name: different_package\n');

    final graph = await fixture.graph();

    await expectLater(
      graph.flutterDependency('library'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects non-map runtime dependency metadata', () async {
    await fixture.package('library', 'dependencies: [native_paths]');

    final graph = await fixture.graph();

    await expectLater(
      graph.flutterDependency('library'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects stale workspace roots', () async {
    await fixture.package('library', '');

    final graph = await fixture.graph();

    expect(
      () => graph.verifyRoot('library', fixture.root),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unresolved workspace roots', () async {
    final graph = await fixture.graph();

    expect(
      () => graph.verifyRoot('missing', fixture.root),
      throwsA(isA<FormatException>()),
    );
  });

  test('detects an environment Flutter constraint alone', () async {
    await fixture.package('framework', 'environment: {flutter: ">=3.0.0"}');

    final graph = await fixture.graph();

    expect(await graph.flutterDependency('framework'), 'framework');
  });

  test('detects an SDK dependency without naming assumptions', () async {
    await fixture.package(
      'framework',
      'dependencies: {framework_alias: {sdk: "flutter"}}',
    );

    final graph = await fixture.graph();

    expect(await graph.flutterDependency('framework'), 'framework');
  });

  test('accepts pure-Dart libraries with plugin and Flutter names', () async {
    await fixture.package(
      'plugin_platform_interface',
      'dependencies: {flutter_helpers: any}',
    );
    await fixture.package('flutter_helpers', '');

    final graph = await fixture.graph();

    expect(await graph.flutterDependency('plugin_platform_interface'), isNull);
  });

  test('accepts neutral packages that depend on dartssh2', () async {
    await fixture.package('neutral_transport', 'dependencies: {dartssh2: any}');
    await fixture.package('dartssh2', '');

    final graph = await fixture.graph();

    // Séance's neutral API intentionally consumes dartssh2 transitively.
    expect(await graph.flutterDependency('neutral_transport'), isNull);
  });

  test('rejects a missing package configuration', () async {
    await expectLater(
      DependencyGraph.load(fixture.config),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.path,
          'path',
          fixture.config.path,
        ),
      ),
    );
  });

  test('rejects malformed package configuration JSON', () async {
    await fixture.write('.dart_tool/package_config.json', '{');

    await expectLater(
      DependencyGraph.load(fixture.config),
      throwsA(allOf(isA<FormatException>(), isA<PackageConfigError>())),
    );
  });

  for (final contents in ['', '[library]']) {
    test('rejects empty or non-map YAML: $contents', () async {
      final pubspec = await fixture.write('pubspec.yaml', contents);

      await expectLater(
        readPubspec(pubspec),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains(pubspec.path),
          ),
        ),
      );
    });
  }

  test('identifies the source file in malformed YAML diagnostics', () async {
    final pubspec = await fixture.write('pubspec.yaml', 'name: [');

    await expectLater(
      readPubspec(pubspec),
      throwsA(
        isA<YamlException>()
            .having((error) => error.span?.sourceUrl, 'source URL', pubspec.uri)
            .having(
              (error) => error.toString(),
              'diagnostic',
              contains(p.prettyUri(pubspec.uri)),
            ),
      ),
    );
  });

  test('rejects integer pubspec keys before returning a map', () async {
    final pubspec = await fixture.write('pubspec.yaml', '''
name: library
7: invalid_key
''');

    // Reading must reject invalid keys before a later consumer triggers a cast.
    await expectLater(
      readPubspec(pubspec),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains(pubspec.path),
        ),
      ),
    );
  });

  test('reads quoted dependency names and flow-style YAML', () async {
    final pubspec = await fixture.write('pubspec.yaml', '''
name: library
dependencies: {"neutral": any}
dev_dependencies: {'test_helper': any}
dependency_overrides: {native_paths: {path: ../native_paths}}
''');

    final parsed = await readPubspec(pubspec);

    expect(dependencyNames(parsed, dependencySections), [
      'neutral',
      'test_helper',
      'native_paths',
    ]);
  });
}

class _Fixture {
  _Fixture(this.root);

  final Directory root;
  final _packages = <Map<String, String>>[];

  File get config => File(p.join(root.path, '.dart_tool/package_config.json'));

  static Future<_Fixture> create() async =>
      _Fixture(await Directory.systemTemp.createTemp('dependency-graph-'));

  Future<File> write(String path, String contents) async {
    final file = File(p.join(root.path, path));
    await file.parent.create(recursive: true);
    return file.writeAsString(contents);
  }

  Future<Directory> package(String name, String fields) async {
    final relative = 'resolved packages/$name';
    await write('$relative/pubspec.yaml', 'name: $name\n$fields\n');
    _packages.add({
      'name': name,
      'rootUri': Uri.directory('../$relative').toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.12',
    });
    return Directory(p.join(root.path, relative));
  }

  Future<DependencyGraph> graph() async {
    await write(
      '.dart_tool/package_config.json',
      jsonEncode({'configVersion': 2, 'packages': _packages}),
    );
    return DependencyGraph.load(config);
  }
}
