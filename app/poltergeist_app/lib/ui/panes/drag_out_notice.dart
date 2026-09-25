import '../../l10n/app_localizations.dart';
import '../../services/drag_out_controller.dart' show DragOutLeftOut;

/// The notice strip's sentence for rows a drag-out left behind (00 D14's
/// drag-out amendment): how many, and why, with one ARB message per
/// reason and one for a mix.
String dragOutLeftOutText(AppLocalizations l10n, DragOutLeftOut leftOut) {
  final count = leftOut.count;
  if (leftOut.links == count) return l10n.paneNoticeDragOutLinksLeftOut(count);
  if (leftOut.flaggedNames == count) {
    return l10n.paneNoticeDragOutNamesLeftOut(count);
  }
  return l10n.paneNoticeDragOutItemsLeftOut(count);
}
