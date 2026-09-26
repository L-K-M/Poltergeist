// P2-07's end-to-end leg: the exporter's promise is that a pasted
// command does what the plan previewed, so this pastes it: the
// generated preview and live lines run through `sh -c` against the
// real rsync on PATH. The remote side is a stand-in `ssh` that keeps
// OpenSSH's remote-command contract (the args after the host joined
// with single spaces, run by a shell from the login directory), so the
// remote-shell re-parse the escaping exists for is the real one
// without an sshd. Skipped unless an rsync 3.x is installed: macOS's
// openrsync and rsync 2.6.9 lack --delete-delay. The package itself
// still never runs rsync (05 §2, D6; the lib/ invariant test): only
// this test does, to check the text the exporter hands the user.
@TestOn('posix')
library;

import 'dart:io';

import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

final _now = DateTime(2026, 9, 22, 15, 4, 7);

/// Quote, space, `$`, a command substitution, a glob, and an NFD
/// accent: every way the remote shell could reinterpret the root.
const _hostileName = "it's a \$HOME `touch pwned` * cafe\u0301";

const _fakeSsh = r'''#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    -l|-p|-o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
cd "$POLTERGEIST_FAKE_REMOTE_HOME" || exit 255
exec sh -c "$*"
''';

void main() {
  final skip = _hasRsync3() ? false : 'needs rsync 3.x on PATH';

  late Directory temp;
  late String home;
  late String remoteRoot;
  late String localRoot;
  late Map<String, String> environment;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rsync_export_exec_');
    final bin = Directory('${temp.path}/bin')..createSync();
    File('${bin.path}/ssh').writeAsStringSync(_fakeSsh);
    final chmod = Process.runSync('chmod', ['755', '${bin.path}/ssh']);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
    home = '${temp.path}/home';
    remoteRoot = '$home/$_hostileName';
    localRoot = '${temp.path}/local';
    Directory(remoteRoot).createSync(recursive: true);
    Directory(localRoot).createSync();
    environment = {
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
      'POLTERGEIST_FAKE_REMOTE_HOME': home,
    };
  });

  tearDown(() => temp.delete(recursive: true));

  const remote = 'remote-host';
  const rules = SyncRuleSet(
    deletions: DeletionPolicy.trash,
    excludeGlobs: ['Private Notes/'],
    trashPathRight: 'old files',
  );

  void seedSource(String root) {
    _write('$root/keep.txt');
    _write('$root/Private Notes/secret.txt');
    _write('$root/.poltergeist-trash/source-side.txt');
  }

  void seedDestination(String root) {
    _write('$root/.poltergeist-trash/rsync-20260101-000000/earlier.txt');
    _write('$root/stale.txt');
  }

  /// Runs the preview line, checks it changed nothing and itemized the
  /// plan, then runs the live line.
  Future<void> paste(String block, String destination) async {
    final lines = block.split('\n');
    const previewPrefix = "# Preview first (matches Poltergeist's plan):  ";
    final preview = lines
        .singleWhere((l) => l.startsWith(previewPrefix))
        .substring(previewPrefix.length);
    final live = lines.singleWhere((l) => l.isNotEmpty && !l.startsWith('#'));

    final before = _tree(destination);
    final dryRun = await Process.run('sh', [
      '-c',
      preview,
    ], environment: environment);
    expect(dryRun.exitCode, 0, reason: '${dryRun.stderr}');
    expect(_tree(destination), before);
    final itemized = '${dryRun.stdout}';
    expect(itemized, contains('keep.txt'));
    expect(itemized, contains(RegExp(r'\*deleting +stale\.txt')));
    expect(itemized, isNot(contains('Private Notes')));
    expect(itemized, isNot(contains('.poltergeist-trash')));

    final run = await Process.run('sh', ['-c', live], environment: environment);
    expect(run.exitCode, 0, reason: '${run.stderr}');
  }

  void expectConverged(String destination, {required String backupDir}) {
    expect(_tree(destination), {
      '.poltergeist-trash/',
      '.poltergeist-trash/rsync-20260101-000000/',
      '.poltergeist-trash/rsync-20260101-000000/earlier.txt',
      'keep.txt',
      '$backupDir/',
      '$backupDir/stale.txt',
    });
    // Nothing ran or landed beside the root on the remote side.
    expect(_tree(home, recursive: false), {'$_hostileName/'});
  }

  test('a pasted Mirror push lands in the hostile remote root with the '
      'default and user excludes intact', () async {
    seedSource(localRoot);
    seedDestination(remoteRoot);
    final block = buildRsyncCommand(
      ResolvedSyncEndpoints(
        left: ResolvedLocalEndpoint(path: localRoot, os: SyncEndpointOs.posix),
        right: ResolvedRemoteEndpoint(
          user: 'deploy',
          host: remote,
          path: remoteRoot,
        ),
      ),
      rules,
      engineSkipPaths: const [],
      now: _now,
    );
    await paste(block, remoteRoot);
    // The remote-destination backup dir went through the remote
    // shell escaped, so it arrived with its space.
    expectConverged(remoteRoot, backupDir: 'old files');
  }, skip: skip);

  test('a pasted Mirror pull reads the hostile remote root and keeps its '
      'backups in the in-root trash', () async {
    seedSource(remoteRoot);
    seedDestination(localRoot);
    final block = buildRsyncCommand(
      ResolvedSyncEndpoints(
        left: ResolvedRemoteEndpoint(
          user: 'deploy',
          host: remote,
          path: remoteRoot,
        ),
        right: ResolvedLocalEndpoint(path: localRoot, os: SyncEndpointOs.posix),
      ),
      rules,
      engineSkipPaths: const [],
      now: _now,
    );
    expect(block, contains("trash path 'old files' cannot be passed"));
    await paste(block, localRoot);
    expectConverged(
      localRoot,
      backupDir: '.poltergeist-trash/rsync-20260922-150407',
    );
  }, skip: skip);
}

bool _hasRsync3() {
  try {
    final result = Process.runSync('rsync', ['--version']);
    final match = RegExp(
      r'^rsync\s+version\s+v?(\d+)\.',
      multiLine: true,
    ).firstMatch('${result.stdout}');
    return result.exitCode == 0 &&
        match != null &&
        int.parse(match.group(1)!) >= 3;
  } on ProcessException {
    return false;
  }
}

void _write(String path) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(path.split('/').last);
}

/// Every entry under [root], relative, directories with a trailing `/`.
Set<String> _tree(String root, {bool recursive = true}) {
  final prefix = '$root/';
  return {
    for (final entity in Directory(root).listSync(recursive: recursive))
      entity.path.substring(prefix.length) + (entity is Directory ? '/' : ''),
  };
}
