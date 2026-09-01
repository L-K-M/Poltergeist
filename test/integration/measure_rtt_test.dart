import 'measure_rtt.dart';
import 'package:test/test.dart';

void main() {
  test('measures the SSH version-to-KEX exchange', () async {
    var clock = Duration.zero;
    final probe = _FakeSshRttProbe(
      onKex: () => clock = const Duration(milliseconds: 10),
    );

    final elapsed = await measureSshExchange(
      'fixture',
      2201,
      connect: (_, _) async => probe,
      now: () => clock,
    );

    expect(probe.calls, ['read-version', 'send-version', 'read-kex', 'close']);
    expect(elapsed, const Duration(milliseconds: 10));
  });
}

class _FakeSshRttProbe implements SshRttProbe {
  final List<String> calls = [];
  final void Function() onKex;

  _FakeSshRttProbe({required this.onKex});

  @override
  Future<void> readServerIdentification() async {
    calls.add('read-version');
  }

  @override
  Future<void> sendClientIdentification() async {
    calls.add('send-version');
  }

  @override
  Future<void> readServerKexHeader() async {
    calls.add('read-kex');
    onKex();
  }

  @override
  Future<void> close() async {
    calls.add('close');
  }
}
