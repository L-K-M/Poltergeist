import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show TransferConcurrency, maxGlobalInFlightTransfers;

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import '../../services/transfer_limits_controller.dart';
import 'activity_format.dart';

/// The throttle popover's fixed choices (02 §6): Off plus the three
/// named presets; anything else selects Custom and opens the field.
const _presets = <int?>[null, 256 * 1000, 1000 * 1000, 5 * 1000 * 1000];

/// 02 §6's bandwidth popover: Download and Upload independently, each
/// Off / 256 KB/s / 1 MB/s / 5 MB/s / custom. Selections apply to the
/// limiter immediately; custom text parses through
/// [parseTransferRate] — invalid input stays an inline error, never a
/// silent clamp. Below them, D37's default cap on each server's
/// simultaneous transfers: Automatic or a fixed count, applied the same
/// way.
class BandwidthPopover extends StatefulWidget {
  const BandwidthPopover({super.key, required this.controller});

  final ActivityPanelController controller;

  @override
  State<BandwidthPopover> createState() => _BandwidthPopoverState();
}

class _BandwidthPopoverState extends State<BandwidthPopover> {
  bool _downCustom = false;
  bool _upCustom = false;
  final _downField = TextEditingController();
  final _upField = TextEditingController();
  String? _downError;
  String? _upError;

  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    // A persisted value that is not a preset opens as Custom with the
    // current rate filled in — the popover never pretends a custom
    // limit is one of its named choices. The prefill reads the theme
    // platform, so it must run here, not in initState.
    final down = widget.controller.downloadLimiter?.bytesPerSecond;
    final up = widget.controller.uploadLimiter?.bytesPerSecond;
    _downCustom = down != null && !_presets.contains(down);
    _upCustom = up != null && !_presets.contains(up);
    if (_downCustom) _downField.text = _customText(down!);
    if (_upCustom) _upField.text = _customText(up!);
  }

  @override
  void dispose() {
    _downField.dispose();
    _upField.dispose();
    super.dispose();
  }

  String _customText(int bytesPerSecond) =>
      formatTransferLimit(bytesPerSecond, platform: _platform);

  TargetPlatform get _platform => Theme.of(context).platform;

  void _applyCustom({required bool download}) {
    final l10n = AppLocalizations.of(context);
    final field = download ? _downField : _upField;
    final parsed = parseTransferRate(field.text);
    setState(() {
      if (download) {
        _downError =
            parsed == null ? l10n.bandwidthInvalid(_maxText(l10n)) : null;
      } else {
        _upError =
            parsed == null ? l10n.bandwidthInvalid(_maxText(l10n)) : null;
      }
    });
    if (parsed == null) return;
    if (download) {
      widget.controller.setDownloadLimit(parsed);
    } else {
      widget.controller.setUploadLimit(parsed);
    }
  }

  String _maxText(AppLocalizations l10n) =>
      formatTransferLimit(maxTransferRateBytesPerSecond, platform: _platform);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final down = widget.controller.downloadLimiter?.bytesPerSecond;
    final up = widget.controller.uploadLimiter?.bytesPerSecond;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.bandwidthPopoverTitle,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          _DirectionRow(
            label: l10n.bandwidthDownLabel,
            current: down,
            customSelected: _downCustom,
            field: _downField,
            error: _downError,
            fieldKey: const ValueKey('bandwidth.down.field'),
            chipKeyPrefix: 'bandwidth.down.',
            onPreset: (value) {
              setState(() {
                _downCustom = false;
                _downError = null;
              });
              widget.controller.setDownloadLimit(value);
            },
            onCustom: () => setState(() => _downCustom = true),
            onApply: () => _applyCustom(download: true),
          ),
          const SizedBox(height: 8),
          _DirectionRow(
            label: l10n.bandwidthUpLabel,
            current: up,
            customSelected: _upCustom,
            field: _upField,
            error: _upError,
            fieldKey: const ValueKey('bandwidth.up.field'),
            chipKeyPrefix: 'bandwidth.up.',
            onPreset: (value) {
              setState(() {
                _upCustom = false;
                _upError = null;
              });
              widget.controller.setUploadLimit(value);
            },
            onCustom: () => setState(() => _upCustom = true),
            onApply: () => _applyCustom(download: false),
          ),
          if (widget.controller.transferLimits case final limits?) ...[
            const SizedBox(height: 12),
            _PerServerRow(limits: limits),
          ],
        ],
      ),
    );
  }
}

/// D37's default cap: how many files move to or from each server at
/// once. A server's own choice, set in its editor, outranks this one.
class _PerServerRow extends StatelessWidget {
  const _PerServerRow({required this.limits});

  final TransferLimitsController limits;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: limits,
      builder: (context, _) {
        final current = limits.perServer;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.transferLimitPerServerLabel,
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  key: const ValueKey('transferLimit.perServer.automatic'),
                  label: Text(l10n.transferLimitAutomatic),
                  selected: current.isAutomatic,
                  onSelected: (_) => limits.setPerServer(
                    const TransferConcurrency.automatic(),
                  ),
                ),
                for (final files in transferConcurrencyChoices)
                  ChoiceChip(
                    key: ValueKey('transferLimit.perServer.$files'),
                    label: Text('$files'),
                    selected: current.files == files,
                    onSelected: (_) =>
                        limits.setPerServer(TransferConcurrency.fixed(files)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.transferLimitPerServerNote(maxGlobalInFlightTransfers),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DirectionRow extends StatelessWidget {
  const _DirectionRow({
    required this.label,
    required this.current,
    required this.customSelected,
    required this.field,
    required this.error,
    required this.fieldKey,
    required this.chipKeyPrefix,
    required this.onPreset,
    required this.onCustom,
    required this.onApply,
  });

  final String label;
  final int? current;
  final bool customSelected;
  final TextEditingController field;
  final String? error;
  final Key fieldKey;
  final String chipKeyPrefix;
  final void Function(int? value) onPreset;
  final VoidCallback onCustom;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final platform = Theme.of(context).platform;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (var i = 0; i < _presets.length; i++)
              ChoiceChip(
                key: ValueKey('$chipKeyPrefix$i'),
                label: Text(
                  _presets[i] == null
                      ? l10n.bandwidthOff
                      : formatTransferLimit(
                          _presets[i]!,
                          platform: platform,
                        ),
                ),
                selected: !customSelected && current == _presets[i],
                onSelected: (_) => onPreset(_presets[i]),
              ),
            ChoiceChip(
              key: ValueKey('${chipKeyPrefix}custom'),
              label: Text(l10n.bandwidthCustom),
              selected: customSelected,
              onSelected: (_) => onCustom(),
            ),
          ],
        ),
        if (customSelected)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: fieldKey,
                    controller: field,
                    decoration: InputDecoration(
                      hintText: l10n.bandwidthCustomHint,
                      errorText: error,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => onApply(),
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilledButton(
                    key: ValueKey('${chipKeyPrefix}set'),
                    onPressed: onApply,
                    child: Text(l10n.bandwidthSet),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
