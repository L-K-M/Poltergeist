// Gate code stays under tool/ so it cannot become an application dependency.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/license_gate.dart';

const String _canonicalUnlicense = '''
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or distribute this software, either in source code form or as a compiled binary, for any purpose, commercial or non-commercial, and by any means.

In jurisdictions that recognize copyright laws, the author or authors of this software dedicate any and all copyright interest in the software to the public domain. We make this dedication for the benefit of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of relinquishment in perpetuity of all present and future rights to this software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <http://unlicense.org/>
''';

void main() {
  late Directory sandbox;
  late _GitFixture spdx;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-license-gate-test-',
    );
    spdx = _GitFixture.create(p.join(sandbox.path, 'spdx'), {
      'text/Unlicense.txt': _canonicalUnlicense,
    });
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('passes without Séance dependencies', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      includeMarker: false,
    );

    final report = await _verify(project, spdx, LicenseGateMode.markerOnly);

    expect(report.declarationCount, 0);
    expect(report.pinnedRevisionCount, 0);
  });

  test('requires the marker when a declaration is added', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
      includeMarker: false,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('missing the required'),
        ),
      ),
    );
  });

  test('fails closed when a declaration has no lock entry', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
      includeLockEntry: false,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('is not resolved'),
        ),
      ),
    );
  });

  test('fails closed when a git lock omits its resolved commit', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    final lock = File(p.join(project.directory.path, 'pubspec.lock'));
    lock.writeAsStringSync(
      lock.readAsStringSync().replaceFirst(
        '      resolved-ref: ${seance.revision}\n',
        '',
      ),
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('no full resolved-ref'),
        ),
      ),
    );
  });

  test('fails closed when the resolving lock is untracked', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _git(project.directory, const ['rm', '--cached', 'pubspec.lock']);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('committed and clean'),
        ),
      ),
    );
  });

  test('fails closed when dependency resolution changes the lock', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    final lock = File(p.join(project.directory.path, 'pubspec.lock'));
    lock.writeAsStringSync('${lock.readAsStringSync()}# changed by pub get\n');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('committed and clean'),
        ),
      ),
    );
  });

  test('fails closed on malformed dependency YAML', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      includeMarker: false,
    );
    _write(project.directory, 'pubspec.yaml', 'dependencies: [\n');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('invalid YAML'),
        ),
      ),
    );
  });

  test('does not let a root lock cover a standalone package', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, 'tool/bench/pubspec.yaml', '''
name: bench
dependencies:
  seance_core:
    git:
      url: ${seance.directory.path}
      ref: ${seance.revision}
      path: packages/seance_core
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('not covered by a pubspec.lock'),
        ),
      ),
    );
  });

  for (final fileName in const ['pubspec.yaml', 'pubspec.lock']) {
    test('rejects a symlinked $fileName', () async {
      final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
        'LICENSE': _canonicalUnlicense,
      });
      final project = _ProjectFixture.create(
        p.join(sandbox.path, 'project'),
        seance: seance,
      );
      final file = File(p.join(project.directory.path, fileName));
      final targetName = 'real-$fileName';
      file.renameSync(p.join(project.directory.path, targetName));
      Link(file.path).createSync(targetName);

      await expectLater(
        _verify(project, spdx, LicenseGateMode.markerOnly),
        throwsA(
          isA<LicenseGateException>().having(
            (error) => error.message,
            'message',
            contains('symbolic link'),
          ),
        ),
      );
    });
  }

  test('requires the marker for a lock-only Séance pin', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      includeMarker: false,
    );
    _write(project.directory, 'pubspec.lock', '''
packages:
  seance_protocol:
    dependency: transitive
    description:
      path: packages/seance_protocol
      ref: v0.8.0
      resolved-ref: ${seance.revision}
      url: ${seance.directory.path}
    source: git
    version: "0.8.0"
''');
    _commitProjectChanges(project.directory);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('missing the required'),
        ),
      ),
    );
  });

  test('scans tracked manifests under generated directory names', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      includeMarker: false,
    );
    _write(project.directory, 'build/pubspec.yaml', '''
name: nested
dependencies:
  seance_core:
    git:
      url: ${seance.directory.path}
      ref: v0.8.0
      path: packages/seance_core
''');
    _write(project.directory, 'build/pubspec.lock', '''
packages:
  seance_core:
    dependency: "direct main"
    description:
      path: packages/seance_core
      ref: v0.8.0
      resolved-ref: ${seance.revision}
      url: ${seance.directory.path}
    source: git
    version: "0.8.0"
''');
    _commitProjectChanges(project.directory);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('missing the required'),
        ),
      ),
    );
  });

  test('accepts every permitted SPDX license and file name', () async {
    const licenses = {
      'Unlicense': 'canonical unlicense terms',
      'MIT': 'canonical mit terms',
      'Apache-2.0': 'canonical apache terms',
      'BSD-2-Clause': 'canonical bsd two terms',
      'BSD-3-Clause': 'canonical bsd three terms',
      'ISC': 'canonical isc terms',
    };
    const licenseFiles = {
      'LICENSE': 'canonical unlicense terms',
      'LICENSE.txt': 'canonical mit terms',
      'LICENSE.md': 'canonical apache terms',
      'LICENCE': 'canonical bsd two terms',
      'UNLICENSE': 'canonical bsd three terms',
      'COPYING': 'canonical isc terms',
    };
    final allSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-all'), {
      for (final entry in licenses.entries)
        'text/${entry.key}.txt': entry.value,
    });
    final seance = _GitFixture.create(
      p.join(sandbox.path, 'Seance'),
      licenseFiles,
    );
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    final report = await _verify(
      project,
      allSpdx,
      LicenseGateMode.release,
      permittedLicenseIds: licenses.keys.toSet(),
    );

    expect(report.matchedLicenseIds, licenses.keys.toSet());
  });

  test('ignores copyright notices wherever they appear', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Unlicense.txt': 'first term\nsecond term',
    });
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': '''
Copyright 2024 Before
first term
Copyright (c) 2025 Middle
second term
Copyright © 2026 After
''',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    final report = await _verify(
      project,
      customSpdx,
      LicenseGateMode.release,
      permittedCopyrightHolders: {'Before', 'Middle', 'After'},
    );

    expect(report.matchedLicenseIds, {'Unlicense'});
  });

  test('does not erase substantive copyright restrictions', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Unlicense.txt': 'first term\nsecond term',
    });
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': '''
first term
Copyright © 2026 Example disallows redistribution.
second term
''',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    await expectLater(
      _verify(project, customSpdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted LICENSE'),
        ),
      ),
    );
  });

  test('does not mistake a limited grant for a holder name', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Unlicense.txt': 'first term\nsecond term',
    });
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': '''
first term
Copyright © 2026 Example grants use only for evaluation.
second term
''',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    await expectLater(
      _verify(project, customSpdx, LicenseGateMode.release),
      throwsA(isA<LicenseGateException>()),
    );
  });

  for (final restriction in const [
    'ACME PERSONAL USE ONLY',
    'Acme Proprietary',
    'Acme No Sharing',
    'Acme Not Free',
  ]) {
    test('does not erase notice-shaped restriction: $restriction', () async {
      final customSpdx = _GitFixture.create(
        p.join(sandbox.path, 'spdx-custom'),
        {'text/Unlicense.txt': 'first term\nsecond term'},
      );
      final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
        'LICENSE':
            '''
first term
Copyright 2026 $restriction
second term
''',
      });
      final project = _ProjectFixture.create(
        p.join(sandbox.path, 'project'),
        seance: seance,
      );

      await expectLater(
        _verify(project, customSpdx, LicenseGateMode.release),
        throwsA(isA<LicenseGateException>()),
      );
    });
  }

  test('matches an Apache placeholder to an actual notice', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Apache-2.0.txt': '''
first term
Copyright [yyyy] [name of copyright owner]
second term
''',
    });
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': '''
first term
Copyright 2026 Example
second term
''',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    final report = await _verify(
      project,
      customSpdx,
      LicenseGateMode.release,
      permittedLicenseIds: {'Apache-2.0'},
      permittedCopyrightHolders: {'Example'},
    );

    expect(report.matchedLicenseIds, {'Apache-2.0'});
  });

  test('accepts the canonical Unlicense from the pinned tree', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    final report = await _verify(project, spdx, LicenseGateMode.release);

    expect(report.pinnedRevisionCount, 1);
    expect(report.matchedLicenseIds, {'Unlicense'});
  });

  test('rejects a missing license in the pinned tree', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'README.md': 'No license yet.',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('no recognized license'),
        ),
      ),
    );
  });

  test('rejects restrictive content under a recognized name', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'COPYING': 'GNU GENERAL PUBLIC LICENSE Version 3',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted COPYING'),
        ),
      ),
    );
  });

  test('checks the locked revision rather than repository HEAD', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'README.md': 'No license yet.',
    });
    final unlicensedRevision = seance.revision;
    seance.commit({'LICENSE': _canonicalUnlicense});
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
      lockedRevision: unlicensedRevision,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects a second restrictive license candidate', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
      'COPYING': 'GNU GENERAL PUBLIC LICENSE Version 3',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted COPYING'),
        ),
      ),
    );
  });

  test('rejects one restrictive revision among multiple pins', () async {
    final core = _GitFixture.create(p.join(sandbox.path, 'Seance-core'), {
      'LICENSE': _canonicalUnlicense,
    });
    final protocol = _GitFixture.create(
      p.join(sandbox.path, 'Seance-protocol'),
      {'LICENSE': 'Copyright holders prohibit redistribution.'},
    );
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: core,
    );
    final lock = File(p.join(project.directory.path, 'pubspec.lock'));
    lock.writeAsStringSync('''
${lock.readAsStringSync()}
  seance_protocol:
    dependency: transitive
    description:
      path: packages/seance_protocol
      ref: v0.8.0
      resolved-ref: ${protocol.revision}
      url: ${protocol.directory.path}
    source: git
    version: "0.8.0"
''');
    _commitProjectChanges(project.directory);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('seance_protocol'),
        ),
      ),
    );
  });

  test('rejects a gate that runs before dependency resolution', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: dart pub get
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('before dependency resolution'),
        ),
      ),
    );
  });

  test('rejects a publisher that bypasses the gate job', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
  publish:
    needs: gate
    steps:
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('bypasses the license gate'),
        ),
      ),
    );
  });

  test('rejects a disabled gate step', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - if: false
        run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects a soft-failing gate step', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - continue-on-error: true
        run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects a commented marker paired with an echo', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      # run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: echo dart run tool/license_gate/bin/check.dart
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects a same-job gate after publishing', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - uses: softprops/action-gh-release@v2
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects dependency resolution after the gate', () async {
    final seance = _GitFixture.create(p.join(sandbox.path, 'Seance'), {
      'LICENSE': _canonicalUnlicense,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seance: seance,
    );
    _write(project.directory, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: flutter build apk
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('after the license gate'),
        ),
      ),
    );
  });
}

Future<LicenseGateReport> _verify(
  _ProjectFixture project,
  _GitFixture spdx,
  LicenseGateMode mode, {
  Set<String> permittedLicenseIds = const {'Unlicense'},
  Set<String> permittedCopyrightHolders = const {'L-K-M'},
}) => verifySeanceLicenseGate(
  repositoryRoot: project.directory,
  mode: mode,
  settings: LicenseGateSettings(
    spdxRepository: spdx.directory.path,
    spdxRevision: spdx.revision,
    permittedLicenseIds: permittedLicenseIds,
    permittedCopyrightHolders: permittedCopyrightHolders,
  ),
);

final class _ProjectFixture {
  final Directory directory;

  const _ProjectFixture._(this.directory);

  static _ProjectFixture create(
    String path, {
    _GitFixture? seance,
    bool includeMarker = true,
    bool includeLockEntry = true,
    String? lockedRevision,
  }) {
    final directory = Directory(path)..createSync(recursive: true);
    _write(
      directory,
      '.github/workflows/release.yml',
      includeMarker
          ? '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - uses: softprops/action-gh-release@v2
'''
          : 'name: Release\n',
    );

    if (seance == null) {
      _write(directory, 'pubspec.yaml', 'name: fixture\n');
      _write(directory, 'pubspec.lock', 'packages: {}\n');
      _commitProject(directory);
      return _ProjectFixture._(directory);
    }

    final revision = lockedRevision ?? seance.revision;
    _write(directory, 'pubspec.yaml', '''
name: fixture
dependencies:
  seance_core:
    git:
      url: ${seance.directory.path}
      ref: $revision
      path: packages/seance_core
''');
    _write(
      directory,
      'pubspec.lock',
      includeLockEntry
          ? '''
packages:
  seance_core:
    dependency: "direct main"
    description:
      path: packages/seance_core
      ref: $revision
      resolved-ref: $revision
      url: ${seance.directory.path}
    source: git
    version: "0.8.0"
'''
          : 'packages: {}\n',
    );
    _commitProject(directory);
    return _ProjectFixture._(directory);
  }
}

final class _GitFixture {
  final Directory directory;
  String revision;

  _GitFixture._(this.directory, this.revision);

  static _GitFixture create(String path, Map<String, String> files) {
    final directory = Directory(path)..createSync(recursive: true);
    _git(directory, const ['init', '--quiet']);
    _git(directory, const ['config', 'user.name', 'Fixture']);
    _git(directory, const ['config', 'user.email', 'fixture@example.invalid']);
    final fixture = _GitFixture._(directory, '');
    fixture.commit(files);
    return fixture;
  }

  void commit(Map<String, String> files) {
    for (final entry in files.entries) {
      _write(directory, entry.key, entry.value);
    }
    _git(directory, const ['add', '.']);
    _git(directory, const ['commit', '--quiet', '-m', 'Fixture']);
    revision = _git(directory, const ['rev-parse', 'HEAD']).trim();
  }
}

void _write(Directory root, String relativePath, String contents) {
  final file = File(p.join(root.path, relativePath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void _commitProject(Directory directory) {
  _git(directory, const ['init', '--quiet']);
  _git(directory, const ['config', 'user.name', 'Fixture']);
  _git(directory, const ['config', 'user.email', 'fixture@example.invalid']);
  _git(directory, const ['add', '.']);
  _git(directory, const ['commit', '--quiet', '-m', 'Fixture']);
}

void _commitProjectChanges(Directory directory) {
  _git(directory, const ['add', '.']);
  _git(directory, const ['commit', '--quiet', '-m', 'Change fixture']);
}

String _git(Directory directory, List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  if (result.exitCode == 0) return result.stdout as String;

  throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
}
