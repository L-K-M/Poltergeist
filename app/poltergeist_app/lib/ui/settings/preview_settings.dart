// The Settings → Editing tab's "Preview & downloads" section (06 §8):
// the preview-cache size limit, the Clear Preview Cache button, and the
// large-download confirmation threshold — one setting shared by remote
// previews, Quick Look productions, compare sides, and external-editor
// checkouts. Follows the tab's immediate-persist idiom: capture the
// requested value, apply + save, revert field and live value on
// failure.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../top_toast.dart';

/// The live values and write sinks the section needs — assembled by the
/// shell so the dialog reads fresh numbers at open and never captures a
/// stale controller.
final class PreviewDownloadsSettings {
  const PreviewDownloadsSettings({
    required this.available,
    required this.capacityBytes,
    required this.thresholdBytes,
    required this.onCapacityChanged,
    required this.onThresholdChanged,
    required this.onClearCache,
  });

  /// Whether the §5.3 cache exists — false leaves the section
  /// rendered-disabled (a cache-less boot has nothing to size or clear).
  /// A flag rather than the cache itself: the Settings window renders
  /// this section in an isolate the cache does not live in.
  final bool available;

  /// Live cache cap in bytes.
  final int capacityBytes;

  /// Live large-download threshold in bytes.
  final int thresholdBytes;

  /// Applies + persists a new cache cap. Must throw on persist failure
  /// so the field can revert (the immediate-persist idiom).
  final Future<void> Function(int bytes) onCapacityChanged;

  /// Applies + persists a new threshold — same contract.
  final Future<void> Function(int bytes) onThresholdChanged;

  /// The `Clear Preview Cache` action; returns the bytes ACTUALLY
  /// reclaimed (06 §8: the toast never reports the pre-clear total).
  final Future<int> Function() onClearCache;
}

/// The §8 "Preview & downloads" rows. MiB text fields commit on
/// submit/focus-loss; invalid input restores the current value — no
/// half-parsed write ever reaches the stores.
class PreviewDownloadsSection extends StatefulWidget {
  const PreviewDownloadsSection({super.key, required this.settings});

  final PreviewDownloadsSettings settings;

  @override
  State<PreviewDownloadsSection> createState() =>
      _PreviewDownloadsSectionState();
}

class _PreviewDownloadsSectionState extends State<PreviewDownloadsSection> {
  late final TextEditingController _capacityField;
  late final TextEditingController _thresholdField;

  static const _mib = 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _capacityField = TextEditingController(
      text: '${widget.settings.capacityBytes ~/ _mib}',
    );
    _thresholdField = TextEditingController(
      text: '${widget.settings.thresholdBytes ~/ _mib}',
    );
  }

  @override
  void dispose() {
    _capacityField.dispose();
    _thresholdField.dispose();
    super.dispose();
  }

  /// Parses a MiB field into bytes; null rejects the commit (the field
  /// reverts to the live value instead of writing a partial parse).
  int? _parseMib(TextEditingController field, int liveBytes) {
    final parsed = int.tryParse(field.text.trim());
    if (parsed == null || parsed <= 0) {
      field.text = '${liveBytes ~/ _mib}';
      return null;
    }
    return parsed * _mib;
  }

  Future<void> _commitCapacity() async {
    final bytes = _parseMib(_capacityField, widget.settings.capacityBytes);
    if (bytes == null) return;
    try {
      await widget.settings.onCapacityChanged(bytes);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      // Immediate-persist revert: the field and the live value both
      // return to the pre-commit state.
      _capacityField.text =
          '${widget.settings.capacityBytes ~/ _mib}';
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  Future<void> _commitThreshold() async {
    final bytes = _parseMib(
      _thresholdField,
      widget.settings.thresholdBytes,
    );
    if (bytes == null) return;
    try {
      await widget.settings.onThresholdChanged(bytes);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      _thresholdField.text =
          '${widget.settings.thresholdBytes ~/ _mib}';
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  Future<void> _clearCache() async {
    try {
      final reclaimed = await widget.settings.onClearCache();
      if (!mounted) return;
      showTopToastIn(
        context,
        message: AppLocalizations.of(
          context,
        ).previewCacheCleared(reclaimed ~/ _mib),
      );
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) showTopToastIn(context, message: error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = widget.settings.available;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.previewSettingsSectionTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.previewCacheLimitLabel,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            SizedBox(
              width: 90,
              child: TextField(
                key: const ValueKey('preview.cacheLimitField'),
                controller: _capacityField,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  isDense: true,
                  suffixText: l10n.previewMiBSuffix,
                ),
                onSubmitted: (_) => unawaited(_commitCapacity()),
                onTapOutside: (_) => unawaited(_commitCapacity()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('preview.clearCache'),
            onPressed: enabled ? () => unawaited(_clearCache()) : null,
            child: Text(l10n.previewClearCacheLabel),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.previewThresholdLabel,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            SizedBox(
              width: 90,
              child: TextField(
                key: const ValueKey('preview.thresholdField'),
                controller: _thresholdField,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  isDense: true,
                  suffixText: l10n.previewMiBSuffix,
                ),
                onSubmitted: (_) => unawaited(_commitThreshold()),
                onTapOutside: (_) => unawaited(_commitThreshold()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
