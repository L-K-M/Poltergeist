// Ported from Séance app/seance_app/lib/ui/appearance_settings.dart @ f4d2f71; see docs/PORTS.md.
// Divergences: strings localize through ARB (D20) and presets show their
// names from it; no Terminal colours section (no terminal here); the
// interface font is a text field only, since Poltergeist has no installed-
// font picker; the section is a column the Settings window's tab and the
// Settings dialog both scroll, written against [AppearanceSettingsModel]
// rather than Séance's settings backend.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/settings_models.dart';
import '../../theme/app_appearance.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_palette.dart';
import '../../theme/theme_presets.dart';
import '../color_picker.dart';
import '../top_toast.dart';

/// Settings → Appearance: this device's theme, after Vervellum's
/// `AppearanceView` by way of Séance. Pick a preset, then change anything.
///
/// Written to be played with. Every control writes straight through the
/// model and the app repaints as it does; there is no Save button, and
/// there should not be one, because the only way to judge a theme is to
/// look at it. The window or dialog this section is in repaints too, so the
/// section is its own preview.
///
/// The palette is this section's own copy, edited here and handed to the
/// model whole: in the Settings window, [AppearanceSettingsModel.value]
/// trails each write by a round trip to the app.
class AppearanceSection extends StatefulWidget {
  const AppearanceSection({super.key, required this.model});

  final AppearanceSettingsModel model;

  @override
  State<AppearanceSection> createState() => _AppearanceSectionState();
}

const List<ThemeSlot> _colourSlots = [
  ThemeSlot.surface,
  ThemeSlot.sidebar,
  ThemeSlot.raised,
  ThemeSlot.text,
  ThemeSlot.secondaryText,
  ThemeSlot.hairline,
  ThemeSlot.selection,
];

const List<ThemeSlot> _statusSlots = [
  ThemeSlot.online,
  ThemeSlot.offline,
  ThemeSlot.connecting,
  ThemeSlot.unknown,
];

/// What the Colours and Status colours rows call each slot.
String slotLabel(AppLocalizations l10n, ThemeSlot slot) => switch (slot) {
  ThemeSlot.surface => l10n.appearanceSlotSurface,
  ThemeSlot.sidebar => l10n.appearanceSlotSidebar,
  ThemeSlot.raised => l10n.appearanceSlotRaised,
  ThemeSlot.text => l10n.appearanceSlotText,
  ThemeSlot.secondaryText => l10n.appearanceSlotSecondaryText,
  ThemeSlot.hairline => l10n.appearanceSlotHairline,
  ThemeSlot.selection => l10n.appearanceSlotSelection,
  ThemeSlot.online => l10n.appearanceSlotOnline,
  ThemeSlot.offline => l10n.appearanceSlotOffline,
  ThemeSlot.connecting => l10n.appearanceSlotConnecting,
  ThemeSlot.unknown => l10n.appearanceSlotUnknown,
};

/// Each preset's name as the reader's language says it. The stored `name`
/// stays English (see [ThemePresets]); nothing here is written back.
Map<ThemePalette, String> presetLabels(AppLocalizations l10n) => {
  ThemePresets.poltergeist: l10n.themePresetPoltergeist,
  ThemePresets.graphite: l10n.themePresetGraphite,
  ThemePresets.paper: l10n.themePresetPaper,
  ThemePresets.newsprint: l10n.themePresetNewsprint,
  ThemePresets.solarized: l10n.themePresetSolarized,
  ThemePresets.midnight: l10n.themePresetMidnight,
  ThemePresets.terminal: l10n.themePresetTerminal,
  ThemePresets.vapor: l10n.themePresetVapor,
  ThemePresets.bubblegum: l10n.themePresetBubblegum,
  ThemePresets.highContrast: l10n.themePresetHighContrast,
};

/// A preset tile's minimum width: two to a row on a phone's Settings, three
/// or so in the Settings window.
const double _presetTileMinWidth = 148;
const double _presetGap = 10;

/// The corner a preset tile draws at its preset's own scale, so the grid
/// previews the corners as well as the colours.
const double _presetTileRadius = 8;

/// Below this the corner slider says "Square" rather than a percentage.
const double _squareCornerScale = 0.01;

/// The gap between two of the section's parts.
const double _partGap = 32;

class _AppearanceSectionState extends State<AppearanceSection> {
  late ThemePalette _palette = widget.model.value.palette;
  late ThemeModePreference _mode = widget.model.value.mode;

  /// Colours handed back to Automatic this session, so switching one off
  /// Automatic again returns what it was rather than starting over. Not
  /// persisted: it is an undo for a click, not a second copy of the theme.
  /// Cleared by anything that replaces the theme wholesale (a preset, a
  /// paste, a reset), which is not what it undoes.
  final Map<ThemeSlot, Color> _setAside = {};

  late final TextEditingController _font = TextEditingController(
    text: _palette.fontFamily ?? '',
  );

  /// One write in flight at a time; see [_persist].
  bool _writing = false;
  bool _dirty = false;

  @override
  void dispose() {
    _font.dispose();
    super.dispose();
  }

  /// What Automatic colours follow here, whatever the palette.
  Brightness get _automatic =>
      automaticBrightness(MediaQuery.platformBrightnessOf(context), _mode);

  /// The brightness the palette is drawn at.
  Brightness get _drawnAt => resolveBrightness(
    _palette,
    MediaQuery.platformBrightnessOf(context),
    _mode,
  );

  /// Writes the palette and mode as they are now, one write at a time.
  ///
  /// The controls write through on every change (a corner drag is dozens a
  /// second), and each write is a settings save, and in the Settings window
  /// a round trip to the app as well. Changes that land while one is in
  /// flight fold into a single write after it, of whatever is current then,
  /// rather than queueing one each. Finishes even if the section is closed
  /// mid-drag, so the last value is the one that sticks.
  Future<void> _persist() async {
    if (_writing) {
      _dirty = true;
      return;
    }
    _writing = true;
    try {
      do {
        _dirty = false;
        try {
          await widget.model.setAppearance(_palette, _mode);
        } on Object catch (error) {
          if (mounted) {
            showTopToastIn(
              context,
              message: AppLocalizations.of(
                context,
              ).appearanceNotSaved(error.toString()),
            );
          }
        }
      } while (_dirty);
    } finally {
      _writing = false;
    }
  }

  void _replace(ThemePalette palette) {
    if (palette == _palette) return;
    setState(() => _palette = palette);
    unawaited(_persist());
  }

  /// An edit to one value: the result is named for what it now matches.
  void _edit(ThemePalette palette) => _replace(palette.relabelled());

  /// A whole theme at once: a preset, a paste, the reset.
  void _adopt(ThemePalette palette) {
    _setAside.clear();
    _font.text = palette.fontFamily ?? '';
    _replace(palette);
  }

  void _setMode(ThemeModePreference mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    unawaited(_persist());
  }

  /// Off Automatic, a slot starts from what it was set aside as, or from
  /// what it draws as right now, so the first change is an adjustment and
  /// not a recovery from black.
  void _setAutomatic(ThemeSlot slot, bool automatic) {
    if (automatic) {
      final current = _palette.slot(slot);
      if (current == null) return;
      _setAside[slot] = current;
      _edit(_palette.withSlot(slot, null));
      return;
    }
    final start =
        _setAside.remove(slot) ??
        resolvedThemeSlots(_palette, _automatic)[slot]!;
    _edit(_palette.withSlot(slot, start));
  }

  Future<void> _pickSlot(ThemeSlot slot, Color current) async {
    final picked = await showColorPicker(
      context,
      initial: current,
      title: slotLabel(AppLocalizations.of(context), slot),
      allowAlpha: slot.allowsAlpha,
    );
    if (picked == null || !mounted) return;
    _edit(_palette.withSlot(slot, picked));
  }

  Future<void> _pickAccent() async {
    final picked = await showColorPicker(
      context,
      initial: _palette.accent,
      title: AppLocalizations.of(context).appearanceSlotAccent,
    );
    if (picked == null || !mounted) return;
    _edit(_palette.copyWith(accent: picked));
  }

  void _commitFont() {
    final family = _font.text.trim();
    if (family == (_palette.fontFamily ?? '')) return;
    _edit(_palette.withFontFamily(family));
  }

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert(_palette.toJson()),
      ),
    );
    if (mounted) showTopToastIn(context, message: l10n.appearanceCopied);
  }

  Future<void> _paste() async {
    final l10n = AppLocalizations.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    final pasted = text == null ? null : ThemePalette.tryParse(text);
    if (pasted == null) {
      showTopToastIn(context, message: l10n.appearancePasteNotATheme);
      return;
    }
    _adopt(pasted);
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context);
    final name = presetLabels(l10n)[ThemePresets.initial]!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.appearanceResetTitle),
        content: Text(l10n.appearanceResetBody(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.appearanceResetCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.appearanceResetConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _adopt(ThemePresets.initial);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = presetLabels(l10n);
    final resolved = resolvedThemeSlots(_palette, _automatic);
    final current = _palette.matchingPreset;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(
          l10n.appearanceThemeSection,
          helpTitle: l10n.appearanceThemeHelpTitle,
          help: l10n.appearanceThemeHelp,
        ),
        _PresetGrid(
          selected: current,
          automatic: _automatic,
          labels: labels,
          onPick: _adopt,
        ),
        _Footnote(l10n.appearancePresetFootnote),
        const Divider(height: _partGap),
        _Heading(l10n.appearanceModeSection),
        ..._modeSection(l10n),
        const Divider(height: _partGap),
        _Heading(
          l10n.appearanceColoursSection,
          helpTitle: l10n.appearanceColoursHelpTitle,
          help: l10n.appearanceColoursHelp,
        ),
        _ColourRow(
          label: l10n.appearanceSlotAccent,
          color: _palette.accent,
          onPick: _pickAccent,
        ),
        for (final slot in _colourSlots) _slotRow(l10n, slot, resolved),
        const Divider(height: _partGap),
        _Heading(l10n.appearanceStatusSection),
        for (final slot in _statusSlots) _slotRow(l10n, slot, resolved),
        _Footnote(l10n.appearanceStatusFootnote),
        const Divider(height: _partGap),
        _Heading(l10n.appearanceShapeSection),
        ..._shapeSection(l10n),
        const Divider(height: _partGap),
        _Heading(l10n.appearanceShareSection),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _copy,
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: Text(l10n.appearanceCopy),
            ),
            OutlinedButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.paste_outlined, size: 18),
              label: Text(l10n.appearancePaste),
            ),
          ],
        ),
        _Footnote(l10n.appearanceShareFootnote),
        const Divider(height: _partGap),
        _Heading(l10n.appearanceStartOverSection),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: _reset,
              child: Text(l10n.appearanceReset(labels[ThemePresets.initial]!)),
            ),
            Text(
              current == null
                  ? l10n.appearanceUsingCustom
                  : l10n.appearanceUsingPreset(labels[current]!),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _modeSection(AppLocalizations l10n) {
    final ownSurface = _palette.surface != null;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          l10n.appearanceModeLabel,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: SegmentedButton<ThemeModePreference>(
          segments: [
            ButtonSegment(
              value: ThemeModePreference.system,
              icon: const Icon(Icons.brightness_auto_outlined),
              label: Text(l10n.appearanceModeSystem),
            ),
            ButtonSegment(
              value: ThemeModePreference.light,
              icon: const Icon(Icons.light_mode_outlined),
              label: Text(l10n.appearanceModeLight),
            ),
            ButtonSegment(
              value: ThemeModePreference.dark,
              icon: const Icon(Icons.dark_mode_outlined),
              label: Text(l10n.appearanceModeDark),
            ),
          ],
          selected: {_mode},
          // A surface of its own decides the brightness, so no mode can
          // change what is drawn; offering the choice would be a control
          // that does nothing.
          onSelectionChanged: ownSurface
              ? null
              : (selection) => _setMode(selection.single),
        ),
      ),
      if (ownSurface)
        _Footnote(
          _drawnAt == Brightness.dark
              ? l10n.appearanceModeFixedDark
              : l10n.appearanceModeFixedLight,
        ),
    ];
  }

  Widget _slotRow(
    AppLocalizations l10n,
    ThemeSlot slot,
    Map<ThemeSlot, Color> resolved,
  ) {
    final automatic = _palette.slot(slot) == null;
    final shown = _palette.slot(slot) ?? resolved[slot]!;
    return _ColourRow(
      label: slotLabel(l10n, slot),
      color: shown,
      automatic: automatic,
      onAutomaticChanged: (value) => _setAutomatic(slot, value),
      onPick: () => _pickSlot(slot, shown),
    );
  }

  List<Widget> _shapeSection(AppLocalizations l10n) {
    final scale = _palette.cornerScale;
    final cornerLabel = scale <= _squareCornerScale
        ? l10n.appearanceCornersSquare
        : l10n.appearanceCornersPercent((scale * 100).round());
    return [
      TextField(
        key: const ValueKey('appearance.fontFamily'),
        controller: _font,
        decoration: InputDecoration(
          labelText: l10n.appearanceFontLabel,
          hintText: l10n.appearanceFontHint,
          helperText: l10n.appearanceFontHelper,
        ),
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _commitFont(),
        onTapOutside: (_) {
          // Overriding onTapOutside replaces TextField's default handler, so
          // the dismissal it would have done has to be done here.
          FocusManager.instance.primaryFocus?.unfocus();
          _commitFont();
        },
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Text(l10n.appearanceCorners),
          Expanded(
            child: Slider(
              min: ThemePalette.minCornerScale,
              max: ThemePalette.maxCornerScale,
              divisions: 40,
              value: scale,
              label: cornerLabel,
              // The text beside the slider is a sibling, not its label:
              // without this a screen reader says "65%" and never of what.
              semanticFormatterCallback: (_) =>
                  l10n.appearanceCornersSemantics(cornerLabel),
              onChanged: (value) =>
                  _edit(_palette.copyWith(cornerScale: value)),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              cornerLabel,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    ];
  }
}

/// A part's heading, in the settings sections' title style, with a help
/// button when there is more to say than fits beside the controls.
class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.helpTitle, this.help});

  final String title;
  final String? helpTitle;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final help = this.help;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (help != null)
            IconButton(
              tooltip: l10n.appearanceHelpTooltip(title),
              icon: const Icon(Icons.help_outline, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(helpTitle ?? title),
                  content: SingleChildScrollView(child: Text(help)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.appearanceHelpClose),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A line of small print under a part's controls.
class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One colour: its name, an Automatic box where it may be Automatic, and a
/// swatch that opens the picker.
class _ColourRow extends StatelessWidget {
  const _ColourRow({
    required this.label,
    required this.color,
    required this.onPick,
    this.automatic,
    this.onAutomaticChanged,
  });

  final String label;

  /// What the swatch shows: the colour set, or what Automatic draws now.
  final Color color;
  final VoidCallback onPick;

  /// Null for a colour that cannot be Automatic.
  final bool? automatic;
  final ValueChanged<bool>? onAutomaticChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final automatic = this.automatic;
    final onAutomaticChanged = this.onAutomaticChanged;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (automatic != null && onAutomaticChanged != null)
            InkWell(
              onTap: () => onAutomaticChanged(!automatic),
              borderRadius: BorderRadius.circular(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: automatic,
                    semanticLabel: l10n.appearanceAutomaticSemantics(label),
                    onChanged: (value) => onAutomaticChanged(value ?? false),
                  ),
                  ExcludeSemantics(child: Text(l10n.appearanceAutomatic)),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          _SwatchButton(
            color: color,
            tooltip: automatic == true
                ? l10n.appearanceSwatchAutomaticTooltip(label)
                : l10n.appearanceSwatchTooltip(label),
            onPressed: onPick,
          ),
        ],
      ),
    );
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  static const double _size = 28;

  @override
  Widget build(BuildContext context) {
    // Merged, tooltip inside: a Tooltip's own annotation above the button
    // would merge into whatever node is above it, which for these rows is
    // the page, and every swatch would say every other's name.
    return MergeSemantics(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          value: formatThemeColor(color),
          excludeSemantics: true,
          onTap: onPressed,
          child: InkWell(
            onTap: onPressed,
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_size / 6),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: ColorSwatchBox(color: color, size: _size),
            ),
          ),
        ),
      ),
    );
  }
}

/// The presets as small pictures of themselves: surface, accent, name and
/// the four status colours, which is what actually differs between two
/// themes that both read as "dark blue" in a list of names.
class _PresetGrid extends StatelessWidget {
  const _PresetGrid({
    required this.selected,
    required this.automatic,
    required this.labels,
    required this.onPick,
  });

  final ThemePalette? selected;

  /// What a preset that leaves its surface Automatic would be drawn at.
  final Brightness automatic;
  final Map<ThemePalette, String> labels;
  final ValueChanged<ThemePalette> onPick;

  /// What each preset looks like at a brightness, in [ThemePresets.all]'s
  /// order. Worked out once per run: the presets never change, the section
  /// rebuilds on every edit, and each look may seed a Material colour
  /// scheme.
  static final Map<Brightness, List<Map<ThemeSlot, Color>>> _looks = {};

  @override
  Widget build(BuildContext context) {
    final looks = _looks.putIfAbsent(
      automatic,
      () => [
        for (final preset in ThemePresets.all)
          resolvedThemeSlots(preset, automatic),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns =
            ((width + _presetGap) / (_presetTileMinWidth + _presetGap))
                .floor()
                .clamp(1, ThemePresets.all.length);
        final tileWidth = (width - _presetGap * (columns - 1)) / columns;
        return Wrap(
          spacing: _presetGap,
          runSpacing: _presetGap,
          children: [
            for (final (i, preset) in ThemePresets.all.indexed)
              SizedBox(
                width: tileWidth,
                child: _PresetTile(
                  preset: preset,
                  label: labels[preset]!,
                  colours: looks[i],
                  selected: identical(selected, preset),
                  onTap: () => onPick(preset),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.label,
    required this.colours,
    required this.selected,
    required this.onTap,
  });

  final ThemePalette preset;
  final String label;
  final Map<ThemeSlot, Color> colours;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final radius = BorderRadius.circular(
      _presetTileRadius * preset.cornerScale,
    );
    final text = colours[ThemeSlot.text]!;
    // Merged with the tooltip inside, as in [_SwatchButton].
    return MergeSemantics(
      child: Tooltip(
        message: l10n.appearancePresetTooltip(label),
        child: Semantics(
          button: true,
          selected: selected,
          child: Material(
            color: colours[ThemeSlot.surface],
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(
                color: selected ? preset.accent : colours[ThemeSlot.hairline]!,
                width: selected ? 2 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: preset.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // In the preset's own text colour: the tile is
                            // drawn in the preset's colours, and Terminal's
                            // name in the app's black would vanish on it.
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: text,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: preset.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        for (final (i, slot) in _statusSlots.indexed) ...[
                          if (i > 0) const SizedBox(width: 3),
                          Expanded(
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: colours[slot],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
