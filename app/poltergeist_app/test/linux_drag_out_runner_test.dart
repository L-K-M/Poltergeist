import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';

String _read(String path) => File(path).readAsStringSync();

/// The body of the C function whose definition starts with [signature],
/// up to its closing brace at column zero.
String _function(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing `$signature`');
  return source.substring(start, source.indexOf('\n}\n', start));
}

/// The Linux drag-out backend's source contract (00 D14's 2026-09-25
/// amendment). The GTK side is verified for real under Xvfb (see
/// docs/STATUS.md); these checks keep the load-bearing lines from
/// quietly drifting: the channel name both sides agree on, the runner
/// wiring, D15's rule that the drag source never deletes, and the
/// owner's rule that it never offers a move.
void main() {
  final channel = _read('linux/runner/drag_out_channel.cc');

  test('serves the channel the Dart backend talks to', () {
    expect(channel, contains('kChannelName[] = "$dragOutChannelName";'));
    expect(channel, contains('"startDrag"'));
    expect(channel, contains('"sessionEnded"'));
  });

  test('is compiled into the runner and registered on the view', () {
    expect(
      _read('linux/runner/CMakeLists.txt'),
      contains('"drag_out_channel.cc"'),
    );
    expect(
      _read('linux/runner/my_application.cc'),
      matches(
        RegExp(r'^\s*drag_out_channel_register\(view\);', multiLine: true),
      ),
    );
  });

  test('never deletes on a move and never offers ask', () {
    // A destination that picked MOVE moves the file itself; handling
    // drag-data-delete would unlink outside D15's confirmed delete.
    expect(
      channel,
      isNot(matches(RegExp(r'g_signal_connect\([^;]*"drag-data-delete"'))),
    );
    expect(channel, isNot(contains('GDK_ACTION_ASK')));
    expect(
      channel,
      isNot(matches(RegExp(r'\b(g_)?(unlink|remove|file_delete)\s*\('))),
    );
  });

  test('offers copy and link only, whatever Dart sends', () {
    // The owner's rule (00 D14's drag-out amendment): no trash may take
    // the source, so no destination may move it. GTK is offered only
    // the actions the copy and link names map to.
    final start = _function(channel, 'void start_drag(');
    expect(start, isNot(contains('GDK_ACTION_MOVE')));
    expect(start, isNot(contains('"move"')));
    final offered = _function(channel, 'GdkDragAction offered_actions(');
    expect(offered, contains('"copy"'));
    expect(offered, contains('"link"'));
    for (final forbidden in ['"move"', 'GDK_ACTION_MOVE', 'GDK_ACTION_ASK']) {
      expect(offered, isNot(contains(forbidden)));
    }
    expect(
      start,
      matches(
        RegExp(
          r'gtk_drag_begin_with_coordinates\(\s*self->view, targets, '
          r'offered_actions\(args\),',
        ),
      ),
    );
    // A destination that reports a move anyway still reads as one: the
    // session end maps it, and nothing acts on it.
    expect(
      _function(channel, 'void on_drag_end('),
      contains('operation = "move";'),
    );
  });

  test('ends the embedder press before the GTK session takes the grab', () {
    final release = channel.indexOf('synthesize_release(self, x, y);');
    final begin = channel.indexOf('gtk_drag_begin_with_coordinates(');
    expect(release, isNonNegative);
    expect(begin, greaterThan(release));
  });

  test('ends the press at the position Dart sent, never at the current '
      'pointer', () {
    // The release reaches Flutter before the `started` reply. Dart's
    // position is outside the view; the current pointer may be back
    // over a pane, where Flutter would read the release as a drop.
    final start = _function(channel, 'void start_drag(');
    final position = start.indexOf('point_at(args, "position", &x, &y)');
    expect(position, isNonNegative);
    expect(
      start.indexOf('synthesize_release(self, x, y);'),
      greaterThan(position),
    );
    final release = _function(channel, 'void synthesize_release(');
    expect(release, isNot(contains('device_position')));
    expect(release, isNot(contains('gdk_device_get_position')));
  });
}
