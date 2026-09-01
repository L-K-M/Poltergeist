import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'check_config.dart';

const _minimumM0TimeoutMinutes = 180;
const _modernAlpineImage =
    'alpine:20260805@sha256:'
    '020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000';
const _modernOpenSshVersion = '10.5_p1-r1';
const _modernOpenSshPackages = [
  'openssh-client-common',
  'openssh-server-pam',
  'openssh-sftp-server',
];

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

  test('pins the current modern OpenSSH fixture', () {
    final dockerfile = File(
      'test/integration/sshd-modern/Dockerfile',
    ).readAsStringSync();

    expect(dockerfile.split('\n').first, 'FROM $_modernAlpineImage');
    for (final package in _modernOpenSshPackages) {
      expect(dockerfile, contains('$package=$_modernOpenSshVersion'));
    }
  });

  test('pins matching legacy OpenSSH client and server packages', () {
    final dockerfile = File(
      'test/integration/sshd-legacy/Dockerfile',
    ).readAsStringSync();

    expect(dockerfile, contains(r'ARG OPENSSH_VERSION='));
    expect(dockerfile, contains(r'openssh-client=${OPENSSH_VERSION}'));
    expect(dockerfile, contains(r'openssh-server=${OPENSSH_VERSION}'));
  });

  test('pulls the frozen legacy image by digest', () {
    final compose =
        loadYaml(File('test/integration/docker-compose.yml').readAsStringSync())
            as YamlMap;
    final services = compose['services'] as YamlMap;
    final legacy = services['sshd-legacy'] as YamlMap;

    expect(
      legacy['image'],
      matches(
        RegExp(r'^ghcr\.io/l-k-m/poltergeist-sshd-legacy@sha256:[a-f0-9]{64}$'),
      ),
    );
    expect(legacy.containsKey('build'), isFalse);
  });

  test('budgets enough time for shaped sequential uploads', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final benchmark = jobs['m0_bench'] as YamlMap;

    expect(
      benchmark['timeout-minutes'],
      greaterThanOrEqualTo(_minimumM0TimeoutMinutes),
    );
  });
}
