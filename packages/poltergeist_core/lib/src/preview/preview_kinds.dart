import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The preview pipeline's capability kinds (06 §3.2/§5.3). Every file —
/// remote or local — classifies into exactly one kind; the kind decides
/// which renderer the preview pane mounts and which per-kind download
/// cap gates remote production.
enum PreviewKind {
  /// Previewable text: extension sets plus known text-bearing basenames,
  /// and the unknown-extension fallback once the produced bytes prove to
  /// be valid non-NUL UTF-8 (06 §5.3).
  text,

  /// Raster formats decode either natively or through an in-process
  /// decoder (06 §5.3): png, jpg/jpeg, gif, webp, bmp, ico, avif.
  image,

  /// PDF renders through the preview renderer seam — a rasterizer when
  /// one ships, the metadata card until then (06 §5.3).
  pdf,

  /// Every remaining file: the metadata card with an Open affordance
  /// (06 §5.3's always-renderable fallback).
  metadata,

  /// A remote production refused before any bytes move: the listing
  /// size exceeds the preview cache capacity, so the produced copy
  /// could never be committed (06 §5.3's over-cap refusal).
  overCacheCap,

  /// A remote production refused by the per-kind cap: images and PDFs
  /// carry a hard byte ceiling (06 §5.3) — over it the pane shows the
  /// card and never downloads.
  overKindCap,
}

/// The default remote-download byte ceiling for image and PDF previews
/// (06 §5.3's "the image/PDF path carries a kind-specific size cap that
/// defaults to 64 MiB"). Text previews have no kind cap — UTF-8 text is
/// always renderable, gated only by the large-download threshold and the
/// cache cap.
const int previewImageKindCapBytes = 64 * 1024 * 1024;
const int previewPdfKindCapBytes = 64 * 1024 * 1024;

/// The preview text loader's read window (06 §5.3: "the pane reads the
/// first 1 MiB only").
const int previewTextMaximumBytes = 1024 * 1024;

/// The large-download confirmation threshold's factory value (06 §5.2:
/// "a large-download confirmation that defaults to 100 MiB").
const int defaultLargeDownloadThresholdBytes = 100 * 1024 * 1024;

/// The preview cache's default capacity (06 §5.3's "keyed, capped (512
/// MiB by default) LRU").
const int defaultPreviewCacheCapacityBytes = 512 * 1024 * 1024;

/// The dedicated producer's concurrent-slot ceiling (03 §4.7's "a
/// dedicated concurrency cap of two producer slots").
const int previewProduceSlotLimit = 2;

/// The OS drag-out producer's own concurrent-slot ceiling (00 D14's
/// drag-out amendment): promise fulfilment draws from a separate budget
/// so a many-file drop into Finder can never starve Quick Look's
/// [previewProduceSlotLimit] slots.
const int dragOutProduceSlotLimit = 2;

/// The [PreviewKind] for [name]'s extension, BEFORE content inspection.
/// Remote entries classify on the listing's name alone so the prompt
/// card and the caps can decide without downloading; a produced file
/// whose extension classified [PreviewKind.metadata] is re-checked as
/// UTF-8 text at render time (06 §5.3's unknown-but-UTF-8 path). The
/// name may be a bare file name or a path — only the last component's
/// extension participates.
PreviewKind previewKindForName(String name) {
  final base = _baseName(name);
  final extension = _rawExtension(base)?.toLowerCase();
  if (extension != null) {
    if (_imageExtensions.contains(extension)) return PreviewKind.image;
    if (_pdfExtensions.contains(extension)) return PreviewKind.pdf;
    if (_textExtensions.contains(extension)) return PreviewKind.text;
  }
  if (_textBasenames.contains(base.toLowerCase())) {
    return PreviewKind.text;
  }
  return PreviewKind.metadata;
}

/// Whether [name] classifies under a kind the pane renders — the
/// dispatch guard shared by the Space verb and the prompt card (06 §5.3:
/// "anything else falls back to the card"). Drives the dispatch table
/// the pane's Space/Esc tests enumerate.
bool previewKindIsRenderable(PreviewKind kind) => switch (kind) {
      PreviewKind.text || PreviewKind.image || PreviewKind.pdf => true,
      _ => false,
    };

/// The per-kind download cap for remote production (06 §5.3), or null
/// when the kind has none (text and the metadata card download whole —
/// their only gates are the threshold prompt and the cache cap).
int? previewKindCapBytes(PreviewKind kind) => switch (kind) {
      PreviewKind.image => previewImageKindCapBytes,
      PreviewKind.pdf => previewPdfKindCapBytes,
      _ => null,
    };

/// A name's leaf extension, lower-cased, without the dot — null when the
/// name has none (or ends in one). Dotfiles like `.zshrc` report no
/// extension: `.zshrc`'s "extension" would be the whole basename.
String? previewExtension(String name) =>
    _rawExtension(_baseName(name))?.toLowerCase();

/// The same leaf extension in its original case — the input to
/// [sanitizePreviewExtension] for cache naming, which preserves case
/// (06 §5.3). Classification uses the lower-cased [previewExtension].
String? previewRawExtension(String name) => _rawExtension(_baseName(name));

/// The cache file-name extension (06 §5.3): [extension] survives only
/// when it full-matches `^[A-Za-z0-9_-]{1,16}$` — anchored, case
/// preserved — and is DROPPED otherwise: the extensionless hash name
/// falls back to content sniffing rather than carrying a fabricated
/// suffix. Remote names are server-controlled, so an "extension" can
/// carry characters illegal in local filenames (Windows `:` `?` `*` `<`
/// `>` `|`, control bytes) or unbounded length — neither may name a
/// file on disk.
String? sanitizePreviewExtension(String? extension) {
  if (extension != null && _safeExtension.hasMatch(extension)) {
    return extension;
  }
  return null;
}

/// The preview cache's collision-safe key (06 §5.3): the tuple
/// (serverId, remotePath, mtimeSeconds, size) hashed, so a remote file
/// that changed since the last preview misses the cache and re-
/// produces. [modifiedAt] may be null in the listing — the tuple then
/// omits it (a re-listing that gains an mtime produces a new key, which
/// is the conservative answer anyway).
String previewCacheKey(
  String serverId,
  String remotePath,
  DateTime? modifiedAt,
  int? size,
) {
  final mtime = modifiedAt?.millisecondsSinceEpoch == null
      ? null
      : modifiedAt!.millisecondsSinceEpoch ~/ 1000;
  final tuple = jsonEncode([serverId, remotePath, mtime, size]);
  return sha256.convert(utf8.encode(tuple)).toString();
}

/// The basename of a POSIX-ish path (remote paths are always POSIX;
/// local names arrive as bare names already).
String _baseName(String name) {
  final slash = name.lastIndexOf('/');
  return slash < 0 ? name : name.substring(slash + 1);
}

String? _rawExtension(String base) {
  if (base.isEmpty || base.startsWith('.')) {
    // A leading dot is the hidden-file marker, not an extension
    // separator: `.zshrc` is extensionless, `.env.local`'s extension is
    // `local`.
    final tail = base.substring(1);
    if (!tail.contains('.')) return null;
    return tail.substring(tail.lastIndexOf('.') + 1);
  }
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  return base.substring(dot + 1);
}

final RegExp _safeExtension = RegExp(r'^[A-Za-z0-9_-]{1,16}$');

/// The Windows-executable extensions (06 §5.3): Script-Host and
/// control-panel spellings that double-click-execute, plus the types
/// whose default verb runs code anyway — shortcuts (`lnk`, `url`),
/// installers (`msi`, `application`), registry merges, compiled help,
/// MMC consoles, troubleshooter packs, and `jar` under an installed
/// Java runtime. They are KEPT in cache names — preview and Quick Look
/// never execute the hash-named copy, and stripping them would break
/// extension-keyed preview of legitimate scripts — so this list guards
/// the OPEN boundary instead: [isExecutableLaunchName] reads it for
/// Windows hosts, and an OS launch of a remote item never re-attaches
/// one of these. The membership-pinning test also asserts every entry
/// passes [_safeExtension], so the sanitizer and the blocklist cannot
/// drift.
const previewWindowsExecutableExtensions = <String>{
  'bat', 'cmd', 'com', 'scr', 'ps1', 'js', 'jse', 'vbs', 'vbe',
  'wsf', 'wsh', 'hta', 'exe', 'pif', 'scf', 'cpl', 'msp', 'mst',
  'msi', 'lnk', 'url', 'reg', 'chm', 'msc', 'jar', 'vb', 'ws',
  'wsc', 'sct', 'application', 'diagcab',
};

/// The desktop hosts [isExecutableLaunchName] knows. What an OS "open"
/// does with a file is decided by the host's association table, not by
/// the file, so the same name can be a document on one host and a
/// program on another.
enum LaunchHost { macos, linux, windows }

/// macOS launch types that run rather than open: Terminal runs
/// `command`/`tool` scripts and a `terminal` file's CommandString;
/// `fileloc`/`inetloc`/`webloc` open their target, which can be a
/// program or an app's URL scheme; `app`/`workflow` are code bundles;
/// Jar Launcher runs `jar`; Installer runs `pkg`/`mpkg` scripts.
const _macosExecutableExtensions = <String>{
  'app', 'command', 'tool', 'terminal', 'workflow', 'fileloc',
  'inetloc', 'webloc', 'jar', 'pkg', 'mpkg',
};

/// Linux launch types that run without an execute bit: file managers
/// behind `xdg-open` launch `desktop` entries, the Java runtime's
/// handler runs `jar`, and `appimage` is listed as defense in depth.
/// Everything else that executes needs the execute bit, which managed
/// checkouts never carry (they are written 0600, 06 §3.1).
const _linuxExecutableExtensions = <String>{'desktop', 'jar', 'appimage'};

/// Whether handing [name] to [host]'s default handler would run it as a
/// program instead of opening it as a document — 06 §5.3's "never
/// executed" rule at the open boundary. [name] may be a bare name, a
/// POSIX path, or a Windows path; only the last component counts, and
/// within it only the LAST extension (`invoice.pdf.exe` is an `exe`),
/// matched case-insensitively after trailing dots and spaces are
/// stripped the way Win32 resolves names (`x.hta.` launches as
/// `x.hta`). The strip applies on every host, where it can only err
/// toward refusing.
///
/// Unlike [previewExtension], a leading dot names an extension: Explorer
/// runs a file called `.js` through Script Host, so the dotfile rule
/// that keeps `.zshrc` extensionless for preview must not apply here.
bool isExecutableLaunchName(String name, {required LaunchHost host}) {
  final extension = _launchExtension(name);
  if (extension == null) return false;
  return switch (host) {
    LaunchHost.windows => previewWindowsExecutableExtensions.contains(
      extension,
    ),
    LaunchHost.macos => _macosExecutableExtensions.contains(extension),
    LaunchHost.linux => _linuxExecutableExtensions.contains(extension),
  };
}

String? _launchExtension(String name) {
  final base = name
      .substring(name.lastIndexOf(_pathSeparator) + 1)
      .replaceFirst(_trailingDotsAndSpaces, '');
  final dot = base.lastIndexOf('.');
  if (dot < 0) return null;
  return base.substring(dot + 1).toLowerCase();
}

final RegExp _pathSeparator = RegExp(r'[/\\]');
final RegExp _trailingDotsAndSpaces = RegExp(r'[. ]+$');

/// Text preview's extension set (06 §5.3 plus the §1.1 editor set —
/// the pane must render everything the editor opens, so the lists share
/// one definition: code, config, markup, data, and document formats).
const _textExtensions = <String>{
  // Plain text and docs
  'txt', 'text', 'md', 'markdown', 'mdown', 'mkd', 'rst', 'org', 'adoc',
  'asciidoc', 'log', 'rtf', 'tex', 'csv', 'tsv', 'nfo', 'readme',
  // Web
  'html', 'htm', 'xhtml', 'xml', 'xsd', 'xsl', 'xslt', 'svg', 'css',
  'scss', 'sass', 'less', 'js', 'mjs', 'cjs', 'jsx', 'ts', 'tsx', 'mts',
  'cts', 'json', 'jsonc', 'json5', 'map', 'vue', 'svelte', 'astro',
  // Data / config
  'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'config', 'properties',
  'env', 'editorconfig', 'gitignore', 'gitattributes', 'gitmodules',
  'dockerignore', 'npmignore', 'plist', 'service',
  // Shell and scripting
  'sh', 'bash', 'zsh', 'fish', 'ksh', 'csh', 'bat', 'cmd', 'ps1',
  'psm1', 'py', 'pyw', 'pyi', 'rb', 'pl', 'pm', 'lua', 'tcl', 'awk',
  'sed', 'r', 'jl', 'ex', 'exs', 'erl', 'hrl', 'clj', 'cljs', 'edn',
  'hs', 'lhs', 'ml', 'mli', 'fs', 'fsx', 'groovy', 'gradle', 'scala',
  'sbt', 'kt', 'kts', 'vim', 'el', 'lisp', 'scm', 'ss', 'rkt', 'nu',
  // Compiled languages
  'c', 'h', 'cc', 'cpp', 'cxx', 'hh', 'hpp', 'hxx', 'm', 'mm', 'cs',
  'java', 'jav', 'go', 'rs', 'swift', 'dart', 'd', 'pas', 'pp', 'f',
  'f90', 'f95', 'for', 'asm', 's', 'zig', 'v', 'vala', 'nim', 'cr',
  // Build / CI
  'cmake', 'mk', 'ninja', 'bazel', 'bzl', 'star', 'gn', 'gni', 'meson',
  'spec', 'ebuild', 'eclass', 'diff', 'patch', 'ipynb',
  // Misc text-bearing formats
  'sql', 'graphql', 'gql', 'proto', 'thrift', 'avdl', 'capnp', 'po',
  'pot', 'strings', 'srt', 'vtt', 'sub', 'ics', 'vcf', 'eml', 'mbox',
  'url', 'webloc', 'desktop', 'theme', 'cuesheet', 'cue', 'ly',
};

/// Basenames that are text regardless of extension (06 §5.3's
/// "known-text basenames").
const _textBasenames = <String>{
  'readme', 'license', 'licence', 'copying', 'authors', 'contributors',
  'changelog', 'news', 'todo', 'notice', 'install', 'makefile',
  'dockerfile', 'vagrantfile', 'gemfile', 'rakefile', 'brewfile',
  'podfile', 'fastfile', 'procfile', 'justfile', 'taskfile',
  '.gitignore', '.gitattributes', '.gitmodules', '.editorconfig',
  '.dockerignore', '.npmignore', '.babelrc', '.eslintrc', '.prettierrc',
  '.zshrc', '.bashrc', '.bash_profile', '.profile', '.zprofile',
  '.vimrc', '.emacs', '.nanorc', '.screenrc', '.tmux.conf',
};

const _imageExtensions = <String>{
  'png', 'jpg', 'jpeg', 'jpe', 'gif', 'webp', 'bmp', 'dib', 'ico',
  'cur', 'avif', 'heic', 'heif', 'tif', 'tiff',
};

const _pdfExtensions = <String>{'pdf'};
