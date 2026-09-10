import 'package:flutter/widgets.dart';

/// The binding surface the forwarder observes (a seam for tests).
abstract interface class AppLifecycleSource {
  AppLifecycleState? get state;
  void addObserver(WidgetsBindingObserver observer);
  void removeObserver(WidgetsBindingObserver observer);
}

final class _WidgetsBindingSource implements AppLifecycleSource {
  const _WidgetsBindingSource();

  @override
  AppLifecycleState? get state => WidgetsBinding.instance.lifecycleState;

  @override
  void addObserver(WidgetsBindingObserver observer) =>
      WidgetsBinding.instance.addObserver(observer);

  @override
  void removeObserver(WidgetsBindingObserver observer) =>
      WidgetsBinding.instance.removeObserver(observer);
}

/// Forwards app lifecycle state to the probe wiring: probes run only while
/// the app is foregrounded (02 §4), so backgrounding must pause the engine
/// and returning must resume it.
final class AppLifecycleForwarder with WidgetsBindingObserver {
  AppLifecycleForwarder({required this.onState, AppLifecycleSource? source})
    : _source = source ?? const _WidgetsBindingSource();

  final AppLifecycleSource _source;
  final ValueChanged<AppLifecycleState?> onState;
  bool _attached = false;

  /// Registers the observer and reports the current state, so wiring starts
  /// from live truth instead of waiting for the next lifecycle change.
  void attach() {
    if (_attached) return;
    _attached = true;
    _source.addObserver(this);
    onState(_source.state);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _source.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A removed observer must never forward (defensive: the binding may
    // have in-flight notifications around detach).
    if (!_attached) return;
    onState(state);
  }
}
