import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  test('product name is non-empty pure ASCII', () {
    // macOS codesign rejects accented file names inside bundle paths; keeping
    // the product name ASCII lets the .app, .deb, AppImage, and APK all carry
    // the same name with no post-sign rename step (Séance needs one — see its
    // scripts/build.sh — because "Séance" is not ASCII).
    expect(productName, isNotEmpty);
    expect(
      productName.codeUnits.every((u) => u >= 0x20 && u < 0x7f),
      isTrue,
      reason: 'bundle/package file names derive from productName; '
          'codesign rejects non-ASCII file names',
    );
    // Packaging derives lowercase identifiers (binary name, .deb package
    // name) from the product name; a space or uppercase surprise there
    // should fail loudly here first.
    expect(productName.toLowerCase(), 'poltergeist');
  });

  test('tagline and homepage are present for packaging metadata', () {
    expect(productTagline, isNotEmpty);
    expect(productHomepage, startsWith('https://github.com/'));
  });
}
