import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// The growth rules of 03 §3.2 are decisions, not tunables — this test pins
/// them to D9's frozen M0 numbers so a casual "let's bump it" fails CI.
void main() {
  test('defaults match the D9 verdict', () {
    const policy = PoolPolicy();

    expect(policy.maxTransports, 2);
    expect(policy.maxTransferChannelsPerTransport, 4);
    expect(policy.maxChannelsPerTransport, 8);
    expect(policy.keepAliveInterval, const Duration(seconds: 30));
    expect(policy.idleExtraTransportTimeout, const Duration(seconds: 60));
    expect(policy.reconnectBackoffCap, const Duration(seconds: 30));
    expect(policy.taskRetryLimit, 5);
  });
}
