@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/src/engine/local_watch_backend.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a leaf watch works below a traverse-only ancestor',
    () async {
      final temporary = await Directory.systemTemp.createTemp('pg-watch-mode-');
      addTearDown(() => temporary.delete(recursive: true));
      final ancestor = await Directory(
        p.join(temporary.path, 'ancestor'),
      ).create();
      final root = await Directory(
        p.join(ancestor.path, 'parent', 'root'),
      ).create(recursive: true);
      addTearDown(() async {
        final restored = await Process.run('chmod', ['0700', ancestor.path]);
        expect(restored.exitCode, 0, reason: 'fixture mode restore failed');
      });
      final restricted = await Process.run('chmod', ['0111', ancestor.path]);
      expect(restricted.exitCode, 0, reason: 'fixture mode restriction failed');
      // Prove the ancestor cannot be listed, while its leaf remains usable.
      await expectLater(
        ancestor.list().toList(),
        throwsA(isA<FileSystemException>()),
      );

      final marker = p.join(root.path, 'created');
      final observed = Completer<Object>();
      final subscription = LocalWatchBackend.platform()
          .watch(root.path)
          .listen(
            (event) {
              if (p.equals(event.path, marker) && !observed.isCompleted) {
                observed.complete(event);
              }
            },
            onError: (Object error) {
              if (!observed.isCompleted) observed.complete(error);
            },
          );
      addTearDown(subscription.cancel);
      await File(marker).writeAsString('native event');
      expect(
        await observed.future.timeout(const Duration(seconds: 5)),
        isA<FileSystemCreateEvent>(),
      );
    },
    skip: Process.runSync('id', ['-u']).stdout.toString().trim() == '0'
        ? 'mode-bit refusal requires a non-root user'
        : false,
  );
}
