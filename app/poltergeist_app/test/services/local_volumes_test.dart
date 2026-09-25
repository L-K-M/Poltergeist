import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/local_volumes.dart';

/// A scripted directory tree: child listings, symbolic links, and the
/// folder set — the enumeration never touches the host's mounts here.
final class _Tree implements VolumeDirectoryReader {
  _Tree({this.children = const {}, this.links = const {}, Set<String>? dirs})
    : dirs = dirs ?? {};

  final Map<String, List<String>> children;
  final Map<String, String> links;
  final Set<String> dirs;

  @override
  List<String> childDirectories(String path) => children[path] ?? const [];

  @override
  String? resolveLink(String path) => links[path];

  @override
  bool isDirectory(String path) =>
      dirs.contains(path) || children.containsKey(path);
}

/// Answers `df -kP <path>` with a fixed free count per path and records
/// every invocation (df and the eject verbs alike).
final class _Runner {
  final calls = <List<String>>[];
  final free = <String, int>{};
  final exitCodes = <String, int>{};

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    if (executable == 'df') {
      final kib = free[arguments.last];
      if (kib == null) return ProcessResult(0, 1, '', 'no such file');
      return ProcessResult(
        0,
        0,
        'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
            '/dev/disk1 100000000 50000000 $kib 50% ${arguments.last}\n',
        '',
      );
    }
    return ProcessResult(0, exitCodes[executable] ?? 0, '', '');
  }
}

void main() {
  group('macOS', () {
    test(
      '/Volumes lists mounts and names the root after the boot link',
      () async {
        final runner = _Runner()
          ..free['/Users/me'] = 1000
          ..free['/'] = 1000
          ..free['/Volumes/STICK'] = 20;
        final volumes = SystemLocalVolumes(
          operatingSystem: 'macos',
          environment: const {'HOME': '/Users/me', 'USER': 'me'},
          hostName: 'mac-mini',
          directories: _Tree(
            children: {
              '/Volumes': [
                '/Volumes/Macintosh HD',
                '/Volumes/STICK',
                '/Volumes/Backup',
              ],
            },
            links: {'/Volumes/Macintosh HD': '/'},
          ),
          run: runner.call,
        );

        final listed = await volumes.list();
        expect(
          [for (final v in listed) v.name],
          ['me', 'Macintosh HD', 'Backup', 'STICK'],
        );
        expect(
          [for (final v in listed) v.kind],
          [
            LocalVolumeKind.home,
            LocalVolumeKind.root,
            LocalVolumeKind.removable,
            LocalVolumeKind.removable,
          ],
        );
        // The boot link never lists as a volume of its own.
        expect(listed.where((v) => v.path == '/Volumes/Macintosh HD'), isEmpty);
        expect(listed.first.freeBytes, 1000 * 1024);
        expect(listed.last.freeBytes, 20 * 1024);
        // A failing df leaves only that row's number absent.
        expect(listed[2].freeBytes, isNull);
      },
    );

    test('eject runs diskutil and reports its answer', () async {
      final runner = _Runner();
      final volumes = SystemLocalVolumes(
        operatingSystem: 'macos',
        environment: const {'HOME': '/Users/me'},
        directories: _Tree(),
        run: runner.call,
      );
      const stick = LocalVolume(
        path: '/Volumes/STICK',
        name: 'STICK',
        kind: LocalVolumeKind.removable,
      );

      expect(await volumes.eject(stick), isTrue);
      expect(runner.calls.last, ['diskutil', 'eject', '/Volumes/STICK']);

      runner.exitCodes['diskutil'] = 1;
      expect(await volumes.eject(stick), isFalse);

      // A fixed volume has no eject verb at all.
      const root = LocalVolume(
        path: '/',
        name: 'HD',
        kind: LocalVolumeKind.root,
      );
      expect(await volumes.eject(root), isFalse);
    });
  });

  group('Linux', () {
    test(
      'udisks mounts are removable, /mnt entries fixed, root is the host',
      () async {
        final volumes = SystemLocalVolumes(
          operatingSystem: 'linux',
          environment: const {'HOME': '/home/me', 'USER': 'me'},
          hostName: 'workstation',
          directories: _Tree(
            children: {
              '/media/me': ['/media/me/CAMERA'],
              '/run/media/me': ['/run/media/me/archive'],
              '/mnt': ['/mnt/nas'],
            },
          ),
          run: _Runner().call,
        );

        final listed = await volumes.list();
        expect(
          [for (final v in listed) (v.name, v.kind)],
          [
            ('me', LocalVolumeKind.home),
            ('workstation', LocalVolumeKind.root),
            ('archive', LocalVolumeKind.removable),
            ('CAMERA', LocalVolumeKind.removable),
            ('nas', LocalVolumeKind.fixed),
          ],
        );
      },
    );

    test('eject tries gio first, then umount', () async {
      final runner = _Runner()..exitCodes['gio'] = 2;
      final volumes = SystemLocalVolumes(
        operatingSystem: 'linux',
        environment: const {'HOME': '/home/me'},
        directories: _Tree(),
        run: runner.call,
      );
      const camera = LocalVolume(
        path: '/media/me/CAMERA',
        name: 'CAMERA',
        kind: LocalVolumeKind.removable,
      );

      expect(await volumes.eject(camera), isTrue);
      expect(runner.calls, [
        ['gio', 'mount', '-u', '/media/me/CAMERA'],
        ['umount', '/media/me/CAMERA'],
      ]);
    });

    test('standard folders honor user-dirs and skip missing ones', () async {
      final config = Directory.systemTemp.createTempSync('pg-xdg-');
      addTearDown(() => config.deleteSync(recursive: true));
      File('${config.path}/user-dirs.dirs').writeAsStringSync(
        '# written by xdg-user-dirs-update\n'
        'XDG_DESKTOP_DIR="\$HOME/Schreibtisch"\n'
        'XDG_DOWNLOAD_DIR="\$HOME/Downloads"\n',
      );
      final volumes = SystemLocalVolumes(
        operatingSystem: 'linux',
        environment: {'HOME': '/home/me', 'XDG_CONFIG_HOME': config.path},
        directories: _Tree(
          dirs: {'/home/me/Schreibtisch', '/home/me/Downloads'},
        ),
        run: _Runner().call,
      );

      // Documents does not exist, so it is not offered.
      expect(await volumes.standardFolders(), [
        '/home/me/Schreibtisch',
        '/home/me/Downloads',
      ]);
    });
  });

  group('Windows', () {
    test('drive letters list with the system drive as root', () async {
      final volumes = SystemLocalVolumes(
        operatingSystem: 'windows',
        environment: const {
          'USERPROFILE': r'C:\Users\me',
          'USERNAME': 'me',
          'SystemDrive': 'C:',
        },
        directories: _Tree(dirs: {r'C:\', r'D:\', r'E:\'}),
        run: _Runner().call,
      );

      final listed = await volumes.list();
      expect(
        [for (final v in listed) (v.name, v.kind)],
        [
          ('me', LocalVolumeKind.home),
          ('C:', LocalVolumeKind.root),
          ('D:', LocalVolumeKind.fixed),
          ('E:', LocalVolumeKind.fixed),
        ],
      );
      // No df on Windows: free space stays absent rather than guessed.
      expect(listed.every((v) => v.freeBytes == null), isTrue);
    });
  });

  test('mobile platforms list no devices', () async {
    for (final os in ['android', 'ios']) {
      final volumes = SystemLocalVolumes(
        operatingSystem: os,
        environment: const {'HOME': '/data'},
        directories: _Tree(),
        run: _Runner().call,
      );
      expect(await volumes.list(), isEmpty, reason: os);
    }
  });

  test('the home is the folder the local pane opens as ~', () {
    String? home(String os, Map<String, String> environment) =>
        SystemLocalVolumes(
          operatingSystem: os,
          environment: environment,
          directories: _Tree(),
          run: _Runner().call,
        ).homeDirectory;

    // A phone lists no volumes, but its app storage still has a home.
    expect(
      home('android', const {'HOME': '/data/user/0/app/files'}),
      '/data/user/0/app/files',
    );
    // The engine's `~` rule: a sandboxed macOS HOME points into the app
    // container, and `~` still means the user's own home.
    expect(
      home('macos', const {
        'HOME': '/Users/me/Library/Containers/com.lkm.poltergeistApp/Data',
      }),
      '/Users/me',
    );
    expect(home('linux', const {'HOME': '/home/me/'}), '/home/me');
    expect(home('android', const {}), isNull);
  });

  group('df parsing', () {
    test('reads the Available column', () {
      expect(
        parseDfAvailableKibibytes(
          'Filesystem 1K-blocks Used Available Use% Mounted on\n'
          '/dev/sda1 100 40 60 40% /\n',
        ),
        60,
      );
    });

    test('a wrapped row still parses', () {
      expect(
        parseDfAvailableKibibytes(
          'Filesystem 1K-blocks Used Available Use% Mounted on\n'
          '/dev/mapper/a-very-long-volume-group-name\n'
          '           100 40 60 40% /\n',
        ),
        60,
      );
    });

    test('garbage answers null', () {
      expect(parseDfAvailableKibibytes(''), isNull);
      expect(parseDfAvailableKibibytes('Filesystem\n'), isNull);
      expect(
        parseDfAvailableKibibytes('Filesystem a b c\n/dev x y z w\n'),
        isNull,
      );
    });
  });

  test('user-dirs parsing expands \$HOME and skips relative values', () {
    expect(
      parseXdgUserDirs(
        'XDG_DESKTOP_DIR="\$HOME/Desktop"\n'
        'XDG_MUSIC_DIR="/srv/music"\n'
        'XDG_VIDEOS_DIR="Videos"\n'
        'garbage\n',
        home: '/home/me',
      ),
      {'XDG_DESKTOP_DIR': '/home/me/Desktop', 'XDG_MUSIC_DIR': '/srv/music'},
    );
  });
}
