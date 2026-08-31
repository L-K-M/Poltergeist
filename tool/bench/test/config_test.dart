import 'package:poltergeist_m0_bench/config.dart';
import 'package:test/test.dart';

void main() {
  test('endpoint settings remain isolate-sendable', () {
    const endpoint = BenchEndpoint(
      host: 'fixture',
      port: 2201,
      username: 'user',
      password: 'test-only',
    );

    expect(
      BenchEndpoint.fromJson(endpoint.toJson()).toJson(),
      endpoint.toJson(),
    );
  });
}
