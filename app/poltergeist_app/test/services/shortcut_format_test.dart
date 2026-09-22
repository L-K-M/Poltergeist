import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/shortcut_format.dart';

void main() {
  test('macOS renders glyph order ⌃⌥⇧⌘', () {
    final chord = SingleActivator(
      LogicalKeyboardKey.keyP,
      meta: true,
      shift: true,
      control: true,
      alt: true,
    );
    expect(formatShortcutActivator(chord, TargetPlatform.macOS), '⌃⌥⇧⌘P');
  });

  test('other platforms spell modifiers in Ctrl+Alt+Shift+Meta order', () {
    final chord = SingleActivator(
      LogicalKeyboardKey.keyP,
      control: true,
      shift: true,
    );
    expect(
      formatShortcutActivator(chord, TargetPlatform.linux),
      'Ctrl+Shift+P',
    );
    expect(
      formatShortcutActivator(chord, TargetPlatform.windows),
      'Ctrl+Shift+P',
    );
  });

  test('named keys render platform spellings', () {
    const chord = SingleActivator(LogicalKeyboardKey.arrowUp);
    expect(formatShortcutActivator(chord, TargetPlatform.macOS), '↑');
    expect(formatShortcutActivator(chord, TargetPlatform.linux), 'Up');
  });

  test('non-SingleActivator shapes have no spelling', () {
    const chord = CharacterActivator('x');
    expect(formatShortcutActivator(chord, TargetPlatform.macOS), isNull);
  });
}
