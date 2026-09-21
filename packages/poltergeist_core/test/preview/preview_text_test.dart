// Contract tests for the 1 MiB preview text loader (06 §5.3).

import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-pt-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  test('loads a small text file whole', () async {
    final file = await writeFile('a.txt', utf8.encode('hello\nworld\n'));
    final result = await loadPreviewText(file);
    expect(result.text, 'hello\nworld\n');
    expect(result.truncated, isFalse);
  });

  test('truncates at the 1 MiB window on a codepoint boundary', () async {
    // Fill past the window with ASCII, then straddle the boundary with
    // a multi-byte codepoint — the loader must clip the partial tail
    // rather than emit a malformed trailing byte. é(2)+🚀(4) place the
    // 🚀 lead byte at window-2, so the window ends mid-codepoint.
    final pad = List<int>.filled(previewTextMaximumBytes - 4, 0x61);
    final tail = utf8.encode('é🚀and a lot more trailing text');
    final file = await writeFile('big.txt', [...pad, ...tail]);
    final result = await loadPreviewText(file);
    expect(result.truncated, isTrue);
    expect(utf8.encode(result.text).length, lessThanOrEqualTo(
      previewTextMaximumBytes,
    ));
    // Decoded text ends on a whole codepoint.
    expect(result.text.endsWith('\uFFFD'), isFalse);
    expect(result.text.length, greaterThan(previewTextMaximumBytes - 20));
  });

  test('strips a leading UTF-8 BOM', () async {
    final file = await writeFile(
      'bom.txt',
      [0xEF, 0xBB, 0xBF, ...utf8.encode('content')],
    );
    final result = await loadPreviewText(file);
    expect(result.text, 'content');
  });

  test('refuses invalid UTF-8 with the §1 string', () async {
    final file = await writeFile('bad.txt', [0xFF, 0xFE, 0x00, 0x01]);
    expect(
      () => loadPreviewText(file),
      throwsA(
        isA<BuiltInEditorException>().having(
          (e) => e.message,
          'message',
          'This file is not valid UTF-8 text.',
        ),
      ),
    );
  });

  test('refuses NUL-bearing bytes as binary', () async {
    final file = await writeFile(
      'nul.txt',
      utf8.encode('has a \x00 byte'),
    );
    expect(
      () => loadPreviewText(file),
      throwsA(
        isA<BuiltInEditorException>().having(
          (e) => e.message,
          'message',
          'This file appears to be binary, not editable text.',
        ),
      ),
    );
  });

  test('fileLooksLikeUtf8Text classifies without throwing', () async {
    expect(
      await fileLooksLikeUtf8Text(
        await writeFile('ok', utf8.encode('plain')),
      ),
      isTrue,
    );
    expect(
      await fileLooksLikeUtf8Text(await writeFile('bin', [0, 1, 2, 3])),
      isFalse,
    );
  });
}
