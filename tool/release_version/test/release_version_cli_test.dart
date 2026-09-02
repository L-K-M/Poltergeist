// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/release_version_cli.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late List<String> output;
  late List<String> errors;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-cli-test-',
    );
    root = Directory(p.join(sandbox.path, 'repository'))..createSync();
    _writeFixture(root);
    output = [];
    errors = [];
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  int run(List<String> arguments) {
    return runReleaseVersionCommand(
      arguments,
      workingDirectory: root,
      writeOutput: output.add,
      writeError: errors.add,
    );
  }

  test('validate prints the Android version code', () {
    expect(run(['validate', '--version', '0.1.0']), 0);
    expect(output, ['0.1.0+10099']);
    expect(errors, isEmpty);
  });

  test('validate rejects an unsupported qualifier', () {
    expect(run(['validate', '--version', '1.0.0-alpha1']), 1);
    expect(errors.single, contains('invalid release version'));
  });

  test('missing command arguments return usage failure', () {
    expect(run(['sync', '--version', '0.1.0']), 64);
    expect(errors.single, startsWith('usage:'));
  });

  test('sync writes deterministic app metadata', () {
    expect(
      run([
        'sync',
        '--version',
        '1.1.0',
        '--pubspec',
        'app/poltergeist_app/pubspec.yaml',
      ]),
      0,
    );

    expect(
      _read(root, 'app/poltergeist_app/pubspec.yaml'),
      contains('version: 1.1.0+1010099'),
    );
    for (final path in _appleInfoPlistPaths) {
      expect(_read(root, path), contains('<string>2.1.0</string>'));
    }
  });

  test('check verifies repository synchronization', () {
    expect(run(['check', '--version', '0.1.0']), 0);
    expect(output.single, contains('3 pubspecs'));
  });

  test('check-tag verifies tag grammar and repository synchronization', () {
    expect(run(['check-tag', '--tag', 'v0.1.0']), 0);
    expect(output.single, contains('v0.1.0'));
  });

  test('check-order verifies tree and repeated prior tags', () {
    expect(
      run([
        'check-order',
        '--version',
        '0.2.0',
        '--prior-tag',
        'v0.0.1',
        '--prior-tag',
        'v0.1.0',
      ]),
      0,
    );
    expect(output.single, contains('0.2.0+20099'));
  });

  test('check-order rejects a downgrade', () {
    expect(run(['check-order', '--version', '0.0.1']), 1);
    expect(errors.single, contains('current tree'));
  });
}

void _writeFixture(Directory root) {
  _write(root, 'pubspec.yaml', 'name: _workspace\n');
  _write(
    root,
    'packages/poltergeist_core/pubspec.yaml',
    'name: poltergeist_core\nversion: 0.1.0\n',
  );
  _write(
    root,
    'tool/bench/pubspec.yaml',
    'name: poltergeist_bench\nversion: 0.1.0\n',
  );
  _write(root, 'app/poltergeist_app/pubspec.yaml', '''
name: poltergeist_app
version: 0.1.0+10099
dependencies:
  poltergeist_core:
    path: ../../packages/poltergeist_core
''');
  _write(root, 'app/poltergeist_app/pubspec.lock', '''
packages:
  poltergeist_core:
    dependency: "direct main"
    description:
      path: "../../packages/poltergeist_core"
    source: path
    version: "0.1.0"
''');
  for (final path in _appleInfoPlistPaths) {
    _write(root, path, '''
<plist>
<dict>
  <key>CFBundleVersion</key>
  <string>1.1.0</string>
</dict>
</plist>
''');
  }
  _write(root, 'README.md', '<!-- version -->0.1.0<!-- /version -->\n');
}

const _appleInfoPlistPaths = [
  'app/poltergeist_app/ios/Runner/Info.plist',
  'app/poltergeist_app/macos/Runner/Info.plist',
];

String _read(Directory root, String path) {
  return File(p.join(root.path, path)).readAsStringSync();
}

void _write(Directory root, String path, String contents) {
  final file = File(p.join(root.path, path));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}
