import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _deadline = Duration(seconds: 10);

enum _Handles { none, root, rootAndParent }

enum _Move { root, parent, higherAncestor, reparentAncestor, caseOnlyAncestor }

/// Isolate native rename permission from notification delivery. These probes
/// do not assert that a refused rename demonstrates a missing loss signal.
void main() {
  for (final handles in _Handles.values) {
    for (final move in _Move.values) {
      test('native rename boundary: ${handles.name}/${move.name}', () async {
        final temporary = await Directory.systemTemp.createTemp('pg-rename-');
        final base = await temporary.resolveSymbolicLinks();
        final root = Directory(p.join(base, 'ancestor', 'parent', 'root'));
        await root.create(recursive: true);
        final subscriptions = <StreamSubscription<FileSystemEvent>>[];
        final events = <String>[];
        final errors = <String>[];
        final paths = switch (handles) {
          _Handles.none => <String>[],
          _Handles.root => [root.path],
          _Handles.rootAndParent => [root.parent.path, root.path],
        };
        final ready = Completer<void>();
        final marker = p.join(root.path, 'ready');

        try {
          // Match production's parent-first Windows installation order.
          for (final path in paths) {
            subscriptions.add(
              Directory(path).watch().listen((event) {
                events.add('$path: $event');
                if (p.equals(event.path, marker) && !ready.isCompleted) {
                  ready.complete();
                }
              }, onError: (Object error) => errors.add(error.toString())),
            );
          }

          // A real child event proves handles are live before the mutation.
          await File(marker).writeAsString('ready');
          if (paths.isNotEmpty) {
            await ready.future.timeout(
              _deadline,
              onTimeout: () => fail(
                'No marker event for $marker; errors: $errors; events: $events',
              ),
            );
          }
          expect(errors, isEmpty);
          events.clear();

          final ancestor = Directory(p.join(base, 'ancestor'));
          final source = switch (move) {
            _Move.root => root,
            _Move.parent => root.parent,
            _Move.higherAncestor ||
            _Move.reparentAncestor ||
            _Move.caseOnlyAncestor => ancestor,
          };
          final destination = switch (move) {
            _Move.reparentAncestor => p.join(base, 'destination', 'ancestor'),
            _Move.caseOnlyAncestor => p.join(base, 'ANCESTOR'),
            _ => '${source.path}-moved',
          };
          if (move == _Move.reparentAncestor) {
            await Directory(p.dirname(destination)).create();
          }

          FileSystemException? refusal;
          try {
            await source.rename(destination);
          } on FileSystemException catch (error) {
            refusal = error;
          }
          if (refusal != null) {
            expect(await source.exists(), isTrue);
          }

          await Future.wait(subscriptions.map((s) => s.cancel()));
          subscriptions.clear();
          // Same fixture, permissions and operation after releasing handles:
          // success here distinguishes a live-handle restriction from ACLs.
          if (refusal != null) await source.rename(destination);
          expect(await Directory(destination).exists(), isTrue);
          print(
            jsonEncode({
              'os': Platform.operatingSystem,
              'osVersion': Platform.operatingSystemVersion,
              'dart': Platform.version,
              'handles': handles.name,
              'move': move.name,
              'watchedPaths': paths,
              'liveRename': refusal == null ? 'permitted' : 'refused',
              'error': refusal?.toString(),
              'errorCode': refusal?.osError?.errorCode,
              'renameAfterRelease': refusal == null
                  ? 'not needed'
                  : 'permitted',
              'eventsBeforeRelease': events,
              'watchErrorsAfterMutation': errors,
            }),
          );
        } finally {
          await Future.wait(subscriptions.map((s) => s.cancel()));
          await temporary.delete(recursive: true);
        }
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }
}
