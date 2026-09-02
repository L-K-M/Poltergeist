// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/release_version.dart';

void main() {
  late Directory sandbox;
  late Directory root;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-version-test-',
    );
    root = Directory(p.join(sandbox.path, 'repository'))..createSync();
    _writeFixture(root);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('sync changes only app release metadata', () {
    final core = _read(root, 'packages/poltergeist_core/pubspec.yaml');
    final bench = _read(root, 'tool/bench/pubspec.yaml');
    final readme = _read(root, 'README.md');
    final workspace = ReleaseVersionWorkspace(root);

    workspace.syncAppMetadata(
      version: ReleaseVersion.parse('1.1.0'),
      pubspecPath: 'app/poltergeist_app/pubspec.yaml',
    );

    expect(
      _read(root, 'app/poltergeist_app/pubspec.yaml'),
      contains('version: 1.1.0+1010099\n'),
    );
    for (final path in _appleInfoPlistPaths) {
      expect(_read(root, path), contains('<string>2.1.0</string>'));
    }
    expect(_read(root, 'packages/poltergeist_core/pubspec.yaml'), core);
    expect(_read(root, 'tool/bench/pubspec.yaml'), bench);
    expect(_read(root, 'README.md'), readme);
  });

  test('sync rejects a missing top-level version', () {
    _write(root, 'app/poltergeist_app/pubspec.yaml', 'name: poltergeist_app\n');

    expect(
      () => ReleaseVersionWorkspace(root).syncAppMetadata(
        version: ReleaseVersion.parse('0.1.0'),
        pubspecPath: 'app/poltergeist_app/pubspec.yaml',
      ),
      throwsA(isA<ReleaseVersionStateException>()),
    );
  });

  test('sync validates every metadata source before writing', () {
    final pubspecPath = 'app/poltergeist_app/pubspec.yaml';
    final original = _read(root, pubspecPath);
    File(p.join(root.path, _appleInfoPlistPaths.last)).deleteSync();

    expect(
      () => ReleaseVersionWorkspace(root).syncAppMetadata(
        version: ReleaseVersion.parse('1.1.0'),
        pubspecPath: pubspecPath,
      ),
      throwsA(isA<ReleaseVersionStateException>()),
    );
    expect(_read(root, pubspecPath), original);
  });

  test('sync keeps the maximum Apple build version within bounds', () {
    ReleaseVersionWorkspace(root).syncAppMetadata(
      version: ReleaseVersion.parse('2099.99.99'),
      pubspecPath: 'app/poltergeist_app/pubspec.yaml',
    );

    for (final path in _appleInfoPlistPaths) {
      expect(_read(root, path), contains('<string>2100.99.99</string>'));
    }
  });

  test('check accepts synchronized repository state', () {
    final report = ReleaseVersionWorkspace(root).check();

    expect(report.version.semantic, '0.1.0');
    expect(report.version.androidVersionCode, 10099);
    expect(report.pubspecCount, 3);
    expect(report.lockedPackageCount, 1);
  });

  test('check accepts an explicit expected version', () {
    final expected = ReleaseVersion.parse('0.1.0');

    final report = ReleaseVersionWorkspace(root).check(expected: expected);

    expect(report.version.semantic, expected.semantic);
  });

  for (final drift in _Drift.values) {
    test('check rejects ${drift.name} drift', () {
      drift.apply(root);

      expect(
        () => ReleaseVersionWorkspace(root).check(),
        throwsA(
          isA<ReleaseVersionStateException>().having(
            (error) => error.message,
            'message',
            contains(drift.messageFragment),
          ),
        ),
      );
    });
  }

  test('check-tag accepts canonical tag and synchronized tree', () {
    final report = ReleaseVersionWorkspace(root).checkTag('v0.1.0');

    expect(report.version.semantic, '0.1.0');
  });

  test('check-tag rejects a bare version', () {
    expect(
      () => ReleaseVersionWorkspace(root).checkTag('0.1.0'),
      throwsA(isA<ReleaseVersionFormatException>()),
    );
  });

  test('check-tag rejects a valid tag for a different tree version', () {
    expect(
      () => ReleaseVersionWorkspace(root).checkTag('v0.2.0'),
      throwsA(isA<ReleaseVersionStateException>()),
    );
  });

  test('release order accepts a target newer than tree and prior tags', () {
    final target = ReleaseVersion.parse('0.2.0');

    final checked = ReleaseVersionWorkspace(
      root,
    ).checkReleaseOrder(target: target, priorTags: const ['v0.0.1', 'v0.1.0']);

    expect(checked.semantic, target.semantic);
  });

  test('release order rejects a target older than the current tree', () {
    expect(
      () => ReleaseVersionWorkspace(root).checkReleaseOrder(
        target: ReleaseVersion.parse('0.0.1'),
        priorTags: const [],
      ),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (error) => error.message,
          'message',
          contains('current tree'),
        ),
      ),
    );
  });

  test('release order rejects a target not newer than every prior tag', () {
    expect(
      () => ReleaseVersionWorkspace(
        root,
      ).checkReleaseOrder(priorTags: const ['v0.1.0']),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (error) => error.message,
          'message',
          contains('prior tag v0.1.0'),
        ),
      ),
    );
  });

  test('release order fails closed on an unsupported prior tag', () {
    expect(
      () => ReleaseVersionWorkspace(root).checkReleaseOrder(
        target: ReleaseVersion.parse('0.2.0'),
        priorTags: const ['v0.1.0-alpha1'],
      ),
      throwsA(isA<ReleaseVersionStateException>()),
    );
  });

  test('check rejects a missing path dependency pubspec', () {
    File(
      p.join(root.path, 'packages/poltergeist_core/pubspec.yaml'),
    ).deleteSync();

    expect(
      () => ReleaseVersionWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (error) => error.message,
          'message',
          contains('path dependency'),
        ),
      ),
    );
  });

  test('check rejects a non-path lock source', () {
    _replace(
      root,
      'app/poltergeist_app/pubspec.lock',
      'source: path',
      'source: hosted',
    );

    expect(
      () => ReleaseVersionWorkspace(root).check(),
      throwsA(
        isA<ReleaseVersionStateException>().having(
          (error) => error.message,
          'message',
          contains('app lock'),
        ),
      ),
    );
  });
}

enum _Drift {
  package('pubspec'),
  appSemantic('app pubspec'),
  appBuild('version code'),
  appleBuild('Apple bundle version'),
  lock('lock'),
  readme('README');

  final String messageFragment;

  const _Drift(this.messageFragment);

  void apply(Directory root) {
    switch (this) {
      case _Drift.package:
        _replace(root, 'tool/bench/pubspec.yaml', '0.1.0', '0.2.0');
      case _Drift.appSemantic:
        _replace(
          root,
          'app/poltergeist_app/pubspec.yaml',
          '0.1.0+10099',
          '0.2.0+20099',
        );
      case _Drift.appBuild:
        _replace(
          root,
          'app/poltergeist_app/pubspec.yaml',
          '0.1.0+10099',
          '0.1.0+1',
        );
      case _Drift.appleBuild:
        _replace(
          root,
          _appleInfoPlistPaths.first,
          '<string>1.1.0</string>',
          '<string>1.0.0</string>',
        );
      case _Drift.lock:
        _replace(
          root,
          'app/poltergeist_app/pubspec.lock',
          'version: "0.1.0"',
          'version: "0.2.0"',
        );
      case _Drift.readme:
        _replace(root, 'README.md', '>0.1.0<', '>0.2.0<');
    }
  }
}

void _writeFixture(Directory root) {
  _write(root, 'pubspec.yaml', 'name: _workspace\npublish_to: none\n');
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
      relative: true
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
  _write(
    root,
    'README.md',
    '**Current version:** v<!-- version -->0.1.0<!-- /version -->\n',
  );
}

const _appleInfoPlistPaths = [
  'app/poltergeist_app/ios/Runner/Info.plist',
  'app/poltergeist_app/macos/Runner/Info.plist',
];

void _replace(Directory root, String path, String before, String after) {
  final file = File(p.join(root.path, path));
  final current = file.readAsStringSync();
  final changed = current.replaceFirst(before, after);
  expect(changed, isNot(current), reason: '$before missing from $path');
  file.writeAsStringSync(changed);
}

String _read(Directory root, String path) {
  return File(p.join(root.path, path)).readAsStringSync();
}

void _write(Directory root, String path, String contents) {
  final file = File(p.join(root.path, path));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}
