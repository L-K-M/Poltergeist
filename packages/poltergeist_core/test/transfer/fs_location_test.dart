import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// Endpoints compare by value: the queue's task, the pane asking whether
/// a finished transfer touched its folder, and the journal's decoded
/// copy each hold their own instance.
void main() {
  test('server endpoints naming one server are equal', () {
    final a = ServerFsLocation('srv-${1}');
    final b = ServerFsLocation('srv-${1}');

    expect(identical(a, b), isFalse);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect({a, b}, hasLength(1));
  });

  test('different servers, and local vs server, differ', () {
    expect(const ServerFsLocation('a'), isNot(const ServerFsLocation('b')));
    expect(const LocalFsLocation(), isNot(const ServerFsLocation('a')));
    expect(const ServerFsLocation('a'), isNot(const LocalFsLocation()));
  });

  test('the local endpoint equals itself however it was built', () {
    // ignore: prefer_const_constructors
    expect(LocalFsLocation(), const LocalFsLocation());
  });
}
