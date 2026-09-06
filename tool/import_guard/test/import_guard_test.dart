// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/import_guard.dart';

const _core = 'packages/poltergeist_core';
const _app = 'app/poltergeist_app';

void main() {
  late _Fixture fixture;

  setUp(() async => fixture = await _Fixture.create());
  tearDown(() async => fixture.root.delete(recursive: true));

  test('accepts connection imports and Flutter app code', () async {
    await fixture.write(
      '$_core/lib/src/connection/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.write(
      '$_app/lib/main.dart',
      "import 'package:flutter/material.dart';",
    );
    await fixture.expectExit(0);
    await fixture.expectScriptExit(0);
  });

  for (final source in [
    "import 'package:dartssh2/dartssh2.dart';",
    "export 'package:dartssh2/dartssh2.dart';",
    r"import 'package:dart\u0073sh2/dartssh2.dart';",
    "import 'safe.dart' if (dart.library.io) 'package:dartssh2/dartssh2.dart';",
  ]) {
    test('rejects SSH outside connection: $source', () async {
      await fixture.write('$_app/lib/main.dart', source);
      await fixture.expectExit(1, 'dartssh2');
    });
  }

  test('ignores comments and ordinary strings', () async {
    await fixture.write('$_core/lib/example.dart', '''
/*
import 'package:dartssh2/dartssh2.dart';
*/
const example = "package:flutter/widgets.dart";
''');
    await fixture.expectExit(0);
  });

  test('rejects a plugin whose name has no Flutter prefix', () async {
    await fixture.package('native_paths', 'flutter: {plugin: {platforms: {}}}');
    await fixture.write(
      '$_core/lib/example.dart',
      "import 'package:native_paths/native_paths.dart';",
    );
    await fixture.expectExit(1, 'native_paths');
  });

  for (final package in [
    'flutter',
    'flutter_test',
    'flutter_driver',
    'flutter_localizations',
    'flutter_web_plugins',
    'integration_test',
    'sky_engine',
    'flutter_gpu',
  ]) {
    test('reports unresolved SDK package $package as a violation', () async {
      await fixture.write(
        '$_core/lib/core.dart',
        "import 'package:$package/api.dart';",
      );
      await fixture.expectExit(1, package);
    });
  }

  test('missing package configuration gives shell remediation', () async {
    await File(
      p.join(fixture.root.path, '.dart_tool/package_config.json'),
    ).delete();
    await fixture.expectScriptExit(2, 'run dart pub get');
  });

  test(
    'reports interpolated directives without a null-check failure',
    () async {
      await fixture.write(
        '$_core/lib/core.dart',
        r"import 'package:$name/api.dart';",
      );
      await fixture.expectExit(1, 'non-constant import/export URI');
    },
  );

  test('rejects an unused declared plugin', () async {
    await fixture.package('native_paths', 'flutter: {plugin: {platforms: {}}}');
    await fixture.write('$_core/pubspec.yaml', '''
name: poltergeist_core
dependencies: {native_paths: any}
''');
    await fixture.expectExit(1, 'native_paths');
  });

  test('rejects a transitive Flutter dependency', () async {
    await fixture.package('bridge', 'dependencies: {native_paths: any}');
    await fixture.package(
      'native_paths',
      'dependencies: {flutter: {sdk: flutter}}',
    );
    await fixture.write(
      '$_core/lib/example.dart',
      "export 'package:bridge/bridge.dart';",
    );
    await fixture.expectExit(1, 'native_paths');
  });

  test('rejects inline Flutter SDK declarations', () async {
    await fixture.write('$_core/pubspec.yaml', '''
name: poltergeist_core
dev_dependencies: {flutter_test: {sdk: flutter}}
''');
    await fixture.expectExit(1, 'Flutter');
  });

  test('rejects quoted SSH declarations in app overrides', () async {
    await fixture.write('$_app/pubspec.yaml', '''
name: poltergeist_app
dependency_overrides: {"dartssh2": any}
''');
    await fixture.expectExit(1, 'dartssh2');
  });

  for (final location in [
    '$_core/lib/src/connection_extra/ssh.dart',
    '$_core/test/ssh_test.dart',
    '$_core/lib/core.dart',
    'packages/poltergeist_sync/lib/sync.dart',
  ]) {
    test('rejects SSH at $location', () async {
      await fixture.write(location, "import 'package:dartssh2/dartssh2.dart';");
      if (location.startsWith('packages/poltergeist_sync/')) {
        await fixture.write(
          'packages/poltergeist_sync/pubspec.yaml',
          'name: poltergeist_sync',
        );
        await fixture._register(
          'poltergeist_sync',
          'packages/poltergeist_sync',
        );
      }
      await fixture.expectExit(1, 'dartssh2');
    });
  }

  for (final source in [
    "export 'dart:ui';",
    "import\n /* note */ 'dart:ui_web';",
    "export 'safe.dart' if (dart.library.ui) 'package:native_paths/paths.dart';",
    "/* note */ import r'package:native_paths/paths.dart';",
  ]) {
    test('rejects Flutter directive: $source', () async {
      await fixture.package(
        'native_paths',
        'flutter: {plugin: {platforms: {}}}',
      );
      await fixture.write('$_core/lib/core.dart', source);
      await fixture.expectExit(1, 'Flutter');
    });
  }

  for (final section in [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    test('checks plugins declared in $section', () async {
      await fixture.package(
        'native_paths',
        'environment: {flutter: ">=3.0.0"}',
      );
      await fixture.write(
        '$_core/pubspec.yaml',
        'name: poltergeist_core\n$section: {native_paths: any}',
      );
      await fixture.expectExit(1, 'native_paths');
    });
  }

  test('checks the local override file', () async {
    await fixture.write(
      '$_app/pubspec_overrides.yaml',
      'dependency_overrides: {dartssh2: any}',
    );
    await fixture.expectExit(1, 'dartssh2');
  });

  test(
    'allows external Flutter tests and pure packages with plugin names',
    () async {
      await fixture.package(
        'flutter_example',
        'dev_dependencies: {flutter_test: {sdk: flutter}}',
      );
      await fixture.package(
        'plugin_interface',
        'dependencies: {flutter_example: any}',
      );
      await fixture.write(
        '$_core/lib/core.dart',
        "import 'package:plugin_interface/api.dart';",
      );
      await fixture.expectExit(0);
    },
  );

  test('excludes generated trees and the M0 harness', () async {
    for (final directory in ['build', '.dart_tool', '.symlinks', 'ephemeral']) {
      await fixture.write(
        '$_core/$directory/bad.dart',
        "import 'package:dartssh2/dartssh2.dart';",
      );
    }
    await fixture.write(
      'tool/bench/lib/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.expectExit(0);
  });

  for (final platform in ['ios', 'macos']) {
    test('excludes generated $platform CocoaPods links', () async {
      final headers = Directory(
        p.join(fixture.root.path, '$_app/$platform/Pods/Headers'),
      );
      await headers.create(recursive: true);
      await Link(p.join(headers.path, 'Public')).create('../Generated');
      await fixture.expectExit(0);
    });
  }

  test('does not exclude a Dart source directory named Pods', () async {
    await fixture.write(
      '$_app/lib/Pods/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.expectExit(1, 'dartssh2');
  });

  for (final name in [
    'build',
    'ephemeral',
    '.dart_tool',
    '.symlinks',
    '.git',
  ]) {
    for (final location in ['$_core/lib', '$_core/test', '$_app/lib/src']) {
      test('scans source directory $location/$name', () async {
        await fixture.write(
          '$location/$name/ssh.dart',
          "import 'package:dartssh2/dartssh2.dart';",
        );
        await fixture.expectExit(1, 'dartssh2');
      });
    }
  }

  test('scans a package named build', () async {
    await fixture.write('packages/build/pubspec.yaml', 'name: fixture_build');
    await fixture._register('fixture_build', 'packages/build');
    await fixture.write(
      'packages/build/lib/ssh.dart',
      "import 'package:dartssh2/dartssh2.dart';",
    );
    await fixture.expectExit(1, 'dartssh2');
  });

  test('skips generated native outputs with symlinks', () async {
    for (final output in [
      'linux/flutter/ephemeral',
      'windows/flutter/ephemeral',
      'macos/Flutter/ephemeral',
      'ios/Flutter/ephemeral',
      'ios/.symlinks',
      'macos/.symlinks',
      'android/app/build',
      'android/build',
    ]) {
      final directory = Directory(p.join(fixture.root.path, _app, output));
      await directory.create(recursive: true);
      await Link(p.join(directory.path, 'generated')).create('absent');
    }
    await fixture.expectExit(0);
  });

  test('reports an empty package URI as a violation', () async {
    await fixture.write('$_core/lib/core.dart', "import 'package:';");
    await fixture.expectExit(1, 'invalid package URI');
  });

  test('identifies a missing package name', () async {
    await fixture.write('$_core/pubspec.yaml', 'description: unnamed');
    await fixture.expectExit(2, _core);
  });

  for (final directory in ['packages', 'app']) {
    test('fails closed without $directory', () async {
      await Directory(
        p.join(fixture.root.path, directory),
      ).delete(recursive: true);
      await fixture.expectExit(2, 'Missing scan root');
    });

    test('fails closed on linked $directory root', () async {
      final path = p.join(fixture.root.path, directory);
      final target = '$path-target';
      await Directory(path).rename(target);
      await Link(path).create(target);

      await fixture.expectExit(2, 'Linked scan root');
    });
  }

  for (final input in [
    '.dart_tool/package_config.json',
    '$_core/pubspec.yaml',
  ]) {
    test('fails closed without $input', () async {
      await File(p.join(fixture.root.path, input)).delete();
      await fixture.expectExit(2, p.basename(input));
    });
  }

  test('fails closed on malformed YAML through the shell entrypoint', () async {
    await fixture.write('$_core/pubspec.yaml', 'name: [');
    await fixture.expectExit(2);
    await fixture.expectScriptExit(2, 'dependency scan failed');
  });

  test('fails closed on invalid Dart', () async {
    await fixture.write('$_core/lib/core.dart', "import 'unterminated");
    await fixture.expectExit(2);
  });

  test('fails closed on an unresolved import', () async {
    await fixture.write(
      '$_core/lib/core.dart',
      "import 'package:absent/api.dart';",
    );
    await fixture.expectExit(2, 'Unresolved dependency absent');
  });

  test('fails closed on linked source', () async {
    await Link(
      p.join(fixture.root.path, '$_core/lib/link.dart'),
    ).create('core.dart');
    await fixture.expectExit(2, 'Linked scan input');
  });
}

class _Fixture {
  _Fixture(this.root, this._config);

  final Directory root;
  final Map<String, Object?> _config;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('import-guard-');
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    final packages = config['packages'] as List<dynamic>;
    for (final entry in packages.cast<Map<String, dynamic>>()) {
      entry['rootUri'] = configFile.uri
          .resolve(entry['rootUri'] as String)
          .toString();
    }
    final fixture = _Fixture(root, config);
    await fixture.write(
      'scripts/check-imports.sh',
      await File('scripts/check-imports.sh').readAsString(),
    );

    // CLI checks invoke the real shell entrypoint from a different directory.
    final tool = Directory('tool/import_guard');
    await for (final file in tool.list(recursive: true)) {
      if (file is! File || p.split(file.path).contains('test')) continue;
      await fixture.write(file.path, await file.readAsString());
    }

    await fixture.write('$_core/pubspec.yaml', 'name: poltergeist_core\n');
    await fixture.write('$_app/pubspec.yaml', 'name: poltergeist_app\n');
    await fixture.write('$_core/lib/core.dart', '// Empty fixture.\n');
    await fixture.write('$_app/lib/main.dart', '// Empty fixture.\n');
    await fixture._register('poltergeist_core', _core);
    // SSH fixture classification must not depend on the workspace's own pin.
    await fixture.package('dartssh2', '');
    return fixture;
  }

  Future<void> write(String path, String contents) async {
    final file = File(p.join(root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<void> package(String name, String fields) async {
    final path = 'resolved/$name';
    await write('$path/pubspec.yaml', 'name: $name\n$fields\n');
    await _register(name, path);
  }

  Future<void> _register(String name, String path) async {
    final packages = _config['packages'] as List<dynamic>;
    packages.removeWhere((dynamic entry) => entry['name'] == name);
    packages.add({
      'name': name,
      'rootUri': Directory(p.join(root.path, path)).uri.toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.12',
    });
    await write('.dart_tool/package_config.json', jsonEncode(_config));
  }

  Future<void> expectExit(int code, [String? diagnostic]) async {
    late int actualCode;
    late String output;
    try {
      final violations = await checkImports(root.path);
      actualCode = violations.isEmpty ? 0 : 1;
      output = violations.join('\n');
    } catch (error) {
      actualCode = 2;
      output = '$error';
    }
    expect(actualCode, code, reason: output);
    if (diagnostic != null) expect(output, contains(diagnostic));
  }

  Future<void> expectScriptExit(int code, [String? diagnostic]) async {
    final result = await Process.run(
      'bash',
      [p.join(root.path, 'scripts/check-imports.sh')],
      environment: {
        'PATH':
            '${p.dirname(Platform.resolvedExecutable)}'
            '${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH']}',
      },
    );
    expect(result.exitCode, code, reason: '${result.stdout}\n${result.stderr}');
    if (diagnostic != null) expect(result.stderr, contains(diagnostic));
  }
}
