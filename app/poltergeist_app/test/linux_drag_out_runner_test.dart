import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';

String _read(String path) => File(path).readAsStringSync();

/// The Linux drag-out backend's source contract (00 D14's 2026-09-25
/// amendment). The GTK side is verified for real under Xvfb (see
/// docs/STATUS.md); these checks keep the load-bearing lines from
/// quietly drifting: the channel name both sides agree on, the runner
/// wiring, and D15's rule that the drag source never deletes.
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

  test('ends the embedder press before the GTK session takes the grab', () {
    final release = channel.indexOf('synthesize_release(self, pointer);');
    final begin = channel.indexOf('gtk_drag_begin_with_coordinates(');
    expect(release, isNonNegative);
    expect(begin, greaterThan(release));
  });
}
