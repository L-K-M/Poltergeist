import 'dart:io';

import 'package:test/test.dart';

import 'check_config.dart';

void main() {
  test('accepts loopback long-form publishing', () {
    final errors = findExposureErrors({
      'services': {
        'safe': {
          'ports': [
            {'host_ip': '127.0.0.1', 'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors, isEmpty);
  });

  test('rejects a resolved short-form mapping without host IP', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {
          'ports': [
            {'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors.single, contains('all interfaces'));
  });

  test('rejects a non-loopback long-form mapping', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {
          'ports': [
            {'host_ip': '0.0.0.0', 'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors.single, contains('0.0.0.0'));
  });

  test('rejects host networking without published ports', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {'network_mode': 'host'},
      },
    });

    expect(errors.single, contains('host networking'));
  });

  test('audits the OpenSSH 10 post-quantum default', () {
    final config = File(
      'test/integration/sshd-common/config/sshd_config.chacha',
    ).readAsStringSync();

    expect(config, contains('mlkem768x25519-sha256'));
    expect(config, isNot(contains('sntrup761x25519-sha512')));
  });
}
