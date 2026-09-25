import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/drag_out_controller.dart';
import 'package:poltergeist_app/ui/panes/drag_out_notice.dart';

/// The left-out notice picks its sentence by what stayed behind: one
/// per reason, and one for a mix (00 D14's drag-out amendment).
void main() {
  final l10n = AppLocalizationsEn();

  test('links alone say that links cannot go out', () {
    expect(
      dragOutLeftOutText(l10n, const DragOutLeftOut(links: 1)),
      "1 link was left out: links can't be dragged out of Poltergeist.",
    );
    expect(
      dragOutLeftOutText(l10n, const DragOutLeftOut(links: 3)),
      "3 links were left out: links can't be dragged out of Poltergeist.",
    );
  });

  test('flagged names alone say the names are not valid UTF-8', () {
    expect(
      dragOutLeftOutText(l10n, const DragOutLeftOut(flaggedNames: 1)),
      "1 item was left out: its name isn't valid UTF-8, so it can't be "
      'dragged out.',
    );
    expect(
      dragOutLeftOutText(l10n, const DragOutLeftOut(flaggedNames: 2)),
      "2 items were left out: their names aren't valid UTF-8, so they "
      "can't be dragged out.",
    );
  });

  test('a mix names both rules', () {
    expect(
      dragOutLeftOutText(l10n, const DragOutLeftOut(links: 1, flaggedNames: 1)),
      "2 items were left out: links and names that aren't valid UTF-8 "
      "can't be dragged out of Poltergeist.",
    );
    expect(
      dragOutLeftOutText(l10n, const DragOutLeftOut(unlisted: 1)),
      "1 item was left out: it can't be dragged out of Poltergeist.",
    );
  });
}
