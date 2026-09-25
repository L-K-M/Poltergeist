import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show FileSortDirection, FileSortKey;

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'pane_format.dart' show formatPaneModified;

/// The listing's column geometry (D32 §6), shared by the column header,
/// the rows, and the inline-rename editor's insets: one table, so a
/// header cell always sits over the cells it sorts. Widths scale with
/// the text scale (D20), the paddings do not.
@immutable
class PaneColumnMetrics {
  const PaneColumnMetrics._({
    required this.sizeWidth,
    required this.modifiedWidth,
  });

  /// The metrics for a pane [width] wide: below [_sizeColumnBreakpoint]
  /// the Size column folds away (Finder drops columns right-to-left of
  /// the name rather than starving it), so a narrow pane still shows
  /// readable names and dates.
  ///
  /// [modifiedWidth] is the Date Modified column's measured width
  /// ([modifiedWidthIn]); without one the column takes its floor. The
  /// column never takes more than [_modifiedShare] of the pane beyond
  /// that floor, so a narrow pane keeps its names and an ellipsis only
  /// returns to the longest dates there.
  factory PaneColumnMetrics.forWidth(
    double width,
    TextScaler scaler, {
    double? modifiedWidth,
  }) {
    final showSize = width >= scaler.scale(_sizeColumnBreakpoint);
    final floor = scaler.scale(_modifiedColumnWidth);
    return PaneColumnMetrics._(
      sizeWidth: showSize ? scaler.scale(_sizeColumnWidth) : 0,
      modifiedWidth: modifiedWidth == null
          ? floor
          : math.min(modifiedWidth, math.max(floor, width * _modifiedShare)),
    );
  }

  /// The Date Modified column's width in [context]: the widest date a
  /// row can print ("Today at", "Yesterday at" or a full date, each at a
  /// two-digit month, day and hour) in the rows' style, locale and text
  /// scale, and never below the spec's 116 px. A fixed width cut most
  /// full dates to an ellipsis on Linux's default font.
  static double modifiedWidthIn(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final localeName = Localizations.localeOf(context).toString();
    final scaler = MediaQuery.textScalerOf(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final now = DateTime(2026, 12, 29, 23);
    var widest = 0.0;
    for (final sample in [
      DateTime(2026, 12, 29, 22, 58),
      DateTime(2026, 12, 28, 22, 58),
      DateTime(2025, 12, 28, 22, 58),
    ]) {
      final text = formatPaneModified(
        sample,
        now: now,
        localeName: localeName,
        today: l10n.paneDateToday,
        yesterday: l10n.paneDateYesterday,
      );
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return math.max(scaler.scale(_modifiedColumnWidth), widest.ceilToDouble());
  }

  /// The metrics the nearest [PaneColumnMetricsScope] provides — the
  /// pane surface measures its width once for the header and every row.
  /// Outside a scope (a lone row in a test) the full column set applies.
  factory PaneColumnMetrics.of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<PaneColumnMetricsScope>();
    return scope?.metrics ??
        PaneColumnMetrics.forWidth(
          double.infinity,
          MediaQuery.textScalerOf(context),
        );
  }

  static const _sizeColumnWidth = 60.0;
  static const _modifiedColumnWidth = 116.0;
  static const _modifiedShare = 0.35;
  static const _sizeColumnBreakpoint = 360.0;

  /// Leading inset of every row, before the kind glyph.
  static const startPadding = 8.0;

  /// Trailing inset after the last column.
  static const endPadding = 10.0;

  static const glyphSize = 16.0;
  static const glyphGap = 6.0;

  /// Space between the name, size, and date columns.
  static const columnGap = 12.0;

  /// Zero while the pane is too narrow for the Size column.
  final double sizeWidth;
  final double modifiedWidth;

  bool get showsSize => sizeWidth > 0;

  /// Where the name text starts inside a row.
  double get nameStart => startPadding + glyphSize + glyphGap;

  /// The space the trailing columns take after the name column.
  double get trailingExtent =>
      (showsSize ? columnGap + sizeWidth : 0) +
      columnGap +
      modifiedWidth +
      endPadding;

  @override
  bool operator ==(Object other) =>
      other is PaneColumnMetrics &&
      other.sizeWidth == sizeWidth &&
      other.modifiedWidth == modifiedWidth;

  @override
  int get hashCode => Object.hash(sizeWidth, modifiedWidth);
}

/// Hands one pane's measured [PaneColumnMetrics] to its column header
/// and rows.
class PaneColumnMetricsScope extends InheritedWidget {
  const PaneColumnMetricsScope({
    super.key,
    required this.metrics,
    required super.child,
  });

  final PaneColumnMetrics metrics;

  @override
  bool updateShouldNotify(PaneColumnMetricsScope oldWidget) =>
      metrics != oldWidget.metrics;
}

/// D32 §6's column header: Name | Size | Date Modified over the Details
/// listing, 22 px, click to sort with a chevron on the sorted column.
/// It sits OUTSIDE the listing's scroll view so the drop zone's row
/// math (the list's origin is row 0) never has to subtract it.
class PaneColumnHeader extends StatelessWidget {
  const PaneColumnHeader({
    super.key,
    required this.paneTabId,
    required this.sortKey,
    required this.sortDirection,
    required this.onSort,
    this.enabled = true,
  });

  /// Keys the cells (`<paneTabId>.column.<key>`) for tests and the
  /// localization contract.
  final String paneTabId;
  final FileSortKey sortKey;
  final FileSortDirection sortDirection;
  final ValueChanged<FileSortKey> onSort;

  /// False while the listing is inert (connection lost, restored,
  /// disowned rows): the header stays visible but takes no clicks.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final metrics = PaneColumnMetrics.of(context);
    final height = MediaQuery.textScalerOf(context).scale(22);
    return IgnorePointer(
      ignoring: !enabled,
      child: Container(
        key: ValueKey('$paneTabId.columns'),
        height: height,
        decoration: BoxDecoration(
          color: chrome.paneBackground,
          border: Border(bottom: BorderSide(color: chrome.separator)),
        ),
        padding: const EdgeInsetsDirectional.only(
          start: PaneColumnMetrics.startPadding,
          end: PaneColumnMetrics.endPadding,
        ),
        child: Row(
          children: [
            Expanded(
              child: _cell(
                context,
                l10n,
                FileSortKey.name,
                l10n.paneColumnName,
                TextAlign.start,
              ),
            ),
            if (metrics.showsSize) ...[
              const SizedBox(width: PaneColumnMetrics.columnGap),
              SizedBox(
                width: metrics.sizeWidth,
                child: _cell(
                  context,
                  l10n,
                  FileSortKey.size,
                  l10n.paneColumnSize,
                  TextAlign.end,
                ),
              ),
            ],
            const SizedBox(width: PaneColumnMetrics.columnGap),
            SizedBox(
              width: metrics.modifiedWidth,
              child: _cell(
                context,
                l10n,
                FileSortKey.modified,
                l10n.paneColumnModified,
                TextAlign.end,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    AppLocalizations l10n,
    FileSortKey key,
    String label,
    TextAlign align,
  ) {
    final chrome = PoltergeistChrome.of(context);
    final sorted = key == sortKey;
    final ascending = sortDirection == FileSortDirection.ascending;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: sorted
          ? Theme.of(context).colorScheme.onSurface
          : chrome.secondaryText,
      fontWeight: sorted ? FontWeight.w600 : FontWeight.w500,
    );
    final text = Flexible(
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        style: style,
      ),
    );
    final chevron = sorted
        ? Icon(
            ascending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
            size: 14,
            color: chrome.secondaryText,
          )
        : const SizedBox(width: 14);
    return Semantics(
      button: true,
      label: label,
      value: sorted
          ? (ascending
                ? l10n.paneColumnSortedAscending
                : l10n.paneColumnSortedDescending)
          : null,
      hint: l10n.paneColumnSortHint,
      excludeSemantics: true,
      onTap: () => onSort(key),
      child: InkWell(
        key: ValueKey('$paneTabId.column.${key.name}'),
        onTap: () => onSort(key),
        hoverColor: chrome.hoverFill,
        child: Row(
          mainAxisAlignment: align == TextAlign.end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: align == TextAlign.end
              ? [chevron, text]
              : [
                  // The name column's label starts over the row's name
                  // text, past the kind glyph (Finder's alignment).
                  const SizedBox(
                    width:
                        PaneColumnMetrics.glyphSize +
                        PaneColumnMetrics.glyphGap,
                  ),
                  text,
                  chevron,
                ],
        ),
      ),
    );
  }
}
