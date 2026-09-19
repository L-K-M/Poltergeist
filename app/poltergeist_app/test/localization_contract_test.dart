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
  'lib/services/ssh_config_import_setup.dart': {
    r"'$home/.ssh/config'",
    "'~'",
  },
  // The composed queue's honest-absence connection seam: the refusal's
  // `operation` label is diagnostic metadata (the exception renders
  // `message`, which is ARB copy) — never authored UI text.
  'lib/services/transfer_queue_session.dart': {
    "'transfer channel'",
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
    // The activity panel's persisted keys (02 §1/§6): height, the two
    // throttle limits, and the auto-remove flag — settings.json keys.
    "'layout.activityPanelHeight'",
    "'transfer.downloadLimitBytesPerSecond'",
    "'transfer.uploadLimitBytesPerSecond'",
    "'transfer.autoClearCompleted'",
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
  },
  // The settings.json key the session document lives under (02 §3).
  'lib/services/session_state_store.dart': {"'session.state'"},
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
  },
  // The settings.json key the workspace list document lives under
  // (02 §3 — separate from the auto-session key by design).
  'lib/services/workspace_list_store.dart': {"'workspaces.saved'"},
  // The disposed-use diagnostic — the strip's assert-message posture.
  'lib/services/workspace_library.dart': {
    "'save on a disposed WorkspaceLibrary'",
    // The blank-label ArgumentError's name and reason — a programming-
    // error diagnostic, never rendered.
    "'label'",
    "'must not be blank'",
  },
  // The save dialog's name-field widget key — plumbing, not copy.
  'lib/ui/workspace/save_workspace_dialog.dart': {"'workspaceSave.name'"},
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
    r"'${e.code} — $msg'",
    r"'the vault master key'",
    r"'Could not save $what to the OS keyring (${_describe(e)}). Unlock '",
    r"'the login keyring or install gnome-keyring, then try again.'",
  },
  'lib/services/file_stores.dart': {
    "'-'",
    "''",
    "':'",
    "'.'",
    r"'${file.path}.corrupt-$stamp'",
    r"'$host:$port'",
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
  // Registered commands render from the registry keyed by id — widget
  // plumbing, not authored copy. The pane ids and focus-node labels key
  // to the engine's paneTabId channel identity (03 §3.2).
  'lib/ui/workspace_shell.dart': {
    "'command.\${command.id}'",
    "'connectionEngine is ignored when engineSession is provided'",
    "'pane.left.listing'",
    "'pane.right.listing'",
    "'openInPane: no bookmark for \${server.serverId}'",
    // The status bar's sync chip widget key — plumbing, not copy.
    "'statusbar.syncChip'",
    // The activity panel's widget keys (splitter, panel, status chips)
    // and the reveal-in-pane's missing-bookmark diagnostic — plumbing
    // and a reported fault, never rendered copy.
    "'activity.panel.splitter'",
    "'activity.splitter'",
    "'activity.panel'",
    "'statusbar.transferChip'",
    "'statusbar.limitChip'",
    r"'revealInPane: no bookmark for $serverId'",
    // The confirm dialog's bullet list marker — typographic, not copy.
    r"'• ${tabCloseTriggerLabel(l10n, trigger)}'",
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
  },
  // Debug-only placement-slot invariant diagnostics — never rendered.
  'lib/ui/menus/app_menus.dart': {
    "'the macOS application menu is platform chrome only'",
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
    "'go.open'",
    "'go.toFolder'",
    "'file.rename'",
    "'file.getInfo'",
    "'view.refresh'",
    "'pane.focusLeft'",
    "'pane.focusRight'",
    "'pane.swapFocus'",
    "'edit.selectAll'",
    "'edit.invertSelection'",
    "'selection.quickSelect'",
    "'view.filter'",
    "'view.toggleSecondPane'",
    "'view.toggleActivityPanel'",
    "'view.toggleSyncBrowsing'",
    "'tab.new'",
    "'tab.close'",
    "'tab.reopenClosed'",
    "'tab.next'",
    "'tab.previous'",
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
    // Root-path fallback in the remote tooltip — path data, not copy.
    "'/'",
  },
  'lib/ui/panes/pane_view.dart': {
    "'pane.footer'",
    "'pane.error.retry'",
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
    r"'${widget.controller.paneTabId}.path.field'",
    r"'${widget.controller.paneTabId}.filter.field'",
    r"'${widget.controller.paneTabId}.filter.clear'",
    r"'${controller.paneTabId}.filter.emptyClear'",
    r"'${controller.paneTabId}.notice.dismiss'",
    r"'${controller.paneTabId}.syncChip'",
    "''",
    // The rename editor's stem-selection dot — name arithmetic, not copy.
    "'.'",
    "'/'",
    "'\\\\'",
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
  },
  // The inspector's widget keys — widget plumbing keyed for tests and
  // the pointer-bounce boundary, never authored copy. '' is the empty
  // header while no target is selected; 'owner'/'group'/'others' and
  // 'read'/'write'/'execute' are the permissions grid's key segments,
  // and their uppercase first letters render the rwx column heads.
  'lib/ui/panes/info_panel.dart': {
    "''",
    "'infoPanel.close'",
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
    "''",
    r"'${target.port}'",
    r"'$quickConnectAdhocIdPrefix${uuidV4()}'",
    r"'$username@${_hostLabel(target)}'",
    r"'${target.host}:${target.port}'",
  },
  // The save bar's widget keys and the live-session label compositions
  // (endpoint machine data beside ARB-authored copy) — plumbing, never
  // authored copy.
  'lib/ui/panes/save_favorite_bar.dart': {
    "'saveFavorite.bar'",
    "'saveFavorite.name'",
    "'saveFavorite.save'",
    "'saveFavorite.error'",
    r"'${identity.host}:${identity.port}'",
    r"'$username@$host'",
  },
  // The on-disk bookmarks.json shape (keys and quarantine stamp), the
  // pinned model's envelope-id prefix, and the registered command id —
  // persisted format and widget plumbing, not UI copy.
  'lib/services/bookmark_store.dart': {
    "'version'",
    "'bookmarks'",
    "'id'",
    "'bookmark store root'",
    "'bookmark store version \$version'",
    "'bookmark:\$id'",
    r"'$path.corrupt-${_quarantineStamp(now)}'",
    "'-'",
    "':'",
    "'.'",
    "''",
  },
  'lib/ui/import/ssh_config_import_command.dart': {
    "'favorite.importSshConfig'",
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
  // The Connections surface's widget keys plus the endpoint line — machine
  // data (username@host:port) rendered beside ARB-authored copy.
  'lib/ui/connections/connections_view.dart': {
    "'connections-retry'",
    r"'connection.${server.serverId}'",
    r"'connection.review.${server.serverId}'",
    r"'connection.open.${server.serverId}'",
    r"'${server.username}@${server.host}:${server.port}'",
  },
  'lib/ui/connections/connections_command.dart': {
    "'view.connections'",
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
    r"'${transferEndpointLabel(task.source, localLabel: localLabel)}:'",
    r"' $sourcePath'",
    r"'${transferEndpointLabel(task.destination, localLabel: localLabel)}:'",
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
    "''",
    r"'\n'",
    "', '",
    "' → '",
    r"'${transferEndpointLabel(entry.source, localLabel: l10n.activityTaskRouteLocal)}'",
    r"'${transferEndpointLabel(entry.destination, localLabel: l10n.activityTaskRouteLocal)}'",
    r"':${entry.destinationDir}'",
    r"'$time · $verb · $names'",
    r"'$route · $outcome'",
    r"' · ${entry.error}'",
    r"'${entry.error == null ? '' : ' · ${entry.error}'}'",
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
    "'quitFlush.dismiss'",
  },
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
