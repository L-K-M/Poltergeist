// The Sync Files sheet (D32 §7, amending 05 §7's "never a modal
// wizard"): Transmit's options sheet in front of the plan review. Two
// endpoint tiles with a direction toggle, the handful of options the
// engine really supports, and a plain-language "Here's the plan:"
// paragraph (sync_policy_sentence.dart) that restates the options
// truthfully before anything is scanned.
//
// The sheet never scans or runs. It pops a [SyncSheetResult]; the shell
// persists and opens the plan tab, whose controller owns the scan, the
// review, and the run exactly as before. Hidden on purpose: "Follow
// symbolic links" (v2) and an age filter (the engine has none, and
// under Mirror it would delete old files) — the sheet never offers what
// the engine cannot do.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../services/rsync_endpoints.dart';
import '../../services/sync_plan_controller.dart' show SyncCaseOverrides;
import '../../services/uuid.dart';
import '../../theme/app_theme.dart';
import '../server_appearance.dart';
import '../server_label_scope.dart';
import 'rsync_copy.dart';
import 'sync_pair_editor.dart';
import 'sync_policy_sentence.dart';
import 'sync_sheet_dialogs.dart';

/// Below this window width the sheet is a full-screen dialog (D32 §9).
const double kSyncSheetCompactWidth = 600;

/// Where the sheet was opened from — it decides the title, whether a
/// name field shows, and whether leaving through a verb persists.
enum SyncSheetMode {
  /// ⌥⌘Y over the two panes: nothing persists unless the user saves.
  adHoc,

  /// A sidebar favorite reopened: edits stay with this session until
  /// Save as Favorite updates the favorite in place.
  saved,

  /// `sync.newSavedSync`: a name field, and every verb but Cancel
  /// persists the favorite first.
  newSaved,
}

/// The verb the sheet closed with.
enum SyncSheetAction {
  /// newSaved only: persist the favorite, open nothing.
  save,

  /// Scan and open the review; nothing runs until Run.
  simulate,

  /// Scan, then run straight away when the plan only creates;
  /// otherwise land on the review with the reason banner.
  synchronize,
}

/// What the sheet hands back to the shell.
final class SyncSheetResult {
  const SyncSheetResult({
    required this.action,
    required this.pair,
    this.caseOverrides,
  });

  final SyncSheetAction action;
  final SyncPair pair;

  /// The Advanced editor's case answers — null leaves the stored pair
  /// state authoritative.
  final SyncCaseOverrides? caseOverrides;
}

/// Resolves a remote endpoint's server reference to its catalog entry
/// (badge and name) — null when the shell cannot.
typedef SyncServerLookup = ServerConfig? Function(BookmarkServerRef ref);

/// Opens the sheet; null when cancelled.
Future<SyncSheetResult?> showSyncSetupSheet(
  BuildContext context, {
  required SyncSheetMode mode,
  SyncPair? initial,
  SyncPairState? pairState,
  List<Bookmark> servers = const [],
  required bool Function(SyncEndpoint endpoint) endpointAvailable,
  RsyncEndpointResolver? rsyncEndpoints,
  Future<bool> Function(SyncPair pair)? onSaveFavorite,
  SyncServerLookup? serverFor,
}) => showDialog<SyncSheetResult>(
  context: context,
  builder: (_) => SyncSetupSheet(
    mode: mode,
    initial: initial,
    pairState: pairState,
    servers: servers,
    endpointAvailable: endpointAvailable,
    rsyncEndpoints: rsyncEndpoints,
    onSaveFavorite: onSaveFavorite,
    serverFor: serverFor,
  ),
);

/// The sheet itself — public so tests can mount it directly.
final class SyncSetupSheet extends StatefulWidget {
  const SyncSetupSheet({
    super.key,
    required this.mode,
    this.initial,
    this.pairState,
    this.servers = const [],
    required this.endpointAvailable,
    this.rsyncEndpoints,
    this.onSaveFavorite,
    this.serverFor,
  });

  final SyncSheetMode mode;

  /// The pair to start from; null only for a new saved sync opened
  /// without two bound panes (the tiles then ask for folders).
  final SyncPair? initial;

  /// The pair's stored state when the shell could read it before a
  /// scan — §4's clock flags feed the plan sentence and the rsync
  /// export, the case overrides seed the Advanced editor.
  final SyncPairState? pairState;

  /// The remote bookmarks the Advanced editor's endpoint pickers offer.
  final List<Bookmark> servers;

  /// Whether an endpoint can serve a filesystem in this process
  /// (SyncEnvironment.endpointAvailable) — false keeps Simulate and
  /// Synchronize disabled behind the honest notice instead of opening a
  /// tab that could only fail.
  final bool Function(SyncEndpoint endpoint) endpointAvailable;

  /// Null hides Copy as rsync Command.
  final RsyncEndpointResolver? rsyncEndpoints;

  /// Persists a named pair as a saved sync (true on success); null
  /// hides Save as Favorite.
  final Future<bool> Function(SyncPair pair)? onSaveFavorite;

  final SyncServerLookup? serverFor;

  @override
  State<SyncSetupSheet> createState() => _SyncSetupSheetState();
}

class _SyncSetupSheetState extends State<SyncSetupSheet> {
  late SyncSheetMode _mode = widget.mode;
  late final String _id = widget.initial?.id ?? uuidV4();
  late final DateTime? _lastRunAt = widget.initial?.lastRunAt;
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late SyncEndpoint? _left = widget.initial?.left;
  late SyncEndpoint? _right = widget.initial?.right;
  late SyncRuleSet _rules = widget.initial?.rules ?? const SyncRuleSet();

  /// The pair's rules, kept while "Skip items matching rules" is
  /// unchecked so re-checking restores them.
  late List<String> _globs = List.of(_rules.excludeGlobs);
  late bool _skipRules = _globs.isNotEmpty;

  /// The one-way direction the toggle returns to from Both Ways.
  late SyncDirection _oneWay = _rules.direction == SyncDirection.bidirectional
      ? SyncDirection.leftToRight
      : _rules.direction;

  /// The deletion choice the checkbox restores when re-checked.
  late DeletionPolicy _deletionChoice = _rules.deletions == DeletionPolicy.none
      ? DeletionPolicy.trash
      : _rules.deletions;
  SyncCaseOverrides? _caseOverrides;

  /// The sheet's own focus — Enter here is the default button.
  final _rootFocus = FocusNode(debugLabel: 'sync.sheet');

  @override
  void dispose() {
    _name.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  /// Synchronize is the default button (D32 §7): Enter fires it while
  /// the sheet itself holds focus. A focused control (a Tab-reached
  /// button, the name field) keeps Enter for itself.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (FocusManager.instance.primaryFocus != _rootFocus) {
      return KeyEventResult.ignored;
    }
    _finish(SyncSheetAction.synchronize);
    return KeyEventResult.handled;
  }

  // -- Derived state -------------------------------------------------------

  bool get _bothWays => _rules.direction == SyncDirection.bidirectional;

  /// The pair the options describe — null while a side has no folder.
  SyncPair? get _pair {
    final left = _left;
    final right = _right;
    if (left == null || right == null) return null;
    return SyncPair(
      id: _id,
      name: _name.text.trim(),
      left: left,
      right: right,
      rules: _rules.copyWith(excludeGlobs: _skipRules ? _globs : const []),
      lastRunAt: _lastRunAt,
    );
  }

  bool get _complete =>
      _pair != null &&
      (_mode != SyncSheetMode.newSaved || _name.text.trim().isNotEmpty);

  bool get _available =>
      _complete &&
      widget.endpointAvailable(_left!) &&
      widget.endpointAvailable(_right!);

  void _setRules(SyncRuleSet rules) => setState(() => _rules = rules);

  // -- Option edits --------------------------------------------------------

  void _toggleDirection() {
    if (_bothWays) {
      _setRules(_rules.copyWith(direction: _oneWay));
      return;
    }
    _oneWay = _rules.direction == SyncDirection.leftToRight
        ? SyncDirection.rightToLeft
        : SyncDirection.leftToRight;
    _setRules(_rules.copyWith(direction: _oneWay));
  }

  void _setBothWays(bool bothWays) => _setRules(
    bothWays
        // Additive never deletes (05 §6) — the invariant is structural.
        ? _rules.copyWith(
            direction: SyncDirection.bidirectional,
            deletions: DeletionPolicy.none,
          )
        : _rules.copyWith(direction: _oneWay),
  );

  void _setDeleteOrphans(bool delete) => _setRules(
    _rules.copyWith(deletions: delete ? _deletionChoice : DeletionPolicy.none),
  );

  void _setDeletionChoice(DeletionPolicy? policy) {
    if (policy == null || policy == DeletionPolicy.none) return;
    _deletionChoice = policy;
    _setRules(_rules.copyWith(deletions: policy));
  }

  Future<void> _setSkipRules(bool skip) async {
    // Checking with no rules yet has nothing to apply — open the
    // editor so the checkbox never reads on while doing nothing.
    if (skip && _globs.isEmpty) {
      await _editRules();
      return;
    }
    setState(() => _skipRules = skip);
  }

  Future<void> _editRules() async {
    final globs = await showSyncRulesDialog(context, globs: _globs);
    if (globs == null || !mounted) return;
    setState(() {
      _globs = globs;
      _skipRules = globs.isNotEmpty;
    });
  }

  Future<void> _editTimeOffset() async {
    final result = await showSyncTimeOffsetDialog(
      context,
      initial: (
        toleranceSecs: _rules.mtimeToleranceSecs,
        ignoreHourShift: _rules.acceptedTimeShifts.contains(kSyncHourShiftSecs),
      ),
    );
    if (result == null || !mounted) return;
    // Only the 1-hour membership is this dialog's to change — any other
    // accepted shift (the Advanced editor's, an older build's) stays.
    final others = [
      for (final shift in _rules.acceptedTimeShifts)
        if (shift != kSyncHourShiftSecs) shift,
    ];
    _setRules(
      _rules.copyWith(
        mtimeToleranceSecs: result.toleranceSecs,
        acceptedTimeShifts: [
          if (result.ignoreHourShift) kSyncHourShiftSecs,
          ...others,
        ],
      ),
    );
  }

  // -- The ⋯ menu ----------------------------------------------------------

  Future<void> _saveFavorite() async {
    final save = widget.onSaveFavorite;
    final pair = _pair;
    if (save == null || pair == null) return;
    final name = await showSyncFavoriteNameDialog(
      context,
      initialName: pair.name,
    );
    if (name == null || !mounted) return;
    final named = SyncPair(
      id: pair.id,
      name: name,
      left: pair.left,
      right: pair.right,
      rules: pair.rules,
      lastRunAt: pair.lastRunAt,
    );
    if (!await save(named) || !mounted) return;
    setState(() {
      _name.text = name;
      // The pair is a favorite now: a later save updates it in place.
      if (_mode == SyncSheetMode.adHoc) _mode = SyncSheetMode.saved;
    });
  }

  Future<void> _advanced() async {
    final l10n = AppLocalizations.of(context);
    final state = widget.pairState;
    final result = await showDialog<SyncPairEditorResult>(
      context: context,
      builder: (_) => SyncPairEditorDialog(
        // The editor needs a whole pair; an unset side is an empty
        // local path, which its path field renders as blank.
        initial: SyncPair(
          id: _id,
          name: _name.text.trim(),
          left: _left ?? const LocalEndpoint(''),
          right: _right ?? const LocalEndpoint(''),
          rules: _rules.copyWith(excludeGlobs: _skipRules ? _globs : const []),
          lastRunAt: _lastRunAt,
        ),
        initialCaseOverrides:
            _caseOverrides ??
            (state == null
                ? null
                : SyncCaseOverrides(
                    left: state.caseSensitiveOverrideLeft,
                    right: state.caseSensitiveOverrideRight,
                  )),
        servers: widget.servers,
        saveLabel: l10n.syncRulesDone,
      ),
    );
    if (result == null || !mounted) return;
    final pair = result.pair;
    setState(() {
      _name.text = pair.name;
      _left = pair.left;
      _right = pair.right;
      _rules = pair.rules;
      _globs = List.of(pair.rules.excludeGlobs);
      _skipRules = _globs.isNotEmpty;
      if (pair.rules.direction != SyncDirection.bidirectional) {
        _oneWay = pair.rules.direction;
      }
      if (pair.rules.deletions != DeletionPolicy.none) {
        _deletionChoice = pair.rules.deletions;
      }
      _caseOverrides = result.caseOverrides ?? _caseOverrides;
    });
  }

  Future<void> _copyRsync() async {
    final resolver = widget.rsyncEndpoints;
    final pair = _pair;
    if (resolver == null || pair == null) return;
    await copyPairRsyncCommand(
      context,
      pair,
      resolver,
      pairState: widget.pairState,
    );
  }

  bool get _canCopyRsync {
    final resolver = widget.rsyncEndpoints;
    final pair = _pair;
    return resolver != null && pair != null && resolver(pair) != null;
  }

  void _finish(SyncSheetAction action) {
    final pair = _pair;
    if (pair == null) return;
    final ready = action == SyncSheetAction.save ? _complete : _available;
    if (!ready) return;
    Navigator.of(context).pop(
      SyncSheetResult(
        action: action,
        pair: pair,
        caseOverrides: _caseOverrides,
      ),
    );
  }

  // -- Layout --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final compact = MediaQuery.sizeOf(context).width < kSyncSheetCompactWidth;
    final title = _mode == SyncSheetMode.newSaved
        ? l10n.syncSheetNewSavedTitle
        : l10n.syncSheetTitle;
    final content = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, compact ? 8 : 0, 20, 12),
      child: _buildContent(context, l10n),
    );
    final buttons = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 20, 16),
      child: _buildButtons(context, l10n),
    );
    final body = Focus(
      focusNode: _rootFocus,
      autofocus: _mode != SyncSheetMode.newSaved,
      onKeyEvent: _onKey,
      child: compact
          ? Column(
              children: [
                Expanded(child: content),
                buttons,
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Column(
                    children: [
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      // A reopened favorite names itself — the sheet
                      // edits that favorite's session, not a new pair.
                      if (_mode == SyncSheetMode.saved)
                        Text(
                          _name.text.trim(),
                          key: const ValueKey('sync.sheet.favoriteName'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: PoltergeistChrome.of(
                                  context,
                                ).secondaryText,
                              ),
                        ),
                    ],
                  ),
                ),
                Flexible(child: content),
                buttons,
              ],
            ),
    );
    if (compact) {
      return Dialog.fullscreen(
        key: const ValueKey('sync.sheet'),
        child: Scaffold(
          appBar: AppBar(
            leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
            title: Text(title),
          ),
          body: SafeArea(child: body),
        ),
      );
    }
    return Dialog(
      key: const ValueKey('sync.sheet'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kSyncSheetCompactWidth),
        child: body,
      ),
    );
  }

  Widget _buildContent(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final pair = _pair;
    final unavailable = _complete && !_available;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_mode == SyncSheetMode.newSaved) ...[
          TextField(
            key: const ValueKey('sync.sheet.name'),
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.syncEditorNameLabel,
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Expanded(
              child: _EndpointTile(
                key: const ValueKey('sync.sheet.left'),
                endpoint: _left,
                serverFor: widget.serverFor,
                onChoose: _advanced,
              ),
            ),
            _DirectionToggle(
              direction: _rules.direction,
              sourceLabel: _left == null
                  ? ''
                  : syncEndpointFolderName(
                      _rules.direction == SyncDirection.rightToLeft
                          ? _right!
                          : _left!,
                    ),
              destinationLabel: _right == null
                  ? ''
                  : syncEndpointFolderName(
                      _rules.direction == SyncDirection.rightToLeft
                          ? _left!
                          : _right!,
                    ),
              onPressed: pair == null ? null : _toggleDirection,
            ),
            Expanded(
              child: _EndpointTile(
                key: const ValueKey('sync.sheet.right'),
                endpoint: _right,
                serverFor: widget.serverFor,
                onChoose: _advanced,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Divider(height: 1, color: chrome.separator),
        const SizedBox(height: 8),
        _CompareRow(
          comparison: _rules.comparison,
          onChanged: (mode) => _setRules(_rules.copyWith(comparison: mode)),
        ),
        _CheckRow(
          checkKey: const ValueKey('sync.sheet.deleteOrphans'),
          label: l10n.syncSheetDeleteOrphans,
          value: _rules.deletions != DeletionPolicy.none,
          caption: _bothWays ? l10n.syncSheetDeleteOrphansBothWays : null,
          onChanged: _bothWays ? null : _setDeleteOrphans,
        ),
        if (_rules.deletions != DeletionPolicy.none)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: RadioGroup<DeletionPolicy>(
              groupValue: _rules.deletions,
              onChanged: _setDeletionChoice,
              child: Column(
                children: [
                  RadioListTile<DeletionPolicy>(
                    key: const ValueKey('sync.sheet.deleteTrash'),
                    value: DeletionPolicy.trash,
                    dense: true,
                    visualDensity: const VisualDensity(
                      horizontal: VisualDensity.minimumDensity,
                      vertical: VisualDensity.minimumDensity,
                    ),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.syncSheetDeleteToTrash),
                  ),
                  RadioListTile<DeletionPolicy>(
                    key: const ValueKey('sync.sheet.deletePermanent'),
                    value: DeletionPolicy.permanent,
                    dense: true,
                    visualDensity: const VisualDensity(
                      horizontal: VisualDensity.minimumDensity,
                      vertical: VisualDensity.minimumDensity,
                    ),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.syncSheetDeletePermanently),
                  ),
                ],
              ),
            ),
          ),
        _CheckRow(
          checkKey: const ValueKey('sync.sheet.includeHidden'),
          label: l10n.syncSheetIncludeHidden,
          value: _rules.includeHidden,
          onChanged: (value) =>
              _setRules(_rules.copyWith(includeHidden: value)),
        ),
        _CheckRow(
          checkKey: const ValueKey('sync.sheet.skipRules'),
          label: l10n.syncSheetSkipRules,
          value: _skipRules,
          onChanged: _setSkipRules,
          trailing: [
            Tooltip(
              message: _globs.isEmpty
                  ? l10n.syncSheetRuleCount(0)
                  : _globs.join('\n'),
              child: Text(
                l10n.syncSheetRuleCount(_globs.length),
                key: const ValueKey('sync.sheet.ruleCount'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: chrome.secondaryText,
                ),
              ),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: const ValueKey('sync.sheet.editRules'),
              onPressed: _editRules,
              child: Text(l10n.syncSheetEditRules),
            ),
          ],
        ),
        Padding(
          // Aligned with the checkbox labels above.
          padding: const EdgeInsets.only(left: 32),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _toleranceLabel(l10n),
                  key: const ValueKey('sync.sheet.tolerance'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _datesCompared ? null : chrome.secondaryText,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('sync.sheet.timeOffset'),
                onPressed: _datesCompared ? _editTimeOffset : null,
                child: Text(l10n.syncSheetTimeOffset),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Divider(height: 1, color: chrome.separator),
        const SizedBox(height: 12),
        if (pair != null) ...[
          Text(
            l10n.syncSheetPlanLead,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          _PlanParagraph(
            clauses: syncPolicySentence(l10n, pair, widget.pairState),
          ),
        ],
        if (unavailable) ...[
          const SizedBox(height: 12),
          Row(
            key: const ValueKey('sync.sheet.unavailable'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 16,
                color: chrome.secondaryText,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.syncRemoteUnavailable,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: chrome.secondaryText,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Whether the comparison reads modification dates at all — the
  /// tolerance only means something when it does.
  bool get _datesCompared => _rules.comparison == ComparisonMode.sizeAndMtime;

  String _toleranceLabel(AppLocalizations l10n) {
    if (!_datesCompared) return l10n.syncSheetToleranceUnused;
    final hour = _rules.acceptedTimeShifts.contains(kSyncHourShiftSecs);
    final others = _rules.acceptedTimeShifts
        .where((shift) => shift != kSyncHourShiftSecs)
        .length;
    return [
      l10n.syncSheetTolerance(_rules.mtimeToleranceSecs),
      if (hour) l10n.syncSheetToleranceHourShift,
      if (others > 0) l10n.syncSheetToleranceOtherShifts(others),
    ].join(', ');
  }

  Widget _buildButtons(BuildContext context, AppLocalizations l10n) {
    final complete = _complete;
    final available = _available;
    final more = PopupMenuButton<_SheetMenuItem>(
      key: const ValueKey('sync.sheet.more'),
      tooltip: l10n.syncSheetMore,
      icon: const Icon(Icons.more_horiz),
      onSelected: (item) {
        switch (item) {
          case _SheetMenuItem.bothWays:
            _setBothWays(!_bothWays);
          case _SheetMenuItem.saveFavorite:
            unawaited(_saveFavorite());
          case _SheetMenuItem.advanced:
            unawaited(_advanced());
          case _SheetMenuItem.copyRsync:
            unawaited(_copyRsync());
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          key: const ValueKey('sync.sheet.more.bothWays'),
          value: _SheetMenuItem.bothWays,
          checked: _bothWays,
          enabled: _pair != null,
          child: Text(l10n.syncSheetBothWays),
        ),
        const PopupMenuDivider(),
        if (widget.onSaveFavorite != null && _mode != SyncSheetMode.newSaved)
          PopupMenuItem(
            key: const ValueKey('sync.sheet.more.saveFavorite'),
            value: _SheetMenuItem.saveFavorite,
            enabled: complete,
            child: Text(l10n.syncSaveAsFavorite),
          ),
        PopupMenuItem(
          key: const ValueKey('sync.sheet.more.advanced'),
          value: _SheetMenuItem.advanced,
          child: Text(l10n.syncSheetAdvanced),
        ),
        if (widget.rsyncEndpoints != null)
          PopupMenuItem(
            key: const ValueKey('sync.sheet.more.rsync'),
            value: _SheetMenuItem.copyRsync,
            enabled: _canCopyRsync,
            child: Text(l10n.syncCopyRsyncCommand),
          ),
      ],
    );
    // The ⋯ menu stays leftmost; the verbs right-align and wrap on a
    // narrow sheet.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        more,
        const SizedBox(width: 16),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                key: const ValueKey('sync.sheet.cancel'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.syncCancel),
              ),
              if (_mode == SyncSheetMode.newSaved)
                OutlinedButton(
                  key: const ValueKey('sync.sheet.save'),
                  onPressed: complete
                      ? () => _finish(SyncSheetAction.save)
                      : null,
                  child: Text(l10n.syncEditorSave),
                ),
              Tooltip(
                message: l10n.syncSheetSimulateTooltip,
                child: OutlinedButton(
                  key: const ValueKey('sync.sheet.simulate'),
                  onPressed: available
                      ? () => _finish(SyncSheetAction.simulate)
                      : null,
                  child: Text(l10n.syncSheetSimulate),
                ),
              ),
              Tooltip(
                message: l10n.syncSheetSynchronizeTooltip,
                child: FilledButton(
                  key: const ValueKey('sync.sheet.synchronize'),
                  onPressed: available
                      ? () => _finish(SyncSheetAction.synchronize)
                      : null,
                  child: Text(l10n.syncSheetSynchronize),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _SheetMenuItem { bothWays, saveFavorite, advanced, copyRsync }

/// One endpoint: its icon (a computer, or the server's own badge), the
/// host or "This computer", and the shortened path with the full path
/// in the tooltip.
class _EndpointTile extends StatelessWidget {
  const _EndpointTile({
    super.key,
    required this.endpoint,
    required this.serverFor,
    required this.onChoose,
  });

  final SyncEndpoint? endpoint;
  final SyncServerLookup? serverFor;
  final VoidCallback onChoose;

  static const double _iconSize = 40;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final endpoint = this.endpoint;
    if (endpoint == null) {
      return Column(
        children: [
          Icon(
            Icons.create_new_folder_outlined,
            size: _iconSize,
            color: chrome.secondaryText,
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: onChoose,
            child: Text(l10n.syncSheetChooseFolders),
          ),
        ],
      );
    }
    final (icon, caption, path) = switch (endpoint) {
      LocalEndpoint(:final path) => (
        Icon(Icons.computer, size: _iconSize, color: chrome.secondaryText),
        l10n.syncSheetThisComputer,
        path,
      ),
      RemoteEndpoint(:final server, :final path) => _remote(
        context,
        l10n,
        server,
        path,
      ),
    };
    // One announcement per tile: the caption, the shortened path, and
    // the tooltip's full path merge into a single node.
    return MergeSemantics(
      child: Column(
        children: [
          SizedBox.square(
            dimension: _iconSize + 8,
            child: Center(child: icon),
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Tooltip(
            message: path,
            child: Text(
              shortenSyncPath(path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: chrome.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  (Widget, String, String) _remote(
    BuildContext context,
    AppLocalizations l10n,
    BookmarkServerRef server,
    String path,
  ) {
    final config = serverFor?.call(server);
    final configId = server.serverConfigId;
    final identity = server.identity;
    final caption =
        config?.label ??
        (configId == null
            ? null
            : ServerLabelScope.maybeOf(context)?.call(configId)) ??
        (identity == null
            ? null
            : identity.port == 22
            ? '${identity.username}@${identity.host}'
            : '${identity.username}@${identity.host}:${identity.port}') ??
        l10n.syncSheetServerFallback;
    final badge = config == null
        ? ServerBadge.glyph(
            tint: ServerTint.none,
            icon: null,
            size: _iconSize,
            semanticsLabel: caption,
          )
        : ServerBadge(
            tint: ServerTint.of(config),
            mark: config.mark,
            size: _iconSize,
            semanticsLabel: caption,
          );
    return (badge, caption, path);
  }
}

/// The ←/→ pair between the tiles: the lit arrow points from source to
/// destination; both light up for Both Ways (which only the ⋯ menu can
/// select, so a click here never picks it by accident).
class _DirectionToggle extends StatelessWidget {
  const _DirectionToggle({
    required this.direction,
    required this.sourceLabel,
    required this.destinationLabel,
    required this.onPressed,
  });

  final SyncDirection direction;
  final String sourceLabel;
  final String destinationLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final lit = theme.colorScheme.primary;
    final dim = chrome.secondaryText.withValues(alpha: 0.45);
    final leftLit = direction != SyncDirection.leftToRight;
    final rightLit = direction != SyncDirection.rightToLeft;
    final tooltip = direction == SyncDirection.bidirectional
        ? l10n.syncSheetBothWaysTooltip
        : l10n.syncSheetDirectionTooltip(sourceLabel, destinationLabel);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          excludeSemantics: true,
          child: Material(
            color: chrome.capsuleFill,
            shape: const StadiumBorder(),
            child: InkWell(
              key: const ValueKey('sync.sheet.direction'),
              customBorder: const StadiumBorder(),
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_back,
                      key: const ValueKey('sync.sheet.direction.left'),
                      size: 20,
                      color: leftLit ? lit : dim,
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_forward,
                      key: const ValueKey('sync.sheet.direction.right'),
                      size: 20,
                      color: rightLit ? lit : dim,
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

/// "Use the [▾] to determine if a file has changed" — the ARB template
/// carries a {choice} slot so a translation can move the dropdown; the
/// text on either side of the slot renders around it.
class _CompareRow extends StatelessWidget {
  const _CompareRow({required this.comparison, required this.onChanged});

  final ComparisonMode comparison;
  final ValueChanged<ComparisonMode> onChanged;

  /// A placeholder no translation contains — the split point.
  static const String _slot = '\u{FFFC}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final sentence = l10n.syncSheetCompareSentence(_slot);
    final at = sentence.indexOf(_slot);
    final before = at < 0 ? sentence : sentence.substring(0, at).trimRight();
    final after = at < 0
        ? ''
        : sentence.substring(at + _slot.length).trimLeft();
    Widget choice(String label) =>
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) => Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            if (before.isNotEmpty)
              Text(before, style: theme.textTheme.bodyMedium),
            // Natural width on a desktop sheet, never wider than the
            // row: a phone (or a large text scale) ellipsizes the
            // choice instead of overflowing.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: IntrinsicWidth(
                child: DropdownButton<ComparisonMode>(
                  key: const ValueKey('sync.sheet.compare'),
                  value: comparison,
                  isDense: true,
                  isExpanded: true,
                  style: theme.textTheme.bodyMedium,
                  borderRadius: BorderRadius.circular(8),
                  onChanged: (mode) {
                    if (mode != null) onChanged(mode);
                  },
                  items: [
                    DropdownMenuItem(
                      value: ComparisonMode.sizeAndMtime,
                      child: choice(l10n.syncSheetCompareSizeDate),
                    ),
                    DropdownMenuItem(
                      value: ComparisonMode.sizeOnly,
                      child: choice(l10n.syncSheetCompareSize),
                    ),
                    DropdownMenuItem(
                      value: ComparisonMode.contentHash,
                      child: choice(l10n.syncSheetCompareChecksum),
                    ),
                  ],
                ),
              ),
            ),
            if (after.isNotEmpty)
              Text(after, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// A dense checkbox row — the whole label toggles it; [trailing]
/// widgets sit after the label.
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.checkKey,
    required this.label,
    required this.value,
    required this.onChanged,
    this.caption,
    this.trailing = const [],
  });

  final Key checkKey;
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? caption;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final enabled = onChanged != null;
    return Row(
      children: [
        Checkbox(
          key: checkKey,
          value: value,
          visualDensity: VisualDensity.compact,
          onChanged: enabled ? (checked) => onChanged!(checked ?? false) : null,
        ),
        Flexible(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? () => onChanged!(!value) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: enabled ? null : chrome.secondaryText,
                  ),
                ),
                if (caption != null)
                  Text(
                    caption!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: chrome.secondaryText,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (trailing.isNotEmpty) ...[const SizedBox(width: 8), ...trailing],
      ],
    );
  }
}

/// "Here's the plan:" — the clauses as one paragraph; destructive ones
/// red with a warning glyph (color and shape both carry it, D20).
class _PlanParagraph extends StatelessWidget {
  const _PlanParagraph({required this.clauses});

  final List<SyncPolicyClause> clauses;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    final base = theme.textTheme.bodyMedium;
    final spans = <InlineSpan>[];
    for (final clause in clauses) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: ' '));
      if (clause.tone == SyncPolicyTone.destructive) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(
                Icons.warning_amber_rounded,
                key: const ValueKey('sync.sheet.plan.warning'),
                size: 15,
                color: error,
              ),
            ),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: clause.text,
          style: clause.tone == SyncPolicyTone.destructive
              ? TextStyle(color: error, fontWeight: FontWeight.w600)
              : null,
        ),
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      key: const ValueKey('sync.sheet.plan'),
      style: base,
    );
  }
}

/// A long path's tail for the tiles — the last three segments behind an
/// ellipsis (the full path rides the tooltip).
String shortenSyncPath(String path) {
  const keep = 3;
  final separator = path.contains('\\') && !path.contains('/') ? '\\' : '/';
  final segments = path.split(separator).where((s) => s.isNotEmpty).toList();
  if (segments.length <= keep) return path;
  final tail = segments.sublist(segments.length - keep).join(separator);
  return '…$separator$tail';
}
