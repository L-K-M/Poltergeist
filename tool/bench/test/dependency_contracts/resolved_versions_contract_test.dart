import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _productLocks = {
  'workspace': '../../../pubspec.lock',
  'app': '../../../app/poltergeist_app/pubspec.lock',
};

void main() {
  for (final package in ['cryptography', 'dartssh2']) {
    test('$package contracts cover workspace and app versions', () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:$package/$package.dart'),
      );
      expect(
        library,
        isNotNull,
        reason: '$package must resolve in the harness',
      );
      final manifest = await _readYaml(library!.resolve('../pubspec.yaml'));
      final version = manifest['version'];
      expect(version, isA<String>(), reason: '$package must declare a version');

      final harness = await Isolate.resolvePackageUri(
        Uri.parse('package:poltergeist_m0_bench/harness.dart'),
      );
      expect(harness, isNotNull, reason: 'The harness package must resolve');

      // The app ignores core dev-deps and resolves separately. Bind all three
      // resolutions to the exercised versions; use checkout paths, not cwd.
      for (final entry in _productLocks.entries) {
        final lock = await _readYaml(harness!.resolve(entry.value));
        expect(
          lock['packages'],
          containsPair(package, containsPair('version', version)),
          reason: '${entry.key} must resolve the tested $package $version',
        );
      }
    });
  }
}

Future<YamlMap> _readYaml(Uri path) async =>
    loadYaml(await File.fromUri(path).readAsString()) as YamlMap;
