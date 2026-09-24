import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// The Unix launch chain behind a local file's Open: `xdg-open`, then
/// `gio open` when xdg-utils is not installed, typed failures otherwise.
void main() {
  final calls = <List<String>>[];

  OpenerProcessRunner runner(Map<String, ProcessResult?> results) =>
      (executable, arguments) async {
        calls.add([executable, ...arguments]);
        final result = results[executable];
        if (result == null) {
          throw ProcessException(
            executable,
            arguments,
            'No such file or directory',
            2,
          );
        }
        return result;
      };

  ProcessResult exit(int code, [String stderr = '']) =>
      ProcessResult(0, code, '', stderr);

  setUp(calls.clear);

  test('xdg-open handles the file when it is installed', () async {
    final opener = LocalFileOpener.unix(run: runner({'xdg-open': exit(0)}));

    await opener.open('/home/me/a b.txt');

    expect(calls, [
      ['xdg-open', '/home/me/a b.txt'],
    ]);
  });

  test('a missing xdg-open falls back to gio open', () async {
    final opener = LocalFileOpener.unix(run: runner({'gio': exit(0)}));

    await opener.open('/home/me/report.pdf');

    expect(calls, [
      ['xdg-open', '/home/me/report.pdf'],
      ['gio', 'open', '/home/me/report.pdf'],
    ]);
  });

  test('gio failing reports its own error', () async {
    final opener = LocalFileOpener.unix(
      run: runner({'gio': exit(1, 'gio: No application is registered')}),
    );

    await expectLater(
      opener.open('/home/me/big.bin'),
      throwsA(
        isA<RemoteFileException>()
            .having((e) => e.operation, 'operation', 'open')
            .having((e) => e.message, 'message', contains('No application')),
      ),
    );
  });

  test('no opener at all is a typed launch failure', () async {
    final opener = LocalFileOpener.unix(run: runner({}));

    await expectLater(
      opener.open('/home/me/big.bin'),
      throwsA(
        isA<RemoteFileException>()
            .having((e) => e.path, 'path', '/home/me/big.bin')
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.other),
      ),
    );
  });

  test('macOS never falls back past open', () async {
    final opener = LocalFileOpener.unix(run: runner({}), isMacOS: true);

    await expectLater(
      opener.open('/Users/me/a.txt'),
      throwsA(isA<RemoteFileException>()),
    );
    expect(calls, [
      ['open', '/Users/me/a.txt'],
    ]);
  });
}
