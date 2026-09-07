// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/protocol_guard.dart';

const _core = 'packages/poltergeist_core';
const _engine = '$_core/lib/src/engine';

void main() {
  late _Fixture fixture;
  setUp(() async => fixture = await _Fixture._create());
  tearDown(() async => fixture._root.delete(recursive: true));

  test(
    'accepts data fields, methods, getters, comments, and strings',
    () async {
      await fixture._write('$_engine/data.dart', '''
// Function callback; class Escaped extends EngineEvent {}
class Data {
  final bytes = 3;
  final label = 'void Function() callback';
  void consume(void Function() callback) => callback();
  void Function() get callback => () {};
}
''');
      expect(await fixture._check(), isEmpty);
    },
  );

  for (final declaration in [
    'late Function callback;',
    'late Function? callback;',
    'late void Function() callback;',
    'late Callback callback;',
    'final callback = () {};',
    'final callback = tearOff;',
    'static final callback = tearOff;',
    'late T callback;',
    'late List<Callback> callback;',
    'late ({Callback callback, int bytes}) callback;',
  ]) {
    test('rejects resolved callback field: $declaration', () async {
      await fixture._write('$_engine/types.dart', '''
typedef Callback = void Function();
void tearOff() {}
''');
      await fixture._write('$_engine/data.dart', '''
import 'types.dart';
class Data<T extends Function> { $declaration }
''');
      expect(await fixture._check(), [contains('Data.callback')]);
    });
  }

  test('allows only the named internal class in its exact file', () async {
    await fixture._write('$_engine/progress_coalescer.dart', '''
class ProgressCoalescer { final callback = () {}; }
class Other { final callback = () {}; }
''');
    await fixture._write('$_engine/connect_log_coalescer.dart', '''
class ConnectLogCoalescer { final callback = () {}; }
class OtherLog { final callback = () {}; }
''');
    await fixture._write('$_engine/elsewhere.dart', '''
class ProgressCoalescer { final callback = () {}; }
class ConnectLogCoalescer { final callback = () {}; }
''');
    final violations = await fixture._check();
    expect(violations, hasLength(4));
    expect(violations, contains(contains('Other.callback')));
    expect(violations, contains(contains('OtherLog.callback')));
    expect(violations, contains(contains('elsewhere.dart: ProgressCoalescer')));
    expect(
      violations,
      contains(contains('elsewhere.dart: ConnectLogCoalescer')),
    );
  });

  test('an allowlisted class cannot become a protocol subtype', () async {
    await fixture._write('$_engine/progress_coalescer.dart', '''
import 'protocol.dart';
class ProgressCoalescer extends EngineEvent { final callback = () {}; }
''');
    expect(await fixture._check(), [contains('ProgressCoalescer.callback')]);
  });

  test('the connect-log coalescer cannot become a protocol subtype either',
      () async {
    await fixture._write('$_engine/connect_log_coalescer.dart', '''
import 'protocol.dart';
class ConnectLogCoalescer extends EngineEvent { final callback = () {}; }
''');
    expect(
        await fixture._check(), [contains('ConnectLogCoalescer.callback')]);
  });

  for (final source in [
    'class Escaped extends EngineEvent {}',
    'class Escaped implements EngineRequest {}',
    'class Escaped extends Intermediate {}',
    'typedef Alias = EngineEvent; class Escaped extends Alias {}',
    'mixin Helper {} class Escaped = EngineEvent with Helper;',
    'enum Escaped implements EngineEvent { value }',
    'extension type Escaped(Intermediate value) implements EngineEvent {}',
  ]) {
    test('rejects relocated protocol subtype: $source', () async {
      await fixture._write('$_core/lib/escaped.dart', '''
import 'src/engine/protocol.dart';
$source
''');
      expect(await fixture._check(), [contains('Escaped is outside engine/')]);
    });
  }

  test('rejects an extension type callback representation', () async {
    await fixture._write('$_engine/wrapper.dart', '''
extension type Wrapper(void Function() callback) {}
''');
    expect(await fixture._check(), [contains('Wrapper.callback')]);
  });

  for (final fieldType in [
    'CallbackWrapper',
    'Nested',
    'Generic<int>',
    'Container<CallbackWrapper>',
    'List<CallbackWrapper>',
    '({CallbackWrapper value, int bytes})',
  ]) {
    test('rejects external callback wrapper field: $fieldType', () async {
      await fixture._write('$_core/lib/wrapper.dart', '''
extension type CallbackWrapper(void Function() value) {}
extension type Nested(CallbackWrapper value) {}
extension type Generic<T>(void Function(T) value) {}
extension type Container<T>(T value) {}
''');
      await fixture._write('$_engine/data.dart', '''
import '../../wrapper.dart';
class Data { late $fieldType callback; }
''');
      expect(await fixture._check(), [contains('Data.callback')]);
    });
  }

  test(
    'allows a phantom callback argument with an integer representation',
    () async {
      await fixture._write('$_core/lib/wrapper.dart', '''
extension type Phantom<T>(int value) {}
''');
      await fixture._write('$_engine/data.dart', '''
import '../../wrapper.dart';
class Data { late Phantom<void Function()> value; }
''');
      expect(await fixture._check(), isEmpty);
    },
  );

  for (final (base, declaration) in [
    (
      'class Base { final void Function() callback = () {}; }',
      'class Data extends Base {}',
    ),
    ('mixin Hooks { final callback = () {}; }', 'class Data with Hooks {}'),
    (
      'class Base<T> { late T callback; }',
      'class Data extends Base<void Function()> {}',
    ),
    (
      'class Base<T> { late T callback; } '
          'class Middle<U> extends Base<List<U>> {}',
      'class Data extends Middle<void Function()> {}',
    ),
    (
      'class Base { final void Function() callback = () {}; }',
      'class Data extends Base { '
          '@override void Function() get callback => () {}; }',
    ),
  ]) {
    test('rejects inherited callback storage: $declaration', () async {
      await fixture._write('$_core/lib/base.dart', base);
      await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
$declaration
''');
      expect(await fixture._check(), [contains('Data.callback')]);
    });
  }

  test('rejects inherited private callback storage', () async {
    await fixture._write('$_core/lib/base.dart', '''
class Base { final _callback = () {}; }
''');
    await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
class Data extends Base {}
''');
    expect(await fixture._check(), [contains('Data._callback')]);
  });

  test('allows static superclass callbacks and computed getters', () async {
    await fixture._write('$_core/lib/base.dart', '''
class Base {
  static final callback = () {};
  void Function() get computed => () {};
}
''');
    await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
class Data extends Base {}
''');
    expect(await fixture._check(), isEmpty);
  });

  test(
    'allows interface-only callback fields implemented by getters',
    () async {
      await fixture._write('$_core/lib/base.dart', '''
class Base { final void Function() callback = () {}; }
''');
      await fixture._write('$_engine/data.dart', '''
import '../../base.dart';
class Data implements Base {
  @override void Function() get callback => () {};
}
''');
      expect(await fixture._check(), isEmpty);
    },
  );

  test('an allowlisted payload cannot use inherited callbacks', () async {
    await fixture._write('$_core/lib/base.dart', '''
class Base { final void Function() callback = () {}; }
''');
    await fixture._write('$_engine/progress_coalescer.dart', '''
import '../../base.dart';
import 'protocol.dart';
class ProgressCoalescer extends Base implements EngineEvent {}
''');
    expect(await fixture._check(), [contains('ProgressCoalescer.callback')]);
  });

  test(
    'detects relocation into app despite unresolved Flutter imports',
    () async {
      await fixture._write('app/poltergeist_app/lib/escaped.dart', '''
import 'package:flutter/widgets.dart';
import 'package:poltergeist_core/src/engine/protocol.dart' as engine;
class Escaped extends engine.EngineEvent {}
''');
      expect(await fixture._check(), [contains('Escaped is outside engine/')]);
    },
  );

  test(
    'finds callbacks in mixins and source directories named build',
    () async {
      await fixture._write('$_engine/build/hooks.dart', '''
mixin Hooks { final callback = () {}; }
''');
      expect(await fixture._check(), [contains('Hooks.callback')]);
    },
  );

  test('ignores generated outputs and the benchmark harness', () async {
    for (final directory in [
      '$_core/build',
      'app/poltergeist_app/linux/flutter/ephemeral',
      'tool/bench/lib',
    ]) {
      await fixture._write('$directory/generated.dart', 'not valid Dart');
    }
    expect(await fixture._check(), isEmpty);
  });

  for (final directory in ['packages', 'app', _engine]) {
    test('fails closed without $directory', () async {
      await Directory(
        p.join(fixture._root.path, directory),
      ).delete(recursive: true);
      await expectLater(fixture._check(), throwsA(isA<FileSystemException>()));
    });
  }

  test('fails closed on an empty engine directory', () async {
    await File(p.join(fixture._root.path, '$_engine/protocol.dart')).delete();
    await expectLater(fixture._check(), throwsFormatException);
  });

  test('fails closed on malformed Dart', () async {
    await fixture._write('$_engine/data.dart', 'class Unfinished {');
    await expectLater(fixture._check(), throwsA(anything));
  });

  test('fails closed on an unresolved engine field type', () async {
    await fixture._write(
      '$_engine/data.dart',
      'class Data { late Unknown field; }',
    );
    await expectLater(fixture._check(), throwsFormatException);
  });

  test('fails closed on linked engine input', () async {
    await Link(
      p.join(fixture._root.path, '$_engine/linked.dart'),
    ).create('protocol.dart');
    await expectLater(fixture._check(), throwsA(isA<FileSystemException>()));
  });

  test('CLI exits distinguish clean, violations, and scan failures', () async {
    await fixture._expectExit(0);
    await fixture._write(
      '$_engine/data.dart',
      'class Data { final callback = () {}; }',
    );
    await fixture._expectExit(1, 'Data.callback');
    await fixture._write('$_engine/data.dart', 'class Unfinished {');
    await fixture._expectExit(2, 'protocol scan failed');
  });
}

class _Fixture {
  _Fixture(this._root);

  final Directory _root;

  static Future<_Fixture> _create() async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('protocol-guard-'),
    );
    await fixture._write('$_core/pubspec.yaml', '''
name: poltergeist_core
environment: {sdk: ^3.12.0}
''');
    await fixture._write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'poltergeist_core',
            'rootUri': '../$_core',
            'packageUri': 'lib/',
            'languageVersion': '3.12',
          },
        ],
      }),
    );
    await fixture._write('$_engine/protocol.dart', '''
abstract class EngineRequest {}
abstract class EngineEvent {}
class Intermediate extends EngineEvent {}
''');
    await Directory(p.join(fixture._root.path, 'app')).create();
    return fixture;
  }

  Future<void> _write(String path, String contents) async {
    final file = File(p.join(_root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<List<String>> _check() => checkProtocol(_root.path);

  Future<void> _expectExit(int expected, [String? diagnostic]) async {
    // Resolve from the workspace so nested test invocations find the same CLI.
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_poltergeist_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved');

    final script = workspace.resolve('../tool/protocol_guard/bin/check.dart');
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      script.toFilePath(),
      _root.path,
    ]);
    expect(
      result.exitCode,
      expected,
      reason: '${result.stdout}\n${result.stderr}',
    );
    if (diagnostic != null) expect(result.stderr, contains(diagnostic));
  }
}
