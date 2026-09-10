import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';

void main() {
  SshConfigImportSetup? build({
    Map<String, String> environment = const {'HOME': '/home/tester'},
    bool isMacOS = false,
    bool isWindows = false,
    String supportPath = '/support',
  }) => buildSshConfigImportSetup(
    environment: environment,
    isMacOS: isMacOS,
    isWindows: isWindows,
    supportPath: supportPath,
    onError: (_, _) {},
  );

  test('builds the POSIX wiring from the environment', () {
    final setup = build();

    expect(setup, isNotNull);
    expect(setup!.configPath, '/home/tester/.ssh/config');
    expect(setup.service.homeDirectory, '/home/tester');
    expect(setup.bookmarks, isA<FileBookmarkStore>());
  });

  test('stays unregistered without a home directory', () {
    expect(build(environment: const {}), isNull);
  });

  test('stays unregistered on Windows', () {
    // The core import service normalizes POSIX paths, so a drive-letter
    // config cannot be read there; the command must not register a
    // surface that always fails.
    expect(build(isWindows: true), isNull);
  });

  test('recovers the real home from a macOS sandbox container', () {
    final setup = build(
      environment: const {
        'HOME': '/Users/alice/Library/Containers/com.lkm.poltergeistApp/Data',
      },
      isMacOS: true,
    );

    expect(setup!.service.homeDirectory, '/Users/alice');
    expect(setup.configPath, '/Users/alice/.ssh/config');
  });
}
