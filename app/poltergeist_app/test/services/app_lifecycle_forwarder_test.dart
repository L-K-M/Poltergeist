import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/app_lifecycle_forwarder.dart';

final class _FakeSource implements AppLifecycleSource {
  final observers = <WidgetsBindingObserver>[];

  @override
  AppLifecycleState? state;

  @override
  void addObserver(WidgetsBindingObserver observer) => observers.add(observer);

  @override
  void removeObserver(WidgetsBindingObserver observer) =>
      observers.remove(observer);
}

void main() {
  test('attach registers the observer and reports the current state', () {
    final source = _FakeSource()..state = AppLifecycleState.resumed;
    final seen = <AppLifecycleState?>[];
    final forwarder = AppLifecycleForwarder(
      source: source,
      onState: seen.add,
    );

    forwarder.attach();

    expect(source.observers, [same(forwarder)]);
    expect(seen, [AppLifecycleState.resumed]);
  });

  test('lifecycle changes forward to the listener', () {
    final source = _FakeSource();
    final seen = <AppLifecycleState?>[];
    AppLifecycleForwarder(
      source: source,
      onState: seen.add,
    ).attach();
    seen.clear();

    source.observers.single.didChangeAppLifecycleState(
      AppLifecycleState.hidden,
    );

    expect(seen, [AppLifecycleState.hidden]);
  });

  test('detach unregisters once; a second detach is a no-op', () {
    final source = _FakeSource();
    final forwarder = AppLifecycleForwarder(
      source: source,
      onState: (_) {},
    );

    forwarder.detach();
    expect(source.observers, isEmpty);

    forwarder.attach();
    forwarder.detach();
    forwarder.detach();
    expect(source.observers, isEmpty);
  });

  test(
    'a duplicate attach reports the current state without double registration',
    () {
      final source = _FakeSource()..state = AppLifecycleState.paused;
      final seen = <AppLifecycleState?>[];
      final forwarder = AppLifecycleForwarder(
        source: source,
        onState: seen.add,
      );

      forwarder.attach();
      forwarder.attach();

      expect(source.observers, [same(forwarder)]);
      expect(seen, [AppLifecycleState.paused]);
    },
  );

  test('detach stops forwarding later lifecycle changes', () {
    final source = _FakeSource();
    final seen = <AppLifecycleState?>[];
    final forwarder = AppLifecycleForwarder(
      source: source,
      onState: seen.add,
    )..attach();
    final observer = source.observers.single;
    seen.clear();

    forwarder.detach();
    observer.didChangeAppLifecycleState(AppLifecycleState.hidden);

    expect(seen, isEmpty);
  });
}
