import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';

import '../support/fake_bookmark_store.dart';

void main() {
  late BookmarkRepository bookmarks;

  setUp(() {
    // The setup must forward the caller's store, never build its own: the
    // Connections surface lists the same bookmarks, and a second instance
    // over one file would race the first one's write tail.
    bookmarks = FakeBookmarkStore();
  });

  SshConfigImportSetup? build({
    Map<String, String> environment = const {'HOME': '/home/tester'},
    bool isMacOS = false,
    bool isWindows = false,
  }) => buildSshConfigImportSetup(
    environment: environment,
    isMacOS: isMacOS,
    isWindows: isWindows,
    bookmarks: bookmarks,
  );

  test('builds the POSIX wiring from the environment', () {
    final setup = build();

    expect(setup, isNotNull);
    expect(setup!.configPath, '/home/tester/.ssh/config');
    expect(setup.service.homeDirectory, '/home/tester');
    expect(setup.bookmarks, same(bookmarks));
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
