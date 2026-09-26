import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

const _generatedDartSuffixes = {'.freezed.dart', '.g.dart', '.mocks.dart'};

// Technical literals are reviewed per file so an allowlist cannot hide UI copy.
const _allowedTechnicalLiterals = <String, Set<String>>{
  // Flutter menu serialization and the AppKit checkmark channel protocol.
  'lib/services/checked_platform_menu.dart': {
    "'checked'",
    "'flutter/menu'",
    "'poltergeist/menu_checks'",
    "'Menu.setMenus'",
    "'id'",
    "'children'",
    "'0'",
    "'setChecked'",
    r"'${item['id']}'",
  },
  // View schema keys and validation diagnostics, never rendered UI copy.
  'lib/services/view_preferences_store.dart': {
    "'view.preferences'",
    "'version'",
    "'defaults'",
    "'locations'",
    "'location'",
    "'preferences'",
    "'Unsupported view preferences schema'",
    "'Invalid view preference locations'",
    "'Invalid view preference record'",
  },
  'lib/services/view_preferences.dart': {
    "'identity'",
    "'Must not be empty'",
    "'canonicalPath'",
    "'kind'",
    "'Invalid view location identity'",
    "'Invalid view location canonical path'",
    "'columns'",
    "'Name must be first'",
    "'Columns must be unique'",
    "'columnWidths'",
    "'Widths must be positive and finite'",
    "'mode'",
    "'density'",
    "'directories'",
    "'hiddenFiles'",
    "'dates'",
    "'sortKey'",
    "'sortDirection'",
    r"'Invalid view preferences: ${error.message}'",
    "'View columns must be a list'",
    "'View column widths must be numbers'",
    "'View preferences require a JSON object'",
    r"'Invalid view preference: $field'",
  },
  // The empty query starts a transient selection session; it is not UI copy.
  'lib/services/quick_select_state.dart': {"''"},
  // The DnD verb/containment rules' path mechanics: UNC and POSIX
  // separators, the root-join, and the Windows path-shape patterns —
  // string surgery, never rendered UI copy.
  'lib/services/pane_drop.dart': {
    r"r'\\'",
    r"r'\'",
    r"'$root$separator'",
    // Windows path-shape patterns for the case-fold and volume checks —
    // regex machinery, never rendered.
    r"r'^([A-Za-z]:|\\\\)'",
    r"r'^[A-Za-z]:'",
  },
  // Selection-model validation diagnostics for programmer errors (unknown
  // targets, duplicate row identities); never rendered UI copy.
  'lib/services/selection_state.dart': {
    "'selectedKeys'",
    "'not a visible row'",
    "'rows'",
    "'duplicate row identities'",
    "'key'",
  },
  'lib/main.dart': {
    r"'${supportDirectory.path}${Platform.pathSeparator}settings.json'",
    r"'${supportDirectory.path}${Platform.pathSeparator}bookmarks.json'",
    // The §3.1 record store's file name inside app support — a path
    // literal, not copy.
    r"'${supportDirectory.path}${Platform.pathSeparator}sync_records.json'",
    // The writable server store and vault store file names inside app
    // support — path literals, not copy.
    r"'${supportDirectory.path}${Platform.pathSeparator}servers.json'",
    r"'${supportDirectory.path}${Platform.pathSeparator}vault.json'",
    // The M7 preview cache's directory name inside app support — a path
    // literal, not copy.
    r"'${supportDirectory.path}${Platform.pathSeparator}preview-cache'",
    // The engine-less pin-store fallback path — same machine path data.
    r"'${supportDirectory.path}${Platform.pathSeparator}'",
    r"'$kPinStoreFileName'",
    // The engine's append-only identity-read log — same machine path data.
    r"'$kIdentityAuditLogFileName'",
    // The runId device prefix when enrollment has no cached id — a
    // machine identity string, never rendered.
    "'local'",
  },
  // The production engine session's store file names and wiring literals
  // (paths inside the app-support directory, the review pane-tab id) —
  // plus the empty identity fallbacks of the bookmark-to-config mapping.
  'lib/services/engine_session.dart': {
    "'host_keys.json'",
    "'incidents.json'",
    "'identity_reads.jsonl'",
    "'review'",
    "'review-connect serverId must equal bookmark.id'",
    r"'$supportDirectoryPath$separator$_pinStoreFileName'",
    r"'$supportDirectoryPath$separator$_incidentStoreFileName'",
    r"'$supportDirectoryPath$separator$_identityAuditLogFileName'",
    "'bookmark.id'",
    "'bookmark has no embedded server identity'",
    // The setPermissions assert's mode-range diagnostic — a programming-
    // error message, never rendered.
    "'permissions must be a twelve-bit mode (0x000-0xFFF)'",
  },
  // The M7 preview session's cache-key prefix for a local file — machine
  // identity handed to PreviewCache, never rendered UI copy.
  'lib/services/preview_session.dart': {r"'local:${entry.path}'"},
  // The Quick Look platform channel's method and argument names
  // (06 §5.1) — channel plumbing, never rendered UI copy.
  'lib/services/quick_look_channel.dart': {
    "'poltergeist/quicklook'",
    "'showPreview'",
    "'updatePreview'",
    "'hidePreview'",
    "'isAvailable'",
    "'isVisible'",
    "'paths'",
    "'index'",
    "'closed'",
    // Every call names the workspace window it comes from (00 D39).
    "'viewId'",
  },
  // The macOS toolbar band's `poltergeist/window` channel: method names
  // and a wiring-fault diagnostic that only reaches the runner's reply,
  // never a rendered surface.
  'lib/services/macos_toolbar_band_channel.dart': {
    "'poltergeist/window'",
    "'isToolbarBandVisible'",
    "'toolbarBandChanged'",
    "'BAD_ARGS'",
    "'toolbarBandChanged needs a bool argument'",
  },
  // The D15 trash channel server (03 §7.1): Platform.operatingSystem ids
  // and wiring-fault diagnostics that only reach the error reporter,
  // never a rendered surface.
  'lib/services/trash_channel.dart': {
    "'macos'",
    "'windows'",
    r"'unexpected trash channel message: $message'",
    r"'$error'",
  },
  // The import wiring's POSIX-shaped ssh_config path (the core import
  // normalizes on `/`). The bookmark store it writes is the caller's now:
  // one instance serves the import command and the Connections surface.
  'lib/services/ssh_config_import_setup.dart': {r"'$home/.ssh/config'", "'~'"},
  // The composed queue's honest-absence connection seam: the refusal's
  // `operation` label is diagnostic metadata (the exception renders
  // `message`, which is ARB copy) — never authored UI text.
  'lib/services/transfer_queue_session.dart': {"'transfer channel'"},
  // The checkout session's store paths — machine data, never rendered UI
  // copy (its `df` probe moved to local_volumes.dart).
  'lib/services/checkout_session.dart': {
    "'\$supportDirectoryPath\${Platform.pathSeparator}'",
    "'managed_remote_files.json'",
    "'\$supportDirectoryPath\${Platform.pathSeparator}checkouts'",
  },
  'lib/services/app_preferences.dart': {
    "'layout.paneRatio'",
    "'window.left'",
    "'window.top'",
    "'window.width'",
    "'window.height'",
    "'tabs.newTabTarget'",
    "'panes.doubleClickAction'",
    "'tabs.reconnectRestored'",
    // The D32 region widths (10 §3.1) — settings.json keys.
    "'layout.sidebarWidth'",
    "'layout.inspectorWidth'",
    // The activity panel's persisted keys (02 §1/§6): the two throttle
    // limits and the auto-remove flag — settings.json keys.
    "'transfer.downloadLimitBytesPerSecond'",
    "'transfer.uploadLimitBytesPerSecond'",
    "'transfer.autoClearCompleted'",
    // D37's per-server transfer caps: the default and the overrides
    // keys, and the stored spelling of an override's Automatic —
    // settings.json data, never rendered.
    "'transfer.perServerConcurrency'",
    "'transfer.serverConcurrency'",
    "'automatic'",
    // The sidebar's persisted keys (02 §4, D33): the hidden intent, the
    // collapsed-group set and the row density — settings.json keys,
    // never rendered.
    "'layout.sidebarHidden'",
    "'sidebar.collapsedGroups'",
    "'sidebar.density'",
    "'sidebar.pinnedServers'",
    // The preview panel's persisted keys (06 §8): cache capacity and the
    // large-download confirmation threshold — settings.json keys.
    "'preview.cacheCapacityBytes'",
    "'preview.largeDownloadThresholdBytes'",
    // The D19 update-check opt-out (02 §5) — a settings.json key.
    "'updates.checkEnabled'",
    // The device theme and its mode (Device themes): settings.json keys.
    "'theme.palette'",
    "'theme.mode'",
  },
  'lib/services/atomic_file.dart': {r"'.poltergeist-${uuidV4()}.tmp'"},
  // The session-state document's on-disk schema (02 §3): settings.json
  // keys, record field names, and validation diagnostics — the same
  // posture as the sibling versioned stores, never rendered UI copy.
  'lib/services/session_state.dart': {
    "'pane.left'",
    "'pane.right'",
    "'version'",
    "'activePane'",
    "'secondPaneHidden'",
    "'panes'",
    "'paneId'",
    "'activeTab'",
    "'nextTabOrdinal'",
    "'tabs'",
    "'kind'",
    "'local'",
    "'remote'",
    "'unbound'",
    "'id'",
    "'path'",
    "'serverId'",
    "'bookmark'",
    "'listing'",
    "'name'",
    "'type'",
    "'size'",
    "'uid'",
    "'gid'",
    "'accessedAt'",
    "'modifiedAt'",
    "'contentSha256'",
    "'mode'",
    r"'bookmark:${bookmarkJson['id']}'",
    "'Invalid session tab'",
    "'Invalid session tab kind'",
    "'Invalid session tab serverId'",
    "'Invalid session tab bookmark'",
    "'Invalid session tab path'",
    "'Invalid session tab listing'",
    "'Invalid session pane'",
    "'Invalid session pane id'",
    "'Invalid session pane counters'",
    "'Invalid session pane active tab'",
    "'Invalid session pane tab counter'",
    "'Invalid session pane tabs'",
    "'Invalid session state'",
    "'Unsupported session state schema'",
    "'Invalid session active pane'",
    "'Invalid session pane visibility'",
    "'Invalid session panes'",
    "'Invalid session entry'",
    // The activity panel's optional visibility flag (02 §1's third
    // splitter chrome): key plus its strict-type diagnostic.
    "'activityPanelHidden'",
    "'Invalid session activity panel flag'",
    // The D32 inspector's optional visibility and tab (10 §3.1): keys
    // plus their strict-type diagnostics.
    "'inspectorHidden'",
    "'inspectorTab'",
    "'Invalid session inspector flag'",
    "'Invalid session inspector tab'",
    // 00 D39's document of the windows open beside the first: its list
    // key plus its strict-decode diagnostics.
    "'windows'",
    "'Invalid session windows'",
    "'Unsupported session windows schema'",
    "'Invalid session windows list'",
  },
  // The settings.json key the session document lives under (02 §3).
  'lib/services/session_state_store.dart': {
    "'session.state'",
    // 00 D39: the windows open beside the first, under their own key.
    "'session.windows'",
  },
  // 00 D39's workspace windows: the runner channel's name, the diagnostics
  // a failed native call carries to the error reporter, and debug labels
  // for keys and focus scopes — never rendered UI copy.
  'lib/services/workspace_windows/window_host.dart': {
    "'poltergeist/windows'",
    r"'WindowHostException: $message'",
    "'no window host'",
    "'the runner answered no view id'",
  },
  // 00 D39's extra windows' integrations: the drop-in and macOS titlebar
  // channels' names, and the id a header control's passthrough rectangle
  // goes by on the titlebar channel — wire data, never rendered.
  'lib/services/window_drop_in.dart': {"'poltergeist/dropin'"},
  'lib/services/workspace_windows/window_titlebar.dart': {
    "'poltergeist/titlebar'",
  },
  'lib/ui/shell/window_toolbar_passthrough.dart': {
    r"'passthrough-${_serial++}'",
  },
  'lib/services/workspace_windows/workspace_windows.dart': {
    r"'window $serial navigator'",
    r"'window $serial messenger'",
    r"'window $serial'",
    "'active window navigator'",
    "'active window messenger'",
  },
  // 00 D39's window command ids (D21 plumbing), never rendered.
  'lib/ui/shell/window_commands.dart': {
    "'window.new'",
    "'window.close'",
  },
  // The workspace document's on-disk schema (02 §3): the session-shape
  // tab fields it reuses plus the persisted lens keys — the same
  // posture as the sibling versioned stores, never rendered UI copy.
  'lib/services/workspace_state.dart': {
    "'filterQuery'",
    "'filterFieldOpen'",
    "'hiddenFiles'",
    "'viewMode'",
    "'list'",
    "'details'",
    "'paneId'",
    "'activeTab'",
    "'tabs'",
    "'panes'",
    "'id'",
    "'label'",
    "'savedAt'",
    "'lastOpenedAt'",
    "'snapshot'",
    "'version'",
    "'workspaces'",
    "'Invalid workspace tab'",
    "'Invalid workspace tab filter'",
    "'Invalid workspace tab flags'",
    "'Invalid workspace tab view mode'",
    "'Invalid workspace pane'",
    "'Invalid workspace pane id'",
    "'Invalid workspace pane active tab'",
    "'Invalid workspace pane tabs'",
    "'Invalid workspace snapshot'",
    "'Invalid workspace panes'",
    "'Invalid workspace'",
    "'Invalid workspace id'",
    "'Invalid workspace label'",
    "'Invalid workspace timestamp'",
    "'Invalid workspace list'",
    "'Unsupported workspace list schema'",
    "'Invalid workspace list entries'",
    // The pre-migration serialization assert — a programming-error
    // diagnostic, never rendered.
    "'Legacy (v1) workspace document serialized before migration; '",
    "'migrate to favorites before saving.'",
  },
  // The settings.json key the workspace list document lives under
  // (02 §3 — separate from the auto-session key by design).
  'lib/services/workspace_list_store.dart': {"'workspaces.saved'"},
  // The disposed-use diagnostics — the strip's assert-message posture —
  // plus the endpoint literals: '~' is a launcher pane's recorded
  // endpoint (the bookmark schema requires a path), '/' the remote-path
  // floor a corrupt relative path clamps to, and the synthesized
  // endpoint bookmark's namespaced id — machine data, never rendered.
  'lib/services/workspace_library.dart': {
    "'save on a disposed WorkspaceLibrary'",
    "'recapture on a disposed WorkspaceLibrary'",
    // The load-before-mutate ordering asserts — programming-error
    // diagnostics, never rendered.
    "'save before WorkspaceLibrary.load() completed'",
    "'recapture before WorkspaceLibrary.load() completed'",
    "'markOpened before WorkspaceLibrary.load() completed'",
    "'~'",
    "'/'",
    // The placeholder tab's empty filter seed — a starting value, not
    // copy.
    "''",
    r"'${workspace.id}:$paneId'",
    // The blank-label ArgumentError's name and reason — a programming-
    // error diagnostic, never rendered.
    "'label'",
    "'must not be blank'",
  },
  // The save dialog's name-field widget key — plumbing, not copy.
  'lib/ui/workspace/save_workspace_dialog.dart': {"'workspaceSave.name'"},
  // The General dialog's keys/toggle key — plumbing for tests, never
  // rendered.
  'lib/ui/settings/general_settings.dart': {
    "'general.settings.dialog'",
    "'general.settings.close'",
    "'updates.checkEnabled'",
  },
  // The Settings command id (D21 plumbing) — registered, never rendered.
  // Its construction assert is a programmer diagnostic.
  'lib/ui/settings/app_settings_command.dart': {
    "'app.settings'",
    "'Settings needs a section to show.'",
  },
  // The Appearance section's empty font field and the pretty-printed
  // clipboard's indent, and the font field's test key: plumbing, never
  // rendered. Preset names reach the screen through ARB (presetLabels).
  'lib/ui/settings/appearance_settings.dart': {
    "''",
    "'  '",
    "'appearance.fontFamily'",
  },
  // A theme's stored form, shared with Séance so a copied theme pastes
  // into either app: its JSON keys, the hex notation's prefixes and
  // glue, and the stored name of a palette that is no preset. The
  // Appearance section never shows the stored name (see presetLabels).
  'lib/theme/theme_palette.dart': {
    "'#'",
    "'0x'",
    "''",
    r"'$digit$digit'",
    r"r'^[0-9a-f]+$'",
    "'0'",
    r"'$rgb${alpha.toRadixString(16).padLeft(2, '0')}'",
    r"'#${hex.toUpperCase()}'",
    "'Custom'",
    "'name'",
    "'accent'",
    "'fontFamily'",
    "'cornerScale'",
  },
  // The presets' stored names: English and the same as Séance's, so a
  // pasted preset keeps its name in either app. Shown through ARB
  // (themePreset*), never as these literals.
  'lib/theme/theme_presets.dart': {
    "'Poltergeist'",
    "'Graphite'",
    "'Paper'",
    "'Newsprint'",
    "'Solarized'",
    "'Midnight'",
    "'Terminal'",
    "'Vapor'",
    "'Bubblegum'",
    "'High contrast'",
  },
  // The Settings window's wire (D36): channel names, the argument its
  // engine starts with, and the diagnostics of a malformed or orphaned
  // call — plumbing between two isolates, never rendered. A window that
  // loses the app renders ARB copy instead (settingsWindowUnreachable).
  'lib/services/settings_window/settings_window_link.dart': {
    "'poltergeist/settings_window'",
    "'poltergeist/settings_link'",
    "'--poltergeist-settings-window'",
    // What the failed call printed, carried to the window verbatim, as
    // the dialog shows it.
    r"'$error'",
  },
  'lib/services/settings_window/settings_window_host.dart': {
    r"'No Settings window method ${call.method}'",
    r"'${method.name} goes to the window'",
    "'This section is not available.'",
  },
  'lib/services/settings_window/remote_settings.dart': {
    r"'No Settings window method ${call.method}'",
    "'Settings link closed'",
  },
  // 10 §8's platform-row command ids (D21 plumbing), never rendered.
  'lib/ui/menus/app_menu_commands.dart': {
    "'app.checkForUpdates'",
    "'app.quit'",
  },
  // The workspace command ids (D21 plumbing) — the open commands key
  // per-record to the persisted workspace id.
  'lib/ui/workspace/workspace_commands.dart': {
    "'workspace.save'",
    "'workspace.open.empty'",
    r"'workspace.open.${saved.id}'",
  },
  // Ported Séance contracts (see docs/PORTS.md): the exception messages are
  // frozen port text, kept byte-identical to the source. D20 localization
  // applies where the UI renders them (the prompt-UI slice), not here.
  'lib/services/secure_master_key.dart': {
    r"'Saved secrets are unavailable: the OS keyring is locked '",
    r"'or missing. Unlock the login keyring (or install gnome-keyring), '",
    r"'then retry.'",
    r"'poltergeist.vault.masterKey.v1'",
    r"'poltergeist.apikey.$name'",
    r"'${e.code} — $msg'",
    r"'the vault master key'",
    r"'the $name key'",
    r"'Could not save $what to the OS keyring (${_describe(e)}). Unlock '",
    r"'the login keyring or install gnome-keyring, then try again.'",
  },
  // Ported Séance vault/rekey-journal format (see docs/PORTS.md): the
  // document keys, journal file suffix, and thrown diagnostics are the
  // frozen on-disk format and reported faults, never rendered UI copy.
  'lib/services/file_stores.dart': {
    "'-'",
    "''",
    "':'",
    "'.'",
    r"'${file.path}.corrupt-$stamp'",
    r"'$host:$port'",
    r"'${file.path}.rekey'",
    "'version'",
    "'snapshots'",
    "'blobs'",
    "'Expected a vault map.'",
    "'Invalid vault map entry.'",
    "'Invalid vault recovery journal.'",
    "'Finish vault recovery before changing credentials.'",
    "'A pending vault recovery must be completed first.'",
    "'No matching snapshot.'",
  },
  'lib/services/settings_store.dart': {
    "'settings root'",
    "'settings key'",
    r"'$path.corrupt-$stamp'",
    "'.'",
    "'-'",
    "''",
    "':'",
  },
  // 04 §4.5's keystore/settings key names and the persisted account-field
  // names — machine identifiers, never rendered UI copy.
  'lib/services/sync_credentials.dart': {
    "'sync.token'",
    "'sync.token.retained.v1'",
    "'poltergeist.sync.deviceId'",
    "'poltergeist.sync.passphraseUnverified'",
    "'poltergeist.sync.notices'",
    "'poltergeist.sync.account'",
    r"'$entry'",
    "'baseUrl'",
    "'username'",
    "'mode'",
  },
  // The recorded Séance release tag — a machine fact interpolated into
  // ARB copy at the render site, never authored text.
  'lib/services/sync_account_gate.dart': {"'v0.9.0'"},
  // The URL-scheme whitelist of the ported validator — grammar literals,
  // not copy.
  'lib/services/sync_enrollment_validation.dart': {
    "'http'",
    "'https'",
    // The confirmation field's empty default — a missing-argument value,
    // not rendered copy.
    "''",
  },
  // The settings.json keys behind the §3.2 verdict stores — machine
  // identifiers, never rendered UI copy.
  'lib/services/sync_verdict_stores.dart': {
    "'poltergeist.sync.negativePins'",
    "'poltergeist.sync.keptPinVerdicts'",
    "'poltergeist.sync.tripwireIds'",
    r"'$entry'",
  },
  // The rsync export seam's `Platform.operatingSystem` id — machine
  // data compared, never rendered.
  'lib/services/rsync_endpoints.dart': {"'windows'"},
  // The §3.3 status keys, the §4.4 retained-account record's field
  // names, and the programmer-error diagnostics (missing token, wrong
  // mode, failed typed confirmation) — machine data and reported
  // faults, never authored copy.
  'lib/services/bookmark_backup_service.dart': {
    "'poltergeist.sync.lastSyncAt'",
    "'poltergeist.sync.lastSyncError'",
    "'poltergeist.sync.retainedAccount'",
    "'poltergeist.sync.switchSynced'",
    "'poltergeist.sync.syncSecrets'",
    "'baseUrl'",
    "'username'",
    r"'$error'",
    "'enrolled without a session token'",
    "'enrolled without a readable vault key'",
    "'account deletion exists only in separate mode'",
    "'typed confirmation must equal the account name'",
    "'the switch requires a separate-mode account'",
    "'a backup round is in flight'",
    "'no retained separate account'",
    "'retained account without a retained token'",
    "'not enrolled — cannot resolve a pin conflict'",
    // The shared-mode vault precondition faults — reported programmer/
    // state errors, never rendered copy.
    "'the vault is unavailable — cannot save secrets'",
    "'the vault is unavailable — cannot duplicate servers'",
  },
  'lib/theme/app_theme.dart': {
    "'JetBrains Mono'",
    "'SF Mono'",
    "'Menlo'",
    "'Consolas'",
    "'DejaVu Sans Mono'",
    "'monospace'",
  },
  // Ported Séance JSONL record shape (see docs/PORTS.md): the field names
  // and separators are the frozen on-disk format, not UI copy.
  'lib/services/identity_audit_log.dart': {
    "'at'",
    "'serverId'",
    "'serverLabel'",
    "'path'",
    "'viaBookmark'",
    "'ok'",
    "'error'",
    "''",
    "'\${jsonEncode(event.toJson())}\\n'",
    "'\${kept.join('\\n')}\\n'",
    "'\\n'",
  },
  // Exception texts and audit-record fields — machine-facing data the
  // dialog renders inside an ARB-authored sentence, never standalone UI
  // copy (the reader's wording mirrors Séance's).
  'lib/services/identity_file_reader.dart': {
    "'\$_causeMessage (\$path)'",
    "'Could not read identity file \$path: \$_causeMessage'",
  },
  'lib/services/prompt_coordinator.dart': {
    "'No identity-file reader is wired'",
    "'\${data.username}@\${data.host}'",
  },
  // Monospace rendering of machine data (fingerprints, endpoints,
  // transcripts) plus list joins — no authored copy.
  'lib/ui/connection_status_panel.dart': {"'\\n'", "'monospace'"},
  'lib/ui/prompts/credential_dialog.dart': {"''", "'monospace'"},
  // Monospace rendering of machine data (endpoints, identity paths) plus
  // null-fallbacks for optional labels — no authored copy.
  'lib/ui/import/ssh_config_import_dialog.dart': {
    "''",
    "'monospace'",
    r"'${row.host.effectiveHost}:${row.port}'",
  },
  'lib/ui/prompts/host_key_dialog.dart': {"'monospace'", "'\$type\\n\$value'"},
  'lib/ui/adaptive_shell.dart': {
    "'primary-pane'",
    "'secondary-pane'",
    "'pane-splitter'",
  },
  'lib/ui/layout/pane_allocation.dart': {
    "'width'",
    "'must be finite and non-negative'",
    "'ratio'",
    "'must be finite'",
  },
  // The ported syntax engine's grammar literals (06 §2.2, ported from
  // Séance's editor_syntax.dart @ 2e6d1f1): language ids, keyword sets,
  // comment/string delimiters, regex patterns, and the extension/basename
  // detection maps — tokenizer data, never rendered UI copy. Generated
  // mechanically by scanning the file with the same analyzer pass this
  // gate runs; regenerated on any §7 language addition.
  'lib/ui/editor_syntax.dart': {
    '"\'"',
    '"\'\'\'"',
    '\'"""\'',
    '\'"\'',
    '\'#!\'',
    '\'#\'',
    '\'*/\'',
    '\'--\'',
    '\'-->\'',
    '\'--[[\'',
    '\'.\'',
    '\'.bash_aliases\'',
    '\'.bash_logout\'',
    '\'.bash_profile\'',
    '\'.bashrc\'',
    '\'.dockerfile\'',
    '\'.dockerignore\'',
    '\'.editorconfig\'',
    '\'.gitconfig\'',
    '\'.gitignore\'',
    '\'.gitmodules\'',
    '\'.htaccess\'',
    '\'.htpasswd\'',
    '\'.npmrc\'',
    '\'.profile\'',
    '\'.zprofile\'',
    '\'.zshenv\'',
    '\'.zshrc\'',
    '\'/\'',
    '\'/*\'',
    '\'//\'',
    '\'0X\'',
    '\'0x\'',
    '\';\'',
    '\'<!--\'',
    '\'BEGIN\'',
    '\'END\'',
    '\'False\'',
    '\'None\'',
    '\'SyntaxToken(\$start, \$end, \${type.name})\'',
    '\'True\'',
    '\'[[\'',
    '\'\\n\'',
    '\']]\'',
    '\'`\'',
    '\'```\'',
    '\'abstract\'',
    '\'add\'',
    '\'alias\'',
    '\'all\'',
    '\'alter\'',
    '\'and\'',
    '\'arg\'',
    '\'as\'',
    '\'assert\'',
    '\'async\'',
    '\'attr_accessor\'',
    '\'attr_reader\'',
    '\'attr_writer\'',
    '\'authorized_keys\'',
    '\'auto\'',
    '\'await\'',
    '\'base\'',
    '\'bash\'',
    '\'begin\'',
    '\'between\'',
    '\'bless\'',
    '\'bool\'',
    '\'break\'',
    '\'bun\'',
    '\'by\'',
    '\'c\'',
    '\'c-family\'',
    '\'caller\'',
    '\'case\'',
    '\'catch\'',
    '\'cc\'',
    '\'cd\'',
    '\'cfg\'',
    '\'chan\'',
    '\'char\'',
    '\'charset\'',
    '\'chomp\'',
    '\'chop\'',
    '\'cjs\'',
    '\'class\'',
    '\'close\'',
    '\'cmd\'',
    '\'cmp\'',
    '\'commit\'',
    '\'conf\'',
    '\'config\'',
    '\'config.ru\'',
    '\'const\'',
    '\'constraint\'',
    '\'containerfile\'',
    '\'continue\'',
    '\'copy\'',
    '\'covariant\'',
    '\'cpp\'',
    '\'crate\'',
    '\'create\'',
    '\'crontab\'',
    '\'cs\'',
    '\'css\'',
    '\'cxx\'',
    '\'dart\'',
    '\'declare\'',
    '\'def\'',
    '\'default\'',
    '\'defer\'',
    '\'defined\'',
    '\'del\'',
    '\'delete\'',
    '\'deno\'',
    '\'desktop\'',
    '\'die\'',
    '\'distinct\'',
    '\'do\'',
    '\'dockerfile\'',
    '\'dockerfile.\'',
    '\'done\'',
    '\'double\'',
    '\'drop\'',
    '\'dynamic\'',
    '\'each\'',
    '\'echo\'',
    '\'elif\'',
    '\'else\'',
    '\'elseif\'',
    '\'elsif\'',
    '\'end\'',
    '\'ensure\'',
    '\'entrypoint\'',
    '\'enum\'',
    '\'env\'',
    '\'eq\'',
    '\'error\'',
    '\'esac\'',
    '\'eval\'',
    '\'except\'',
    '\'exec\'',
    '\'exists\'',
    '\'exit\'',
    '\'export\'',
    '\'expose\'',
    '\'extend\'',
    '\'extends\'',
    '\'extension\'',
    '\'external\'',
    '\'factory\'',
    '\'false\'',
    '\'fi\'',
    '\'final\'',
    '\'finally\'',
    '\'float\'',
    '\'fn\'',
    '\'for\'',
    '\'foreach\'',
    '\'foreign\'',
    '\'from\'',
    '\'fstab\'',
    '\'func\'',
    '\'function\'',
    '\'ge\'',
    '\'gemfile\'',
    '\'gemspec\'',
    '\'get\'',
    '\'getmetatable\'',
    '\'global\'',
    '\'gnumakefile\'',
    '\'go\'',
    '\'goto\'',
    '\'grant\'',
    '\'grep\'',
    '\'group\'',
    '\'gt\'',
    '\'h\'',
    '\'having\'',
    '\'healthcheck\'',
    '\'hh\'',
    '\'hosts\'',
    '\'hpp\'',
    '\'htm\'',
    '\'html\'',
    '\'if\'',
    '\'impl\'',
    '\'implements\'',
    '\'import\'',
    '\'important\'',
    '\'in\'',
    '\'include\'',
    '\'index\'',
    '\'inherit\'',
    '\'ini\'',
    '\'initial\'',
    '\'inner\'',
    '\'insert\'',
    '\'instanceof\'',
    '\'int\'',
    '\'interface\'',
    '\'into\'',
    '\'ipairs\'',
    '\'is\'',
    '\'java\'',
    '\'javascript\'',
    '\'join\'',
    '\'js\'',
    '\'json\'',
    '\'jsonc\'',
    '\'jsx\'',
    '\'key\'',
    '\'keyframes\'',
    '\'keys\'',
    '\'known_hosts\'',
    '\'ksh\'',
    '\'kt\'',
    '\'kts\'',
    '\'label\'',
    '\'lambda\'',
    '\'last\'',
    '\'late\'',
    '\'le\'',
    '\'left\'',
    '\'less\'',
    '\'let\'',
    '\'library\'',
    '\'like\'',
    '\'limit\'',
    '\'local\'',
    '\'long\'',
    '\'lt\'',
    '\'lua\'',
    '\'maintainer\'',
    '\'makefile\'',
    '\'map\'',
    '\'markdown\'',
    '\'match\'',
    '\'md\'',
    '\'media\'',
    '\'mixin\'',
    '\'mjs\'',
    '\'mod\'',
    '\'module\'',
    '\'mut\'',
    '\'my\'',
    '\'namespace\'',
    '\'ne\'',
    '\'new\'',
    '\'next\'',
    '\'nil\'',
    '\'no\'',
    '\'node\'',
    '\'none\'',
    '\'nonlocal\'',
    '\'not\'',
    '\'null\'',
    '\'nullptr\'',
    '\'of\'',
    '\'off\'',
    '\'offset\'',
    '\'on\'',
    '\'onbuild\'',
    '\'open\'',
    '\'operator\'',
    '\'or\'',
    '\'order\'',
    '\'our\'',
    '\'outer\'',
    '\'override\'',
    '\'package\'',
    '\'page\'',
    '\'pairs\'',
    '\'part\'',
    '\'pass\'',
    '\'pcall\'',
    '\'perl\'',
    '\'php\'',
    '\'pl\'',
    '\'plist\'',
    '\'pm\'',
    '\'pop\'',
    '\'primary\'',
    '\'print\'',
    '\'private\'',
    '\'proc\'',
    '\'properties\'',
    '\'protected\'',
    '\'pub\'',
    '\'public\'',
    '\'push\'',
    '\'puts\'',
    '\'py\'',
    '\'python\'',
    '\'pyw\'',
    '\'raise\'',
    '\'rake\'',
    '\'rakefile\'',
    '\'range\'',
    '\'rawequal\'',
    '\'rawget\'',
    '\'rawset\'',
    '\'rb\'',
    '\'read\'',
    '\'readonly\'',
    '\'redo\'',
    '\'ref\'',
    '\'references\'',
    '\'repeat\'',
    '\'require\'',
    '\'require_relative\'',
    '\'required\'',
    '\'rescue\'',
    '\'rethrow\'',
    '\'retry\'',
    '\'return\'',
    '\'revert\'',
    '\'revoke\'',
    '\'right\'',
    '\'rollback\'',
    '\'rs\'',
    '\'ruby\'',
    '\'run\'',
    '\'say\'',
    '\'scala\'',
    '\'scalar\'',
    '\'scss\'',
    '\'sealed\'',
    '\'select\'',
    '\'self\'',
    '\'service\'',
    '\'set\'',
    '\'setmetatable\'',
    '\'sh\'',
    '\'shell\'',
    '\'shift\'',
    '\'short\'',
    '\'show\'',
    '\'signed\'',
    '\'socket\'',
    '\'sort\'',
    '\'source\'',
    '\'splice\'',
    '\'sql\'',
    '\'ssh_config\'',
    '\'sshd_config\'',
    '\'static\'',
    '\'stopsignal\'',
    '\'struct\'',
    '\'sub\'',
    '\'super\'',
    '\'supports\'',
    '\'svg\'',
    '\'swift\'',
    '\'switch\'',
    '\'sync\'',
    '\'table\'',
    '\'template\'',
    '\'test\'',
    '\'then\'',
    '\'this\'',
    '\'throw\'',
    '\'throws\'',
    '\'tie\'',
    '\'time\'',
    '\'timer\'',
    '\'toml\'',
    '\'tonumber\'',
    '\'tostring\'',
    '\'trait\'',
    '\'transaction\'',
    '\'trap\'',
    '\'true\'',
    '\'try\'',
    '\'ts\'',
    '\'tsx\'',
    '\'type\'',
    '\'typedef\'',
    '\'typename\'',
    '\'typeof\'',
    '\'undef\'',
    '\'undefined\'',
    '\'union\'',
    '\'unique\'',
    '\'unless\'',
    '\'unpack\'',
    '\'unset\'',
    '\'unshift\'',
    '\'unsigned\'',
    '\'until\'',
    '\'update\'',
    '\'use\'',
    '\'user\'',
    '\'using\'',
    '\'values\'',
    '\'var\'',
    '\'view\'',
    '\'virtual\'',
    '\'void\'',
    '\'volume\'',
    '\'wantarray\'',
    '\'warn\'',
    '\'when\'',
    '\'where\'',
    '\'while\'',
    '\'with\'',
    '\'workdir\'',
    '\'xhtml\'',
    '\'xml\'',
    '\'xor\'',
    '\'xpcall\'',
    '\'yaml\'',
    '\'yes\'',
    '\'yield\'',
    '\'yml\'',
    '\'zsh\'',
    'r\'([-a-zA-Z]+)[ \\t]*:\'',
    'r\'</?[A-Za-z][A-Za-z0-9:._-]*\'',
    'r\'\\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?\'',
    'r\'\\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?|\\\$[0-9@#?*!\$-]\'',
    'r\'\\b(sh|bash|zsh|ksh|dash|ash)\\b\'',
    'r\'\\blua(?:5\\.[1-4]|jit)?\\b\'',
    'r\'\\bperl\\b\'',
    'r\'\\bruby\\b\'',
    'r\'^#{1,6}[ \\t].*\$\'',
    'r\'^[ \\t]*(?:-[ \\t]+)*([^\\s#-][^:\\n]*?)[ \\t]*:(?=[ \\t]|\$)\'',
    'r\'^[ \\t]*\\[[^\\]\\n]+\\]\'',
  },
  // The pane ids and focus-node labels key to the engine's paneTabId
  // channel identity (03 §3.2) — widget plumbing, not authored copy.
  'lib/ui/workspace_shell.dart': {
    "'connectionEngine is ignored when engineSession is provided'",
    "'pane.left.listing'",
    "'pane.right.listing'",
    // The sidebar region's widget key plus the open-path diagnostics —
    // reported faults and machine data, never rendered copy.
    "'sidebar.region'",
    r"'sidebar.open: localFolder ${bookmark.id} has no path'",
    r"'sidebar.open: savedSync ${bookmark.id} has no spec'",
    // The catalog open path's unresolved-serverConfigId diagnostic and
    // the transient bookmark's empty sort key — reported fault and
    // machine data, never rendered copy.
    r"'sidebar.open: serverConfigId ${ref.serverConfigId} '",
    "'resolves to no pulled server'",
    "''",
    // The D32 chrome's widget keys and focus-node labels (splitters,
    // inspector mounts, header title/filter, the connect dialog) and the reveal-in-pane's missing-bookmark diagnostic —
    // plumbing and a reported fault, never rendered copy.
    "'sidebar.splitter'",
    "'inspector.splitter'",
    "'inspector.overlay'",
    "'inspector.region'",
    "'header.title'",
    "'header.filter'",
    r"'revealInPane: no bookmark for $serverId'",
    // The header title's address grammar (10 §4): the `user@host`
    // subtitle and the `user@host:path` / `label:path` tooltip —
    // machine data like the sidebar's addresses.
    r"'${identity.username}@${identity.host}'",
    r"'${identity.username}@${identity.host}:${loc.path}'",
    r"'${bookmark.label}:${loc.path}'",
    // The confirm dialog's bullet list marker — typographic, not copy.
    r"'• ${tabCloseTriggerLabel(l10n, trigger)}'",
    // The Connect dialog rows' endpoint grammar (`user@host:port`) —
    // machine data, like the header subtitle's.
    r"'$host:$port'",
    r"'$user@$address'",
    // The built-in editor's route keys (06 §4.2) and the reported
    // wiring fault — machine data and a dev-facing diagnostic, never
    // rendered copy (the toast is the ARB string).
    r"'local:${file.absolute.path}'",
    r"'local:${resolved.absolute.path}'",
    r"'remote:${record.serverId}:${record.remotePath}'",
    "'remote edit reached without a checkout session'",
    "'remote edit upload reached without a checkout session'",
    // The §3.3 dirty-prompt's in-flight upload key (serverId|remotePath)
    // and the external-open diagnostics — wiring faults that only reach
    // the error reporter plus typed-error copy surfaced verbatim, the
    // same posture as RemoteFileException messages.
    r"'${record.serverId}|${record.remotePath}'",
    "'The selected editor no longer exists.'",
    "'open-with reached without a configured editor registry'",
    "'remote open-with reached without a checkout session'",
    "'remote open reached without a checkout session'",
    // The extension-binding key's basename arithmetic — path mechanics.
    r"'\\'",
    "'/'",
    "'.'",
    // The duplicate-server failure toast interpolates the error verbatim —
    // the SourceServerChanged sentence is upstream-authored English surfaced
    // like RemoteFileException messages.
    r"'$error'",
  },
  // The built-in editor's document-structure literals — the text field's
  // empty initial value and the newline joiners/splitters are plumbing,
  // never rendered copy. 'Aa' is the universal match-case glyph (Séance
  // carries the same literal); its accessible name is the ARB tooltip
  // editorMatchCaseTooltip, so translating the glyph itself would be
  // wrong.
  'lib/ui/editor_checkout_upload.dart': {
    r"'${copy.serverId}|${copy.remotePath}'",
  },
  'lib/ui/built_in_text_editor.dart': {
    "'window.new'",
    "'editor.save'",
    "'editor.close'",
    "'editor.find'",
    "'editor.undo'",
    "'editor.redo'",
    "'editor.cut'",
    "'editor.copy'",
    "'editor.paste'",
    "'editor.selectAll'",
    "''",
    "'\\n'",
    "'Aa'",
  },
  // The workspace controller's debug assert message — a dev-facing
  // invariant, never rendered.
  'lib/services/workspace_controller.dart': {
    "'Workspace panes must be distinct PaneTabsController instances.'",
    "'Active pane must be one of this workspace\\'s panes.'",
    "'source strip refused to re-home a detached tab'",
  },
  // The tab strip's engine-channel id arithmetic and its fail-closed
  // guard diagnostic — machine data, never rendered UI copy.
  'lib/services/pane_tabs_controller.dart': {
    r"'$paneId.tab${_nextTabOrdinal++}'",
    "'tab close guard fired with no presenter wired'",
    "'tab replacement guard fired with no presenter wired'",
    "'workspace pane state must match the strip it lands on'",
    "'state.paneId'",
    "'newTab on a disposed PaneTabsController'",
    "'addTab on a disposed PaneTabsController'",
    "'restoreSession on a disposed PaneTabsController'",
    "'openSyncPlanTab on a disposed PaneTabsController'",
  },
  // The pane controller's machine data: the home anchor the engine
  // expands, the dotfile filter prefix, the root path, the taxonomy
  // operations. Non-VFS faults carry a machine sentinel message
  // ('fault:<kind>', never rendered — the view maps the typed fault to
  // ARB copy per D20).
  'lib/services/pane_controller.dart': {
    // Loss uses a localized banner; the typed error has no raw diagnostic.
    "''",
    "'row keys out of sync with entries'",
    "'reconnect'",
    "'~'",
    "'.'",
    "'/'",
    "'connect'",
    "'open'",
    "'list'",
    // The rename commit's operation tag and its path arithmetic — the
    // engine's operation label and machine path data, never UI copy.
    "'rename'",
    r"'$base$baseSeparator'",
    r"'$parent$raw'",
    "'fault:\${fault.name}'",
    // The U+FFFD flagged-name signal Quick Select excludes from matching
    // — a byte-level literal, never rendered (02 §13).
    r"'\uFFFD'",
    // Debug-only invariant messages — never rendered.
    "'_loweredNames out of sync with _listing — assign via _setListing'",
    // The create verbs' operation tags and path arithmetic (02 §8.3's
    // file.newFolder / file.newFile) — the engine's operation labels and
    // machine path data, never UI copy.
    "'create directory'",
    "'create file'",
    r"'${location.path}$separator'",
    r"'$parent$candidate'",
    r"'$parent$baseName'",
  },
  // The bridged lease's config source: the resolve operation tag and the
  // sync-endpoint serverId scheme — machine identifiers, never UI copy
  // (the catalog-miss message itself is ARB).
  'lib/services/server_config_source.dart': {
    "'resolve server'",
    "'sync-endpoint:'",
    r"'$_syncServerIdPrefix$catalogId'",
    r"'$_syncServerIdPrefix${identity!.username}@${identity.host}:'",
    r"'${identity.port}'",
  },
  // The location type's value semantics: toString output for debugging
  // and the path-separator arithmetic (POSIX and Windows forms).
  'lib/services/pane_location.dart': {
    "''",
    "'\\\\'",
    "'\\\\\\\\'",
    "'/'",
    "':'",
    r"'$trimmed\\'",
    r"'$parent\\'",
    "'LocalPaneLocation(\$path)'",
    "'RemotePaneLocation(\$serverId, \$path)'",
  },
  // The sync link's path arithmetic: relative-tail joins under the two
  // anchors — machine data, never authored copy.
  'lib/services/sync_browsing_controller.dart': {
    r"'$anchor$separator'",
    r"'$anchor${rel.join(separator)}'",
    r"'$anchor$separator${rel.join(separator)}'",
  },
  // The sync environment's machine literals: the sync_runs directory
  // name and its path joins under app support, the RemoteFileException
  // operation name, and the remote-endpoint refusal detail — the plan
  // view renders the ARB unsupported state for the error kind, never
  // this message. Plumbing, never authored copy.
  'lib/services/sync_environment.dart': {
    "'sync_runs'",
    r"'$supportDirectoryPath${Platform.pathSeparator}'",
    r"'$kSyncStateDirectoryName'",
    r"'$kSyncRunsDirectoryName'",
    "'sync endpoint'",
    "'remote sync endpoints are not available yet'",
  },
  // The plan controller's machine literals: the 'local' device-id
  // default, §9's heavy-suggestion noise names + glob join, the
  // relative-path separator split, and the ServerFsLocation fallback
  // id for a config-less remote ref — plumbing and machine data, never
  // authored copy.
  'lib/services/sync_plan_controller.dart': {
    "'local'",
    r"'**/$name/'",
    "'node_modules'",
    "'.git'",
    "'build'",
    "'target'",
    "'__pycache__'",
    "'/'",
    "'remote'",
  },
  // The facade matches the executor's machine error sentinel to pick
  // the cancelled item state — protocol plumbing, never authored copy.
  'lib/services/sync_queue_facade.dart': {"'Cancelled'"},
  // The sync_state store's directory name and per-pair file-path join
  // under app support — machine paths, never authored copy.
  'lib/services/sync_state_store.dart': {
    "'sync_state'",
    r"'${directory.path}${Platform.pathSeparator}$pairId.json'",
  },
  // The inline-rename validator's grammar literals: the path separator
  // and the NTFS forbidden-character class — machine data, never
  // authored copy.
  'lib/services/pane_rename.dart': {
    "'/'",
    "'.'",
    "' '",
    'r\'[<>:"\\\\|?*]\'',
    r"r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'",
  },
  // The path-field resolver's grammar literals: separator characters,
  // drive-spec regexes, tilde forms, and dot segments — machine data,
  // never authored copy.
  'lib/services/pane_path_input.dart': {
    "r'^[A-Za-z]:'",
    r"r'^[A-Za-z]:$'",
    "''",
    "'~'",
    "'~/'",
    r"'~\\'",
    "'/'",
    r"'\\'",
    r"'\\\\'",
    "'.'",
    "'..'",
    r"'${win[0]}:\\'",
    r"'${rawSegments[0]}\\'",
    r"'$stem$separator$child'",
    r"'$prefix${segments.join(separator)}'",
  },
  // Menu-row widget keys keyed to the registry's command/menu ids —
  // widget plumbing, not authored copy.
  'lib/ui/menus/app_menu_host.dart': {
    r"'menu.${menu.id.name}'",
    r"'menu.item.${command.id}'",
    "'menu.main'",
  },
  // Debug-only placement-slot invariant diagnostics — never rendered.
  'lib/ui/menus/app_menus.dart': {
    "'commands reach the macOS application menu via appMenuOnMac'",
    r"'${p.group}:${p.order}'",
    r"'${command.id} shares menu slot ${p.group}:${p.order}'",
  },
  // The pane-command registry ids (D21 plumbing) and the pane view's
  // widget keys plus path-separator arithmetic — machine data, never
  // authored copy.
  'lib/ui/panes/pane_commands.dart': {
    "'go.back'",
    "'go.editPath'",
    "'go.enclosing'",
    "'go.forward'",
    "'go.home'",
    "'go.open'",
    "'go.toFolder'",
    "'file.editBuiltIn'",
    "'file.rename'",
    "'file.getInfo'",
    "'view.refresh'",
    "'pane.focusLeft'",
    "'pane.focusRight'",
    "'pane.swapFocus'",
    "'edit.undoSelection'",
    "'edit.redoSelection'",
    "'edit.selectAll'",
    "'edit.invertSelection'",
    "'selection.quickSelect'",
    "'view.filter'",
    "'view.toggleSecondPane'",
    "'view.toggleSidebar'",
    "'view.toggleActivityPanel'",
    "'view.toggleSyncBrowsing'",
    // The M7 preview commands (06 §5.3/D21): command ids, never rendered.
    "'file.preview'",
    "'view.togglePreview'",
    "'tab.new'",
    "'tab.close'",
    "'tab.reopenClosed'",
    "'tab.next'",
    "'tab.previous'",
    // D32's view.toggleHidden and selection.copyPath ids, and the
    // newline that joins several copied paths — machine data.
    "'view.toggleHidden'",
    "'selection.copyPath'",
    "'view.sortBy'",
    r"'$kViewSortByCommandId:${key.name}'",
    r"'\n'",
    r"'Duplicate shortcut activator $activator: later command wins'",
  },
  // The tab strip's widget keys and pane-id name lookup — widget plumbing
  // keyed to the engine's paneTabId identity, never authored copy.
  'lib/ui/panes/pane_tabs_view.dart': {
    r"'${tabs.paneId}.tab.new'",
    r"'${tab.id}.close'",
    // The drag-insertion indicator's widget key — plumbing, not copy.
    "'pane.tabDropIndicator'",
    // The entry-drop wrapper's reorder key — plumbing, not copy.
    r"'entry-drop-${tab.id}'",
    // D32's active-pane marker and the tab menu's row keys — plumbing
    // keyed to the strip and tab ids, never authored copy.
    r"'${tabs.paneId}.activeIndicator'",
    r"'${tabs.paneId}.stripSeparator'",
    r"'${tab.id}.menu.close'",
    r"'${tab.id}.menu.closeOthers'",
    r"'${tab.id}.menu.duplicate'",
    r"'${tab.id}.menu.moveToOtherPane'",
    r"'${tab.id}.menu.copyPath'",
    // Root-path fallback in the remote tooltip — path data, not copy.
    "'/'",
    // The sync tab's endpoint tooltip plumbing: the pair's two paths
    // joined by the sync glyph and the config-less remote ref's
    // fallback id — machine data inside a tooltip, never authored copy.
    r"'${_endpointTooltip(session.pair.left)} ⇄ '",
    r"'${_endpointTooltip(session.pair.right)}'",
    r"'${server.identity?.host ?? server.serverConfigId ?? 'remote'}:$path'",
    "'remote'",
  },
  'lib/ui/panes/pane_view.dart': {
    "'pane.error.retry'",
    "'pane.error.cancel'",
    "'pane.banner'",
    "'pane.banner.cancel'",
    "'pane.banner.retry'",
    "'pane.reconnectBar'",
    "'pane.reconnectBar.reconnect'",
    "'pane.connect.cancel'",
    "'pane.typeAhead'",
    // The save bar's adhoc-keyed widget key — plumbing, not copy.
    r"'saveFavorite.${adhoc.id}'",
    r"'${controller.paneTabId}.path'",
    r"'${controller.paneTabId}.cancel'",
    r"'${controller.paneTabId}.progress'",
    r"'${widget.controller.paneTabId}.quickSelect.field'",
    r"'${widget.controller.paneTabId}.rename.field'",
    // The rename editor's box key and the single space it measures an
    // empty name by — plumbing, never copy.
    r"'${widget.controller.paneTabId}.rename.box'",
    "' '",
    r"'${widget.controller.paneTabId}.path.field'",
    // D32 §6's location-header keys: the name, the summary line, and
    // the ancestor menu with its rows — plumbing, never copy.
    r"'${controller.paneTabId}.path.name'",
    r"'${controller.paneTabId}.path.summary'",
    r"'${controller.paneTabId}.path.ancestors'",
    r"'${controller.paneTabId}.path.ancestor.$i'",
    r"'${controller.paneTabId}.filter.emptyClear'",
    r"'${controller.paneTabId}.notice.dismiss'",
    r"'${controller.paneTabId}.syncChip'",
    "''",
    // The rename editor's stem-selection dot — name arithmetic, not copy.
    "'.'",
  },
  // D32 §6's column header keys — plumbing keyed to the tab id and the
  // sort key's enum name, never authored copy.
  'lib/ui/panes/pane_column_header.dart': {
    r"'$paneTabId.columns'",
    r"'$paneTabId.column.${key.name}'",
  },
  // The context menu's row keys — registry plumbing, never copy.
  'lib/ui/panes/pane_context_menu.dart': {
    r"'pane.context.${command.id}'",
  },
  // The missing-mirror cause's empty-name fallback — a null-safety
  // placeholder, never rendered as copy.
  'lib/ui/panes/sync_browse_chip.dart': {"''"},
  // Byte-unit table, the unevaluated dash, and the trailing-".0" trim
  // — technical formatting (02 §2.3 rendering rules).
  'lib/ui/panes/pane_format.dart': {
    "'B'",
    "'KB'",
    "'MB'",
    "'GB'",
    "'TB'",
    "'—'",
    "'.0'",
    r"'$bytes ${_byteUnits[0]}'",
    r"'$text ${_byteUnits[unit]}'",
    // The octal pad's fill character — formatting mechanics, not copy.
    "'0'",
    // The kind-glyph classifier's extension tables, their separator,
    // and the extension dot — file-name machine data, never rendered.
    "'png jpg jpeg gif webp bmp tif tiff heic heif svg ico avif psd raw'",
    "'txt md markdown rst log csv tsv rtf doc docx odt pages xls xlsx ods '",
    "'numbers ppt pptx odp epub'",
    "'json yaml yml toml xml html htm css scss js mjs ts jsx tsx dart py rb '",
    "'go rs java kt swift c h cc cpp hpp'",
    "'m mm cs php sh bash zsh fish ps1 bat sql ini conf cfg env lock'",
    "'zip tar gz tgz bz2 xz 7z rar zst lz4 dmg iso deb rpm pkg jar apk'",
    "'mp3 wav flac aac ogg m4a opus'",
    "'mp4 mov mkv avi webm m4v wmv mpg'",
    "' '",
    "'pdf'",
    "'.'",
  },
  // D34's standard-folder table: lowercase folder names matched against
  // a path's last segment: file-name machine data, never rendered.
  'lib/ui/place_glyphs.dart': {
    "'desktop'",
    "'documents'",
    "'downloads'",
    "'pictures'",
    "'photos'",
    "'music'",
    "'movies'",
    "'videos'",
    "'applications'",
  },
  // The inspector's widget keys — widget plumbing keyed for tests and
  // the pointer-bounce boundary, never authored copy. '' is the empty
  // header while no target is selected; 'owner'/'group'/'others' and
  // 'read'/'write'/'execute' are the permissions grid's key segments,
  // and their uppercase first letters render the rwx column heads.
  'lib/ui/panes/info_panel.dart': {
    "''",
    "'infoPanel.calculateSize'",
    "'infoPanel.cancelSize'",
    "'infoPanel.retrySize'",
    "'infoPanel.copyPath'",
    "'infoPanel.octalField'",
    "'infoPanel.applyPermissions'",
    "'infoPanel.applyEnclosed'",
    "'infoPanel.cancelEnclosed'",
    "'infoPanel.enclosedDecline'",
    "'infoPanel.enclosedConfirm'",
    r"'infoPanel.permCell.${rowKeys[row]}.${columnKeys[column]}'",
    "'owner'",
    "'group'",
    "'others'",
    "'read'",
    "'write'",
    "'execute'",
  },
  // The permissions editor's machine literals: the U+FFFD flagged-name
  // test (02 §13), the octal pad's fill character, and the path-key
  // plumbing the enclosed-apply walks share with folder_size.dart —
  // never rendered copy.
  'lib/services/pane_permissions.dart': {
    r"'\uFFFD'",
    "'0'",
    "'.'",
    "'..'",
    "'/'",
    "r'\\'",
    r"r'^[A-Za-z]:[\\/]'",
    r"r'\\'",
  },
  // The dot-segment sentinels a hostile listing could echo and the
  // separator characters the dedupe key strips — machine path data,
  // never rendered.
  'lib/services/folder_size.dart': {
    "'.'",
    "'..'",
    "'/'",
    "r'\\'",
    r"r'^[A-Za-z]:[\\/]'",
    r"r'\\'",
  },
  // The app.dart entry is the engine-seam assert (the demo entries left
  // with the deleted surface).
  'lib/app.dart': {
    "'connectionEngine is a test seam; engineSession supplies its own '",
    "'lanes. Provide one, not both.'",
  },
  // The persisted probe settings keys and record field names: the on-disk
  // settings.json shape, not UI copy (03 §6's per-server device-local map).
  'lib/services/probe_settings_store.dart': {
    "'probe.enabled'",
    "'probe.servers'",
    "'host'",
    "'port'",
    "'exposure'",
    "'connected'",
  },
  // The Quick Connect address grammar's separators and scheme spellings
  // (02 §2.7 machine syntax), the adhoc server-id prefix (03 §3.5), and
  // the password-stripped echo reconstructions — parser mechanics, never
  // rendered copy (user copy lives in ARB and is mapped at the render
  // site, D20).
  'lib/services/quick_connect_address.dart': {
    "'adhoc:'",
    "'@'",
    "':'",
    "'['",
    "']'",
    "'/'",
    "'://'",
    "'sftp://'",
    "''",
    r"'${split.username}@${split.hostport}'",
    r"'sftp://${split.username}@${split.hostport}$suffix'",
    r"'/$path'",
  },
  // The Quick Connect form's widget keys, the adhoc-id mint, the tab
  // label compositions (username@host:port machine data beside
  // ARB-authored copy), and the empty-string fallbacks — plumbing, never
  // authored copy.
  'lib/ui/panes/quick_connect_view.dart': {
    "'quickConnect.field'",
    "'quickConnect.connect'",
    "'quickConnect.importSshConfig'",
    "''",
    r"'${target.port}'",
    r"'$quickConnectAdhocIdPrefix${uuidV4()}'",
    r"'$username@${_hostLabel(target)}'",
    r"'${target.host}:${target.port}'",
    // The `$USER@` prefill's environment keys and its user@ join (D32
    // §6) — process-environment machine data, never authored copy.
    "'USER'",
    "'USERNAME'",
    r"'$user@'",
  },
  // The Not saved banner's widget keys — plumbing, never authored copy.
  'lib/ui/panes/save_favorite_bar.dart': {
    "'saveFavorite.bar'",
    "'saveFavorite.name'",
    "'saveFavorite.confirm'",
    "'saveFavorite.save'",
    "'saveFavorite.label'",
    "'saveFavorite.error'",
    "'saveFavorite.dismiss'",
  },
  // The shared name prompt's empty default and the endpoint grammar a
  // live session is labelled and matched by (`user@host:port`) —
  // machine data beside ARB-authored copy, never authored copy.
  'lib/ui/save_to_servers.dart': {
    "''",
    r"'${identity.host}:${identity.port}'",
    r"'${identity.username}@$host'",
    r"'${identity.username}@${identity.host.toLowerCase()}:'",
    r"'${identity.port}'",
  },
  'lib/ui/import/ssh_config_import_command.dart': {
    "'favorite.importSshConfig'",
  },
  // The §3.7 surface's widget keys — plumbing, not copy. Rendered text
  // comes from the checkoutLocalEdits* ARB keys.
  'lib/ui/local_edits_review.dart': {
    "'localEdits.review'",
    r"'localEdits.record.${record.id}'",
    r"'localEdits.recovered.${entry.directory}/$name'",
  },
  // The composed indicator's empty label for the "neither truth" case: it
  // paints nothing, so there is no wording to author.
  // '' is the none-appearance's empty label. The two long literals are a
  // developer-facing debug assert message, never rendered to users.
  'lib/ui/server_state_indicator.dart': {
    "''",
    "'Probe truth must be painted by ProbeStatusDot/ServerStateIndicator; '",
    "'ServerStateGlyph has no probe paint.'",
  },
  // The D32 sidebar library (sidebar_view.dart and its parts): widget keys,
  // selection-key and menu-key compositions, path separators for folder
  // labels, and semantics/tooltip labels composed of localized parts or
  // endpoint data — plumbing, never authored copy.
  'lib/ui/sidebar/sidebar_view.dart': {
    "'sidebar.noMatches'",
    "'sidebar.noMatches.clear'",
    // The empty query: Clear filter's and the stale-query drop's.
    "''",
    "'sidebar.filter'",
    "'sidebar.filter.field'",
    "'sidebar.bottomBar'",
    "'sidebar.add'",
    "'sidebar.settings'",
    "'sidebar.density'",
    "'sidebar.add.newServer'",
    "'sidebar.add.quickConnect'",
    "'sidebar.add.currentFolder'",
    "'sidebar.add.newGroup'",
    "'sidebar.add.importSshConfig'",
    "'/'",
    "'sidebar.syncChip'",
    r"r'\'",
    r"'device:$path'",
    r"'fav:$id'",
    r"'server:$serverId'",
    "'sidebar.menu'",
    r"'$keyPrefix.open'",
    r"'$keyPrefix.openNewTab'",
    r"'$keyPrefix.openOtherPane'",
  },
  'lib/ui/sidebar/sidebar_devices_section.dart': {
    r"'${volume.name} ${volume.path}'",
    r"'sidebar.device.${volume.path}'",
    r"'sidebar.section.$sectionKey'",
    r"'device:${volume.path}'",
    "''",
    r"'${volume.name}, ${l10n.sidebarFreeSpaceSemantics(freeSpace!)}'",
    r"'sidebar.device.eject.${volume.path}'",
    "'sidebar.menu.addToFavorites'",
    "'sidebar.menu.eject'",
    // D32 §9's "This device" row: its widget key and the '~' home anchor
    // the engine expands (the local pane's own home) — machine data.
    "'sidebar.device.thisDevice'",
    "'~'",
  },
  // D32 §9's Home presentation of the sidebar: widget keys and the empty
  // query the clear button writes — plumbing, never authored copy.
  'lib/ui/sidebar/sidebar_home.dart': {
    "'sidebar.home.search'",
    "'sidebar.home.list'",
    "'sidebar.home.add'",
    "'sidebar.home.search.clear'",
    "''",
    // A Home row's announcement joins its localized parts.
    "', '",
  },
  'lib/ui/sidebar/sidebar_dialogs.dart': {
    "''",
    "'sidebar.renameField'",
    "'sidebar.renameSave'",
    "'sidebar.groupField'",
    "'sidebar.groupSave'",
    "'sidebar.deleteConfirm'",
    "'sidebar.saveServerField'",
    "'sidebar.saveServerSave'",
  },
  'lib/ui/sidebar/sidebar_favorites_section.dart': {
    "'sidebar.retry'",
    r"'sidebar.group.$collapseKey'",
    r"'sidebar.section.$collapseKey'",
    "'sidebar.favorites.header'",
    r"'sidebar.section.$sectionKey'",
    "'sidebar.favorites.add'",
    "' '",
    "'sidebar.favorites.empty'",
    "'sidebar.favorites.addStandard'",
    "'sidebar.importSshConfig'",
    r"'sidebar.favorite.${bookmark.id}'",
    "'sidebar.menu.updateWorkspace'",
    "'sidebar.menu.rename'",
    "'sidebar.menu.moveToGroup'",
    "'sidebar.menu.ungroup'",
    "'sidebar.menu.newGroup'",
    "'sidebar.menu.delete'",
  },
  // PINNED's widget keys: plumbing, never authored copy.
  'lib/ui/sidebar/sidebar_pinned_section.dart': {
    r"'sidebar.catalog.row.${server.id}'",
    r"'sidebar.favorite.${bookmark.id}'",
    "'sidebar.pinned.header'",
    r"'sidebar.section.$sectionKey'",
  },
  'lib/ui/sidebar/sidebar_servers_section.dart': {
    "''",
    r"'${bookmark.label} ${sessionEndpointLabel(bookmark)}'",
    r"'sidebar.adhoc.${bookmark.id}'",
    r"'sidebar.group.$collapseKey'",
    r"'sidebar.section.$collapseKey'",
    "'sidebar.servers.empty'",
    "'sidebar.servers.quickConnect'",
    "'sidebar.servers.header'",
    r"'sidebar.section.$sectionKey'",
    "'sidebar.servers.add'",
    "'sidebar.catalog.menu.pin'",
    "'sidebar.menu.pin'",
    "' '",
    r"'sidebar.catalog.row.${server.id}'",
    r"'$username@${host.toLowerCase()}:$port'",
    r"'sidebar.row.disconnect.${server.serverId}'",
    "'sidebar.menu.disconnect'",
    r"'\n'",
    r"'sidebar.menu.review.$id'",
    "'sidebar.menu.localEdits'",
    r"'${identity.username}@${identity.host}:${identity.port}'",
    r"'${server.username}@${server.host}:${server.port}'",
    "'sidebar.catalog.menu'",
    "'sidebar.catalog.menu.edit'",
    "'sidebar.catalog.menu.duplicate'",
    "'sidebar.catalog.menu.delete'",
    "'sidebar.adhoc.menu.save'",
  },
  // The portable kit's empty query (the filter's clear button).
  'lib/ui/sidebar/sidebar_kit.dart': {
    "''",
    // The first-verb, row button and header "+" focus nodes' debug
    // labels: diagnostics, never shown.
    "'SidebarRow first verb'",
    "'SidebarRow action'",
    "'SidebarRow menu button'",
    "'SidebarSectionHeader add'",
    // A header dot's words join its title and count on a line of their
    // own, as a merged semantics node joins its parts: a separator, not
    // copy (the words are the host's).
    r"'\n'",
  },
  // The sidebar filter's term split and the path-separator trimming of
  // the selection match — machinery, never rendered.
  'lib/ui/sidebar/sidebar_facts.dart': {
    r"r'\s+'",
    "'/'",
    r"r'\'",
    r"r'^[A-Za-z]:[\\/]$'",
    // The compact Home's home-relative paths and `user@host:port`
    // endpoints — path and address grammar over machine data.
    "'~'",
    r"'$base$separator'",
    r"'~$separator${here.substring(base.length + 1)}'",
    "':'",
    r"'[$host]:$port'",
    r"'$host:$port'",
    r"'$username@$address'",
  },
  // The sidebar commands' registry ids.
  'lib/ui/sidebar/sidebar_commands.dart': {
    "'view.filterSidebar'",
    "'view.toggleSidebarDensity'",
    "'favorite.add'",
    "'connect.saveToServers'",
  },
  // The ported middle-ellipsis glyph and its head/tail compositions —
  // typography, not copy.
  'lib/ui/middle_ellipsis_text.dart': {
    "'…'",
    r"'${graphemes.take(head).join()}$_ellipsis'",
    r"'${graphemes.skip(graphemes.length - tail).join()}'",
  },
  // The collapse-key namespaces, the legacy keys they migrate, the
  // empty filter query, and the controller's ArgumentError/StateError
  // diagnostics — persisted identifiers and programmer errors, never
  // rendered UI copy.
  'lib/services/sidebar_controller.dart': {
    "'sec:'",
    "'fav:'",
    "'srv:'",
    r"'$_section${section.name}'",
    r"'$_favoriteGroup$groupKey'",
    r"'$_serverGroup$groupKey'",
    "'sidebar.connections'",
    "'sidebar.catalog'",
    "'sidebar.catalog.'",
    "''",
    "'id'",
    "'unknown bookmark'",
    "'SidebarController used after dispose'",
  },
  // DEVICES enumeration: mount roots, OS ids, environment keys, drive
  // letters, the XDG user-dirs file and its keys, the fallback folder
  // names (on-disk names, not display copy — rows show the folder's own
  // name), and the df/diskutil/gio/umount invocations and parsing.
  'lib/services/local_volumes.dart': {
    // The home anchor the engine expands (`homeDirectory`).
    "'~'",
    "'/Volumes'",
    "'/media'",
    "'/run/media'",
    "'/mnt'",
    "'/'",
    "'windows'",
    "'macos'",
    "'linux'",
    "'USERPROFILE'",
    "'HOME'",
    "'USER'",
    "'USERNAME'",
    "'LOGNAME'",
    "'SystemDrive'",
    "'C:'",
    r"'${String.fromCharCode(code)}:'",
    r"'$letter\\'",
    "'XDG_DESKTOP_DIR'",
    "'Desktop'",
    "'XDG_DOCUMENTS_DIR'",
    "'Documents'",
    "'XDG_DOWNLOAD_DIR'",
    "'Downloads'",
    "'XDG_CONFIG_HOME'",
    "'.config'",
    "'user-dirs.dirs'",
    "'diskutil'",
    "'eject'",
    "'gio'",
    "'mount'",
    "'-u'",
    "'umount'",
    r"r'^\s*(XDG_[A-Z]+_DIR)\s*=\s*\x22(.*)\x22\s*$'",
    r"'\n'",
    r"r'$HOME'",
    r"'$home${value.substring(5)}'",
    "'df'",
    "'-kP'",
    "' '",
    r"r'\s+'",
  },
  // The probe owner's dedup key composition (serverId@host:port) —
  // machine identity, never rendered.
  'lib/services/sidebar_probe_owner.dart': {
    r"'$serverId@${host.toLowerCase()}:$port'",
    r"'$serverId@'",
  },
  // Debug diagnostics only (`toString` of two immutable rows); never
  // rendered, so there is no copy to author.
  'lib/services/connection_status_controller.dart': {
    r"'PaneFailure($paneTabId, $message)'",
    r"'ConnectionServer($serverId, $label, $status)'",
  },
  // Tier-B benchmark plumbing (08 §6): results-document schema keys,
  // environment-detection probes, and temp-file name templates — wire
  // format and diagnostics, never rendered UI copy.
  'lib/bench/bench_results.dart': {
    "'poltergeist-d12-results-1'",
    "'profile'",
    "'debug'",
    "'release'",
    "'unknown'",
    'r\'"([^"]+)"\\s*\$\'',
    "'/proc/cpuinfo'",
    'r\'^model name\\s*:\\s*(.+)\$\'',
    "'runnerImage'",
    "'arch'",
    "'dartVersion'",
    "'flutterVersion'",
    "'mode'",
    "'cpuModel'",
    "'scenarioConfig'",
    "'scenario'",
    "'repetition'",
    "'status'",
    "'ok'",
    "'value'",
    "'unit'",
    "'fingerprint'",
    "'error'",
    "'schema'",
    "'rows'",
    r"'${target.path}.bench-$pid-'",
    r"'${DateTime.now().microsecondsSinceEpoch}.tmp'",
    r"'${const JsonEncoder.withIndent('  ').convert(toJson())}\n'",
    "'  '",
  },
  // Tier-B frame-aggregation diagnostics: the InsufficientFrames/invalid
  // input error text the checker publishes, not UI copy.
  'lib/bench/frame_stats.dart': {
    r"'captured $captured frame(s), but the scroll window requires >= '",
    r"'$required'",
    r"'no positive vsync interval in ${intervals.length} samples'",
  },
  // The activity panel's registered command id (D21 plumbing).
  'lib/ui/activity/activity_commands.dart': {"'queue.togglePause'"},
  // D32's shell command ids (D21 plumbing) and the Help menu's
  // repository links — machine identifiers and URLs, not copy.
  'lib/ui/shell/shell_commands.dart': {
    "'view.toggleInspector'",
    "'view.showAlerts'",
    "'connect.quickConnect'",
    "'connect.disconnect'",
    "'view.toggleFullScreen'",
    "'selection.transferToOtherPane'",
    "'selection.moveToOtherPane'",
    "'file.reveal'",
    "'file.downloadTo'",
    "'file.newFolder'",
    "'file.newFile'",
    "'file.delete'",
    "'file.deletePermanently'",
    "'file.duplicate'",
    "'help.keyboardShortcuts'",
    "'help.releaseNotes'",
    "'help.reportIssue'",
    "'https://github.com/L-K-M/Poltergeist/releases'",
    "'https://github.com/L-K-M/Poltergeist/issues'",
  },
  // The shortcuts sheet's key and the typographic joiner between a
  // command's alternative chords (glyph strings, not prose).
  'lib/ui/shell/keyboard_shortcuts_dialog.dart': {
    "'  ·  '",
    "'help.shortcuts.dialog'",
  },
  // The delete dialog's widget keys, the prepare-failure detail passed
  // as a placeholder, and the empty size stand-in for an unsized count.
  'lib/ui/shell/delete_confirm_dialog.dart': {
    "'delete.dialog'",
    "'delete.cancel'",
    "'delete.confirm'",
    "'delete.headline'",
    "'delete.serverTrash'",
    "'delete.trashUnavailable'",
    r"'$_error'",
    "''",
  },
  // The Connect dialog's keys and a server row's announced label (its
  // name and endpoint, both data) — plumbing, never authored copy.
  'lib/ui/shell/connect_dialog.dart': {
    "'connect.dialog'",
    r"'connect.server.${choice.id}'",
    r"'${choice.label}, ${choice.detail}'",
  },
  // The Quick Look overlay's widget keys and the line break it splits
  // the first line on for syntax detection — plumbing, never copy.
  'lib/ui/quick_look_overlay.dart': {
    r"'\n'",
    "'quickLook.overlay'",
    "'quickLook.title'",
    "'quickLook.close'",
    "'quickLook.text'",
    "'quickLook.image'",
    "'quickLook.noPreview'",
  },
  // The activity button's ring key — test plumbing, never copy.
  'lib/ui/shell/header_activity_button.dart': {"'header.activityRing'"},
  // The header's button and overflow-menu keys, keyed to the registry's
  // command ids — widget plumbing, not authored copy.
  'lib/ui/shell/header_toolbar.dart': {
    r"'command.${command.id}'",
    r"'toolbar.overflow.${command.id}'",
    "'toolbar.overflow'",
  },
  // D32 §9's compact posture: the browser subtitle's `user@host` address
  // grammar (10 §4, machine data like the header's), the Transfers
  // panel's shared widget key, the rename seed's extension dot, and the
  // empty fallbacks of optional labels — plumbing, never authored copy.
  'lib/ui/compact/compact_browser.dart': {
    r"'${identity.username}@${identity.host}'",
  },
  'lib/ui/compact/compact_inspector_sheet.dart': {"'activity.panel'"},
  'lib/ui/compact/compact_listing.dart': {"''"},
  'lib/ui/compact/compact_pane_messages.dart': {"''"},
  'lib/ui/compact/compact_rename_dialog.dart': {"'.'"},
  // The inspector's widget keys (its surface, the Transfers panel it
  // mounts, the tab switcher's per-tab keys) — plumbing, not copy.
  'lib/ui/inspector/inspector_view.dart': {
    "'inspector'",
    "'activity.panel'",
    r"'inspector.tab.${value.name}'",
  },
  // The Alerts tab's list/empty-state keys and per-alert row keys —
  // plumbing keyed to the alert identity, not copy.
  'lib/ui/inspector/alerts_view.dart': {
    "'alerts.empty'",
    "'alerts.list'",
    r"'alert.${alert.key}'",
    r"'alert.${alert.key}.dismiss'",
  },
  // Alert identities for session dismissal and list keys — machine
  // data, never rendered (the view localizes each alert's copy).
  'lib/services/alert_center.dart': {
    r"'task:${task.id}'",
    "'conflicts'",
    "'restored'",
    r"'server:${server.serverId}'",
    r"'edits:$serverId'",
    r"'update:${info.latestVersion}'",
    r"'dragout:${notice.id}'",
  },
  // Rate/ETA rendering and path grammar: the `/s` suffix, the ETA unit
  // glyphs, the custom-rate regex and its unit table, both path
  // separators, the endpoint:path composition, and the `→` route arrow
  // — technical formatting and machine data, reviewed per file.
  'lib/ui/activity/activity_format.dart': {
    r"'${formatPaneSize(bytesPerSecond.round(), platform: platform)}/s'",
    r"'${formatPaneSize(bytesPerSecond, platform: platform)}/s'",
    r"'${seconds}s'",
    r"'${minutes}m ${seconds % 60}s'",
    r"'${hours}h ${minutes % 60}m'",
    r"'${hours ~/ 24}d ${hours % 24}h'",
    "','",
    "'.'",
    "''",
    "'b'",
    "'k'",
    "'kb'",
    "'m'",
    "'mb'",
    "'g'",
    "'gb'",
    "'t'",
    "'tb'",
    r"r'^(\d+(?:[.,]\d+)?)\s*([kmgt]?i?b)?(?:\s*/\s*s)?$'",
    "'/'",
    "'\\\\'",
    r"'$candidate/'",
    r"'$path/'",
    r"'${transferEndpointLabel(task.source, localLabel: localLabel, serverLabel: serverLabel)}:'",
    r"' $sourcePath'",
    r"'${transferEndpointLabel(task.destination, localLabel: localLabel, serverLabel: serverLabel)}:'",
    r"' ${task.destinationDir}'",
    r"'$source → $destination'",
  },
  // The panel's widget keys plus the growing-totals `+` marker —
  // plumbing and machine grammar, never authored copy.
  'lib/ui/activity/activity_panel.dart': {
    "'activity.tab.activity'",
    "'activity.tab.history'",
    "'activity.pause'",
    "'activity.bandwidth'",
    "'activity.bandwidthPopover'",
    "'activity.clearCompleted'",
    "'activity.close'",
    "'activity.conflicts'",
    "'activity.restoredBanner'",
    "'activity.restoredBanner.resume'",
    "'activity.restoredBanner.discard'",
    "'activity.footer'",
    "''",
    "'+'",
    r"'$done${growing ? '+' : ''}'",
    r"'$total${growing ? '+' : ''}'",
    r"'${formatPaneSize(totalBytes, platform: platform)}'",
    r"'${growing ? '+' : ''}'",
  },
  // Task-row and item sub-row widget keys plus the bytes/progress
  // separators and the still-scanning `+` — machine data compositions
  // beside ARB-authored copy.
  'lib/ui/activity/activity_rows.dart': {
    "'activity.taskList'",
    r"'activity.task.${task.id}'",
    r"'activity.taskBody.${task.id}'",
    r"'activity.item.${item.id}'",
    r"'activity.cancel.${task.id}'",
    r"'activity.retry.${task.id}'",
    r"'activity.remove.${task.id}'",
    r"'activity.copyError.${task.id}'",
    r"'activity.reveal.${task.id}'",
    r"'activity.itemSkip.${item.id}'",
    r"'activity.itemCancel.${item.id}'",
    r"'activity.itemResolve.${item.id}'",
    r"'activity.itemRetry.${item.id}'",
    "' / '",
    "' · '",
    "'+'",
    "''",
  },
  // The conflict strip/dialog's widget keys and the size·mtime summary
  // composition — plumbing and machine data, never authored copy.
  'lib/ui/activity/conflict_widgets.dart': {
    r"'activity.conflict.${conflict.itemId}'",
    r"'activity.conflictResolve.${conflict.itemId}'",
    r"'conflict.verb.${verb.name}'",
    "'conflict.applyToAll'",
    r"'$size · $modified'",
  },
  // The History tab's widget keys, the filter's haystack joins, the
  // endpoint:path route composition, and the `·`/`→` separators —
  // machine data rendered inside ARB-labelled surfaces.
  'lib/ui/activity/history_view.dart': {
    "'history.filter'",
    "'history.clear'",
    "'history.list'",
    r"'history.copy.${entry.taskId}'",
    "''",
    r"'\n'",
    "', '",
    "' → '",
    r"'${transferEndpointLabel(entry.source, localLabel: l10n.activityTaskRouteLocal, serverLabel: serverLabel)}'",
    r"'${transferEndpointLabel(entry.destination, localLabel: l10n.activityTaskRouteLocal, serverLabel: serverLabel)}'",
    r"':${entry.destinationDir}'",
    r"'$time · $verb · $names'",
    r"'$route · $outcome'",
    r"' · ${entry.error}'",
    r"'${entry.error == null ? '' : ' · ${entry.error}'}'",
    r"'$title\n$details'",
  },
  // The popover's per-direction widget keys — test plumbing composed
  // from the direction prefix, never authored copy.
  'lib/ui/activity/bandwidth_popover.dart': {
    "'bandwidth.down.field'",
    "'bandwidth.up.field'",
    "'bandwidth.down.'",
    "'bandwidth.up.'",
    r"'$chipKeyPrefix$i'",
    r"'${chipKeyPrefix}custom'",
    r"'${chipKeyPrefix}set'",
    // D37's per-server cap chips: their keys, and the fixed counts, which
    // are bare numbers rather than copy.
    "'transferLimit.perServer.automatic'",
    r"'transferLimit.perServer.$files'",
    r"'$files'",
  },
  // The drag avatar's badges are glyphs, not authored copy: the `+`
  // copy badge (Finder's convention — a move carries none) and the
  // multi-selection count, which is a bare number.
  'lib/ui/panes/pane_drop_area.dart': {r"'$count'", "'+'"},
  // Diagnostic literals, never user-facing: the unbound-seam assert
  // fires only in debug builds, and the UnsupportedError guards a
  // foreign persistence seam no production queue supplies.
  'lib/services/quit_guard.dart': {
    "'QuitGuard queue seam was never bound — the shell owns bindQueue'",
  },
  'lib/services/app_transfer_queue.dart': {
    "'AppTransferQueue persistence must support a non-closing flush'",
  },
  // The quit-guard dialogs' widget keys — test plumbing, never authored
  // copy (the copy itself is ARB-backed per D20).
  'lib/ui/quit_dialog.dart': {
    "'Quit dialog shown without live tasks (02 §10)'",
    "'quit.dialog'",
    "'quit.keepTransferring'",
    "'quit.cancelTransfers'",
    "'quit.pauseAndQuit'",
    "'quitFlush.dialog'",
    "'quitFlush.quitAnyway'",
    "'quitFlush.dismiss'",
  },
  // The enrollment form's widget keys, the §4.1 `ghost-<8 hex>` username
  // suggestion placeholder (a generated value, not authored copy), and
  // the error interpolation feeding ARB templates — plumbing and machine
  // data only.
  'lib/ui/settings/backup_enrollment_form.dart': {
    r"'$error'",
    r"'ghost-${uuidV4().substring(0, 8)}'",
    "'backup.mode.separate'",
    "'backup.mode.shared'",
    "'backup.fleet.checkbox'",
    "'backup.shared.disclosure'",
    "'backup.enroll.action'",
    "'backup.enroll.url'",
    "'backup.enroll.username'",
    "'backup.enroll.password'",
    "'backup.enroll.passphrase'",
    "'backup.enroll.confirm'",
    "'backup.enroll.continue'",
    "'backup.enroll.status'",
  },
  // The enrolled view's widget keys and locator-keyed conflict buttons —
  // widget plumbing, never authored copy.
  'lib/ui/settings/backup_enrolled_view.dart': {
    r"'$error'",
    "'backup.enrolled'",
    "'backup.enrolled.status'",
    "'backup.enrolled.syncSecrets'",
    "'backup.enrolled.backupNow'",
    "'backup.enrolled.signOut'",
    "'backup.enrolled.switch'",
    "'backup.enrolled.delete'",
    "'backup.enrolled.deleteRetained'",
    "'backup.signout.dialog'",
    "'backup.signout.confirm'",
    "'backup.delete.dialog'",
    "'backup.delete.confirmField'",
    "'backup.delete.confirm'",
    "'backup.deleteRetained.dialog'",
    "'backup.deleteRetained.confirmField'",
    "'backup.deleteRetained.decline'",
    "'backup.deleteRetained.confirm'",
    r"'backup.pin.keep.${conflict.locator}'",
    r"'backup.pin.accept.${conflict.locator}'",
  },
  // The switch dialog's widget keys and locator-keyed hold-set rows —
  // plumbing; '' is the failed-phase fallback while no error is set.
  'lib/ui/settings/backup_switch_dialog.dart': {
    "''",
    "'backup.switch.dialog'",
    "'backup.switch.continue'",
    "'backup.switch.close'",
    "'backup.switch.fleet'",
    "'backup.switch.url'",
    "'backup.switch.username'",
    "'backup.switch.password'",
    "'backup.switch.passphrase'",
    "'backup.switch.error'",
    "'backup.switch.conflicts'",
    "'backup.switch.done'",
    "'backup.switch.failed'",
    r"'backup.switch.conflict.${conflict.locator}'",
    r"'backup.switch.adoptFleet.${conflict.locator}'",
    r"'backup.switch.keepLocal.${conflict.locator}'",
  },
  // The section dialog's widget keys — plumbing only.
  'lib/ui/settings/backup_settings.dart': {
    "'backup.settings.dialog'",
    "'backup.settings.close'",
  },
  // The registered command id (D21 plumbing).
  'lib/ui/settings/backup_settings_command.dart': {"'open-settings-backup'"},
  // The Editing sections' bounded mount (06 §8): widget keys, the
  // `*.ext` chip prefix, and the comma separators of the extensions
  // field — plumbing and machine data, never authored copy.
  'lib/ui/settings/editor_settings.dart': {
    "'editors.settings.dialog'",
    "'editors.settings.close'",
    "'editors.remove.dialog'",
    "'editors.remove.confirm'",
    "'editors.default'",
    "'editors.default.builtin'",
    "'editors.default.system'",
    r"'editors.default.${editor.id}'",
    "'editors.add'",
    r"'editors.row.${editor.id}'",
    r"'*.$extension'",
    r"'editors.edit.${editor.id}'",
    r"'editors.remove.${editor.id}'",
    "', '",
    "','",
    "'editors.edit.save'",
  },
  // The ported external-editor service (Séance D2): the
  // `poltergeist/files` channel name and method keys, the reserved
  // selector ids and prefix, the registry document's schema keys,
  // extension/id validation regexes and FormatException diagnostics,
  // and the launch-failure StateError messages — typed diagnostics
  // surfaced verbatim via error.toString(), the same posture as
  // RemoteFileException messages; never authored UI copy.
  'lib/services/external_file_opener.dart': {
    "'poltergeist/files'",
    "'poltergeist.system'",
    "'poltergeist.builtin'",
    "'poltergeist.'",
    "'platform'",
    "'id'",
    "'displayName'",
    "'launchTarget'",
    "'acceptedExtensions'",
    "'editors'",
    "'extensionDefaults'",
    "'defaultEditorId'",
    "'version'",
    "'Unknown editor platform'",
    r"'Unknown editor id: $editorId'",
    "'Editor id is reserved'",
    "'At most 64 external editors can be configured.'",
    r"'.$extension'",
    r"'file.$extension'",
    r"'\\'",
    "'/'",
    "'.'",
    "'*'",
    r"r'[/\\*?\x00-\x1f\x7f]'",
    r"'Invalid file extension: $value'",
    "'At most 64 extensions can be configured.'",
    "'openWithApplication'",
    "'path'",
    "'bundleIdentifier'",
    "'pickApplication'",
    "'title'",
    r"'${editor.displayName} is configured for another platform.'",
    r"'${editor.displayName} is no longer installed at '",
    r"'${editor.launchTarget}.'",
    r"'${editor.displayName} is not executable.'",
    "'The selected application has no bundle identifier.'",
    "'Choose a regular executable file.'",
    "'.exe'",
    "'Windows editors must be .exe applications.'",
    "'Windows editors must be .exe applications'",
    "'The selected file is not executable.'",
    "'exe'",
    r"r'^[A-Za-z0-9._-]{1,64}$'",
    "'Invalid editor id'",
    r"r'[\x00-\x1f\x7f]'",
    "'Invalid editor name'",
    r"'\u0000'",
    "'Invalid editor target'",
    "'Editor executable paths must be absolute'",
    // The platform-aware absoluteness check's Windows drive/UNC patterns
    // — regex and path mechanics, never rendered copy.
    r"r'^[A-Za-z]:[\\/]'",
    r"'\\\\'",
  },
  // The registry document's settings.json key and the refuse-at-write
  // diagnostic — machine data and a typed-error message surfaced
  // verbatim through the error-toast convention, never ARB copy.
  'lib/services/editor_registry_controller.dart': {
    "'editorRegistry'",
    r"'Unknown editor id: $id'",
  },
  // The submenuItems/menuPlacement.submenu exclusivity assert — a
  // dev-facing invariant message, never rendered copy.
  'lib/services/registered_command.dart': {
    "'A parameterized command must not also join a merged submenu '",
    "'via menuPlacement.submenu.'",
  },
  // The parameterized command's ids, item-suffix plumbing, and the
  // chooser/remember dialog's widget keys — plumbing, never copy.
  'lib/ui/panes/open_with_commands.dart': {
    "'open-with-external'",
    "'open-with-external:other'",
    r"'$kOpenWithExternalCommandId:$suffix'",
    "'builtin'",
    "''",
    r"'editor.${editor.id}'",
    "'system'",
    r"'$kOpenWithExternalCommandId:configure'",
    "'openWith.builtin'",
    r"'openWith.${editor.id}'",
    "'openWith.system'",
    "'openWith.other'",
    "'openWith.remember'",
    "'openWith.confirm'",
  },
  // The M7 preview panel's widget keys (06 §5.3) — test/plumbing handles
  // for the card buttons, never authored copy — plus the metadata-card
  // joiners (empty segments and the line break composing the detail
  // string, all machine data beside ARB-labelled rows).
  'lib/ui/preview_panel.dart': {
    "''",
    r"'\n'",
    "'preview.close'",
    "'preview.download'",
    "'preview.confirm.cancel'",
    "'preview.confirm.download'",
    "'preview.progress'",
    "'preview.produce.cancel'",
    "'preview.gate.cancel'",
    "'preview.gate.keep'",
    "'preview.text'",
    "'preview.image'",
    "'preview.open'",
    "'preview.openWith'",
    "'preview.truncated.open'",
    "'preview.quickLookCard'",
    "'preview.quickLookCard.cancel'",
    "'preview.quickLookCard.confirm'",
  },
  // The PDF builder seam's external-open button key — plumbing, not copy.
  'lib/ui/pdf_preview.dart': {"'preview.pdf.open'"},
  // The §8 downloads settings section's field/button widget keys and the
  // MiB integer text fed to TextFields — plumbing and numeric machine
  // data, never authored copy.
  'lib/ui/settings/preview_settings.dart': {
    r"'${widget.settings.capacityBytes ~/ _mib}'",
    r"'${widget.settings.thresholdBytes ~/ _mib}'",
    r"'${liveBytes ~/ _mib}'",
    "'preview.cacheLimitField'",
    "'preview.clearCache'",
    "'preview.thresholdField'",
  },
  // The sync command registry's stable ids — command plumbing, never
  // rendered copy (labels resolve through l10n).
  'lib/ui/sync/sync_commands.dart': {
    "'sync.synchronizePanes'",
    "'sync.newSavedSync'",
    "'sync.copyRsyncCommand'",
  },
  // The pair editor's machine literals: numeric TextField seeds, the
  // 1–8 concurrency labels, and the decimal input-filter regex —
  // plumbing and machine data, never authored copy.
  'lib/ui/sync/sync_pair_editor.dart': {
    "''",
    r"'${rules.mtimeToleranceSecs}'",
    r"'${rules.maxDelete}'",
    r"'${rules.deleteFractionWarn}'",
    "r'[0-9.]'",
    r"'$i'",
    "'\\n'",
  },
  // The plan view's machine literals: widget keys, the §8 typed-DELETE
  // sentinel (input validation, never rendered), the side-label
  // tooltip join over ARB values, the §7 ' · ' run-label joiner, and
  // the report's tab/dash separators — plumbing and spec-verbatim
  // grammar, never authored copy.
  'lib/ui/sync/sync_plan_view.dart': {
    "''",
    "'sync.plan.table'",
    "'DELETE'",
    r"'${l10n.syncSideLeft} ⇄ ${l10n.syncSideRight}'",
    "'sync.header.clause'",
    // D32 §7's hold banner: widget key and the comma join of its ARB
    // reason fragments.
    "'sync.plan.holdBanner'",
    "', '",
    "' · '",
    r"'${item.relativePath}\t${item.effective.name}\t'",
    r"'${item.status.name}${item.error != null ? '\t${item.error}' : ''}'",
    r"'\t${item.error}'",
    "'—'",
  },
  // The Sync sheet's machine literals (D32 §7): widget keys, the
  // compare sentence's split marker (U+FFFC, never in a translation),
  // the empty-path/empty-label placeholders, the rules tooltip's line
  // join and the tolerance row's comma join over ARB fragments, the
  // user@host[:port] address form of an embedded identity, and the
  // path shortener's separators and ellipsis — plumbing and machine
  // data, never authored copy.
  'lib/ui/sync/sync_setup_sheet.dart': {
    "''",
    "'sync.sheet'",
    "'sync.sheet.name'",
    "'sync.sheet.favoriteName'",
    "'sync.sheet.left'",
    "'sync.sheet.right'",
    "'sync.sheet.deleteOrphans'",
    "'sync.sheet.deleteTrash'",
    "'sync.sheet.deletePermanent'",
    "'sync.sheet.includeHidden'",
    "'sync.sheet.skipRules'",
    "'\\n'",
    "'sync.sheet.ruleCount'",
    "'sync.sheet.editRules'",
    "'sync.sheet.tolerance'",
    "'sync.sheet.timeOffset'",
    "'sync.sheet.unavailable'",
    "', '",
    "'sync.sheet.more'",
    "'sync.sheet.more.bothWays'",
    "'sync.sheet.more.saveFavorite'",
    "'sync.sheet.more.advanced'",
    "'sync.sheet.more.rsync'",
    "'sync.sheet.cancel'",
    "'sync.sheet.save'",
    "'sync.sheet.simulate'",
    "'sync.sheet.synchronize'",
    r"'${identity.username}@${identity.host}'",
    r"'${identity.username}@${identity.host}:${identity.port}'",
    "'sync.sheet.direction'",
    "'sync.sheet.direction.left'",
    "'sync.sheet.direction.right'",
    "'\\u{FFFC}'",
    "'sync.sheet.compare'",
    "' '",
    "'sync.sheet.plan.warning'",
    "'sync.sheet.plan'",
    r"'\\'",
    "'/'",
    r"'…$separator$tail'",
  },
  // The plan sentence's ICU select keys, its clause join, and the
  // clause's debug toString — machine data, never authored copy.
  'lib/ui/sync/sync_policy_sentence.dart': {
    r"'${tone.name}: $text'",
    "'remote'",
    "'local'",
    "' '",
  },
  // The sheet dialogs' widget keys, the rules field's line split/join,
  // and the tolerance field's numeric seed — plumbing, never copy.
  'lib/ui/sync/sync_sheet_dialogs.dart': {
    "'sync.favoriteName.field'",
    "'sync.favoriteName.save'",
    "'\\n'",
    "'sync.rules.field'",
    "'sync.rules.defaults'",
    "'sync.rules.done'",
    r"'${widget.initial.toleranceSecs}'",
    "'sync.timeOffset.tolerance'",
    "'sync.timeOffset.hourShift'",
    "'sync.timeOffset.done'",
  },
  // The review table's widget keys (sections, rows, their checkboxes,
  // the column header), the section count, and the empty/dash cells
  // of an absent side or a folder's size — plumbing, never copy.
  'lib/ui/sync/sync_plan_table.dart': {
    "'sync.plan.table'",
    r"'sync.section.${group.section.name}'",
    r"'sync.section.${group.section.name}.check'",
    r"'sync.row.${item.relativePath}'",
    "'sync.plan.columns'",
    r"'${items.length}'",
    "''",
    "'—'",
    r"'sync.row.${item.relativePath}.check'",
  },
  // The sync plan format layer's machine data: the rail-3 numeric
  // percentage injected into the ARB {pct} slot, and the config-less
  // remote ref's fallback id inside the ARB {destination} label —
  // interpolation plumbing inside localized templates, never authored
  // copy.
  'lib/ui/sync/sync_plan_format.dart': {
    r"'${(configuredThreshold * 100).round()} %'",
    r"'${server.identity?.host ?? server.serverConfigId ?? server.identity?.username ?? 'server'}:'",
    "'server'",
    r"'${shortenRemotePath ? paneLastSegment(path) : path}'",
    // The size formatter's numeric+unit join and its unit names —
    // machine data inside the ARB {bytes} slot, never authored copy.
    r"'${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}'",
    r"'$bytes B'",
    "'KB'",
    "'MB'",
    "'GB'",
    "'TB'",
    // The reason column's age suffixes and absent-value dash — machine
    // data inside the ARB {sourceAge}/{destinationAge} and size slots.
    r"'${delta}s'",
    r"'${delta ~/ 60}m'",
    r"'${delta ~/ 3600}h'",
    r"'${delta ~/ 86400}d'",
    "'—'",
    // 05 §7's verbatim sentence grammar — the spec fixes the English
    // "X, and Y on Z" shape; the clause fragments themselves are ARB
    // templates, these are the spec's connective joins.
    r"'${parts.sublist(0, parts.length - 1).join(', ')}, '",
    "', '",
    r"'and ${parts.last}'",
    r"'$joined ${l10n.syncHeaderOnDestination(destination)}'",
    // 05 §7's action glyphs — spec-defined symbols, not text copy.
    "'→'",
    "'⇒'",
    "'←'",
    "'⇐'",
    "'⊞'",
    "'✕'",
    "'↯'",
    "'–'",
  },
  // The recents document's schema keys, format diagnostics, dedupe-key
  // prefixes, and the settings.json document key — wire format, never
  // rendered UI copy.
  // Bookmark JSON keys and the home landing path ("/").
  'lib/services/bookmark_landing_path.dart': {
    "'kind'",
    "'remotePath'",
    "'/'",
  },
  'lib/services/recent_locations.dart': {
    "'quickOpen.recentLocations'",
    "'version'",
    "'entries'",
    "'label'",
    "'path'",
    "'serverId'",
    "'bookmark'",
    "'recent location entry'",
    "'recent location serverId'",
    "'recent locations document'",
    "'recent locations entries'",
    r"'remote:$serverId:$path'",
    r"'local:$path'",
    r"'bookmark:$serverId'",
  },
  // The fuzzy matcher's word-separator set — match mechanics, never
  // rendered.
  'lib/services/quick_open_match.dart': {r"' -_./\\:;()[]{}'"},
  // The chord formatter's glyph/name table and modifier joiner —
  // platform keyboard spelling (Ctrl+Shift+P, ⌃⌥⇧⌘P), spec-fixed
  // symbols, not authored copy.
  'lib/services/shortcut_format.dart': {
    r"'$name+'",
    "'⌃'",
    "'⌥'",
    "'⇧'",
    "'⌘'",
    "'Ctrl'",
    "'Alt'",
    "'Shift'",
    "'Meta'",
    "'↑'",
    "'↓'",
    "'←'",
    "'→'",
    "'↩'",
    "'⇥'",
    "'⌫'",
    "'⌦'",
    "'Up'",
    "'Down'",
    "'Left'",
    "'Right'",
    "'Enter'",
    "'Tab'",
    "'Esc'",
    "'Backspace'",
    "'Del'",
    "'Space'",
    "','",
    "'.'",
    "'/'",
    r"'\\'",
    "'['",
    "']'",
    "'-'",
    "'='",
    "';'",
    "\"'\"",
    "'`'",
  },
  // The palette's plumbing: the command id, widget key, empty-string
  // and separator joins inside match corpora and row compositions —
  // every rendered word resolves through ARB.
  'lib/ui/quick_open/quick_open_palette.dart': {
    "'app.quickOpen'",
    "'quickOpen.field'",
    "''",
    "' '",
    "'  '",
    "' · '",
    r"'${command.label(l10n)} ${_menuPath(command, l10n) ?? ''}'",
    r"'${bookmark.label} ${_favoriteMatchText(bookmark)}'",
    r"'${recent.path} ${recent.remoteBookmark?.server?.identity?.host ?? ''}'",
    r"'$menu ▸ $submenu'",
    r"'${identity.username}@${identity.host}'",
  },
  // The Séance editor port (see docs/PORTS.md): image format sniffing,
  // font families, controller seeds, regex machinery, and diagnostics —
  // upstream literals, not user-facing copy.
  'lib/services/badge_image.dart': {
    "'png'",
    "'jpg'",
    "'jpeg'",
    "'gif'",
    "'webp'",
    "'bmp'",
    "'svg'",
    "'heic'",
    "'heif'",
    r"'\uFEFF'",
    "'<'",
    "'<svg'",
  },
  'lib/services/server_duplication.dart': {
    // The duplicate-label grammar and its cleanup regex — upstream label
    // machinery (labels are data, not copy), plus the empty strip result.
    r"'$base copy'",
    r"'$base copy $n'",
    "r'(^|\\s+)copy(\\s+\\d+)?\$'",
    "''",
    // SourceServerChanged's message — upstream-authored English surfaced
    // verbatim in the failure toast, the same posture as
    // RemoteFileException messages.
    "'\"\$label\" changed while it was being copied — it was '",
    "'deleted, or it now holds a different credential. Nothing was created.'",
  },
  'lib/services/server_editor_backend.dart': {
    // Credential-resolution empty fallbacks and the identity-read audit
    // label — machine data, never rendered copy.
    "''",
    r"'${config.username}@${config.host}'",
  },
  'lib/ui/connection_log_view.dart': {
    "'monospace'",
    "'Consolas'",
    "'Menlo'",
    "'Courier New'",
  },
  'lib/ui/color_picker.dart': {
    // The hex field's filter regex, preview '#' and seed — input machinery.
    "'[0-9a-fA-F]'",
    "'#'",
    "''",
  },
  'lib/ui/server_editor.dart': {
    // Controller seeds and fallbacks (empty strings and the loaded port),
    // the mono font on the PEM and login-script fields, and error
    // interpolations handed to ARB strings — machinery, not copy.
    "''",
    r"'${e?.port ?? 22}'",
    "'monospace'",
    r"'$error'",
    r"'$e'",
    // D37's override menu: its key, and the fixed counts, which are bare
    // numbers rather than copy.
    "'serverEditor.transferLimit'",
    r"'$files'",
  },
  'lib/ui/server_mark_picker.dart': {
    // The no-bytes picker fault (raised for the caller's localized error
    // path), the typed-emoji seeds and interpolation glue, the debug log,
    // and the curated emoji table — upstream vocabulary, same exemption
    // as the glyph picker.
    "'the file picker returned no image bytes'",
    "''",
    r"'$shortcutHint '",
    r"'${shortcutHint.isEmpty ? '' : '$shortcutHint '}'",
    r"'${l10n.serverMarkPickerEmojiFontNote}'",
    r"'server mark image import failed: $error'",
    ..._portedCuratedEmojiVocabulary,
  },
  // The Séance ports (docs/PORTS.md): upstream English picker/search
  // vocabulary, kept verbatim so the files stay re-diffable against the
  // pinned source — localizing it is the recorded divergence deferred to
  // the picker/editor slice. Nothing the catalog surface ships renders
  // these: section sentinels are substituted with ARB strings in
  // SidebarView and badge semantics carry the caller's label.
  'lib/ui/server_appearance.dart': {
    r"'#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}'",
    "'0'",
    "''",
    r"'${color.name[0].toUpperCase()}${color.name.substring(1)}'",
    "r'\\s+'",
    r"'${glyph.label} ${glyph.keywords}'",
    "'Default'",
    "'default server'",
    "'None'",
    "'Infrastructure'",
    "'Storage'",
    "'Services'",
    "'Building'",
    "'Access'",
    "'Places'",
    "'Marks'",
    ..._portedServerIconVocabulary,
  },
  'lib/ui/server_filter.dart': {
    // The match haystack and the term-split regex — corpus machinery.
    r"'${server.label} ${server.username}@${server.host}:${server.port} '",
    r"'${server.group ?? ''}'",
    "''",
    "r'\\s+'",
  },
  'lib/ui/server_grouping.dart': {
    // Section sentinels — identity keys the view substitutes localized
    // headers for; never rendered raw in Poltergeist.
    "''",
    "'Ungrouped'",
    "' pinned'",
    "'Pinned'",
    "'Other servers'",
  },
  // D32 §11's platform integration: Dock progress diagnostics and the
  // file-manager reveal's process arguments (never user-facing copy).
  'lib/services/dock_progress.dart': {
    r"'$live'",
    r"'Dock progress disabled: $error\n$stack'",
    r"'Dock progress unavailable: $error\n$stack'",
  },
  'lib/services/file_manager_reveal.dart': {
    "'macos'",
    "'windows'",
    "'linux'",
    "'open'",
    "'-R'",
    r"""'explorer.exe /select,"$path"'""",
    "'dbus-send'",
    "'--session'",
    "'--print-reply'",
    "'--dest=org.freedesktop.FileManager1'",
    "'--type=method_call'",
    "'/org/freedesktop/FileManager1'",
    "'org.freedesktop.FileManager1.ShowItems'",
    r"'array:string:$uri'",
    "'string:'",
    "','",
    "'%2C'",
    "'xdg-open'",
    "'gio'",
  },
  // OS drag-out's channel protocol (00 D14's amendment): method names,
  // argument keys, item kinds, the channel name, and the English
  // diagnostics a refused call carries to the native side: wire data,
  // never rendered UI copy (the Alerts tab localizes drag-out failures).
  'lib/services/os_drag_out.dart': {
    "'poltergeist/dragout'",
    "'file'",
    "'kind'",
    "'path'",
    "'name'",
    "'isDirectory'",
    "'promise'",
    "'promiseId'",
    "'size'",
    "'sessionId'",
    "'position'",
    "'allowedOperations'",
    "'items'",
    "'image'",
    "'imageSize'",
    "'imageAnchor'",
    r"'DragOutPromiseException(${failure.name}: $message)'",
    "'startDrag'",
    "'started'",
    "'reason'",
    "'message'",
    // 00 D39: the view a window's drag left, the separator of the
    // window-prefixed session ids crossing the channel, and the refusal
    // a closed window's late promise gets.
    "'viewId'",
    "'/'",
    r"'$viewId$_separator$sessionId'",
    "'no window owns this drag-out session'",
    "'promiseProgress'",
    "'completedBytes'",
    "'totalBytes'",
    "'badArguments'",
    r"'${call.method} expects a map'",
    r"'${call.method} needs a sessionId'",
    "'fulfilPromise'",
    "'destinationPath'",
    "'fulfilPromise needs promiseId and destinationPath'",
    "'no drag-out delegate is attached'",
    "'cancelPromise'",
    "'sessionEnded'",
    "'operation'",
    r"'${call.method} is not a drag-out callback'",
  },
  // The drag-out controller's session and promise ids, macOS's
  // `/private` temp spelling, desktop_drop's `Drops` staging folder
  // name, and the English diagnostics a failed promise hands the native
  // completion (Finder logs them; the user-facing report is the
  // localized Alert).
  'lib/services/drag_out_controller.dart': {
    r"'p${promises.length + 1}'",
    r"'dragout-${++_sequence}'",
    "'/private'",
    r"'$prefix/tmp/'",
    r"'$prefix/var/'",
    "'unknown drag-out session or promise'",
    "'the drag came back into Poltergeist'",
    "'the promise is already being fulfilled'",
    "'no transfer queue to produce remote files'",
    "'no transfer queue to download remote folders'",
    "'the drop asked for a different folder name'",
    "'transfers are paused'",
    "'the download was paused'",
    "'the download was cancelled'",
    "'Drops'",
  },
  // The drag image's ellipsis glyph: typography, not copy.
  'lib/ui/panes/drag_out_image.dart': {"'\u2026'"},
};

/// The icon-label/keyword pairs ported verbatim from Séance's picker
/// table — kept as one list so the allowlist above stays readable. Same
/// exemption as the rest of the port: upstream English until the editor
/// slice decides whether the picker localizes.
const _portedServerIconVocabulary = {
  "'Server'",
  "'dns host machine node'",
  "'Cloud'",
  "'vps provider'",
  "'Cluster'",
  "'kubernetes k8s swarm nodes'",
  "'Virtual machine'",
  "'vm vps kvm hypervisor guest'",
  "'Desktop'",
  "'workstation pc'",
  "'Laptop'",
  "'notebook'",
  "'Board'",
  "'device raspberry pi arduino embedded iot'",
  "'Router'",
  "'gateway firewall modem'",
  "'Network'",
  "'lan switch subnet'",
  "'VPN'",
  "'wireguard tunnel tailscale'",
  "'Data centre'",
  "'rack colo dc data center'",
  "'Satellite'",
  "'uplink relay'",
  "'Sensors'",
  "'iot telemetry probe'",
  "'Printer'",
  "'cups printing'",
  "'Power'",
  "'ups pdu outlet'",
  "'Container'",
  "'docker podman image'",
  "'Database'",
  "'db sql psql postgres mysql redis'",
  "'File store'",
  "'nas smb share folder'",
  "'Backup'",
  "'restic borg snapshot'",
  "'Archive'",
  "'cold tape retention'",
  "'Stack'",
  "'tier layer environment'",
  "'Web'",
  "'http www site nginx apache'",
  "'API'",
  "'rest graphql endpoint'",
  "'Mail'",
  "'smtp imap postfix'",
  "'Chat'",
  "'xmpp matrix irc messaging'",
  "'Forum'",
  "'discourse board community'",
  "'Feed'",
  "'rss atom reader'",
  "'Dashboard'",
  "'grafana panel admin'",
  "'Monitoring'",
  "'prometheus uptime alert health'",
  "'Analytics'",
  "'metrics statistics reports'",
  "'Media'",
  "'plex jellyfin video streaming'",
  "'Music'",
  "'audio navidrome stream'",
  "'Photos'",
  "'immich gallery images'",
  "'Game server'",
  "'minecraft steam gaming'",
  "'Voice'",
  "'sip voip pbx asterisk'",
  "'Cameras'",
  "'cctv nvr surveillance'",
  "'Shop'",
  "'store commerce checkout'",
  "'Billing'",
  "'invoices accounting'",
  "'Calendar'",
  "'caldav scheduling'",
  "'Documents'",
  "'office notes paperwork'",
  "'Wiki'",
  "'knowledge handbook docs'",
  "'AI'",
  "'llm model inference gpu'",
  "'Bot'",
  "'automation agent worker'",
  "'Shell'",
  "'terminal console command'",
  "'Code'",
  "'dev ide source'",
  "'Git'",
  "'repository forge version control'",
  "'Build'",
  "'ci runner pipeline jenkins'",
  "'Plugin'",
  "'addon module'",
  "'Lab'",
  "'staging experiment sandbox'",
  "'Testing'",
  "'bug qa test debug'",
  "'Work in progress'",
  "'wip unfinished'",
  "'Production'",
  "'prod live deploy release'",
  "'Performance'",
  "'speed benchmark load fast'",
  "'Components'",
  "'services parts'",
  "'Secure'",
  "'hardened protected'",
  "'Locked'",
  "'private restricted'",
  "'Keys'",
  "'vault secrets credentials'",
  "'Admin'",
  "'root privileged control'",
  "'Trusted'",
  "'audited verified'",
  "'Home'",
  "'house homelab'",
  "'Work'",
  "'job employer'",
  "'Office'",
  "'company headquarters'",
  "'Factory'",
  "'plant industrial works'",
  "'Cabin'",
  "'cottage retreat'",
  "'Public'",
  "'internet global world'",
  "'Favourite'",
  "'star starred favorite important'",
  "'Loved'",
  "'heart favourite favorite'",
  "'Fast'",
  "'bolt quick lightning'",
  "'Hot'",
  "'busy urgent burning'",
  "'Frozen'",
  "'cold paused dormant'",
  "'Watched'",
  "'observe eye'",
  "'Careful'",
  "'caution warning danger fragile'",
  "'Special'",
  "'magic sparkle'",
  "'Pet project'",
  "'animal'",
  "'Coffee'",
  "'cafe break'",
  "'Anchor'",
  "'stable fixed harbour'",
  "'Green'",
  "'eco leaf efficient'",
};

/// The curated emoji table ported verbatim from Séance's mark picker —
/// same exemption as _portedServerIconVocabulary: upstream vocabulary,
/// kept escaped so the file stays re-diffable against the pin.
const _portedCuratedEmojiVocabulary = {
  r"'\u{1F308}'",
  r"'\u{1F310}'",
  r"'\u{1F31F}'",
  r"'\u{1F332}'",
  r"'\u{1F340}'",
  r"'\u{1F375}'",
  r"'\u{1F383}'",
  r"'\u{1F3AC}'",
  r"'\u{1F3AE}'",
  r"'\u{1F3AF}'",
  r"'\u{1F3B5}'",
  r"'\u{1F3C1}'",
  r"'\u{1F3DD}\u{FE0F}'",
  r"'\u{1F3E0}'",
  r"'\u{1F3E2}'",
  r"'\u{1F3ED}'",
  r"'\u{1F408}'",
  r"'\u{1F40D}'",
  r"'\u{1F415}'",
  r"'\u{1F419}'",
  r"'\u{1F41D}'",
  r"'\u{1F422}'",
  r"'\u{1F427}'",
  r"'\u{1F433}'",
  r"'\u{1F43C}'",
  r"'\u{1F47B}'",
  r"'\u{1F480}'",
  r"'\u{1F4B0}'",
  r"'\u{1F4B3}'",
  r"'\u{1F4BB}'",
  r"'\u{1F4BE}'",
  r"'\u{1F4BF}'",
  r"'\u{1F4C8}'",
  r"'\u{1F4CA}'",
  r"'\u{1F4DA}'",
  r"'\u{1F4DD}'",
  r"'\u{1F4E1}'",
  r"'\u{1F4E6}'",
  r"'\u{1F4F1}'",
  r"'\u{1F4F6}'",
  r"'\u{1F4F7}'",
  r"'\u{1F50B}'",
  r"'\u{1F50C}'",
  r"'\u{1F50D}'",
  r"'\u{1F510}'",
  r"'\u{1F511}'",
  r"'\u{1F512}'",
  r"'\u{1F517}'",
  r"'\u{1F525}'",
  r"'\u{1F527}'",
  r"'\u{1F52C}'",
  r"'\u{1F52E}'",
  r"'\u{1F5A5}\u{FE0F}'",
  r"'\u{1F5A8}\u{FE0F}'",
  r"'\u{1F5C3}\u{FE0F}'",
  r"'\u{1F5C4}\u{FE0F}'",
  r"'\u{1F5DE}\u{FE0F}'",
  r"'\u{1F5FC}'",
  r"'\u{1F680}'",
  r"'\u{1F6A7}'",
  r"'\u{1F6D2}'",
  r"'\u{1F6E0}\u{FE0F}'",
  r"'\u{1F6E1}\u{FE0F}'",
  r"'\u{1F6F0}\u{FE0F}'",
  r"'\u{1F916}'",
  r"'\u{1F980}'",
  r"'\u{1F981}'",
  r"'\u{1F986}'",
  r"'\u{1F989}'",
  r"'\u{1F98A}'",
  r"'\u{1F9D9}'",
  r"'\u{1F9E0}'",
  r"'\u{1F9EA}'",
  r"'\u{1F9F0}'",
  r"'\u{1F9F1}'",
  r"'\u{1F9F9}'",
  r"'\u{1FAAA}'",
  r"'\u{2328}\u{FE0F}'",
  r"'\u{2601}\u{FE0F}'",
  r"'\u{2615}'",
  r"'\u{2699}\u{FE0F}'",
  r"'\u{26A0}\u{FE0F}'",
  r"'\u{26A1}'",
  r"'\u{2705}'",
  r"'\u{2728}'",
  r"'\u{274C}'",
  r"'\u{2B50}'",
};

void main() {
  test('rejects representative authored user-facing literals', () {
    const unlocalizedSources = <({String path, String source})>[
      (
        path: 'lib/ui/example.dart',
        source: "void fixture() { const Text('Disconnected'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source:
            "void fixture() { const SelectableText('Server disconnected'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source: "void fixture() { const TextSpan(text: 'Transfer failed'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source:
            "void fixture() { const InputDecoration(hintText: 'Remote path'); }",
      ),
      (
        path: 'lib/services/example.dart',
        source: "String failureSummary() => 'Connection failed';",
      ),
    ];

    for (final fixture in unlocalizedSources) {
      final offenders = _findDisallowedLiterals(
        path: fixture.path,
        source: fixture.source,
      );

      expect(
        offenders,
        isNotEmpty,
        reason: 'missed literal: ${fixture.source}',
      );
    }
  });

  test('detects user-facing literals nested in interpolation', () {
    const source = "void fixture() { Text('\${wrap('Disconnected')}'); }";

    final offenders = _findDisallowedLiterals(
      path: 'lib/ui/example.dart',
      source: source,
    );

    expect(
      offenders.map((literal) => literal.lexeme),
      contains("'Disconnected'"),
    );
  });

  test('does not let interpolation syntax hide following literals', () {
    const source = '''
void fixture(String path) {
  '\${path.replaceAll('//', '/')}';
  Text('After');
}
''';

    final offenders = _findDisallowedLiterals(
      path: 'lib/ui/example.dart',
      source: source,
    );

    expect(offenders.map((literal) => literal.lexeme), contains("'After'"));
  });

  test('limits technical exceptions to their reviewed file', () {
    const source = "const paneRatioKey = 'layout.paneRatio';";

    expect(
      _findDisallowedLiterals(
        path: 'lib/services/app_preferences.dart',
        source: source,
      ),
      isEmpty,
    );
    expect(
      _findDisallowedLiterals(path: 'lib/ui/example.dart', source: source),
      isNotEmpty,
    );
  });

  test('keeps every technical exception live', () {
    for (final entry in _allowedTechnicalLiterals.entries) {
      final literals = _scanStringLiterals(
        File(entry.key).readAsStringSync(),
      ).map((literal) => literal.lexeme);

      expect(literals, containsAll(entry.value), reason: entry.key);
    }
  });

  test('ignores directives, comments, and generated files', () {
    const source = """
import 'package:flutter/widgets.dart';
import 'default.dart'
    if (dart.library.io) 'native.dart';
// Text('Comment only')
/* SelectableText('Also a comment') */
""";

    expect(
      _findDisallowedLiterals(path: 'lib/example.dart', source: source),
      isEmpty,
    );
    expect(
      _findDisallowedLiterals(path: 'lib/example.g.dart', source: "'copy'"),
      isEmpty,
    );
  });

  test('ignores generated output for every locale', () {
    const source = "String get actionLabel => 'Copier';";

    expect(
      _findDisallowedLiterals(
        path: 'lib/l10n/app_localizations_fr.dart',
        source: source,
      ),
      isEmpty,
    );
  });

  test('rejects source with parser diagnostics', () {
    const malformedSource = "void fixture() { Text('Hidden');";

    expect(
      () => _scanStringLiterals(malformedSource),
      throwsA(isA<StateError>()),
    );
  });

  test('authors user-facing strings only in ARB', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final relativePath = entity.path.replaceAll('\\', '/');
      final violations = _findDisallowedLiterals(
        path: relativePath,
        source: entity.readAsStringSync(),
      );
      offenders.addAll(
        violations.map(
          (violation) => '$relativePath:${violation.line}: ${violation.lexeme}',
        ),
      );
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('generated localization exclusions are present', () {
    for (final path in _generatedLocalizationPaths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'generated localization output is missing: $path',
      );
    }
  });
}

List<({int line, String lexeme})> _findDisallowedLiterals({
  required String path,
  required String source,
}) {
  if (_isGeneratedPath(path)) return const [];

  final allowed = _allowedTechnicalLiterals[path] ?? const <String>{};
  return [
    for (final literal in _scanStringLiterals(source))
      if (!allowed.contains(literal.lexeme))
        (
          line: '\n'.allMatches(source.substring(0, literal.offset)).length + 1,
          lexeme: literal.lexeme,
        ),
  ];
}

bool _isGeneratedPath(String path) {
  if (path.startsWith(_generatedLocalizationPrefix)) return true;

  return _generatedDartSuffixes.any(path.endsWith);
}

Iterable<({int offset, String lexeme})> _scanStringLiterals(String source) {
  final collector = _StringLiteralCollector();
  final result = parseString(content: source, throwIfDiagnostics: false);
  // Malformed code must fail this gate instead of hiding literals.
  if (result.errors.isNotEmpty) {
    throw StateError('source has parse errors; refusing to scan it');
  }

  result.unit.accept(collector);
  return collector.literals;
}

final class _StringLiteralCollector extends RecursiveAstVisitor<void> {
  final literals = <({int offset, String lexeme})>[];

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _record(node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _record(node);
    super.visitStringInterpolation(node);
  }

  void _record(StringLiteral node) {
    if (_belongsToDirective(node)) return;

    literals.add((offset: node.offset, lexeme: node.toSource()));
  }
}

bool _belongsToDirective(AstNode node) {
  AstNode? ancestor = node.parent;
  while (ancestor != null) {
    if (ancestor is Directive) return true;
    ancestor = ancestor.parent;
  }

  return false;
}
