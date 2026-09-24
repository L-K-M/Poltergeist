# 10 — The inspector workspace (UI redesign, D32)

**Status:** Accepted with its PR · **Date:** 2026-09-24 · **Decision:** D32 in
[00-OVERVIEW.md](00-OVERVIEW.md)

This chapter replaces the shipped v1.0 window chrome with a ForkLift- and
Transmit-grade workspace. Where it conflicts with [02-UX.md](02-UX.md) it
wins (D32 names the superseded clauses); everything it does not mention in
02 still holds, including the budgets, accessibility, and i18n rules.

It is written for two readers: the owner deciding whether the product now
feels right, and an implementation agent who needs the exact shapes.

## 1. Why the v1.0 chrome had to go

Measured on the shipped Linux build (screenshots in the PR):

- **The toolbar was the whole command registry.** `_Toolbar` rendered every
  registered command, about 40 of them plus one per saved workspace, as an
  icon button. Several showed the fallback bug icon, labels ellipsized to
  nothing, none had tooltips, and the title shrank to "P…". The code called
  it the "M2 debug surface" that M3 was meant to replace. It never was.
- **Six horizontal chrome bands** stacked before the first file row: menu
  bar, toolbar, tab strip, path bar, pane footer, status bar. The status bar
  said "Ready" forever.
- **Three competing right-hand surfaces.** A 280 px Get Info overlay covered
  each pane's listing, a separate 320 px preview rail, and a bottom activity
  panel. None of them was resizable.
- **The verbs a file manager lives on were missing.** There was no New
  Folder, Delete, Copy to Other Pane, Connect, or context menu. Drag and drop
  was the only way to move a file. Remote transfers failed immediately,
  because the engine had no transfer verbs (STATUS item 23). Remote sync
  failed for the same reason.
- **Mobile was a squeezed desktop.** On a phone you got a desktop menu bar,
  the 40-button strip, 28 px rows, and no way to transfer at all.

The engine underneath (connection pool, queue, sync planner, checkout
pipeline) is strong and heavily tested. The redesign keeps all of it and
changes how it is presented.

## 2. Principles

1. **Few controls, always the right ones.** The header carries the eight
   actions a file manager is used for every minute. Everything else lives in
   menus, context menus, and the palette (D21 still holds: every control is a
   registered command).
2. **Density without clutter.** 13 px text, 22 px rows, one-line sidebar
   rows, no per-row icon rows. Secondary facts (paths, addresses) go in
   tooltips and the inspector, not in second lines.
3. **One place for each kind of truth.**
   - Location facts live in the pane header.
   - Item facts live in Info.
   - Work in flight lives in Transfers.
   - Things that need you live in Alerts.
   Nothing is shown twice.
4. **Nothing blocks the view unless it must.** Dialogs only for decisions
   (conflicts, deletions, host keys). Everything else is a banner, a badge,
   or an alert.
5. **Honest state (D16 still holds).** Every long operation is visible,
   cancellable, and inspectable. The toolbar activity button shows progress
   whenever anything runs, and the inspector opens on Transfers when work
   starts.
6. **Siblings look like siblings.** Séance and Poltergeist share the sidebar
   anatomy, the design tokens, the editor, and the sync account (§10).

## 3. Window anatomy (desktop)

```
┌──────────┬──────────────────────────────────────────────────────────────────────────┐
│ ● ● ●    │ [◧] [‹][›]  Title          [＋📁][🗑][⧉] [⇄ Sync][⚡ Connect] [◌][▭] [🔍 Filter ] │  header 44
│          ├──────────────────────────────┬───────────────────────────────┬───────────┤
│ DEVICES  │ [tab][tab]                +  │ [tab]                      +  │ (i)(⇅)(⚠) │  tabs 30
│ Home     │ 🏠 lmathis ▾                  │ 🖥 demo ▾                      │───────────│
│ Mac HD   │ 329 items · 69 GB available   │ 4 items                       │  preview  │  location 44
│ FAVORITES│ Name ▲        Size   Modified │ Name ▲       Size   Modified  │  name     │  columns 22
│ Desktop  │ ▸ .agents        —   11 Aug…  │ ▸ backups       —   Today…    │  kind     │
│ …        │ ▸ .android       —   18 Sep…  │ ▸ logs          —   Today…    │  size     │  rows 22
│ SERVERS  │   …                           │   …                           │  perms    │
│ ● demo   │                               │                               │           │
│ [+] Synced 2m               ⚙│                               │                               │           │
└──────────┴──────────────────────────────┴───────────────────────────────┴───────────┘
```

- **Columns, left to right:**
  - the sidebar (full height; on macOS it runs under the traffic lights)
  - pane A
  - pane B
  - the inspector
- **The header** spans the three columns right of the sidebar. When the
  sidebar is hidden on macOS it leaves room for the traffic lights.
- **No status bar** and **no bottom panel.** Their contents moved:
  - The selection summary moved to the pane's location header.
  - The transfer summary moved to the header activity button and the
    Transfers tab.
  - The sync-browsing link moved to the pane header.
  - The bandwidth limit moved to the Transfers tab.
- **The active pane** is marked by a 2 px accent line under its tab bar
  (ForkLift's orange line, in the app accent) and an accent-tinted selection.
  The inactive pane's selection is neutral grey.

### 3.1 Sizes, splitters, persistence

| Region | Default | Min | Max | Pref key |
|---|---|---|---|---|
| Window | 1280 × 800 | content 720 × 480 | — | `window.*` |
| Sidebar | 232 | 180 | 360 | `layout.sidebarWidth` |
| Pane A : B | 0.5 | 260 px each | — | `layout.paneRatio` (existing) |
| Inspector | 280 | 240 | 440 | `layout.inspectorWidth` |

- **Three vertical splitters:**
  - sidebar | panes
  - A | B
  - panes | inspector
- **Splitter behavior** (one reusable `ShellSplitter`):
  - 1 px line with an 8 px hit area and a resize cursor.
  - Focusable, resizable with the arrow keys in 16 px steps, and announced
    ("Resize sidebar, 232 pixels").
  - Double-click resets to the default.
  - Dragging the sidebar or inspector more than 48 px past its minimum hides
    it. That counts as a user hide, persisted as `layout.sidebarHidden` /
    `layout.inspectorHidden`.
- **Persistence:** widths are saved once at the end of a drag, never per
  pixel, and restored clamped.

### 3.2 Responsive stages (window content width)

Exactly one region changes per threshold. Auto-collapse is never persisted,
and a user hide always wins.

| Width | Behavior |
|---|---|
| ≥ sidebar + inspector + 2 × 260 + splitters | everything inline |
| below that | the inspector becomes an overlay sheet at the right edge (header button still toggles it) |
| < sidebar + 2 × 260 | the sidebar becomes a drawer |
| < 600 | compact posture (§9): one pane at a time |

## 4. The header toolbar

The header is registry-driven. A command appears only if it declares a
`toolbarPlacement` (slot + order). The curated set:

| Slot | Control | Command | Notes |
|---|---|---|---|
| leading | sidebar toggle | `view.toggleSidebar` | ⌃⌘S (macOS standard) |
| leading | back / forward, joined pair | `go.back`, `go.forward` | ⌘[ ⌘] |
| title | active location: folder name, server dot, `user@host` subtitle for remotes | — | double-click zooms the window on macOS |
| actions | New Folder | `file.newFolder` | ⇧⌘N |
| actions | Move to Trash | `file.delete` | ⌘⌫ |
| actions | Copy to Other Pane | `selection.transferToOtherPane` | F5 / ⇧⌘C |
| primary | **Sync** (labelled) | `sync.synchronizePanes` | ⌥⌘Y, opens the Sync sheet (§7) |
| primary | **Connect** (labelled) | `connect.quickConnect` | ⌘K, a popover with recent servers + Quick Connect |
| status | activity button (progress ring while anything runs, hidden otherwise) | `view.showTransfers` | opens Transfers |
| status | inspector toggle, badge = alert count | `view.toggleInspector` | ⌥⌘I, Finder's Show Inspector chord |
| trailing | filter field (active pane) | `view.filter` | ⌘F; "12 of 348" inside the field |
| trailing | main menu (Linux/Windows only) | — | the full menu tree behind ☰ (§8) |

- **Visual:**
  - Borderless 28 px icon buttons with an 8 px hover capsule.
  - Related buttons sit in one capsule group, as ForkLift does.
  - Primary actions carry text labels.
  - Every control has a tooltip with its shortcut ("New Folder ⇧⌘N").
- **Overflow:** as the window narrows, groups fold into a "»" menu in the
  order actions → primary labels (Sync and Connect become icon-only) →
  actions menu. Labels never ellipsize.

## 5. Sidebar (shared anatomy, §10)

- **DEVICES:**
  - Home (the user name) and the root volume, with free space in the
    trailing text.
  - Mounted volumes: `/Volumes/*` on macOS; `/media/$USER/*`,
    `/run/media/$USER/*` and `/mnt/*` on Linux; drive letters on Windows.
  - Removable volumes get an eject glyph on hover.
- **FAVORITES:**
  - Every bookmark kind: local folder, remote location, workspace, and saved
    sync.
  - Named groups become nested disclosure rows.
  - When the list is empty the section offers "Add Desktop, Documents and
    Downloads" as one click. It is never seeded silently, because favorites
    sync to other devices.
- **SERVERS:**
  - The server list, the same one Séance shows under the shared account.
  - Grouped, and pinned servers come first.
  - Each row carries its live state: a connected, connecting, or failed dot.
    This replaces the separate Connections section.
  - Hovering a connected row shows a disconnect glyph.
  - Unsaved Quick Connect sessions appear at the top in italics, with "Save
    to Servers…".
- **Rows:**
  - One line, 26 px.
  - An 18 px mark with one composed 7 px status dot.
  - A 13 px name that ellipsizes in the middle.
  - Trailing 11 px tabular secondary text (free space, `×N` tabs).
  - Hover fill at 6 %.
  - A rounded selection pill marks the location the active pane is showing.
  - A focus ring only in keyboard mode.
- **Section headers:**
  - 22 px, 11 px semibold, in the secondary text color.
  - The chevron and the "+" appear on hover.
  - The count shows only while collapsed.
- **Filter:** one field at the top, shown at 8+ servers, while a query is
  active, or via ⌥⌘F. It filters all sections.
- **Bottom bar**, 30 px:
  - a "+" menu: New Server…, Quick Connect…, Add Current Folder to
    Favorites, New Group…, Import from ssh config…
  - the sync status: "Synced · 2 min", a spinner, or red "Sync failed" where
    a click retries
  - a gear that opens Settings.
- **Menus:**
  - Right-click opens at the pointer.
  - Shift+F10 and the Menu key open it from the keyboard.
  - On touch, long-press opens the same verbs as a bottom sheet.
- **Drag and drop:**
  - Drop a folder, tab, or pane location on FAVORITES to add it.
  - Drop files on a server or favorite to upload there.

## 6. Panes

- **Tab bar**, 30 px:
  - A chip shows a server dot, then the title.
  - ✕ appears on hover and on the active tab only.
  - "+" sits at the end.
  - Right-click: Close, Close Others, Duplicate, Move to Other Pane, Copy
    Path.
- **Location header**, 44 px:
  - A 20 px location glyph (server mark, volume, or folder), then the
    current folder name in semibold with a "▾" that opens the ancestor menu
    (Finder's title menu).
  - A second line: `329 items · 69 GB available`, or `3 of 329 selected ·
    42.1 MB` (files only).
  - Clicking the name edits the path (⌘L).
  - Trailing: the sync-browsing link chip and a loading spinner with cancel.
- **Column header**, 22 px:
  - Name, Size, Date Modified. Kind, Permissions, Owner, and Group are
    optional (right-click the header).
  - Click to sort. The first click is ascending, except Size and Date,
    which start descending.
  - A chevron shows the sort direction.
  - Resizable columns, with widths in `ViewPreferences`.
- **Rows:**
  - 22 px (comfortable 28, touch 48). Kind glyphs are tinted by category.
  - Accent selection fill with on-accent text in the active pane, grey in
    the inactive one.
  - **Selection happens on pointer-down.** Double-click is detected from
    timestamps, so a click never waits out the double-tap timeout.
- **Context menu** (rows and empty space), built from the registry:
  - Open, Open With ▸, Edit in Poltergeist, Quick Look
  - Get Info, Rename, Duplicate, Copy Path
  - New Folder, New File
  - Copy to Other Pane, Move to Other Pane
  - Move to Trash
- **One banner slot.** Only the highest-priority banner shows: lost
  connection > reconnect > local edits > notice. The footer is gone.
- **Launcher** (an empty tab, or Connect):
  - Quick Connect, prefilled with `$USER@` and port 22.
  - Recent locations.
  - A grid of servers.
  - "Open Home".

## 7. Sync (Transmit's sheet, 05 amended by D32)

"Sync…" (⌥⌘Y, header button) opens a sheet. **The focused pane is the
source.**

```
                              Sync Files
        [💻]                      ←  →                      [🖥]
    This computer                                  demo@127.0.0.1
   /Users/me/site                                   /var/www/site
 ─────────────────────────────────────────────────────────────────
  Use the [Size and Modification Date ▾] to determine if a file has changed
  ☐ Delete orphaned destination files     (→ Move to trash | Delete permanently)
  ☐ Include hidden files
  ☐ Skip items matching rules  [3 rules ▾]  Edit…
    Modification date tolerance  2 s, ignore 1-hour shifts   [Time Offset…]
 ─────────────────────────────────────────────────────────────────
  Here's the plan:
  Your remote folder "site" will be updated from your local folder "site".
  Files that differ in size or date will be replaced with the local version.
  Replaced files are kept in the trash. No files will be deleted.

  [⋯]                               [Cancel]  [Simulate]  [Synchronize]
```

- **Direction:** the arrow pair toggles the direction. "Both ways" (Additive)
  lives in the ⋯ menu so a click can never select it by accident.
- **The plan sentence** is a pure function of the options and is always
  truthful. The engine replaces on any size or date difference, so the copy
  never says "older files are replaced" (05 §7).
- **Simulate** scans and opens the review. The review is the existing plan
  view, regrouped by action class (copy, update, delete, conflicts), with a
  checkbox per row and per section.
- **Synchronize** scans, then:
  - it runs straight away when the plan has no deletions, no replacements,
    and no conflicts;
  - otherwise it lands on the review with a banner saying why.
  The typed-DELETE step (rail 3) and the refusal (rail 4) are unchanged.
- **Hidden rows:** "Follow symbolic links" and "Only files modified in the
  last N days" are not shown. The engine does not support them yet (the
  symlink policy is v2, and an age filter under Mirror would delete old
  files; 05 §6), so the sheet never offers what the engine cannot do.
- **The ⋯ menu:** Save as Favorite…, Advanced… (the full pair editor), Copy
  as rsync Command.

## 8. Menus (all platforms render the same registry)

| Menu | Contents |
|---|---|
| Poltergeist (macOS) | About, Check for Updates…, Settings… ⌘, · Services · Hide, Hide Others, Show All · Quit |
| File | New Tab, New Folder, New File │ Open, Open With ▸, Edit in Poltergeist, Quick Look │ Get Info, Rename, Duplicate │ Copy to Other Pane, Move to Other Pane │ Move to Trash │ Reopen Closed Tab, Close Tab │ (Linux/Windows: Settings…, Quit) |
| Edit | Undo, Redo │ Cut, Copy, Paste │ Select All, Invert Selection, Quick Select │ Copy Path │ Filter |
| View | Show/Hide Sidebar, Inspector, Second Pane │ Info, Transfers, Alerts │ Show Hidden Files │ Refresh │ Enter Full Screen |
| Go | Back, Forward, Enclosing Folder, Home │ Go to Folder…, Edit Path │ Focus Left/Right Pane, Sync Browsing │ Quick Open… |
| Server | Connect… ⌘K, Disconnect │ Synchronize… ⌥⌘Y, New Saved Sync…, Copy as rsync Command │ Import from ssh config…, Back up and sync… │ Save Workspace…, Workspaces ▸ │ Pause/Resume Transfers |
| Window | Minimize, Zoom │ Next/Previous Tab │ Bring All to Front |
| Help | Keyboard Shortcuts, Release Notes, Report an Issue |

- **macOS:** the native menu bar (`PlatformMenuBar`). The "Commands" menu is
  renamed Server.
- **Linux and Windows:** the same tree behind a ☰ button at the header's
  trailing end (GNOME and Windows 11 convention). There is no second chrome
  band.
- **Android:** the ⋮ overflow on the app bar (§9).

## 9. Android and compact posture (< 600 dp)

- **Home is the sidebar**, full screen: Devices, Favorites, and Servers, with
  a search bar and a "+" FAB (New Server, Quick Connect).
- **The browser is a single pane:**
  - The app bar shows back, the folder name, `user@host`, and ⋮.
  - Breadcrumb chips scroll horizontally.
  - Rows are 56 dp, two lines (name; size · date).
  - **A tap opens.** A trailing ⋮ opens the action sheet. Pull to refresh.
- **Two panes on a phone:** the app bar's pane switcher ("A · B") flips
  between the two panes. The other pane is the implicit destination for
  "Copy to Other Pane", so the two-pane model survives without two columns.
- **Selection:** long-press starts it. A contextual app bar shows "3
  selected · 42 MB". The bottom action bar offers Copy to Other Pane, Move,
  Delete, Share, and More.
- **The inspector becomes a draggable bottom sheet** with the same three
  tabs. A floating progress pill above the content opens it on Transfers.
- **Sync** is a full-screen dialog with the same rows as the desktop sheet.
- **Back steps through, in order:**
  1. clear the selection
  2. close the sheet
  3. go back in folder history
  4. return to Home
  5. leave the app
  Predictive back is on (`enableOnBackInvokedCallback`).
- **Tablets (≥ 600 dp)** get the desktop layout. The sidebar becomes a drawer
  below its stage width, and the inspector becomes an overlay sheet.
- **Deferred to their own slices**, recorded in STATUS:
  - all-files storage access
  - the share-to-Poltergeist upload intent
  - a transfer foreground service with notification progress
  - a DocumentsProvider exposing servers to other apps

## 10. Sibling contract with Séance

Poltergeist and Séance are one product family. The contract:

1. **Same sidebar anatomy** (§5): section headers, one-line rows, one status
   dot, a bottom bar with "+" and sync status, and no app bar in the rail.
   Séance shows SERVERS (and PINNED); Poltergeist adds DEVICES and FAVORITES.
2. **Same design tokens:**
   - 13 px body and 11 px captions
   - 22 / 26 px rows
   - 8 px radii
   - the slate dark palette and the Finder-like light palette
   - one brand accent per app (Poltergeist teal, Séance violet)
3. **Same account.** Both apps enroll in the same Séance sync server with the
   same account and passphrase. Poltergeist's enrollment defaults to the
   shared account (04 amended by D32), so Séance's servers appear in
   Poltergeist's SERVERS and vice versa. The copy says "Sync" and "Vault
   passphrase" in both apps.
4. **Same editor.** The built-in editor stack is kept behaviorally identical
   in both directions:
   - Séance has the gutter, the Ln/Col status bar, and the drift banner.
   - Poltergeist has the hardened document I/O, the typed errors, and the
     larger language table.
   Fixes land in both, recorded in `docs/PORTS.md` and Séance's changelog.
5. **Same menu and command conventions.** Settings goes in the app menu on
   macOS, the Edit menu is standard, and Help exists. ⌘K means Connect in
   Poltergeist and Generate Command in Séance: each is the app's primary
   "start something" chord, so the two do not collide.
6. **Same Android navigation model:** the list is home, a pushed detail
   screen follows, system back is handled, and nothing is lost on back.

## 11. Platform integration

- **macOS:**
  - native menus with the standard items (§8)
  - Reveal in Finder (`NSWorkspace.activateFileViewerSelecting`)
  - Dock badge and progress while transfers run (`window_manager`)
  - the accessibility-safe Flutter view controller ported from Séance
- **Linux:**
  - Reveal via `org.freedesktop.FileManager1.ShowItems`, falling back to
    `xdg-open` on the parent folder
  - the ☰ main menu
- **Drag and drop:** drop-in from other apps works today (`desktop_drop`).
  Drag-out to Finder (file promises) stays a v1.x item under D14. It needs a
  native `NSFilePromiseProvider` channel and a Mac to verify. The queue's
  `enqueueProduce` hook is already in place for it.

## 12. What is intentionally not in this chapter

- Icon, column, and cover-flow view modes: 02 §2.2 stands.
- Multi-window: D13 / D25.
- Tree disclosure in lists: ForkLift's inline expansion needs a flattened
  tree model in the controller, so it is its own slice.
- Remote free space: this needs `statvfs@openssh.com` exposed through the
  VFS (an upstream Séance PR). Until then remote headers show the item count
  only.
