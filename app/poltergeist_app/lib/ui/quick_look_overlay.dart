import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/in_app_quick_look.dart';
import '../theme/app_theme.dart';
import 'editor_syntax.dart';
import 'panes/kind_glyph.dart';
import 'panes/pane_format.dart';
import 'preview_panel.dart' show PreviewPdfBuilder;

/// The Linux/Windows Quick Look surface (D32, 06 §5.1): a large floating
/// preview over the panes that Space opens and closes for the focused
/// item, as macOS's `QLPreviewPanel` does there. It renders whatever
/// local file [controller] holds — remote items arrive as produced
/// preview-cache files — and never takes focus, so the listing keeps the
/// keyboard: the arrows move the selection (the session follows it) and
/// Space and Esc reach the session's own tiers. The inspector's docked
/// Info preview is untouched.
///
/// Mounted as a child of the panes-region [Stack]; clicks outside the
/// panel fall through to the listing.
class QuickLookOverlay extends StatelessWidget {
  const QuickLookOverlay({
    super.key,
    required this.controller,
    required this.nameFor,
    this.pdfRenderer,
  });

  final InAppQuickLook controller;

  /// The display name for a shown path (the session maps preview-cache
  /// files back to their remote entry's name).
  final String Function(String path) nameFor;

  final PreviewPdfBuilder? pdfRenderer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final path = controller.currentPath;
        if (path == null) return const SizedBox.shrink();
        return Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) => Center(
              child: SizedBox(
                width: (constraints.maxWidth * 0.86).clamp(0, 960),
                height: (constraints.maxHeight * 0.88).clamp(0, 720),
                child: _Panel(
                  path: path,
                  name: nameFor(path),
                  index: controller.index,
                  count: controller.paths.length,
                  onClose: controller.close,
                  pdfRenderer: pdfRenderer,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.path,
    required this.name,
    required this.index,
    required this.count,
    required this.onClose,
    required this.pdfRenderer,
  });

  final String path;
  final String name;
  final int index;
  final int count;
  final VoidCallback onClose;
  final PreviewPdfBuilder? pdfRenderer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    return Focus(
      // The panel never takes focus itself; a control inside it that
      // does (the close button after a click) still owes Space and Esc
      // their close.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.space) {
          onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        container: true,
        label: l10n.quickLookOverlayLabel,
        child: Material(
          key: const ValueKey('quickLook.overlay'),
          elevation: 12,
          color: theme.colorScheme.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: chrome.separator),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 36,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
                  child: Row(
                    children: [
                      _HeaderIcon(key: ValueKey(path), path: path, name: name),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          key: const ValueKey('quickLook.title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (count > 1) ...[
                        const SizedBox(width: 8),
                        Text(
                          l10n.quickLookPosition(index + 1, count),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: chrome.secondaryText,
                          ),
                        ),
                      ],
                      IconButton(
                        key: const ValueKey('quickLook.close'),
                        tooltip: l10n.quickLookClose,
                        onPressed: onClose,
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: chrome.separator),
              Expanded(
                child: _Body(
                  // A new item starts its own load.
                  key: ValueKey(path),
                  path: path,
                  name: name,
                  pdfRenderer: pdfRenderer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The title bar's kind glyph: a folder once the path proves to be one,
/// else the glyph the name's kind implies.
class _HeaderIcon extends StatefulWidget {
  const _HeaderIcon({
    super.key,
    required this.path,
    required this.name,
  });

  final String path;
  final String name;

  @override
  State<_HeaderIcon> createState() => _HeaderIconState();
}

class _HeaderIconState extends State<_HeaderIcon> {
  late final Future<bool> _folder = FileSystemEntity.isDirectory(widget.path);

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _folder,
    builder: (context, snapshot) => kindIcon(
      context,
      paneKindCategory(
        RemoteFileEntry(
          path: widget.path,
          name: widget.name,
          type: snapshot.data ?? false
              ? RemoteFileType.directory
              : RemoteFileType.file,
        ),
      ),
      size: 16,
    ),
  );
}

/// What the overlay can say about one path once it has looked: a folder,
/// text it read, a file to hand an image or PDF renderer, an image or
/// PDF too large to decode, or nothing renderable.
sealed class _Look {
  const _Look();
}

final class _Folder extends _Look {
  const _Folder();
}

final class _Text extends _Look {
  const _Text(this.content);
  final PreviewTextContent content;
}

final class _Renderable extends _Look {
  const _Renderable(this.kind);
  final PreviewKind kind;
}

/// Over its kind's decode cap ([previewKindCapBytes], 06 §5.2) — the
/// same refusal the Info well gives the same file.
final class _TooLarge extends _Look {
  const _TooLarge();
}

final class _Nothing extends _Look {
  const _Nothing();
}

class _Body extends StatefulWidget {
  const _Body({
    super.key,
    required this.path,
    required this.name,
    required this.pdfRenderer,
  });

  final String path;
  final String name;
  final PreviewPdfBuilder? pdfRenderer;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  late final Future<_Look> _look = _resolve();

  /// Kind by the display name; extensionless or unknown files get the
  /// same UTF-8 re-check the Info tab's well runs (06 §5.3).
  Future<_Look> _resolve() async {
    final path = widget.path;
    if (await FileSystemEntity.isDirectory(path)) return const _Folder();
    final kind = previewKindForName(widget.name);
    switch (kind) {
      case PreviewKind.image:
      case PreviewKind.pdf:
        // The Info well's decode cap holds here too: a full-resolution
        // decode of a multi-hundred-MB image or PDF is a memory spike
        // the overlay must not take on.
        final cap = previewKindCapBytes(kind);
        try {
          if (cap != null && await File(path).length() > cap) {
            return const _TooLarge();
          }
        } on FileSystemException {
          return const _Nothing();
        }
        return _Renderable(kind);
      case _:
        try {
          return _Text(await loadPreviewText(File(path)));
        } on BuiltInEditorException {
          return const _Nothing();
        } on FileSystemException {
          return const _Nothing();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Look>(
      future: _look,
      builder: (context, snapshot) {
        final look = snapshot.data;
        if (look == null) {
          return snapshot.hasError
              ? _nothing(context)
              : const Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
        }
        return switch (look) {
          _Folder() => _nothing(context, folder: true),
          _Text(:final content) => _text(context, content),
          _Renderable(kind: PreviewKind.image) => _image(context),
          _Renderable() => _pdf(context),
          _TooLarge() => _nothing(
            context,
            reason: AppLocalizations.of(context).previewRefusalOverKindCap,
          ),
          _Nothing() => _nothing(context),
        };
      },
    );
  }

  Widget _text(BuildContext context, PreviewTextContent content) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final language = syntaxLanguageFor(
      widget.name,
      firstLine: content.text.split('\n').firstOrNull,
    );
    final syntax = EditorSyntaxTheme.of(theme.brightness);
    final tokens = language == null
        ? const <SyntaxToken>[]
        : tokenizeSyntax(content.text, language);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (content.truncated)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 0),
            child: Text(
              l10n.previewTruncatedLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: PoltergeistChrome.of(context).secondaryText,
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text.rich(
              key: const ValueKey('quickLook.text'),
              TextSpan(
                children: buildHighlightedSpans(
                  text: content.text,
                  tokens: tokens,
                  matches: const [],
                  activeMatchIndex: -1,
                  theme: syntax,
                ),
                style: poltergeistMonoTextStyle.copyWith(
                  fontSize: 13,
                  height: 1.45,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _image(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Semantics(
        label: l10n.previewImageLabel(widget.name),
        image: true,
        child: Image.file(
          File(widget.path),
          key: const ValueKey('quickLook.image'),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _nothing(context),
        ),
      ),
    );
  }

  Widget _pdf(BuildContext context) {
    final renderer = widget.pdfRenderer;
    if (renderer == null) return _nothing(context);
    return renderer(context, File(widget.path));
  }

  /// The no-preview card; [reason] replaces its generic line when the
  /// overlay refused a kind it could otherwise render.
  Widget _nothing(BuildContext context, {bool folder = false, String? reason}) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: kindIcon(
              context,
              paneKindCategory(
                RemoteFileEntry(
                  path: widget.path,
                  name: widget.name,
                  type: folder
                      ? RemoteFileType.directory
                      : RemoteFileType.file,
                ),
              ),
              size: 96,
            ),
          ),
          const SizedBox(height: 12),
          Text(widget.name, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            reason ?? l10n.quickLookNoPreview,
            key: const ValueKey('quickLook.noPreview'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: chrome.secondaryText,
            ),
          ),
        ],
      ),
    );
  }
}
