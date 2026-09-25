import 'package:flutter/widgets.dart';

/// Resolves a pool/bookmark server id to the name the user gave it — the
/// shell provides one over its bookmark and catalog truth so rows that
/// only carry an id (transfer routes, history, alerts) never print a
/// UUID (D32 §1's observed `adhoc:<uuid>` leak).
typedef ServerLabelResolver = String? Function(String serverId);

class ServerLabelScope extends InheritedWidget {
  const ServerLabelScope({
    super.key,
    required this.resolve,
    required super.child,
  });

  final ServerLabelResolver resolve;

  /// The nearest resolver, or null outside a shell (tests mounting a
  /// row alone fall back to the id, the honest last resort).
  static ServerLabelResolver? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ServerLabelScope>()
      ?.resolve;

  @override
  bool updateShouldNotify(ServerLabelScope oldWidget) =>
      !identical(resolve, oldWidget.resolve);
}
