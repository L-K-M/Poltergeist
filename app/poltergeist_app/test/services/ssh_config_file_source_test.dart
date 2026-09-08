import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/ssh_config_file_source.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ssh-import-source-');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('reads existing files and reports missing ones as null', () async {
    final file = File('${temp.path}${Platform.pathSeparator}config');
    file.writeAsStringSync('Host web\n');

    const source = LocalSshConfigFileSource();
    expect(await source.readText(file.path), 'Host web\n');
    expect(await source.readText('${temp.path}/missing'), isNull);
  });

  test('non-UTF-8 bytes decode leniently instead of failing the read',
      () async {
    // A cp1252 smart quote in a comment (0x94) is legal bytes for ssh;
    // strict UTF-8 would throw and make the config look unreadable.
    final file = File('${temp.path}${Platform.pathSeparator}config');
    file.writeAsBytesSync([
      0x23, 0x20, 0x72, 0x65, 0x6d, 0x6f, 0x74, 0x65, // "# remote"
      0x20, 0x94, 0x0a, // " \x94\n"
      0x48, 0x6f, 0x73, 0x74, 0x20, 0x77, 0x65, 0x62, 0x0a, // "Host web\n"
    ]);

    final text = await const LocalSshConfigFileSource().readText(file.path);
    expect(text, isNotNull);
    expect(text, contains('Host web'));
  });

  test('lists regular files lexically, following symlinks', () async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}config.d');
    dir.createSync();
    File('${dir.path}${Platform.pathSeparator}b.conf')
        .writeAsStringSync('Host b\n');
    File('${dir.path}${Platform.pathSeparator}a.conf')
        .writeAsStringSync('Host a\n');

    final link = Link('${dir.path}${Platform.pathSeparator}linked.conf');
    link.createSync('${dir.path}${Platform.pathSeparator}a.conf');

    final listing = await const LocalSshConfigFileSource()
        .listLexical(dir.path);
    expect(listing, isNotNull);
    // The symlink to a file is included; order is lexical.
    expect(
      listing!.map((path) => path.split(Platform.pathSeparator).last),
      ['a.conf', 'b.conf', 'linked.conf'],
    );
  });

  test('a missing directory lists as null, an empty one as empty', () async {
    const source = LocalSshConfigFileSource();
    expect(await source.listLexical('${temp.path}/missing'), isNull);

    final empty = Directory('${temp.path}${Platform.pathSeparator}empty')
      ..createSync();
    expect(await source.listLexical(empty.path), isEmpty);
  });
}
