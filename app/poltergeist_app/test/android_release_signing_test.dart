import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _ciKeyStorePath = 'android/app/ci-release.jks';
const _ciPropertiesPath = 'android/key.properties';
const _publicKeyWarning =
    '# Public debug-grade CI key; never place a production secret in this file.';
const _ciCertificateSha256 =
    '55ED092009200CDD86F7C0CDD782BE380349431054438341CFB8FD2AB434264E';
const _publicCredential = 'poltergeist-ci';
const _jksMagic = <int>[0xfe, 0xed, 0xfe, 0xed];
const _propertyNames = <String>{
  'storeFile',
  'storePassword',
  'keyAlias',
  'keyPassword',
};

void main() {
  test('release APK uses the committed public CI identity', () {
    final propertiesFile = File(_ciPropertiesPath);
    final keyStore = File(_ciKeyStorePath);

    expect(propertiesFile.existsSync(), isTrue);
    expect(keyStore.existsSync(), isTrue);

    final propertiesText = propertiesFile.readAsStringSync();
    expect(propertiesText.split('\n').first, _publicKeyWarning);

    final properties = _parseProperties(propertiesText);
    expect(properties.keys, _propertyNames);
    expect(properties['storeFile'], 'ci-release.jks');
    for (final name in _propertyNames.difference({'storeFile'})) {
      expect(
        properties[name],
        _publicCredential,
        reason: '$name must be public',
      );
    }

    final keyStoreBytes = keyStore.readAsBytesSync();
    expect(keyStoreBytes, hasLength(greaterThan(_jksMagic.length)));
    expect(keyStoreBytes.take(_jksMagic.length), _jksMagic);

    final gradle = _read('android/app/build.gradle.kts');
    expect(
      gradle,
      allOf(
        contains('rootProject.file(ciSigningPropertiesPath)'),
        contains('check(ciSigningPropertiesFile.isFile)'),
        contains(_ciCertificateSha256),
        contains('check(actualCiCertificateSha256 == '),
        contains('create(ciSigningConfigName)'),
        contains(
          'signingConfig = signingConfigs.getByName(ciSigningConfigName)',
        ),
        isNot(contains('signingConfigs.getByName("debug")')),
      ),
    );
  });

  test('public signing files are narrowly allowlisted', () {
    final androidIgnore = _read('android/.gitignore');
    expect(androidIgnore, contains('!/key.properties'));
    expect(androidIgnore, contains('!/app/ci-release.jks'));

    final gitleaks = _read('../../.gitleaks.toml');
    expect(
      gitleaks,
      allOf(
        contains(r'''^app/poltergeist_app/android/app/ci-release\.jks$'''),
        contains(r'''^app/poltergeist_app/android/key\.properties$'''),
      ),
    );
  });
}

Map<String, String> _parseProperties(String contents) {
  final properties = <String, String>{};
  for (final line in contents.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final separator = trimmed.indexOf('=');
    expect(separator, greaterThan(0), reason: 'Invalid property: $line');
    properties[trimmed.substring(0, separator)] = trimmed.substring(
      separator + 1,
    );
  }

  return properties;
}

String _read(String path) => File(path).readAsStringSync();
