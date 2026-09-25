# Changelog

## Unreleased

- **A new workspace.** The window is rebuilt in the style of ForkLift and
  Transmit:
  - A calm header: back and forward, the current location, New Folder,
    Move to Trash and Copy to Other Pane, labelled Sync and Connect
    buttons, an activity ring, a filter field, and (on Linux and
    Windows) a ☰ menu with everything else. The toolbar that showed
    every command as an icon is gone.
  - A resizable sidebar with DEVICES (home, volumes, free space),
    FAVORITES and SERVERS (live status dots, filter, and a bottom bar
    for adding things, sync status and Settings).
  - An inspector column with Info, Transfers and Alerts tabs, in place
    of the bottom activity panel, the Get Info overlay and the status
    bar. Sidebar and inspector widths are remembered, and both give way
    gracefully as the window narrows.
  - Panes get a location header with a menu of enclosing folders,
    sortable columns, denser rows with file-kind icons, selection on
    press, and right-click menus everywhere.
- **Two sidebar views.** The sidebar's rows come in two densities:
  comfortable, the default, with a larger mark and the path, free space
  or `user@host` (with the state first when a server is connecting,
  failed or blocked) spelled on a second line, and compact, one line
  with those details in the tooltip. Switch at the foot of the
  sidebar, on the phone's Home, or with View ▸ Use Compact/Comfortable
  Sidebar Rows; the choice is kept per device.
  - A server's colour leads its row as a line again, a connected server
    wears a green ring, a blocked host key has its own mark, and an
    unreachable host shows a red ring.
  - Saved remote folders are favorites again, listed under Favorites
    beside local folders; "Save to Servers…" is now "Save to
    Favorites…". Servers lists your Séance account's servers (marked as
    such) and live Quick Connect sessions, and a Pinned section keeps
    the ones you pin at the top.
  - Pinned is the sidebar's first section, and saved remote folders pin
    too ("Pin to top" in their menu), so it works without a Séance
    account.
  - A folded group or a filter never hides a live connection: the
    header shows its dot. The filter appears at five servers again,
    says "↵ opens the first", and offers Clear filter.
- **New verbs.** Connect (⌘K), New Folder, New File, Duplicate, Move to
  Trash with a clear confirmation, Copy and Move to Other Pane (F5, F6),
  Show in Finder / File Manager / Explorer, and Help ▸ Keyboard
  Shortcuts.
- **Sync like Transmit.** Sync opens a sheet that states in plain words
  what will happen ("…will be updated from…, 2 files will be deleted"),
  with Simulate and Synchronize. A plan that only adds files runs
  straight away; anything that replaces or deletes stops on a review
  grouped by action, with per-row checkboxes.
- **Android.** On phones the sidebar is the home screen and the browser
  shows one pane at a time with an A·B switcher. Long-press selects,
  and the inspector is a bottom sheet. System back steps through
  selection, sheets, folders and home.
- **Shares an account with Séance.** Bookmark sync now preselects the
  Séance sync account, so both apps show the same servers.
- **Remote transfers work.** Uploads, downloads, remote→remote copies,
  remote managed checkouts, previews, and remote sync endpoints now run
  through the engine's bridged transfer lease. 1.0.0 failed these tasks
  with `unsupported`.
- **Trust before secrets.** Connecting to a server for the first time now
  asks you to approve its host key before it asks for a password. An
  unreachable server fails without asking for a password at all.
- **Fixes:**
  - Remote panes refresh when a transfer, move or delete lands in the
    folder they show.
  - A file that fails to open no longer disables the rest of its pane.
  - Opening a local file on Linux works without xdg-utils, falling back
    to `gio open`.
  - Edits to files opened from a Quick Connect session can be uploaded,
    and those servers show their address instead of an internal id.
  - The editor keeps a second leading byte-order mark as content, and
    Perl's `$#array` and `s#…#…#` no longer highlight as comments.
  - Delete, Shift+Delete and ⌘⌫ act only while the file list has
    focus. Pressed in the sidebar or the inspector, they no longer send
    the pane's selection to the Trash.
  - A local file dropped on a device copies unless Move is held.
  - The workspace is saved and restored again after connecting to a
    server at its home folder (a Quick Connect to `sftp://user@host`,
    or a server opened from SERVERS). Such a tab used to stop every
    later save and lose the layout on the next launch, and its recent
    entry disappeared.
  - A hung network mount no longer freezes or hides DEVICES.
  - Screen readers can activate every header button, inspector tab and
    Sync control, and hear the alert and transfer counts.
  - On a Mac, Control-click opens a sidebar row's menu. The app menu
    gains Check for Updates…, and Linux and Windows gain File ▸ Quit.
- Pre-1.0 history lives in the commit log and the GitHub pre-releases
  (v0.1.0, v0.2.0).

## 1.0.0 — first stable release (2026-09-23, shipped)

The ghost is out of the sheet. Poltergeist 1.0 is a two-pane file browser
for people who live on SFTP: each pane browses a local folder or a remote
server, tabs everywhere, a ForkLift-style favorites sidebar, a previewable
sync planner, an activity panel that journals every job across restarts,
and a built-in text editor — all keyboard-first, all localizable-ready,
all paranoid in the right places.

Highlights:

- **Panes.** Two independent panes with tabs, per-location view
  preferences, Quick Select (type to jump), Quick Open palette,
  filter-as-you-type, and workspace bookmarks that restore a whole
  window's layout.
- **Transfers.** A real queue — reorder, pause, per-item retry, bandwidth
  limits, a five-verb conflict dialog, and a journal that survives the
  app being killed mid-copy. Local↔local transfers are fully working.
- **Remote browsing over SSH.** Connect with keys, agent-less passwords,
  or keyboard-interactive auth; host keys pin on first use (TOFU) and a
  changed key is a hard stop. `~/.ssh/config` imports with a preview and
  dedupe.
- **Sync.** Saved pairs with Update / Mirror / Additive modes, a plan
  view that shows every action before anything moves, trash-first
  deletes with restore, and a copy-as-rsync-command exporter for when
  you want the shell instead.
- **Bookmarks.** Groups, drag-to-reorder, per-device view state, and
  opt-in end-to-end-encrypted backup through a Séance sync server (your
  own, if you self-host one).
- **Editor.** Built-in text editor with syntax highlighting and
  conflict-checked saves, plus "Open with" for your own editors.

Know before you install:

- **Remote transfers are not wired yet.** The engine proves them —
  remote→remote piping included — but the UI-side queue has no protocol
  verbs to reach it, so uploads, downloads, remote sync runs, and remote
  managed checkouts fail fast with a visible `unsupported` error. Local
  work is unaffected. This is the headline fast-follow.
- Linux screen-reader support is blocked upstream in Flutter
  (flutter/flutter#159460); Windows IME uses the legacy IMM32 path with
  known upstream defects. See the README's known-issues section.
- Desktop builds are unsigned by design — first launch takes one extra
  step per platform; see `docs/INSTALL.md`.
- The Android APK and iOS IPA in every release are rehearsal artifacts
  of the desktop codebase, not supported builds.

No telemetry, no account, no crash reporting. The only outbound call the
app ever makes unprompted is a link-only check that a newer release
exists, and it is one setting away from off.
