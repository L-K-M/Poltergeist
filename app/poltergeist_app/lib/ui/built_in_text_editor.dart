// Ported from Séance
// app/seance_app/lib/ui/built_in_text_editor.dart @ 2e6d1f1; see
// docs/PORTS.md. Divergences per 06 §2.3/§2.5: the document I/O lives in
// poltergeist_core (BuiltInTextDocument with LF/no-BOM in-memory
// invariants, LineEnding enum, typed BuiltInEditorException), temp
// suffixes are `.poltergeist-*`, and toast/mono-font/basename are
// injected seams instead of SeanceTheme/remoteBasename hardcodes. All
// user-visible copy resolves through AppLocalizations (D20).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/registered_command.dart';
import 'menus/app_menu_host.dart';
import 'menus/app_menu_commands.dart';
import 'editor_syntax.dart';

/// The built-in text editor (06 §2): one document per desktop window, or
/// a full-window route on phones and tablets. No session/SFTP coupling inside
/// the widget: the
/// caller wires [onSaved] (the per-copy reconcile) and [onUpload] (the
/// conflict-aware save-and-upload) for a managed checkout, or leaves
/// [onUpload] null for a plain local file (the upload UI then vanishes).
class BuiltInTextEditorScreen extends StatefulWidget {
  const BuiltInTextEditorScreen({
    super.key,
    required this.file,
    this.remotePath,
    this.initialText,
    this.saveDocument,
    this.onSaved,
    this.onUpload,
    this.onCloseRequested,
    this.onQuitRequested,
    this.onNewWindowRequested,
    this.quitPending = false,
    this.onCloseGuardChanged,
    required this.showToast,
    required this.monoFontFallback,
    required this.basenameOf,
  });

  /// The local file or managed checkout being edited.
  final File file;

  /// The remote path — display title and language detection only. Null
  /// for a plain local file, where [file]'s path stands in for display.
  final String? remotePath;

  /// Test seam: preloaded text that skips the disk load entirely.
  final String? initialText;

  /// TEST-ONLY seam (06 §2.3): overrides the atomic saver wholesale,
  /// bypassing BOM/CRLF reconstruction and the expectedSha256 conflict
  /// check. Production code never passes it — the screen always saves
  /// through `saveBuiltInTextDocument` so the conflict check stays live.
  /// Returns the new baseline digest for the next save's expected value.
  final Future<String> Function(File file, String text)? saveDocument;

  /// The post-save reconcile hook (06 §2.4): fires after every save that
  /// did not upload — a local-only save, a false/throwing upload alike —
  /// never after a completed upload (that reconciles itself). Must not
  /// throw: inside the upload's `finally` an exception would replace the
  /// original upload error.
  final Future<void> Function()? onSaved;

  /// Save-and-upload for a managed checkout (06 §3.4); null = local-only.
  /// Returns false when the upload was declined (a cancelled conflict
  /// escalation), true on success; throws on failure.
  final Future<bool> Function()? onUpload;

  /// Native document windows use the same discard guard as route pops.
  /// Null retains the phone/tablet route and its normal back button.
  final Future<void> Function()? onCloseRequested;
  final Future<void> Function()? onQuitRequested;
  final Future<void> Function()? onNewWindowRequested;
  final bool quitPending;
  final void Function(Future<bool> Function()? guard)? onCloseGuardChanged;

  /// The top-toast presenter (02 §10) — Séance's `showTopToastIn` hardcode
  /// as an injected seam (06 §2.3).
  final void Function(BuildContext context, String message) showToast;

  /// The monospace family stack — Séance's `SeanceTheme.monoFallback`
  /// hardcode as an injected seam (06 §2.3).
  final List<String> monoFontFallback;

  /// The basename renderer for the two-line title (06 §2.3):
  /// `remoteBasename` for remote paths; a platform-aware basename for
  /// local callers (on Windows it must split `\` too; on POSIX `\` is a
  /// legal filename byte and is never split).
  final String Function(String path) basenameOf;

  @override
  State<BuiltInTextEditorScreen> createState() =>
      _BuiltInTextEditorScreenState();
}

class _BuiltInTextEditorScreenState extends State<BuiltInTextEditorScreen> {
  late final CodeEditingController _text = CodeEditingController(
    language: syntaxLanguageFor(_displayPath),
  );
  final ScrollController _scroll = ScrollController();
  final FocusNode _editorFocus = FocusNode();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _savedText = '';
  String? _error;
  String? _baselineSha256;
  bool _hasUtf8Bom = false;
  LineEnding _lineEnding = LineEnding.lf;
  bool _loading = true;
  bool _saving = false;
  bool _searchOpen = false;
  Future<bool>? _discardDecision;
  bool _searchCaseSensitive = false;
  List<TextRange> _matches = const [];
  int _activeMatch = -1;
  String _lastSearchedText = '';
  String? _lastQuery;
  double? _editorWidth;

  // Status-bar counters, cached: _changed fires on every controller
  // notification — caret moves included — so build must not re-split and
  // re-encode the whole document per frame on megabyte files.
  String _lastStatusText = '';
  int _statusLines = 1;
  int _statusBytes = 0;

  /// Inset around the document text; also part of the scroll-to-match math.
  static const double _editorPadding = 14;

  /// The path the title and language detection render: the remote path
  /// for a managed checkout, the local file's own path otherwise.
  String get _displayPath => widget.remotePath ?? widget.file.path;

  bool get _dirty => !_loading && _text.text != _savedText;

  TextStyle get _editorTextStyle => TextStyle(
    fontFamily: widget.monoFontFallback.first,
    fontFamilyFallback: widget.monoFontFallback,
    fontSize: 14,
    height: 1.35,
  );

  @override
  void initState() {
    super.initState();
    widget.onCloseGuardChanged?.call(_confirmClose);
    _text.addListener(_changed);
    _search.addListener(_searchChanged);
    final initialText = widget.initialText;
    if (initialText == null) {
      _load();
    } else {
      _applyLoadedText(initialText);
      _loading = false;
    }
  }

  Future<void> _load() async {
    try {
      final document = await loadBuiltInTextDocumentDetails(widget.file);
      if (!mounted) return;
      _applyLoadedText(document.text);
      _baselineSha256 = document.sha256;
      _hasUtf8Bom = document.hasUtf8Bom;
      _lineEnding = document.lineEnding;
    } catch (error) {
      if (mounted) _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Install the document with the caret and viewport at the very top, and
  /// re-detect the language now that a `#!` line is available.
  void _applyLoadedText(String text) {
    _savedText = text;
    _statusBytes = utf8.encode(text).length;
    var lines = 1;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0a) lines++;
    }
    _statusLines = lines;
    _lastStatusText = text;
    final newline = text.indexOf('\n');
    _text.language = syntaxLanguageFor(
      _displayPath,
      firstLine: newline < 0 ? text : text.substring(0, newline),
    );
    _text.value = TextEditingValue(
      text: text,
      selection: const TextSelection.collapsed(offset: 0),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _changed() {
    if (!mounted || _loading) return;
    final text = _text.text;
    if (!identical(text, _lastStatusText)) {
      _lastStatusText = text;
      _statusBytes = utf8.encode(text).length;
      var lines = 1;
      for (var i = 0; i < text.length; i++) {
        if (text.codeUnitAt(i) == 0x0a) lines++;
      }
      _statusLines = lines;
    }
    if (_searchOpen &&
        !identical(_text.text, _lastSearchedText) &&
        _text.text != _lastSearchedText) {
      _updateSearchMatches(resetActive: false);
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.onCloseGuardChanged?.call(null);
    _search.removeListener(_searchChanged);
    _text.removeListener(_changed);
    _text.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _editorFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- Search -------------------------------------------------------------

  void _openSearch() {
    if (_loading || _error != null) return;
    final selection = _text.selection;
    String? prefill;
    if (selection.isValid && !selection.isCollapsed) {
      final selected = selection.textInside(_text.text);
      if (selected.isNotEmpty &&
          !selected.contains('\n') &&
          selected.length <= 200) {
        prefill = selected;
      }
    }
    _searchOpen = true;
    if (prefill != null) {
      _search.text = prefill; // Listener recomputes the matches.
    } else {
      _updateSearchMatches(resetActive: true);
    }
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    _searchFocus.requestFocus();
    setState(() {});
    _revealActiveMatch();
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    _searchOpen = false;
    _matches = const [];
    _activeMatch = -1;
    _lastQuery = null;
    _text.setSearchMatches(const [], -1);
    setState(() {});
    _editorFocus.requestFocus();
  }

  void _searchChanged() {
    if (!mounted || !_searchOpen) return;
    // The controller also notifies on selection changes inside the query
    // field; only an actual query edit warrants re-searching the document.
    if (_search.text == _lastQuery) return;
    _updateSearchMatches(resetActive: true);
    setState(() {});
    _revealActiveMatch();
  }

  void _updateSearchMatches({required bool resetActive}) {
    _lastSearchedText = _text.text;
    _lastQuery = _search.text;
    _matches = _searchOpen
        ? findSearchMatches(
            _text.text,
            _search.text,
            caseSensitive: _searchCaseSensitive,
          )
        : const [];
    if (_matches.isEmpty) {
      _activeMatch = -1;
    } else if (resetActive ||
        _activeMatch < 0 ||
        _activeMatch >= _matches.length) {
      // Start from the first match at or after the caret.
      final caret = _text.selection.isValid ? _text.selection.start : 0;
      final index = _matches.indexWhere((match) => match.start >= caret);
      _activeMatch = index < 0 ? 0 : index;
    }
    _text.setSearchMatches(_matches, _activeMatch);
  }

  void _nextMatch() => _stepMatch(1);

  void _previousMatch() => _stepMatch(-1);

  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    _activeMatch = _activeMatch < 0
        ? (delta > 0 ? 0 : _matches.length - 1)
        : (_activeMatch + delta + _matches.length) % _matches.length;
    _text.setSearchMatches(_matches, _activeMatch);
    // Park the caret on the match so editing or Escape resumes there. Both
    // controller mutations notify, and _changed rebuilds — no setState here.
    final match = _matches[_activeMatch];
    _text.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    _revealActiveMatch();
  }

  void _toggleCaseSensitive() {
    _searchCaseSensitive = !_searchCaseSensitive;
    _updateSearchMatches(resetActive: true);
    setState(() {});
    _revealActiveMatch();
  }

  /// Scroll the viewport so the active match is about a third from the top.
  /// Small files get a precise text layout; very large ones fall back to a
  /// line-count estimate rather than laying out megabytes of text.
  void _revealActiveMatch() {
    if (_activeMatch < 0 || _activeMatch >= _matches.length) return;
    if (!_scroll.hasClients) return;
    final match = _matches[_activeMatch];
    final text = _text.text;
    final width = _editorWidth;
    double dy;
    if (text.length <= syntaxHighlightingMaxChars && width != null) {
      final textWidth = width - 2 * _editorPadding;
      // Only the text before the match determines its vertical position, so
      // lay out just that prefix: a full-document layout on every search
      // keystroke would jank on files approaching the highlighting cap. (A
      // soft wrap mid-word at the boundary can be off by one line — fine
      // for positioning the viewport.)
      final prefix = text.substring(0, match.start);
      final painter = TextPainter(
        text: TextSpan(text: prefix, style: _editorTextStyle),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: textWidth > 1 ? textWidth : 1);
      dy = painter
          .getOffsetForCaret(TextPosition(offset: prefix.length), Rect.zero)
          .dy;
      painter.dispose();
    } else {
      var line = 0;
      for (var i = 0; i < match.start; i++) {
        if (text.codeUnitAt(i) == 0x0a) line++;
      }
      final fontSize = MediaQuery.textScalerOf(
        context,
      ).scale(_editorTextStyle.fontSize!);
      dy = line * fontSize * _editorTextStyle.height!;
    }
    dy += _editorPadding; // The text sits below the field's top content inset.
    final position = _scroll.position;
    final target = (dy - position.viewportDimension / 3).clamp(
      0.0,
      position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
    );
  }

  Future<bool> _confirmClose() {
    // A pending write/upload owns the document until its bookkeeping has
    // settled; closing now could hide a failure or its conflict dialog.
    if (_saving && widget.onCloseRequested != null) return Future.value(false);
    return _discardDecision ??= _confirmDiscard().whenComplete(
      () => _discardDecision = null,
    );
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final l10n = AppLocalizations.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.editorDiscardTitle),
            content: Text(l10n.editorDiscardBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.editorDiscardKeep),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.editorDiscardConfirm),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save({bool upload = false}) async {
    if (_saving || _loading || _error != null || widget.quitPending) return;
    final uploadAfterSave = upload && widget.onUpload != null;
    setState(() => _saving = true);
    final value = _text.text;
    try {
      final customSave = widget.saveDocument;
      if (customSave == null) {
        _baselineSha256 = await saveBuiltInTextDocument(
          widget.file,
          value,
          hasUtf8Bom: _hasUtf8Bom,
          lineEnding: _lineEnding,
          expectedSha256: _baselineSha256,
        );
      } else {
        _baselineSha256 = await customSave(widget.file, value);
      }
      // The disk write already committed, so the caller's reconcile
      // hooks must run even when the screen was popped mid-save —
      // skipping them would diverge a managed checkout's bookkeeping
      // from disk with nothing surfaced.
      if (mounted) setState(() => _savedText = value);
      var uploaded = false;
      if (uploadAfterSave) {
        // Upload immediately, no confirmation. The upload reconciles this
        // copy itself; onSaved only needs to run when the upload didn't —
        // including when it throws, hence the finally.
        try {
          uploaded = await widget.onUpload!();
        } finally {
          if (!uploaded) await widget.onSaved?.call();
        }
      } else {
        await widget.onSaved?.call();
      }
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        widget.showToast(
          context,
          uploadAfterSave
              ? uploaded
                    ? _dirty
                          ? l10n.editorSavedUploadedDirty
                          : l10n.editorSavedUploaded
                    : l10n.editorSavedLocallyNotUploaded
              : l10n.editorSavedLocally,
        );
      }
    } catch (error) {
      if (mounted) widget.showToast(context, error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme.of registers the dependency, so brightness flips land here.
    _text.theme = EditorSyntaxTheme.of(Theme.of(context).brightness);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = widget.basenameOf(_displayPath);
    final uploadOnSave = widget.onUpload != null;
    final editor = PopScope(
      canPop: !_dirty && (!_saving || widget.onCloseRequested == null),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _confirmClose() || !context.mounted) return;
        Navigator.of(context).pop();
      },
      child: CallbackShortcuts(
        bindings: {
          if (widget.onNewWindowRequested != null) ...{
            const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
                widget.onNewWindowRequested!,
            const SingleActivator(LogicalKeyboardKey.keyN, control: true):
                widget.onNewWindowRequested!,
          },
          if (widget.onCloseRequested != null) ...{
            const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
                widget.onCloseRequested!,
            const SingleActivator(LogicalKeyboardKey.keyW, control: true):
                widget.onCloseRequested!,
          },
          // ⌘S/Ctrl+S is "save and upload" for a server file; hold Shift to
          // deliberately keep a save local-only.
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
              _save(upload: uploadOnSave),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
              _save(upload: uploadOnSave),
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            meta: true,
            shift: true,
          ): _save,
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            control: true,
            shift: true,
          ): _save,
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
              _nextMatch,
          const SingleActivator(LogicalKeyboardKey.keyG, control: true):
              _nextMatch,
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            meta: true,
            shift: true,
          ): _previousMatch,
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            control: true,
            shift: true,
          ): _previousMatch,
          const SingleActivator(LogicalKeyboardKey.f3): _nextMatch,
          const SingleActivator(LogicalKeyboardKey.f3, shift: true):
              _previousMatch,
          if (_searchOpen)
            const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
        },
        child: Scaffold(
          appBar: AppBar(
            leading: widget.onCloseRequested == null
                ? null
                : IconButton(
                    tooltip: l10n.windowCloseLabel,
                    onPressed: widget.onCloseRequested,
                    icon: const Icon(Icons.close),
                  ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  _displayPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: l10n.editorFindTooltip,
                onPressed: _loading || _error != null ? null : _openSearch,
                icon: const Icon(Icons.search),
              ),
              IconButton(
                tooltip: l10n.editorSaveLocallyTooltip,
                onPressed: _dirty && !_saving ? _save : null,
                icon: const Icon(Icons.save_outlined),
              ),
              if (uploadOnSave)
                IconButton(
                  tooltip: l10n.editorSaveAndUploadTooltip,
                  onPressed: !_saving ? () => _save(upload: true) : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                ),
            ],
            bottom: _searchOpen
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(52),
                    child: _searchBar(context),
                  )
                : null,
          ),
          body: _body(),
          bottomNavigationBar: _loading || _error != null
              ? null
              : SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      _dirty
                          ? l10n.editorStatusDirty(_statusLines, _statusBytes)
                          : l10n.editorStatusClean(_statusLines, _statusBytes),
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
        ),
      ),
    );
    if (widget.onCloseRequested == null) return editor;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: AppMenuHost(
        commands: [
          if (widget.onNewWindowRequested != null)
            RegisteredCommand(
              id: 'window.new',
              scope: CommandScope.app,
              label: (l10n) => l10n.windowNewLabel,
              enabled: () => !widget.quitPending,
              run: (_) => widget.onNewWindowRequested!(),
              activators: (platform) => [
                _editorShortcut(platform, LogicalKeyboardKey.keyN),
              ],
              menuPlacement: const CommandMenuPlacement(
                menu: AppMenuId.file,
                order: 0,
              ),
            ),
          RegisteredCommand(
            id: 'editor.save',
            activators: (platform) => [
              _editorShortcut(platform, LogicalKeyboardKey.keyS),
            ],
            scope: CommandScope.editor,
            label: (l10n) => uploadOnSave
                ? l10n.editorSaveAndUploadTooltip
                : l10n.editorSaveLocallyTooltip,
            enabled: () =>
                !_loading && !_saving && _error == null && !widget.quitPending,
            run: (_) => _save(upload: uploadOnSave),
            menuPlacement: const CommandMenuPlacement(
              menu: AppMenuId.file,
              order: 10,
            ),
          ),
          RegisteredCommand(
            id: 'editor.close',
            activators: (platform) => [
              _editorShortcut(platform, LogicalKeyboardKey.keyW),
            ],
            scope: CommandScope.editor,
            label: (l10n) => l10n.windowCloseLabel,
            run: (_) => widget.onCloseRequested!(),
            menuPlacement: const CommandMenuPlacement(
              menu: AppMenuId.file,
              order: 20,
            ),
          ),
          RegisteredCommand(
            id: 'editor.find',
            activators: (platform) => [
              _editorShortcut(platform, LogicalKeyboardKey.keyF),
            ],
            scope: CommandScope.editor,
            label: (l10n) => l10n.editorFindTooltip,
            enabled: () => !_loading && _error == null,
            run: (_) async => _openSearch(),
            menuPlacement: const CommandMenuPlacement(
              menu: AppMenuId.edit,
              order: 10,
            ),
          ),
          ..._textCommands(context),
          if (Theme.of(context).platform != TargetPlatform.macOS)
            buildQuitCommand(requestClose: widget.onQuitRequested),
        ],
        onRun: (command) async {
          if (command.enabled()) await command.run(context);
        },
        child: editor,
      ),
    );
  }

  Iterable<RegisteredCommand> _textCommands(BuildContext context) {
    final material = MaterialLocalizations.of(context);
    final l10n = AppLocalizations.of(context);
    final actions = <(String, String, LogicalKeyboardKey, Intent)>[
      (
        'editor.undo',
        l10n.editorUndoLabel,
        LogicalKeyboardKey.keyZ,
        const UndoTextIntent(SelectionChangedCause.keyboard),
      ),
      (
        'editor.redo',
        l10n.editorRedoLabel,
        LogicalKeyboardKey.keyZ,
        const RedoTextIntent(SelectionChangedCause.keyboard),
      ),
      (
        'editor.cut',
        material.cutButtonLabel,
        LogicalKeyboardKey.keyX,
        const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      ),
      (
        'editor.copy',
        material.copyButtonLabel,
        LogicalKeyboardKey.keyC,
        CopySelectionTextIntent.copy,
      ),
      (
        'editor.paste',
        material.pasteButtonLabel,
        LogicalKeyboardKey.keyV,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      ),
      (
        'editor.selectAll',
        material.selectAllButtonLabel,
        LogicalKeyboardKey.keyA,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      ),
    ];
    return [
      for (var i = 0; i < actions.length; i++)
        RegisteredCommand(
          id: actions[i].$1,
          scope: CommandScope.editor,
          label: (_) => actions[i].$2,
          enabled: () => !_loading && _error == null && !widget.quitPending,
          activators: (platform) => [
            _editorShortcut(
              platform,
              actions[i].$3,
              shift: actions[i].$1 == 'editor.redo',
            ),
          ],
          run: (_) async {
            final focusContext = FocusManager.instance.primaryFocus?.context;
            if (focusContext != null)
              Actions.maybeInvoke(focusContext, actions[i].$4);
          },
          menuPlacement: CommandMenuPlacement(
            menu: AppMenuId.edit,
            order: 20 + i,
          ),
        ),
    ];
  }

  static SingleActivator _editorShortcut(
    TargetPlatform platform,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) => SingleActivator(
    key,
    meta: platform == TargetPlatform.macOS,
    control: platform != TargetPlatform.macOS,
    shift: shift,
  );

  Widget _searchBar(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final counter = _search.text.isEmpty
        ? ''
        : _matches.isEmpty
        ? l10n.editorNoMatches
        : _matches.length >= searchMatchLimit
        ? l10n.editorMatchCountCapped(_activeMatch + 1, _matches.length)
        : l10n.editorMatchCount(_activeMatch + 1, _matches.length);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: l10n.editorFindHint,
                isDense: true,
                border: InputBorder.none,
              ),
              onSubmitted: (_) {
                if (HardwareKeyboard.instance.isShiftPressed) {
                  _previousMatch();
                } else {
                  _nextMatch();
                }
                _searchFocus.requestFocus();
              },
            ),
          ),
          // Keep focus in the query field: the buttons act without taking it.
          ExcludeFocus(
            child: Row(
              children: [
                if (counter.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(counter, style: theme.textTheme.labelSmall),
                  ),
                IconButton(
                  tooltip: l10n.editorMatchCaseTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: _toggleCaseSensitive,
                  icon: Text(
                    'Aa',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _searchCaseSensitive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.editorPreviousMatchTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: _matches.isEmpty ? null : _previousMatch,
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: l10n.editorNextMatchTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: _matches.isEmpty ? null : _nextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
                IconButton(
                  tooltip: l10n.editorCloseSearchTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: _closeSearch,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.text_snippet_outlined, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _editorWidth = constraints.maxWidth;
        return Actions(
          actions: {
            if (widget.quitPending) ...{
              UndoTextIntent: CallbackAction<UndoTextIntent>(
                onInvoke: (_) => null,
              ),
              RedoTextIntent: CallbackAction<RedoTextIntent>(
                onInvoke: (_) => null,
              ),
            },
          },
          child: TextField(
            controller: _text,
            readOnly: widget.quitPending,
            focusNode: _editorFocus,
            scrollController: _scroll,
            autofocus: true,
            expands: true,
            maxLines: null,
            minLines: null,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            style: _editorTextStyle,
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(_editorPadding),
            ),
          ),
        );
      },
    );
  }
}
