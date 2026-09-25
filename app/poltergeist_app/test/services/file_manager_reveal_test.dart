import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/file_manager_reveal.dart';

void main() {
  late List<(String, List<String>)> calls;
  RevealProcessRunner runner(
    Map<String, int> exitCodes, {
    Set<String> missing = const {},
  }) => (executable, arguments) async {
    calls.add((executable, arguments));
    if (missing.contains(executable)) {
      throw ProcessException(executable, arguments, 'not found', 2);
    }
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

  test('Linux keeps a comma inside the one ShowItems item', () async {
    // dbus-send splits `array:string:` values on commas with no escape,
    // so a bare comma would ask for two items that do not exist.
    final revealer = FileManagerRevealer(
      run: runner({}),
      operatingSystem: 'linux',
    );
    expect(await revealer.reveal('/home/me/a,b.txt'), isTrue);
    final (_, args) = calls.single;
    expect(args, contains('array:string:file:///home/me/a%2Cb.txt'));
  });

  test('Linux falls back to xdg-open when dbus-send is missing', () async {
    final revealer = FileManagerRevealer(
      run: runner({}, missing: {'dbus-send'}),
      operatingSystem: 'linux',
    );
    expect(await revealer.reveal('/home/me/docs/report.pdf'), isTrue);
    expect(calls.last.$1, 'xdg-open');
    expect(calls.last.$2, ['/home/me/docs']);
  });

  test('Linux falls back to gio when xdg-open cannot open it either', () async {
    final revealer = FileManagerRevealer(
      run: runner({'dbus-send': 1}, missing: {'xdg-open'}),
      operatingSystem: 'linux',
    );
    expect(await revealer.reveal('/home/me/docs/report.pdf'), isTrue);
    expect(calls.last.$1, 'gio');
    expect(calls.last.$2, ['open', '/home/me/docs']);
  });

  test('Linux reports failure when nothing opens the folder', () async {
    final revealer = FileManagerRevealer(
      run: runner({'dbus-send': 1, 'xdg-open': 3}, missing: {'gio'}),
      operatingSystem: 'linux',
    );
    expect(await revealer.reveal('/home/me/docs/report.pdf'), isFalse);
    expect(
      [for (final (exe, _) in calls) exe],
      ['dbus-send', 'xdg-open', 'gio'],
    );
  });

  test('Windows quotes the path so a comma cannot split it', () async {
    // Explorer parses its own command line and splits /select's target
    // on commas unless it is quoted; Dart would escape a quote inside an
    // argument (\"), so the whole line rides in the executable slot,
    // which Dart hands to CreateProcessW verbatim once it holds a quote.
    final revealer = FileManagerRevealer(
      run: runner({}),
      operatingSystem: 'windows',
    );
    expect(await revealer.reveal(r'C:\dir\a,b.txt'), isTrue);
    expect(calls.single.$1, r'explorer.exe /select,"C:\dir\a,b.txt"');
    expect(calls.single.$2, isEmpty);
  });

  test('Windows reports failure when Explorer cannot start', () async {
    final revealer = FileManagerRevealer(
      run: runner({}, missing: {r'explorer.exe /select,"C:\x.txt"'}),
      operatingSystem: 'windows',
    );
    expect(await revealer.reveal(r'C:\x.txt'), isFalse);
  });

  test('Windows selects the item in Explorer whatever its exit code', () async {
    final revealer = FileManagerRevealer(
      run: runner({r'explorer.exe /select,"C:\Users\me\file.txt"': 1}),
      operatingSystem: 'windows',
    );
    expect(await revealer.reveal(r'C:\Users\me\file.txt'), isTrue);
    expect(calls.single.$1, startsWith('explorer.exe '));
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
