import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Formats a [ShortcutActivator] for display (02 §8.4's palette rows
/// show the chord they accept; the menus render their own). Modifier
/// order and glyphs follow the platform convention: ⌃⌥⇧⌘ on macOS,
/// `Ctrl+Alt+Shift+Meta+` elsewhere. Only [SingleActivator] has a
/// spelling — anything else yields null and the row shows no hint.
String? formatShortcutActivator(
  ShortcutActivator activator,
  TargetPlatform platform,
) {
  if (activator is! SingleActivator) return null;
  final mac = platform == TargetPlatform.macOS;
  final buffer = StringBuffer();
  void mod(bool flag, String macGlyph, String name) {
    if (!flag) return;
    buffer.write(mac ? macGlyph : '$name+');
  }

  // macOS prints modifiers in ⌃⌥⇧⌘ order; other platforms spell them.
  mod(activator.control, '⌃', 'Ctrl');
  mod(activator.alt, '⌥', 'Alt');
  mod(activator.shift, '⇧', 'Shift');
  mod(activator.meta, '⌘', 'Meta');
  buffer.write(_keyGlyph(activator.trigger, mac));
  return buffer.toString();
}

/// The trigger key's display glyph: arrows and editing keys get symbols
/// on macOS and names elsewhere; letter/digit keys come from
/// [LogicalKeyboardKey.keyLabel] (already uppercase for letters).
String _keyGlyph(LogicalKeyboardKey key, bool mac) {
  final named = switch (key) {
    LogicalKeyboardKey.arrowUp => mac ? '↑' : 'Up',
    LogicalKeyboardKey.arrowDown => mac ? '↓' : 'Down',
    LogicalKeyboardKey.arrowLeft => mac ? '←' : 'Left',
    LogicalKeyboardKey.arrowRight => mac ? '→' : 'Right',
    LogicalKeyboardKey.enter => mac ? '↩' : 'Enter',
    LogicalKeyboardKey.tab => mac ? '⇥' : 'Tab',
    LogicalKeyboardKey.escape => 'Esc',
    LogicalKeyboardKey.backspace => mac ? '⌫' : 'Backspace',
    LogicalKeyboardKey.delete => mac ? '⌦' : 'Del',
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.comma => ',',
    LogicalKeyboardKey.period => '.',
    LogicalKeyboardKey.slash => '/',
    LogicalKeyboardKey.backslash => '\\',
    LogicalKeyboardKey.bracketLeft => '[',
    LogicalKeyboardKey.bracketRight => ']',
    LogicalKeyboardKey.minus => '-',
    LogicalKeyboardKey.equal => '=',
    LogicalKeyboardKey.semicolon => ';',
    LogicalKeyboardKey.quote => "'",
    LogicalKeyboardKey.backquote => '`',
    _ => null,
  };
  return named ?? key.keyLabel;
}
