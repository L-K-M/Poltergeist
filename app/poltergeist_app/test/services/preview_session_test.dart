import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/preview_session.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/preview_harness.dart';

void main() {
  group('panel verb (Space on non-macOS)', () {
    test(
      'selection alone never downloads — Space opens the prompt card',
      () async {
        final h = await PreviewHarness.create();
        await h.connectRemote([previewEntry('notes.txt', size: 4)]);

        // Focus alone ran no production and the panel stayed hidden.
        expect(h.producer.specs, isEmpty);
        expect(h.workspace.previewPanelHidden, isTrue);

        expect(h.session.previewFocused(), isTrue);
        await untilPhase(h.session, PreviewPhase.prompt);
        expect(h.workspace.previewPanelHidden, isFalse);
        expect(h.session.phase, PreviewPhase.prompt);
        expect(h.session.entry?.name, 'notes.txt');
        expect(h.producer.specs, isEmpty);
      },
    );

    test('prompt Space produces; completion renders the text file', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('notes.txt', size: 4)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      expect(h.producer.specs, hasLength(1));
      expect(h.producer.specs.single.serverId, 'srv-1');
      expect(h.producer.specs.single.remotePath, '/srv/home/notes.txt');

      await h.producer.complete(0, utf8.encode('hello\n'));
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.text);
      expect(h.session.text, isNotNull);
      expect(h.session.file, isNotNull);
    });

    test('Space on a rendered card closes the panel', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await h.producer.complete(0, utf8.encode('hi'));
      await untilPhase(h.session, PreviewPhase.rendered);

      h.session.previewFocused();
      expect(h.workspace.previewPanelHidden, isTrue);
      expect(h.session.phase, PreviewPhase.idle);
    });

    test('Space during producing is a no-op (no duplicate task)', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      h.session.previewFocused();
      await previewSettle();
      expect(h.session.phase, PreviewPhase.producing);
      expect(h.producer.specs, hasLength(1));
    });

    test('known over-threshold size confirms before producing', () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('big.txt', size: 100)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
      expect(h.session.confirmBytes, 100);
      expect(h.producer.specs, isEmpty);

      // Esc answers the card's Cancel — the prompt returns.
      expect(h.session.escape(), isTrue);
      expect(h.session.phase, PreviewPhase.prompt);

      // The card's Download starts the production.
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
      h.session.confirmDownload();
      await untilPhase(h.session, PreviewPhase.producing);
      expect(h.producer.specs, hasLength(1));
    });

    test('unknown size parks at the threshold; keep-downloading resumes',
        () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('stream.txt')]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      final spec = h.producer.specs.single;
      expect(spec.expectedSize, isNull);
      expect(spec.gate, isNotNull);
      expect(spec.maximumBytes, h.cache.capacityBytes);

      // The fake producer drives the gate's park through the spec's
      // gate object — crossing the threshold flips the card.
      spec.gate!.wrap(const NullByteSink()).add(List.filled(16, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);

      h.session.confirmDownload();
      expect(h.session.phase, PreviewPhase.producing);
      expect(spec.gate!.isAwaitingConfirmation, isFalse);

      await h.producer.complete(0, utf8.encode('streamed bytes here'));
      await untilPhase(h.session, PreviewPhase.rendered);
    });

    test('denying the gate aborts and returns the cancelled prompt',
        () async {
      final h = await PreviewHarness.create(thresholdBytes: 8);
      await h.connectRemote([previewEntry('stream.txt')]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      final spec = h.producer.specs.single;
      spec.gate!.wrap(const NullByteSink()).add(List.filled(16, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);

      // Esc answers the gate's Cancel — the stream unwinds as cancelled.
      expect(h.session.escape(), isTrue);
      expect(spec.gate!.isDenied, isTrue);
      h.producer.fail(
        0,
        const RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'preview produce',
          message: 'declined',
        ),
      );
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.cancelled);
    });

    test(
      'unknown-size over-cap produce renders the refusal, not a '
      'retryable failure',
      () async {
        final h = await PreviewHarness.create();
        await h.connectRemote([previewEntry('stream.txt')]);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.prompt);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.producing);
        // The queue re-pins the stream-cap abort to the typed limit
        // error (the produce seam's suffix-pin); the session maps it
        // to the over-cap refusal card — never failed→prompt→retry.
        h.producer.fail(
          0,
          const CheckoutLimitException('preview limit exceeded'),
        );
        await untilPhase(h.session, PreviewPhase.rendered);
        expect(h.session.refusal, PreviewRefusal.overCacheCap);
      },
    );

    test(
      'unknown-size image over the kind cap renders overKindCap',
      () async {
        final h = await PreviewHarness.create();
        await h.connectRemote([previewEntry('photo.png')]);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.prompt);
        h.session.previewFocused();
        await untilPhase(h.session, PreviewPhase.producing);
        expect(
          h.producer.specs.single.maximumBytes,
          previewKindCapBytes(PreviewKind.image),
        );
        h.producer.fail(
          0,
          const CheckoutLimitException('preview limit exceeded'),
        );
        await untilPhase(h.session, PreviewPhase.rendered);
        expect(h.session.refusal, PreviewRefusal.overKindCap);
      },
    );

    test('disposing mid-production swallows the late completion',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);

      // The shell tears the session down while the hop is in flight —
      // a completion then must not notify a disposed ChangeNotifier.
      h.session.dispose();
      await h.producer.complete(0, utf8.encode('hi'));
      await previewSettle();
    });

    test('a failed production returns the prompt with the failure card',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      h.producer.fail(
        0,
        const RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'preview produce',
          message: 'boom',
        ),
      );
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.refusal, PreviewRefusal.failed);
    });

    test('metadata refusal for a known size over the cache cap',
        () async {
      final h = await PreviewHarness.create(cacheCapacityBytes: 8);
      await h.connectRemote([previewEntry('huge.txt', size: 4096)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.refusal, PreviewRefusal.overCacheCap);
      expect(h.producer.specs, isEmpty);
    });

    test('metadata refusal for a known size over the kind cap', () async {
      final h = await PreviewHarness.create(cacheCapacityBytes: 128 << 20);
      final overKind = (previewKindCapBytes(PreviewKind.image) ?? 0) + 1;
      await h.connectRemote([previewEntry('wall.png', size: overKind)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.refusal, PreviewRefusal.overKindCap);
      expect(h.producer.specs, isEmpty);
    });

    test('a stale completion still commits to the cache, unrendered',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('one.txt', size: 2),
        previewEntry('two.txt', size: 2),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);

      // Move focus mid-flight: the first production keeps running.
      h.left.setCursorIndex(1);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.session.entry?.name, 'two.txt');

      await h.producer.complete(0, utf8.encode('x'));
      await previewSettle();
      // The new focus's prompt survived — the stale file landed in the
      // cache only (its key is listed, nothing re-rendered).
      expect(h.session.phase, PreviewPhase.prompt);
      expect(h.session.entry?.name, 'two.txt');
      final cached = await h.cache.lookup(
        previewCacheKey('srv-1', '/srv/home/one.txt', null, 2),
      );
      expect(cached, isNotNull);
    });

    test('Esc on producing cancels the task, keeping the panel', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);

      expect(h.session.escape(), isTrue);
      expect(h.producer.cancels, ['produce-0']);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.workspace.previewPanelHidden, isFalse);
      expect(h.session.refusal, PreviewRefusal.cancelled);
    });

    test('togglePanel opens on the focused item and closes', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.togglePanel();
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.workspace.previewPanelHidden, isFalse);
      h.session.togglePanel();
      expect(h.workspace.previewPanelHidden, isTrue);
    });

    test('cached hit renders without a prompt or a task', () async {
      final h = await PreviewHarness.create();
      final entry = previewEntry('cached.txt', size: 3);
      await h.connectRemote([entry]);
      // Pre-seed the cache under the entry's key.
      final key = previewCacheKey('srv-1', entry.path, null, 3);
      final slot = await h.cache.prepare(key, extension: 'txt');
      await File(slot.tempFile.path).writeAsBytes(utf8.encode('abc'));
      await slot.commit();

      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.text, isNotNull);
      expect(h.producer.specs, isEmpty);
    });

    test('re-focusing an in-flight item re-attaches to its production',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('one.txt', size: 2),
        previewEntry('two.txt', size: 2),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      h.producer.progress(0, 1, 2);
      expect(h.session.transferred, 1);

      h.left.setCursorIndex(1);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.left.setCursorIndex(0);
      await untilPhase(h.session, PreviewPhase.producing);
      expect(h.session.transferred, 1);
      expect(h.producer.specs, hasLength(1));
    });

    test('no producer: prompt stays honest, canProduce is false',
        () async {
      final h = await PreviewHarness.create(withProducer: false);
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      expect(h.session.canProduce, isFalse);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
      // Space on the prompt cannot start a production.
      h.session.previewFocused();
      await previewSettle();
      expect(h.session.phase, PreviewPhase.prompt);
    });

    test('unpreviewable remote kind renders the metadata card', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([previewEntry('archive.bin', size: 5)]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.metadata);
      expect(h.producer.specs, isEmpty);
    });

    test('remote directory renders metadata without producing', () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('folder', type: RemoteFileType.directory),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.metadata);
      expect(h.producer.specs, isEmpty);
    });
  });

  group('local previews', () {
    test('a local text file renders immediately', () async {
      final h = await PreviewHarness.create();
      final file = File('${h.tempDir.path}/local.txt')
        ..writeAsStringSync('local body\n');
      await h.connectLocal(h.tempDir, [
        previewEntry('local.txt', size: 11, parent: h.tempDir.path),
      ]);
      expect(file.existsSync(), isTrue);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.kind, PreviewKind.text);
      expect(h.session.text, isNotNull);
    });

    test('a missing local file reports the missing refusal', () async {
      final h = await PreviewHarness.create();
      final ghost = Directory('${h.tempDir.path}/listing')
        ..createSync();
      await h.connectLocal(ghost, [
        previewEntry('gone.txt', size: 4, parent: ghost.path),
      ]);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.rendered);
      expect(h.session.refusal, PreviewRefusal.missing);
    });
  });

  group('Quick Look (macOS platform)', () {
    test('unavailable channel falls back to the panel', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: false,
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      expect(h.session.previewFocused(), isTrue);
      await untilPhase(h.session, PreviewPhase.prompt);
      expect(h.workspace.previewPanelHidden, isFalse);
      expect(h.quickLook.shows, isEmpty);
    });

    test('local Space opens the native panel; Space again closes',
        () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectLocal(h.tempDir, [
        previewEntry('one.txt', size: 2, parent: h.tempDir.path),
      ]);
      h.session.previewFocused();
      await untilTrue(() => h.quickLook.shows.isNotEmpty);
      expect(h.quickLook.shows.single.$1.single, contains('one.txt'));
      await untilTrue(() => h.session.quickLookActive);
      expect(h.workspace.previewPanelHidden, isTrue);

      h.session.previewFocused();
      await untilTrue(() => h.quickLook.hideCalls > 0);
      await untilTrue(() => !h.session.quickLookActive);
    });

    test('remote Space produces then opens the native panel', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectRemote([previewEntry('photo.png', size: 10)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      await untilTrue(() => h.producer.specs.isNotEmpty);

      await h.producer.complete(0, List.filled(10, 7));
      await untilTrue(() => h.quickLook.shows.isNotEmpty);
      final producedPath = h.quickLook.shows.single.$1.single;
      expect(File(producedPath).existsSync(), isTrue);
      expect(h.session.quickLookActive, isTrue);
      expect(h.session.quickLookCard, QuickLookCardKind.none);
    });

    test('the docked panel suppresses the Quick Look leg', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.togglePanel();
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      expect(h.quickLook.shows, isEmpty);
    });

    test('the native close edge clears Quick Look state', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectLocal(h.tempDir, [
        previewEntry('one.txt', size: 2, parent: h.tempDir.path),
      ]);
      h.session.previewFocused();
      await untilTrue(() => h.session.quickLookActive);
      h.quickLook.emitClosed();
      await untilTrue(() => !h.session.quickLookActive);
    });

    test('Esc on the producing overlay cancels the production', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectRemote([previewEntry('a.txt', size: 2)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      // The cancel lands once the produce task exists (the pre-ticket
      // window aborts the pending start instead).
      await untilTrue(() => h.producer.specs.isNotEmpty);
      expect(h.session.escape(), isTrue);
      expect(h.producer.cancels, ['produce-0']);
    });

    test('over-threshold remote Space shows the confirm card', () async {
      final h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
        thresholdBytes: 8,
      );
      await h.connectRemote([previewEntry('big.bin', size: 900)]);
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.confirm,
      );
      expect(h.producer.specs, isEmpty);

      h.session.quickLookConfirm();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
      await untilTrue(() => h.producer.specs.isNotEmpty);
    });
  });

  group('selection header', () {
    test('count, summed bytes, and unknown-size rows stay honest',
        () async {
      final h = await PreviewHarness.create();
      await h.connectRemote([
        previewEntry('a.txt', size: 10),
        previewEntry('b.txt', size: 20),
        previewEntry('c.txt'),
      ]);
      h.left.setCursorIndex(0);
      h.left.setCursorIndex(2, update: SelectionUpdate.range);
      h.session.togglePanel();
      await previewSettle();
      expect(h.session.selectionCount, 3);
      expect(h.session.selectionBytes, 30);
      expect(h.session.selectionUnknownSizes, 1);
    });
  });
}
