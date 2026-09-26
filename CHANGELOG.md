# Changelog

## Unreleased

- **The active pane's accent line is above its tabs.** The coloured line
  that shows which pane is active now runs along the top of that pane's
  tab bar instead of under the tabs, so it no longer sits between a tab
  and the folder it shows.
- **Simultaneous transfers per server.** The Transfers popover, next to
  the bandwidth limits, sets how many files move to or from each server
  at once: Automatic (up to 6, the app's total) or 1 to 5. A server's
  editor can give it its own number. Browsing, editing, previews and sync
  runs are never held back by it, and while one server is at its limit,
  transfers to other servers go ahead instead of waiting behind it.
- **Better on phones and tablets.** Local panes on Android open in the
  app's own documents folder instead of failing on "/~". The inspector
  starts hidden on touch screens so the panes get the width; the header
  toggle brings it back. The sidebar's filter field is full height, and
  compact rows on touch are 40 dp instead of 48.

- **Tabs switch in place.** Settings and the server mark picker showed
  the new tab by scrolling the content sideways to it, and a sideways
  swipe or trackpad scroll flipped between tabs. The new tab now simply
  appears, a swipe no longer changes tabs, and each tab keeps what you
  left in it: a half-typed search or form, the scroll position.

- **Colour that means something.** Icons get their colour back, and
  each colour means one thing in both Poltergeist and Séance, so you can
  find things by colour before you read them:
  - Folders are blue, code orange, images pink, audio and video purple,
    archives brown, PDFs red and links cyan, in the listing, the
    inspector, Quick Look and Transfers.
  - Sidebar places lead with a coloured tile: Home blue, disks
    graphite, a USB stick brown, a workspace teal, a saved sync indigo.
    Desktop, Documents, Downloads, Pictures, Music and Movies get their
    own icons.
  - Toolbar verbs are coloured while you can use them (New Folder blue,
    Move to Trash red, Copy to Other Pane cyan, Sync indigo, Connect
    green) and turn grey when you can't. The same colours mark them in
    right-click menus and the command palette.
  - The inspector's Info, Transfers and Alerts tabs are blue, cyan and
    yellow, and the open one lights up in its colour.
- **Themes.** Settings has an Appearance section (a tab of its own in the
  Settings window, and after General on phones and tablets). Pick one of
  ten themes (Poltergeist, Graphite, Paper, Newsprint, Solarized,
  Midnight, Terminal, Vapor, Bubblegum, High contrast) as a starting
  point, then change any colour, the four server status colours, the
  interface font and how round the corners are; the app repaints as you
  go. Colours left on Automatic follow light or dark as you choose. Copy
  theme and Paste theme carry a theme between devices, and between
  Poltergeist and Séance; themes do not sync. The app starts in Vapor,
  magenta and cyan over violet-black; pick Poltergeist for the teal look
  it had before themes.
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
    header shows its dot, and a screen reader hears it with the header
    ("Connected server hidden", or "Connecting server hidden"). The
    filter appears at five servers again,
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
- **Android is supported.** The release APK is a supported build now,
  not a rehearsal artifact; `docs/INSTALL.md` covers sideloading it, and
  the README lists what it does not do yet. On phones the sidebar is the
  home screen and the browser shows one pane at a time with an A·B
  switcher. Long-press selects, and the inspector is a bottom sheet.
  System back steps through selection, sheets, folders and home.
- **Drag files out of Poltergeist.** Dragging rows past the window's
  edge hands them to the system, so they can land in a file manager or
  another app; several selected items travel together, and they arrive
  as copies (or links). A drag out never moves or deletes the
  originals, so the Trash and the Recycle Bin refuse it; drags between
  the two panes still move. On Linux this carries local files today,
  and so does Windows (built, awaiting its first run on Windows). On
  macOS local files travel as file URLs, and remote files and folders
  as file promises that download straight to where you drop them
  (built, awaiting its first run on a Mac); on Linux and Windows a
  remote drag shows a hint and stays inside the window. A drag that
  comes back into Poltergeist lands like any in-app drag. Pausing a
  dragged remote item's download in Transfers stops the drop and says
  so under Alerts, and a drag that has to leave links or names that
  aren't valid UTF-8 behind says how many.
- **More than one window.** File ▸ New Window (⌘N on macOS, Ctrl+N on
  Linux and Windows) opens another workspace window, so different
  folders, servers and transfers can sit side by side. Each window has
  its own tabs, panes, sidebar and inspector; bookmarks, connections,
  Settings and the transfer queue are shared, so a transfer keeps
  running after the window that started it closes, and every window's
  Transfers tab shows all of them. File ▸ Close Window (⇧⌘W, Ctrl+Shift+W)
  or the close button closes one window; closing the last one quits,
  asking first if transfers are running. The next launch reopens every
  window you had open. For now an extra window does not take files
  dropped from other apps or drag files out, and on macOS it has a
  standard title bar, in-window Quick Look and no screen-reader
  support. Run on Linux; built for macOS and Windows.
- **Settings in its own window.** On macOS, Linux and Windows, Settings
  opens in a window of its own instead of over the workspace, with
  General, Editing and Sync tabs. Settings, Back up and sync… and
  Configure Editors… each open it on their tab, and bring it forward if
  it is already open. Closing it discards anything typed but not saved,
  and quitting from it goes through the same checks as quitting from
  the workspace. Phones and tablets keep the dialogs. Built on all
  three desktops; run so far on Linux only.
- **Download To….** File ▸ Download To… and the row menu download the
  selected remote items into a folder you pick.
- **Shares an account with Séance.** Bookmark sync now preselects the
  Séance sync account, so both apps show the same servers.
- **Remote transfers work.** Uploads, downloads, remote→remote copies,
  remote managed checkouts, previews, and remote sync endpoints now run
  through the engine's bridged transfer lease. 1.0.0 failed these tasks
  with `unsupported`.
- **Trust before secrets.** Connecting to a server for the first time now
  asks you to approve its host key before it asks for a password. An
  unreachable server fails without asking for a password at all.
- **Large transfers stay responsive.** A transfer of more than a few
  thousand files no longer rewrites the transfer journal after every
  file, which slowed the app, delayed quitting and wore the disk. The
  journal is compacted only when finished transfers free more space than
  the rewrite costs.
- **Fixes:**
  - On a Mac in full screen, the titlebar no longer covers the top of
    the window. It slides in with the menu bar, as in other apps, and
    the header uses the room the traffic lights left.
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
  - Pinned servers and folded sidebar sections survive a launch that
    could not read the settings file. Pinning or folding afterwards
    used to replace all of them with just that one change; now the
    sidebar keeps them and shows them again.
- **Mirror leaves alone what it cannot see.** When the source has a
  symbolic link where the destination has a real folder, a Mirror no
  longer deletes that folder's contents, and it no longer copies into a
  link on the destination. Everything under the link is skipped, as the
  exported rsync command already did. When a folder is to be replaced
  by a file, its contents belong to that one row: they are no longer
  deleted while you leave the choice open or keep the folder, no longer
  count twice toward the deletion limits, and no longer show "changed
  since preview" after the replace.
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
