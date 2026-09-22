import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/quick_open_match.dart';
import '../../services/recent_locations.dart';
import '../../services/registered_command.dart';
import '../../services/shortcut_format.dart';
import '../menus/app_menus.dart';
import '../server_appearance.dart';

/// The `app.quickOpen` command id (02 §8.4, ⇧⌘P / Ctrl+Shift+P).
const kQuickOpenCommandId = 'app.quickOpen';

/// How a palette row accepts (02 §8.4's Enter family): plain Enter runs
/// / opens in place, ⌥⏎/Alt+Enter opens in the other pane, and
/// ⌘⏎/Ctrl+Enter opens in a new tab — the same ⌥ = other-pane,
/// ⌘ = new-tab vocabulary §4's sidebar clicks train. Command rows only
/// ever take [plain].
enum QuickOpenAction { plain, newTab, otherPane }

/// The palette's own registration (D21: the surface is reachable as a
/// command, not a hard-coded chord). ⇧⌘P on macOS, Ctrl+Shift+P
/// elsewhere (02 §8.3). [open] shows the palette — the shell supplies
/// the same invocation it routes menu taps through.
RegisteredCommand buildQuickOpenCommand({required void Function() open}) {
  return RegisteredCommand(
    id: kQuickOpenCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.quickOpenCommandLabel,
    icon: Icons.search,
    activators: (platform) => platform == TargetPlatform.macOS
        ? const [
            SingleActivator(LogicalKeyboardKey.keyP, meta: true, shift: true),
          ]
        : const [
            SingleActivator(
              LogicalKeyboardKey.keyP,
              control: true,
              shift: true,
            ),
          ],
    // 02 §9's File menu: between the tab block (New/Reopen/Close at
    // 10–30) and the file verbs (60+).
    menuPlacement: const CommandMenuPlacement(menu: AppMenuId.file, order: 40),
    run: (_) async => open(),
  );
}

/// One flattened, already-filtered row the palette renders. The list
/// carries its section headers as rows too so keyboard highlight and
/// scroll share one index space — headers are never highlightable.
sealed class _Row {}

final class _SectionRow extends _Row {
  _SectionRow(this.title);
  final String title;
}

final class _CommandRow extends _Row {
  _CommandRow(this.command);
  final RegisteredCommand command;
}

final class _FavoriteRow extends _Row {
  _FavoriteRow(this.bookmark);
  final Bookmark bookmark;
}

final class _RecentRow extends _Row {
  _RecentRow(this.location);
  final RecentLocation location;
}

/// Opens the Quick Open palette (02 §8.4): the centered, keyboard-first
/// surface over the live command registry, the favorites list, and the
/// recent-locations list. Command accept routes through [onCommand]
/// (the shell's `_runCommand`, so enablement and the one-shot session
/// rule stay the caller's); favorite and recent accepts carry the
/// Enter-family action back to the shell's pane-resolution rules.
Future<void> showQuickOpenPalette(
  BuildContext context, {
  required List<RegisteredCommand> commands,
  required List<Bookmark> favorites,
  required List<RecentLocation> recents,

  /// Resolves a remote recent to its live bookmark (by serverId); a
  /// null answer plus a null stored snapshot disables the row.
  required Bookmark? Function(RecentLocation recent) resolveRecentBookmark,
  required void Function(RegisteredCommand command) onCommand,
  required void Function(Bookmark bookmark, QuickOpenAction action) onFavorite,
  required void Function(RecentLocation recent, QuickOpenAction action)
  onRecent,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _QuickOpenPalette(
      commands: commands,
      favorites: favorites,
      recents: recents,
      resolveRecentBookmark: resolveRecentBookmark,
      onCommand: onCommand,
      onFavorite: onFavorite,
      onRecent: onRecent,
    ),
  );
}

class _QuickOpenPalette extends StatefulWidget {
  const _QuickOpenPalette({
    required this.commands,
    required this.favorites,
    required this.recents,
    required this.resolveRecentBookmark,
    required this.onCommand,
    required this.onFavorite,
    required this.onRecent,
  });

  final List<RegisteredCommand> commands;
  final List<Bookmark> favorites;
  final List<RecentLocation> recents;
  final Bookmark? Function(RecentLocation recent) resolveRecentBookmark;
  final void Function(RegisteredCommand command) onCommand;
  final void Function(Bookmark bookmark, QuickOpenAction action) onFavorite;
  final void Function(RecentLocation recent, QuickOpenAction action) onRecent;

  @override
  State<_QuickOpenPalette> createState() => _QuickOpenPaletteState();
}

class _QuickOpenPaletteState extends State<_QuickOpenPalette> {
  final _queryController = TextEditingController();
  final _fieldFocus = FocusNode();
  final _listController = ScrollController();

  /// The flat render list (headers included) and the highlight index
  /// into it. Rebuilt per keystroke — enablement re-reads each build,
  /// so a state change between keystrokes still answers live.
  List<_Row> _rows = const [];
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    // No _rebuild() here: it resolves AppLocalizations.of, which cannot
    // run before initState completes. build() computes the rows on
    // every pass — cheap (the lists are small) and always live.
    _fieldFocus.requestFocus();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _fieldFocus.dispose();
    _listController.dispose();
    super.dispose();
  }

  /// The query the current row list answers; a changed query resets the
  /// highlight to the first row, while a same-query rebuild (enablement
  /// flip, highlight move) keeps the user's place.
  String _lastQuery = '';

  void _rebuild() {
    final l10n = AppLocalizations.of(context);
    final query = _queryController.text.trim();
    final queryChanged = query != _lastQuery;
    _lastQuery = query;
    // Command rows match on label AND menu path ("Go ▸ Go to Folder…");
    // favorites on label, host, and path; recents on path and host
    // (02 §8.4's match-fields rule per section).
    final commands = quickOpenFilter(
      query,
      widget.commands,
      (command) => '${command.label(l10n)} ${_menuPath(command, l10n) ?? ''}',
    );
    // §8.4 ranks enabled commands first; disabled rows stay listed,
    // greyed, their reason line explaining why.
    final rankedCommands = [
      ...commands.where((command) => command.enabled()),
      ...commands.where((command) => !command.enabled()),
    ];
    final favorites = quickOpenFilter(
      query,
      widget.favorites,
      (bookmark) => '${bookmark.label} ${_favoriteMatchText(bookmark)}',
    );
    final recents = quickOpenFilter(
      query,
      widget.recents,
      (recent) =>
          '${recent.path} ${recent.remoteBookmark?.server?.identity?.host ?? ''}',
    );
    _rows = [
      if (rankedCommands.isNotEmpty) ...[
        _SectionRow(l10n.quickOpenSectionCommands),
        for (final command in rankedCommands) _CommandRow(command),
      ],
      if (favorites.isNotEmpty) ...[
        _SectionRow(l10n.quickOpenSectionFavorites),
        for (final bookmark in favorites) _FavoriteRow(bookmark),
      ],
      if (recents.isNotEmpty) ...[
        _SectionRow(l10n.quickOpenSectionRecents),
        for (final recent in recents) _RecentRow(recent),
      ],
    ];
    _rowKeys.clear();
    if (queryChanged ||
        _highlight >= _rows.length ||
        (_rows.isNotEmpty && _rows[_highlight] is _SectionRow)) {
      _highlight = _nextSelectable(-1) ?? 0;
    }
  }

  /// The next highlightable row index after [from] (headers skip),
  /// forward or backward by [direction].
  int? _nextSelectable(int from, [int direction = 1]) {
    var i = from + direction;
    while (i >= 0 && i < _rows.length) {
      if (_rows[i] is! _SectionRow) return i;
      i += direction;
    }
    return null;
  }

  void _moveHighlight(int direction) {
    final next = _nextSelectable(_highlight, direction);
    if (next == null) return;
    setState(() => _highlight = next);
    // Keep the highlighted row inside the viewport.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowContext = _rowKeys[_highlight]?.currentContext;
      if (rowContext != null) {
        Scrollable.ensureVisible(
          rowContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 80),
        );
      }
    });
  }

  final _rowKeys = <int, GlobalKey>{};

  bool _rowEnabled(_Row row) => switch (row) {
    _CommandRow(:final command) => command.enabled(),
    _RecentRow(:final location) =>
      !location.isRemote ||
          _resolveRecent(location) != null ||
          location.remoteBookmark != null,
    _ => true,
  };

  String? _rowReason(_Row row, AppLocalizations l10n) => switch (row) {
    _CommandRow(:final command) when !command.enabled() =>
      command.disabledReason?.call(l10n),
    _RecentRow(:final location)
        when location.isRemote &&
            _resolveRecent(location) == null &&
            location.remoteBookmark == null =>
      l10n.quickOpenRecentUnavailable,
    _ => null,
  };

  Bookmark? _resolveRecent(RecentLocation recent) =>
      widget.resolveRecentBookmark(recent);

  void _accept(QuickOpenAction action) {
    if (_highlight < 0 || _highlight >= _rows.length) return;
    final row = _rows[_highlight];
    if (!_rowEnabled(row)) return;
    switch (row) {
      case _SectionRow():
        return;
      case _CommandRow(:final command):
        Navigator.of(context).pop();
        widget.onCommand(command);
      case _FavoriteRow(:final bookmark):
        Navigator.of(context).pop();
        widget.onFavorite(bookmark, action);
      case _RecentRow(:final location):
        Navigator.of(context).pop();
        widget.onRecent(location, action);
    }
  }

  /// §8.4's in-palette chord rule, mechanically checkable against §8.3:
  /// the dialog route sits above the shell's chord scope, so the
  /// palette dispatches activators itself — but ONLY app-scoped
  /// commands. Every pane/selection chord is suspended while the field
  /// holds focus: no keystroke here may run a file verb over the
  /// background pane (the rule replaces round-7's fired-over-the-pane
  /// framing). Unmodified activators (Space, Enter, F2…) belong to the
  /// field/list, never dispatched — the same split §8.2 draws.
  /// Carve-out: the platform text-editing chords keep their field
  /// meaning, so pasting a path into Quick Open never executes a verb.
  bool _dispatchChord(KeyEvent event) {
    final platform = Theme.of(context).platform;
    for (final command in widget.commands) {
      if (command.scope != CommandScope.app) continue;
      for (final activator
          in command.activators?.call(platform) ??
              const <ShortcutActivator>[]) {
        if (activator is! SingleActivator ||
            (!activator.control && !activator.meta && !activator.alt) ||
            _isEditingChord(activator, platform)) {
          continue;
        }
        if (!activator.accepts(event, HardwareKeyboard.instance)) {
          continue;
        }
        // The palette's own toggle chord: ⇧⌘P pressed inside closes —
        // the same gesture that opened it.
        if (command.id == kQuickOpenCommandId) {
          Navigator.of(context).pop();
          return true;
        }
        if (!command.enabled()) {
          // A chord bound to a DISABLED app command no-ops: the palette
          // stays open and highlights that row so its reason line
          // surfaces instead of silently swallowing the key.
          final index = _rows.indexWhere(
            (row) => row is _CommandRow && identical(row.command, command),
          );
          if (index >= 0) setState(() => _highlight = index);
          return true;
        }
        // Close-first: no app command ever runs beneath the overlay.
        Navigator.of(context).pop();
        widget.onCommand(command);
        return true;
      }
    }
    return false;
  }

  /// §8.4's carve-out: chords the text field must keep even when a
  /// command binds them — ⌘X/⌘C/⌘V/⌘Z/⌘A and ⌘⌫ (Ctrl-equivalents on
  /// Windows/Linux), plus macOS's ⌘↑/⌘↓ caret chords.
  bool _isEditingChord(SingleActivator activator, TargetPlatform platform) {
    final primaryOnly = platform == TargetPlatform.macOS
        ? activator.meta && !activator.control && !activator.alt
        : activator.control && !activator.meta && !activator.alt;
    if (!primaryOnly) return false;
    final editingKeys = {
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.backspace,
    };
    // ⌘⇧Z (redo) is an editing chord too — keyZ is carved out with or
    // without Shift.
    if (editingKeys.contains(activator.trigger) &&
        (!activator.shift || activator.trigger == LogicalKeyboardKey.keyZ)) {
      return true;
    }
    return platform == TargetPlatform.macOS &&
        !activator.shift &&
        (activator.trigger == LogicalKeyboardKey.arrowUp ||
            activator.trigger == LogicalKeyboardKey.arrowDown);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent && _dispatchChord(event)) {
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      // Handled here rather than delegated to the route's own dismiss:
      // the field's IME composition (if any) gets Escape only after
      // the palette itself decides there is nothing left to consume.
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _pageHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _pageHighlight(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // The palette-local Enter family (02 §8.4): ⌥⏎/Alt = other pane,
      // ⌘⏎/Ctrl = new tab — the sidebar's modifier vocabulary.
      final keyboard = HardwareKeyboard.instance;
      final action = keyboard.isAltPressed
          ? QuickOpenAction.otherPane
          : (keyboard.isControlPressed || keyboard.isMetaPressed)
          ? QuickOpenAction.newTab
          : QuickOpenAction.plain;
      _accept(action);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Page steps hop roughly one viewport of rows (~8).
  void _pageHighlight(int direction) {
    var target = _highlight;
    for (var i = 0; i < 8; i++) {
      final next = _nextSelectable(target, direction);
      if (next == null) break;
      target = next;
    }
    if (target == _highlight) return;
    setState(() => _highlight = target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rowContext = _rowKeys[_highlight]?.currentContext;
      if (rowContext != null) {
        Scrollable.ensureVisible(rowContext, alignment: 0.5);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final platform = theme.platform;
    final colors = theme.colorScheme;
    _rebuild();

    return Dialog(
      alignment: const Alignment(0, -0.55),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
        child: Semantics(
          label: l10n.quickOpenTitle,
          child: Focus(
            onKeyEvent: _onKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    key: const ValueKey('quickOpen.field'),
                    controller: _queryController,
                    focusNode: _fieldFocus,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: l10n.quickOpenFieldHint,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                    // EditableText consumes a bare Enter before the
                    // ancestor Focus sees it; onSubmitted is the plain-
                    // Enter fallback. Modifier variants never produce
                    // text, so they reach _onKey's Enter branch.
                    onSubmitted: (_) => _accept(QuickOpenAction.plain),
                  ),
                ),
                Flexible(
                  child: _rows.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _queryController.text.trim().isEmpty
                                ? l10n.quickOpenFieldHint
                                : l10n.quickOpenNoMatches(
                                    _queryController.text.trim(),
                                  ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _listController,
                          shrinkWrap: true,
                          itemCount: _rows.length,
                          itemBuilder: (context, index) {
                            final key = _rowKeys.putIfAbsent(
                              index,
                              GlobalKey.new,
                            );
                            return _buildRow(
                              context,
                              key: key,
                              row: _rows[index],
                              highlighted: index == _highlight,
                              l10n: l10n,
                              platform: platform,
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      platform == TargetPlatform.macOS
                          ? l10n.quickOpenHintMacos
                          : l10n.quickOpenHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required Key key,
    required _Row row,
    required bool highlighted,
    required AppLocalizations l10n,
    required TargetPlatform platform,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (row is _SectionRow) {
      return Padding(
        key: key,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(
          row.title,
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final enabled = _rowEnabled(row);
    final reason = _rowReason(row, l10n);
    final (title, subtitle, leading, shortcut) = switch (row) {
      _CommandRow(:final command) => (
        command.label(l10n),
        _menuPath(command, l10n),
        Icon(
          command.icon ?? Icons.bolt_outlined,
          size: 18,
          color: enabled ? colors.onSurfaceVariant : theme.disabledColor,
        ),
        command.activators
            ?.call(platform)
            .map((a) => formatShortcutActivator(a, platform))
            .whereType<String>()
            .join('  '),
      ),
      // Favorites carry their icon+color badge (02 §8.4) — the same
      // accent the sidebar paints, so the two surfaces read alike.
      _FavoriteRow(:final bookmark) => (
        bookmark.label,
        _favoriteSubtitle(bookmark, l10n),
        _favoriteBadge(bookmark, enabled, theme),
        null,
      ),
      _RecentRow(:final location) => (
        location.label,
        location.path,
        Icon(
          location.isRemote ? Icons.cloud_outlined : Icons.folder_outlined,
          size: 18,
          color: enabled ? colors.onSurfaceVariant : theme.disabledColor,
        ),
        null,
      ),
      _ => (null, null, const SizedBox.shrink(), null),
    };

    return Semantics(
      key: key,
      label: title,
      hint: reason,
      button: true,
      enabled: enabled,
      selected: highlighted,
      child: InkWell(
        onTap: enabled ? () => _acceptRow(row) : null,
        child: Container(
          color: highlighted ? colors.surfaceContainerHighest : null,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title!,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: enabled ? colors.onSurface : theme.disabledColor,
                      ),
                    ),
                    if (reason != null || subtitle != null)
                      Text(
                        reason ?? subtitle!,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: reason != null
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (shortcut != null && shortcut.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    shortcut,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: enabled
                          ? colors.onSurfaceVariant
                          : theme.disabledColor,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _acceptRow(_Row row) {
    final index = _rows.indexOf(row);
    if (index >= 0) {
      _highlight = index;
      _accept(QuickOpenAction.plain);
    }
  }

  /// "File ▸ Open" — the command row's subtitle names where the command
  /// lives in the menus (02 §8.4); submenu placements read
  /// "Commands ▸ Workspaces ▸ name".
  String? _menuPath(RegisteredCommand command, AppLocalizations l10n) {
    final placement = command.menuPlacement;
    if (placement == null) return null;
    final menu = appMenuTitle(placement.menu, l10n);
    final submenu = placement.submenu?.call(l10n);
    final label = command.label(l10n);
    return submenu == null
        ? l10n.quickOpenMenuPath(menu, label)
        : l10n.quickOpenMenuPath('$menu ▸ $submenu', label);
  }

  /// The favorite match corpus (02 §8.4): label, host, and path — the
  /// label is applied by the caller; this adds the two hidden fields.
  String _favoriteMatchText(Bookmark bookmark) {
    final identity = bookmark.server?.identity;
    return [
      ?identity?.host,
      ?bookmark.localPath,
      ?bookmark.remotePath,
    ].join(' ');
  }

  /// The favorite row's leading badge: the server accent + icon, kept
  /// small beside the sidebar's 26px badge — a disabled row dims both.
  Widget _favoriteBadge(Bookmark bookmark, bool enabled, ThemeData theme) {
    final accent = serverAccent(context, bookmark.color);
    final scheme = theme.colorScheme;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: enabled
            ? (accent?.container ?? scheme.surfaceContainerHighest)
            : theme.disabledColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        _favoriteIcon(bookmark),
        size: 14,
        color: enabled
            ? (accent?.onContainer ?? scheme.onSurfaceVariant)
            : theme.disabledColor,
      ),
    );
  }

  String? _favoriteSubtitle(Bookmark bookmark, AppLocalizations l10n) {
    switch (bookmark.kind) {
      case BookmarkKind.localFolder:
        return bookmark.localPath;
      case BookmarkKind.remotePath:
        final identity = bookmark.server?.identity;
        final endpoint = identity == null
            ? null
            : '${identity.username}@${identity.host}';
        final parts = [?endpoint, ?bookmark.remotePath].join(' · ');
        return parts.isEmpty ? null : parts;
      case BookmarkKind.workspace:
        return l10n.sidebarKindWorkspace;
      case BookmarkKind.savedSync:
        return l10n.sidebarKindSavedSync;
    }
  }

  IconData _favoriteIcon(Bookmark bookmark) => switch (bookmark.kind) {
    BookmarkKind.localFolder =>
      bookmark.icon != null
          ? serverIconData(bookmark.icon)
          : Icons.folder_outlined,
    BookmarkKind.remotePath => serverIconData(bookmark.icon),
    BookmarkKind.workspace => Icons.space_dashboard_outlined,
    BookmarkKind.savedSync => Icons.sync_alt,
  };
}
