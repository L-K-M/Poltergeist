import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// Ported from Séance
// app/seance_app/test/built_in_text_editor_test.dart @ 2e6d1f1 (the
// document-I/O half; the widget half lives in the app's editor test) —
// with the Poltergeist divergences 06 §2.1 pins: LF/no-BOM in-memory
// text, the LineEnding enum, `.poltergeist-*` sibling names, owner-only
// temp permissions, and the symlink resolve/refuse rules.
void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'poltergeist-editor-test-',
    );
    // The safety layer refuses to walk pre-existing symlinked ancestors
    // (macOS temp dirs begin at one) — resolve once here like callers do.
    directory = Directory(await directory.resolveSymbolicLinks());
    file = File('${directory.path}/config.txt');
    await file.writeAsString('one\ntwo\n');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('loads UTF-8 and atomically saves edited text', () async {
    expect(await loadBuiltInTextDocument(file), 'one\ntwo\n');

    await saveBuiltInTextDocument(file, 'changed\n');

    expect(await file.readAsString(), 'changed\n');
    expect(await directory.list().length, 1);
  });

  test('preserves a UTF-8 BOM and CRLF line endings byte-for-byte', () async {
    await file.writeAsBytes([0xef, 0xbb, 0xbf, ...'one\r\ntwo\r\n'.codeUnits]);
    final document = await loadBuiltInTextDocumentDetails(file);

    // The in-memory invariant: LF, no BOM (06 §2.1).
    expect(document.text, 'one\ntwo\n');
    expect(document.hasUtf8Bom, isTrue);
    expect(document.lineEnding, LineEnding.crlf);

    await saveBuiltInTextDocument(
      file,
      '${document.text}three\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), [
      0xef,
      0xbb,
      0xbf,
      ...'one\r\ntwo\r\nthree\r\n'.codeUnits,
    ]);
  });

  test('a second leading BOM is content and survives the round trip', () async {
    // Utf8Decoder drops a BOM at the start of whatever it is handed, so
    // stripping one BOM and decoding the rest would also swallow the
    // U+FEFF right behind it (ported from Séance's fix).
    const bom = [0xef, 0xbb, 0xbf];
    await file.writeAsBytes([...bom, ...bom, ...bom, ...'a\n'.codeUnits]);
    final document = await loadBuiltInTextDocumentDetails(file);

    expect(document.hasUtf8Bom, isTrue);
    expect(document.text, '﻿﻿a\n');

    await saveBuiltInTextDocument(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), [
      ...bom,
      ...bom,
      ...bom,
      ...'a\n'.codeUnits,
    ]);
  });

  test('a BOM-less LF file round-trips byte-for-byte', () async {
    await file.writeAsBytes('one\ntwo\n'.codeUnits);
    final document = await loadBuiltInTextDocumentDetails(file);

    expect(document.text, 'one\ntwo\n');
    expect(document.hasUtf8Bom, isFalse);
    expect(document.lineEnding, LineEnding.lf);

    await saveBuiltInTextDocument(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'one\ntwo\n'.codeUnits);
  });

  test('mixed line endings normalize on first save by majority vote', () async {
    // 2 CRLF vs 1 lone LF — the vote is crlf, and the lone LF folds into
    // the family on save (06 §2.1's pinned normalization).
    await file.writeAsBytes('a\r\nb\nc\r\n'.codeUnits);
    final document = await loadBuiltInTextDocumentDetails(file);

    expect(document.text, 'a\nb\nc\n');
    expect(document.lineEnding, LineEnding.crlf);

    await saveBuiltInTextDocument(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'a\r\nb\r\nc\r\n'.codeUnits);
  });

  test('a lone-CR file votes LF and normalizes to LF on save', () async {
    // A lone \r never votes: a CR-only file saves back all-LF (06 §2.1).
    await file.writeAsBytes('a\rb\rc'.codeUnits);
    final document = await loadBuiltInTextDocumentDetails(file);

    expect(document.text, 'a\nb\nc');
    expect(document.lineEnding, LineEnding.lf);

    await saveBuiltInTextDocument(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'a\nb\nc'.codeUnits);
  });

  test('a single-line file never grows CRLF', () async {
    await file.writeAsString('single line, no breaks');
    final document = await loadBuiltInTextDocumentDetails(file);

    expect(document.lineEnding, LineEnding.lf);

    await saveBuiltInTextDocument(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'single line, no breaks'.codeUnits);
  });

  test('refuses to overwrite an independently changed local copy', () async {
    final document = await loadBuiltInTextDocumentDetails(file);
    await file.writeAsString('external change\n');

    await expectLater(
      saveBuiltInTextDocument(
        file,
        'built-in change\n',
        expectedSha256: document.sha256,
      ),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The local copy changed in another editor. Reopen it before '
              'saving to avoid losing those changes.',
        ),
      ),
    );
    // The external change survives untouched.
    expect(await file.readAsString(), 'external change\n');
  });

  test('rejects malformed, binary, and oversized content', () async {
    await file.writeAsBytes([0xff]);
    await expectLater(
      loadBuiltInTextDocument(file),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'This file is not valid UTF-8 text.',
        ),
      ),
    );

    await file.writeAsBytes([0, 1, 2]);
    await expectLater(
      loadBuiltInTextDocument(file),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'This file appears to be binary, not editable text.',
        ),
      ),
    );

    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      loadBuiltInTextDocument(file, maximumBytes: 2),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The built-in editor supports text files up to 0 MB.',
        ),
      ),
    );
  });

  test('refuses a file that changed while it was being opened', () async {
    var reads = 0;
    Future<String> tamperingSha256(File target) async {
      final digest = await streamedFileSha256(target);
      if (++reads == 1) {
        // Mutate between the pre-read and post-read digests — the
        // TOCTOU check must catch a file edited mid-open.
        await target.writeAsString('raced change\n');
      }
      return digest;
    }

    await expectLater(
      loadBuiltInTextDocumentDetails(file, sha256Of: tamperingSha256),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The local copy changed while it was being opened.',
        ),
      ),
    );
  });

  test('error messages surface bare — no Exception prefix', () async {
    await file.writeAsBytes([0xff]);
    try {
      await loadBuiltInTextDocument(file);
      fail('expected the load to refuse');
    } on BuiltInEditorException catch (error) {
      // §2.4's toast contract: error.toString() IS the message.
      expect(error.toString(), 'This file is not valid UTF-8 text.');
    }
  });

  test('the save refuses when the target vanished mid-save', () async {
    final document = await loadBuiltInTextDocumentDetails(file);
    await file.delete();
    await expectLater(
      saveBuiltInTextDocument(file, 'edit\n', expectedSha256: document.sha256),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The local copy is missing or no longer a regular file.',
        ),
      ),
    );
  });

  test('a symlinked local target resolves at open and saves through the '
      'link, leaving it intact', () async {
    if (Platform.isWindows) return; // symlink creation needs privileges
    final real = File('${directory.path}/real.conf');
    await real.writeAsString('one\n');
    final link = Link('${directory.path}/alias.conf');
    await link.create(real.path);

    final resolved = await resolveBuiltInEditorTarget(File(link.path));
    expect(resolved.path, real.path);

    final document = await loadBuiltInTextDocumentDetails(resolved);
    await saveBuiltInTextDocument(
      resolved,
      'edited\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    // The link still points at the real file — never replaced by a
    // regular file (06 §2.1 step 2).
    expect(
      await FileSystemEntity.type(link.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await real.readAsString(), 'edited\n');
  });

  test('the save refuses when the target became a symlink', () async {
    if (Platform.isWindows) return;
    final document = await loadBuiltInTextDocumentDetails(file);
    // Swap the target for a symlink after load — the save must refuse
    // rather than replace the link with a regular file.
    await file.delete();
    await Link(file.path).create('${directory.path}/elsewhere.conf');

    await expectLater(
      saveBuiltInTextDocument(file, 'edit\n', expectedSha256: document.sha256),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The local copy is a symbolic link, not a regular file.',
        ),
      ),
    );
    expect(
      await FileSystemEntity.type(file.path, followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test('the temp sibling is owner-only before the first write', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    // 0644 original: the only window the temp can sit at 0600 is between
    // step 1's chmod and step 4's mode restore (06 §2.1/§2.5).
    await Process.run('chmod', ['644', file.path]);
    File? temp;
    await saveBuiltInTextDocument(
      file,
      'edit\n',
      observeTemporary: (temporary) async {
        temp = temporary;
        final stat = await temporary.stat();
        expect(stat.mode & 0x1ff, 0x180); // 0600
      },
    );
    expect(temp, isNotNull);
    expect(await temp!.exists(), isFalse);
    // Step 4 restored the ORIGINAL mode — a 644 original saves back 644.
    final saved = await file.stat();
    expect(saved.mode & 0x1ff, 0x1a4);
  });

  test('a 0600 checkout stays 0600 after a save', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    await Process.run('chmod', ['600', file.path]);
    final document = await loadBuiltInTextDocumentDetails(file);
    await saveBuiltInTextDocument(
      file,
      'edit\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );
    final saved = await file.stat();
    expect(saved.mode & 0x1ff, 0x180);
  });

  test('the encoded output is size-checked too', () async {
    await expectLater(
      saveBuiltInTextDocument(file, 'x' * (builtInEditorMaximumBytes + 1)),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The edited file exceeds the 4 MB built-in editor limit.',
        ),
      ),
    );
  });

  test('the byte-cap sink aborts a stream at the limit', () async {
    final sink = _RecordingSink();
    final capped = MaximumByteSink(sink, maximumBytes: 8);
    await expectLater(
      capped.addStream(
        Stream.fromIterable([
          [1, 2, 3],
          [4, 5, 6],
          [7, 8, 9, 10],
        ]),
      ),
      throwsA(
        isA<CheckoutLimitException>().having(
          (error) => error.toString(),
          'message',
          'The file is larger than the 8-byte editor limit.',
        ),
      ),
    );
    // The third chunk trips the cap before it lands.
    expect(sink.bytes, [1, 2, 3, 4, 5, 6]);
  });

  test('the byte-cap sink passes through under the limit', () async {
    final sink = _RecordingSink();
    final capped = MaximumByteSink(sink, maximumBytes: 8);
    await capped.addStream(
      Stream.fromIterable([
        [1, 2, 3],
        [4, 5],
      ]),
    );
    await capped.close();
    expect(sink.bytes, [1, 2, 3, 4, 5]);
    expect(sink.closed, isTrue);
  });
}

final class _RecordingSink implements StreamSink<List<int>> {
  final bytes = <int>[];
  var closed = false;

  @override
  void add(List<int> event) => bytes.addAll(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> get done => Future.value();
}
