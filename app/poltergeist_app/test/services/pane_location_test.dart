import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_location.dart';

void main() {
  test('POSIX parents climb to the root, which is its own parent', () {
    expect(paneParentPath('/home/tester/docs'), '/home/tester');
    expect(paneParentPath('/home/tester'), '/home');
    expect(paneParentPath('/home'), '/');
    expect(paneParentPath('/'), '/');
    expect(paneParentPath('/home/'), '/');
  });

  test('Windows drive paths keep their drive root', () {
    expect(paneParentPath(r'C:\Users\tester'), r'C:\Users');
    expect(paneParentPath(r'C:\Users'), r'C:\');
    expect(paneParentPath(r'C:\'), r'C:\');
    expect(paneParentPath('C:'), r'C:\');
  });

  test('Windows UNC share roots are their own parent', () {
    expect(paneParentPath(r'\\server\share\docs'), r'\\server\share');
    // Only \\server\share is a listable root; \\server is not a directory.
    expect(paneParentPath(r'\\server\share'), r'\\server\share');
  });

  test('a backslash inside a POSIX name never flips the separator', () {
    // A Windows-migrated file on a Linux server: the path is absolute
    // POSIX, so '/' wins and the backslash is just a name character.
    expect(paneParentPath('/home/a\\b'), '/home');
    expect(paneParentPath('/home/a\\b/file'), '/home/a\\b');
    // Forward-slash Windows forms keep their own separator.
    expect(paneParentPath('C:/Users/tester'), 'C:/Users');
    expect(paneParentPath('C:/'), r'C:\');
  });

  test('relative and empty inputs are pinned, never crashes', () {
    // Degenerate inputs can reach the footer/helper from an unbound
    // pane: they return unchanged rather than throwing.
    expect(paneParentPath(''), '');
    expect(paneParentPath('docs'), 'docs');
    expect(paneParentPath('./docs'), '.');
  });

  test('paneLastSegment labels roots and leaves', () {
    expect(paneLastSegment(null), '');
    expect(paneLastSegment('/'), '/');
    expect(paneLastSegment(r'C:\'), r'C:\');
    expect(paneLastSegment('/home/tester'), 'tester');
    expect(paneLastSegment(r'C:\Users\tester'), 'tester');
  });
}
