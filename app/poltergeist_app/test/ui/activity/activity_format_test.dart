import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/activity/activity_format.dart';

/// 02 §6's transfer-format helpers: the custom-rate parser must read an
/// over-range entry as invalid input (never a crash), and the route
/// line's shared-parent arithmetic keeps every level the roots share.
void main() {
  group('parseTransferRate', () {
    test('rejects a magnitude whose byte product overflows to infinity',
        () {
      // double.parse saturates an over-range literal to Infinity, and
      // Infinity.round() throws — the field's inline-error contract
      // (invalid input is rejected, never clamped) must cover it.
      expect(parseTransferRate('9' * 400), isNull);
    });
  });

  group('commonParentPath', () {
    test('keeps the first path when it parents the rest', () {
      // Seeding at the dirname would drop a level the roots share:
      // /a/b is itself a shared ancestor of /a/b/c.
      expect(commonParentPath(const ['/a/b', '/a/b/c']), '/a/b');
    });

    test('still ascends to the deepest shared directory otherwise', () {
      expect(commonParentPath(const ['/a/x', '/a/y']), '/a');
      expect(commonParentPath(const ['/a/b/c', '/a/b/d']), '/a/b');
    });
  });
}
