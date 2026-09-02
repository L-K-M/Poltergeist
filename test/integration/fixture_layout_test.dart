import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _composePath = 'test/integration/docker-compose.yml';
const _generateDataScript = 'test/integration/generate-data.sh';
const _hostUploadsPath = 'test/integration/runtime/uploads';
const _normalFixtureTarget = '/home/poltergeist/bench/fixtures';
const _normalUploadsTarget = '/home/poltergeist/bench/uploads/host';
const _chrootFixtureTarget = '/srv/sftp/home/poltergeist/bench/fixtures';
const _chrootUploadsTarget = '/srv/sftp/home/poltergeist/bench/uploads/host';

void main() {
  test('binds immutable inputs beside host-visible uploads', () {
    final compose = loadYaml(File(_composePath).readAsStringSync()) as YamlMap;
    final services = compose['services'] as YamlMap;

    _expectMountPair(
      compose['x-modern-service'] as YamlMap,
      fixtureTarget: _normalFixtureTarget,
      uploadsTarget: _normalUploadsTarget,
    );
    _expectMountPair(
      services['sshd-legacy'] as YamlMap,
      fixtureTarget: _normalFixtureTarget,
      uploadsTarget: _normalUploadsTarget,
    );
    _expectMountPair(
      services['sshd-chroot'] as YamlMap,
      fixtureTarget: _chrootFixtureTarget,
      uploadsTarget: _chrootUploadsTarget,
    );
  });

  test(
    'replaces unsafe upload links with an empty writable directory',
    () async {
      final uploads = Directory(_hostUploadsPath);
      await _deleteEntry(uploads.path);
      addTearDown(() => _deleteEntry(uploads.path));

      final external = await Directory.systemTemp.createTemp(
        'poltergeist-upload-target-',
      );
      addTearDown(() => external.delete(recursive: true));
      final sentinel = File('${external.path}/must-survive')
        ..writeAsStringSync('x');
      await Link(uploads.path).create(external.path, recursive: true);

      final result = await Process.run(_generateDataScript, const []);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(await sentinel.exists(), isTrue);
      expect(
        await FileSystemEntity.type(uploads.path, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(await uploads.list().toList(), isEmpty);
      expect(await _permissionBits(uploads.path), '777');
    },
  );
}

void _expectMountPair(
  YamlMap service, {
  required String fixtureTarget,
  required String uploadsTarget,
}) {
  final volumes = (service['volumes'] as YamlList).cast<String>();

  expect(volumes, contains('./runtime/data:$fixtureTarget:ro'));
  expect(volumes, contains('./runtime/uploads:$uploadsTarget:rw'));
}

Future<void> _deleteEntry(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
    return;
  }

  await Link(path).delete();
}

Future<String> _permissionBits(String path) async {
  final result = await Process.run('stat', ['-c', '%a', path]);
  if (result.exitCode != 0) {
    throw StateError('stat failed: ${result.stderr}');
  }

  return '${result.stdout}'.trim();
}
