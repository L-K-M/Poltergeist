import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/file_manager_reveal.dart';

void main() {
  late List<(String, List<String>)> calls;
  RevealProcessRunner runner(Map<String, int> exitCodes) =>
      (executable, arguments) async {
        calls.add((executable, arguments));
        return exitCodes[executable] ?? 0;
      };

  setUp(() => calls = []);

  test('macOS reveals through Finder with open -R', () async {
    final revealer = FileManagerRevealer(
      run: runner({}),
      operatingSystem: 'macos',
    );
    expect(await revealer.reveal('/Users/me/notes.txt'), isTrue);
    expect(calls.single.$1, 'open');
    expect(calls.single.$2, ['-R', '/Users/me/notes.txt']);
  });

  test('Linux asks FileManager1.ShowItems with the file URI', () async {
    final revealer = FileManagerRevealer(
      run: runner({}),
      operatingSystem: 'linux',
    );
    expect(await revealer.reveal('/home/me/a b.txt'), isTrue);
    final (exe, args) = calls.single;
    expect(exe, 'dbus-send');
    expect(args, contains('org.freedesktop.FileManager1.ShowItems'));
    expect(args, contains('array:string:file:///home/me/a%20b.txt'));
  });

  test('Linux falls back to opening the parent folder', () async {
    final revealer = FileManagerRevealer(
      run: runner({'dbus-send': 1}),
      operatingSystem: 'linux',
    );
    expect(await revealer.reveal('/home/me/docs/report.pdf'), isTrue);
    expect(calls.last.$1, 'xdg-open');
    expect(calls.last.$2, ['/home/me/docs']);
  });

  test('Windows selects the item in Explorer whatever its exit code', () async {
    final revealer = FileManagerRevealer(
      run: runner({'explorer': 1}),
      operatingSystem: 'windows',
    );
    expect(await revealer.reveal(r'C:\Users\me\file.txt'), isTrue);
    expect(calls.single.$1, 'explorer');
  });

  test('other platforms are unsupported and never spawn anything', () async {
    final revealer = FileManagerRevealer(
      run: runner({}),
      operatingSystem: 'android',
    );
    expect(revealer.supported, isFalse);
    expect(await revealer.reveal('/sdcard/x'), isFalse);
    expect(calls, isEmpty);
  });
}
