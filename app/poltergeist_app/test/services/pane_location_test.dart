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
}
