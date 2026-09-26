import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Adds AppKit checkmarks to Flutter's native menu transport.
///
/// Flutter 3.47 serializes labels, shortcuts and enablement, but has no menu
/// item state field. The runner applies checks after Flutter installs each
/// menu, using the same generated IDs AppKit stores in NSMenuItem.tag.
final class CheckedPlatformMenuDelegate extends DefaultPlatformMenuDelegate {
  CheckedPlatformMenuDelegate() : super(channel: const _CheckedMenuChannel());
}

/// A native checkable row; [checked] is a snapshot, like its label and shortcut.
final class CheckedPlatformMenuItem extends PlatformMenuItem {
  const CheckedPlatformMenuItem({
    required super.label,
    required this.checked,
    super.shortcut,
    super.onSelected,
  });

  final bool checked;

  @override
  Iterable<Map<String, Object?>> toChannelRepresentation(
    PlatformMenuDelegate delegate, {
    required MenuItemSerializableIdGenerator getId,
  }) => [
    {...PlatformMenuItem.serialize(this, delegate, getId), 'checked': checked},
  ];
}

final class _CheckedMenuChannel extends OptionalMethodChannel {
  const _CheckedMenuChannel() : super('flutter/menu');

  static const _checks = MethodChannel('poltergeist/menu_checks');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final result = await super.invokeMethod<T>(method, arguments);
    if (method == 'Menu.setMenus') {
      final states = <String, bool>{};
      void collect(List<dynamic> items) {
        for (final item in items.cast<Map<dynamic, dynamic>>()) {
          if (item['checked'] case final bool checked) {
            states['${item['id']}'] = checked;
          }
          if (item['children'] case final List<dynamic> children) {
            collect(children);
          }
        }
      }

      collect((arguments as Map<dynamic, dynamic>)['0'] as List<dynamic>);
      // Waiting for Flutter's reply guarantees that the new NSMenu exists.
      // IDs increase across pushes, so a delayed earlier reply cannot alter
      // the checkmarks in a newer menu or another workspace's menu.
      await _checks.invokeMethod<void>('setChecked', states);
    }
    return result;
  }
}
