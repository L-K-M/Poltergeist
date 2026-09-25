import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/local_volumes.dart';
import 'package:poltergeist_app/theme/family_hues.dart';
import 'package:poltergeist_app/ui/panes/kind_glyph.dart';
import 'package:poltergeist_app/ui/panes/pane_format.dart';
import 'package:poltergeist_app/ui/place_glyphs.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// D34's two meaning tables: what kind of item or place takes which
/// glyph and hue. The hues are the vocabulary the sibling apps share, so
/// a folder is the places blue and a PDF the destructive red in both.
void main() {
  group('kindGlyph', () {
    test('each listing kind wears its family hue', () {
      final hues = {
        for (final category in PaneKindCategory.values)
          category: kindGlyph(category).$2,
      };
      expect(hues, {
        PaneKindCategory.folder: FamilyHue.blue,
        PaneKindCategory.link: FamilyHue.cyan,
        PaneKindCategory.image: FamilyHue.pink,
        PaneKindCategory.document: FamilyHue.graphite,
        PaneKindCategory.code: FamilyHue.orange,
        PaneKindCategory.archive: FamilyHue.brown,
        PaneKindCategory.pdf: FamilyHue.red,
        PaneKindCategory.audio: FamilyHue.purple,
        PaneKindCategory.video: FamilyHue.purple,
        PaneKindCategory.other: FamilyHue.graphite,
      });
    });

    test('kinds that share a hue never share a glyph', () {
      final glyphs = {
        for (final category in PaneKindCategory.values)
          kindGlyph(category).$1,
      };
      expect(glyphs, hasLength(PaneKindCategory.values.length));
    });
  });

  group('volumeGlyph', () {
    test('Home is blue, the disks graphite, a removable volume brown', () {
      expect(volumeGlyph(LocalVolumeKind.home).hue, FamilyHue.blue);
      expect(volumeGlyph(LocalVolumeKind.root).hue, FamilyHue.graphite);
      expect(volumeGlyph(LocalVolumeKind.fixed).hue, FamilyHue.graphite);
      expect(volumeGlyph(LocalVolumeKind.removable).hue, FamilyHue.brown);
    });
  });

  group('standardFolderGlyph', () {
    test('names a standard folder directly inside home', () {
      expect(
        standardFolderGlyph('/home/ada/Downloads', home: '/home/ada'),
        (glyph: Icons.download, hue: FamilyHue.cyan),
      );
      expect(
        standardFolderGlyph('/Users/ada/Pictures', home: '/Users/ada/'),
        (glyph: Icons.photo, hue: FamilyHue.pink),
      );
      expect(
        standardFolderGlyph(r'C:\Users\ada\Music', home: r'C:\Users\ada'),
        (glyph: Icons.music_note, hue: FamilyHue.purple),
      );
    });

    test('matches the name case-insensitively', () {
      expect(
        standardFolderGlyph('/home/ada/documents', home: '/home/ada'),
        isNotNull,
      );
    });

    test('a name alone elsewhere is just a folder', () {
      expect(
        standardFolderGlyph('/srv/Downloads', home: '/home/ada'),
        isNull,
      );
      expect(
        standardFolderGlyph('/home/ada/work/Downloads', home: '/home/ada'),
        isNull,
      );
      expect(standardFolderGlyph('/home/ada/Downloads', home: null), isNull);
      expect(standardFolderGlyph('/home/ada/Projects', home: '/home/ada'),
          isNull);
    });
  });

  group('favoriteGlyph', () {
    final stamp = DateTime.utc(2026, 9, 25);
    Bookmark favorite(
      BookmarkKind kind, {
      String? path,
      ServerIcon? icon,
    }) => Bookmark(
      id: 'f',
      kind: kind,
      label: 'f',
      localPath: path,
      icon: icon,
      sortKey: 'f',
      createdAt: stamp,
      updatedAt: stamp,
    );

    test('a folder is blue; a standard folder takes its own glyph', () {
      expect(
        favoriteGlyph(favorite(BookmarkKind.localFolder, path: '/x/work')),
        (glyph: Icons.folder, hue: FamilyHue.blue),
      );
      expect(
        favoriteGlyph(
          favorite(BookmarkKind.localFolder, path: '/home/ada/Downloads'),
          home: '/home/ada',
        ).hue,
        FamilyHue.cyan,
      );
    });

    test('the icon the user picked wins over a standard folder\'s', () {
      final place = favoriteGlyph(
        favorite(
          BookmarkKind.localFolder,
          path: '/home/ada/Downloads',
          icon: ServerIcon.database,
        ),
        home: '/home/ada',
      );
      expect(place.glyph, isNot(Icons.download));
      expect(place.hue, FamilyHue.blue);
    });

    test('a workspace is the recipes teal, a saved sync the sync indigo', () {
      expect(favoriteGlyph(favorite(BookmarkKind.workspace)).hue, FamilyHue.teal);
      expect(
        favoriteGlyph(favorite(BookmarkKind.savedSync)).hue,
        FamilyHue.indigo,
      );
    });
  });
}
