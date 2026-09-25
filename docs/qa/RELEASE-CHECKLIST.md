# Release QA checklist

Manual QA per release — automated tests cannot see native chrome, IMEs, or
screen readers (08 §9). Copy this file into the release PR, fill every row
with the QA machine's result and date, and attach the filled copy to the PR.

> **v1.0.0 disposition (2026-09-22):** every row below that needs a real
> desktop — native chrome, IME composition, screen readers, first-launch OS
> gates, drag/drop feel, Quick Look, hardware benchmarks — is marked
> **OWNER MANUAL QA**: pending a human pass on the named platform. Nothing
> here is claimed done that a person has not run. The rows with automation
> evidence say so inline. The manual pass runs against the v1.0.0 release
> assets after the tag, on fresh machines, following `docs/INSTALL.md` only.

## Per-platform chrome (D11)

- [ ] **macOS** — OWNER MANUAL QA: unified toolbar look; traffic lights
  placed correctly at every window size; native menu bar complete with
  enabled-states correct; Edit-menu routing (Copy/Paste against file list
  vs rename field vs editor); no "Show Tab Bar" leakage; focus flag
  cleared after closing the last editor (the SEA-008 class). The 52 pt
  toolbar band: every header control, the sidebar filter and splitter
  (inline and in the narrow-window drawer), the built-in editor's back,
  Find, Save and Upload buttons, dialog tops, and top-toast actions take
  clicks, while empty band space still drags and double-click zooms
  (the band insets are pinned by `macos_toolbar_band_test.dart`; only
  the native hit-testing needs a Mac). Full screen (green button,
  ⌃⌘F, and back out): no titlebar strip covers the header; the
  titlebar only slides in with the menu bar; the header's traffic-light
  gap closes with the sidebar hidden and returns on exit; the window
  comes back with its 52 pt band intact.
- [ ] **Windows** — OWNER MANUAL QA: native titlebar; snap layouts work;
  Flutter-drawn `MenuBar` complete; Alt+F4 quits cleanly with a running
  queue (prevent-close flush prompt).
- [ ] **Linux** — OWNER MANUAL QA: server-side decorations; `.deb` and
  AppImage both launch; `StartupWMClass` maps the window to the desktop
  entry (the `StartupWMClass=Com.lkm.poltergeist_app` contract itself is
  enforced by `scripts/package-linux.sh` + its test, not manual).
- [ ] **Android** (D35) — OWNER MANUAL QA on a phone and a tablet: the
  APK installs per `docs/INSTALL.md` and a later release's APK upgrades
  it in place with data kept; connect, browse, upload, and download;
  every back step (selection, sheet, field, folder history, Home, leave)
  with the predictive-back animation on Android 13+; the keyboard never
  covers a focused field (IME insets); TalkBack reads Home, rows, and
  the selection bar. The compact posture's behavior itself is pinned by
  `test/ui/compact/compact_posture_test.dart`.

## IME smoke

Flutter desktop on Windows is IMM32, not TSF — composition behavior is the
known-divergent surface.

- [ ] OWNER MANUAL QA: rename a file with Japanese and Korean input on
  Windows, macOS, and Linux (IBus/fcitx): composition renders in place,
  Enter commits, Esc cancels the composition without cancelling the
  rename.
- [ ] OWNER MANUAL QA: type CJK in the editor and the filter field;
  verify highlighting never fights composition (the
  `CodeEditingController` IME guard).

## Screen reader smoke

- [ ] OWNER MANUAL QA: **macOS VoiceOver** and **Windows NVDA** (Narrator
  as an optional secondary pass): traverse file rows (name–kind–size–date
  announced), column headers with sort state, tabs, sidebar groups
  (expanded state), activity rows (completion announced once); operate
  one full transfer keyboard-and-reader only.
- [ ] **Linux**: not tested — broken upstream (see README's known-issues
  note for the linked issue). Each release re-checks whether upstream has
  fixed it and drops the exclusion when the fix lands.

## Trust and platform behaviors

- [ ] OWNER MANUAL QA: first-launch unsigned-app paths (D23): Gatekeeper
  right-click-open on macOS, SmartScreen "More info → Run anyway" on
  Windows — both match the steps documented in `docs/INSTALL.md`.
- [ ] Trash per platform (D15): macOS Put Back — OWNER MANUAL QA;
  Windows Explorer undo — OWNER MANUAL QA; Linux restore-from-trash —
  OWNER MANUAL QA: `gio trash --restore` where the installed GLib
  supports the flag (it
  takes the trash-side suffixed name, not the original path), else
  `gio open trash://` + a file-manager restore; record which path the QA
  machine used. (Linux trash round-trip is additionally covered by
  `trash_roundtrip_linux_test.dart` in CI — the restore-UX row still
  wants a human pass.)
- [ ] OWNER MANUAL QA: drop-in from Finder/Explorer/Nautilus into each
  pane; in-app pane↔pane drag; File ▸ Download To… and the row menu's
  Download To… land a remote selection in the picked folder.
- [ ] OWNER MANUAL QA: OS drag-out (D14 amendment 2026-09-25). On each
  desktop platform, drag a local file, a local folder, and a
  three-item selection from a pane past the window edge into the file
  manager: the items arrive as copies, within a volume as well as
  across (a drag out only ever offers copy and link, never move), and
  the originals stay in the pane. A drag onto the Trash (the Dock Trash,
  the file manager's Trash, the Recycle Bin) is refused and nothing is
  trashed; a drag into a folder copies. Esc mid-drag cancels, and the
  next click in the pane still selects. The drag image shows the name,
  or "N items" with a count badge. Drag out and back into the other
  pane: it lands like an in-app drag (a same-volume move stays a move),
  and a drag between the two panes still moves.
- [ ] OWNER MANUAL QA (macOS): drag a remote file and a remote folder
  from a server pane onto the Desktop and into a Finder window: each
  arrives complete, Transfers shows the download, and Finder shows
  progress. Repeat onto a folder that already holds a same-named file:
  the existing file is never replaced (the Transfers row fails with a
  clear message). Cancel from Finder mid-download: the Transfers row
  cancels and no partial file remains under the name. Pause the queue,
  then drag a remote folder: the drop fails at once with an Alert. Drag
  a remote file into Mail and Messages and record whether they accept
  promises. Record whether Finder ever offers "Keep Both" and what name
  it hands back (the folder path refuses a renamed URL today).
- [ ] OWNER MANUAL QA (macOS backend, `macos/Runner/DragOutChannel.swift`).
  This code has never run on a Mac, so do it before the two macOS items
  above. `flutter build macos` compiles it (it is in the Runner target).
  Then, in a debug build with Console.app filtered to Poltergeist:
  1. Drag a local file past the window edge: the image is its Finder
     icon and name, in the spot the in-app avatar held (no jump at the
     edge), and it follows the pointer at that offset. Drop it on the
     Desktop (the same volume): it arrives as a copy and the original
     stays. ⌘⌥ makes an alias; ⌘ (Finder's forced move) does not move
     it: record whether Finder refuses the drop or copies.
  2. Without moving the mouse first, click a row: it selects on the
     first click (no stuck press), and hover highlights come back.
  3. Start drags from a row near the toolbar band and from rows across
     the pane (all under `desktop_drop`'s overlay): each hands off.
  4. Drag three items: a pile of icons under AppKit's count badge "3".
  5. Press Esc mid-drag: the image slides back, nothing lands, and
     typing and shortcuts still work afterwards (no stuck key).
  6. Drag a local file onto the Dock's Trash: the Trash refuses the
     drop (it does not highlight, and the image slides back) and the
     file stays where it was.
  7. During a large remote file promise, record whether Finder shows a
     progress pie (the write lands in a hidden temp file first, so it
     may not) and whether Finder offers a cancel; if it does, cancel:
     the Transfers row cancels and nothing remains under the name.
  8. Drop the same remote file twice into one folder: record Finder's
     prompt and choice and the name the second copy lands under.
     Poltergeist never replaces the existing file.
  9. Drag a remote row out of the window and back onto the other pane:
     the pane labels it with the in-app verb, the drop lands in-app,
     and no copy appears under `$TMPDIR/Drops` (desktop_drop's staging
     folder; confirm it is `echo $TMPDIR` plus `Drops`).
  10. Quit Poltergeist while a large remote file promise is running:
      nothing appears under the promised name (a hidden
      `.poltergeist-*.tmp` may remain beside it).
  11. Console shows no AppKit exception or assertion from Poltergeist
      during any of the above.
- [ ] OWNER MANUAL QA (Linux, Windows): drag a remote row past the window
  edge: no OS drag starts, the pane shows the "use Download To…" hint,
  and the drag keeps working inside the window.
- [ ] OWNER MANUAL QA (Windows backend, `windows/runner/drag_out.cpp`).
  This code has never run on Windows, so do it before the Windows rows
  of the drag-out items above. `flutter build windows` must compile it
  under the runner's `/W4 /WX` and link `windowscodecs.lib`; a warning
  is a bug to fix, not to silence. Then, in a debug build started from
  a console (`flutter run -d windows`):
  1. Drag a local file past the window edge into an Explorer window on
     the same drive: the cursor shows a copy, the file is copied, and
     the original stays. On another drive it copies too. Ctrl and Alt
     while dragging force a copy and a shortcut; Shift (a forced move)
     does not move it: record whether Explorer refuses the drop or
     copies.
     (No "Move to …" caption is expected: drop descriptions are not
     enabled yet.)
  2. The drag image is Poltergeist's pill (the name, or "N items" with
     a count badge) under the pointer at the offset the in-app avatar
     had (no jump at the edge), sharp at 100 %, 150 %, and 200 %
     scaling, and neither clipped nor stretched.
  3. Without moving the mouse first, click a row: it selects on the
     first click (no stuck press). Hover highlights come back, and a
     plain click selects one row (Ctrl and Shift are not stuck).
  4. Press Esc mid-drag: nothing lands, and typing into the filter
     field works afterwards (no stuck key).
  5. Drag a three-item selection: all three arrive.
  6. While the drag hovers Explorer, a running transfer's row in
     Transfers keeps moving (Dart keeps running during the drag loop).
  7. Drag out and back onto the other pane: the pane labels it with the
     in-app verb, and a same-drive drop moves in-app.
  8. Drop onto the Desktop, a browser upload field (Edge or Chrome),
     Outlook or Teams, and Notepad: each receives the files.
  9. Drag a local file onto the Recycle Bin, on the Desktop and in
     Explorer's navigation pane: each refuses the drop (the no-drop
     cursor) and the file stays where it was.
  10. With a pen or a touch screen, a row drag past the edge stays
      in-app (no OS drag starts and nothing stays pressed).
  11. The console shows no assertion or error from the embedder or the
      runner during any of the above (in particular no "key up without
      key down" after Esc).
- [ ] OWNER MANUAL QA: the Settings window (D36). On each desktop
  platform: Settings, Back up and sync… and Configure Editors… each open
  one window on General, Sync and Editing; choosing another while it is
  open brings it forward on that tab. A change made there (the update
  check switch, an editor added, a preview limit) shows in the workspace
  at once and survives a restart, and a change made in the workspace
  (an editor added from Open With) shows in the open window without
  reopening it. Closing it leaves the app running and its main window
  drawing; reopening opens a fresh screen. Quitting while the Settings
  window is focused and the quit guard is armed (a transfer running)
  still asks first, on macOS with ⌘Q (the window forwards the request
  to the app). Closing the workspace window takes the Settings window
  with it. On Windows the window stays above the workspace. Linux was
  run under Xvfb (STATUS D36 section); macOS and Windows are compiled
  by CI only, so this row is their first run.
- [ ] OWNER MANUAL QA: more than one workspace window (D38). On each
  desktop platform: File ▸ New Window (⌘N / Ctrl+N) opens a window with
  a local home tab in each pane, as the active window, at the size of
  the one it came from; typing and shortcuts go to the window you are
  in, and clicking back into another window puts focus back where it
  was there. Tabs, navigation and connections in one window leave the
  other alone; a transfer started in one shows in both windows'
  Transfers and keeps running after its window closes. Close a tab on a
  server that the other window still browses: the other window stays
  connected. A host-key or password prompt appears in the window you
  are working in. On macOS the menu bar acts on the key window (New Tab,
  Close Tab, Get Info), ⇧⌘W closes the key window, and Enter Full Screen
  works on an extra window; on Linux and Windows View ▸ Enter Full
  Screen takes the window it was chosen in. Closing the first window
  while another is open only hides it; New Window then brings it back
  empty. Closing the last window, and Quit with several open, ask first
  when a transfer is running, then close everything. Quit with two
  windows open and relaunch: both come back with their tabs. On macOS
  with VoiceOver on, open a second window: the first window's elements
  still read correctly. Linux was run under Xvfb with openbox (STATUS
  D38 section); macOS and Windows are compiled by CI only, so this row
  is their first run.
- [ ] OWNER MANUAL QA: theme flip (light/dark) live-restyles listing,
  plan view, and editor; HiDPI scaling at 100 %/150 %/200 % shows no
  clipped chrome.
- [ ] OWNER MANUAL QA: scroll feel — listing, plan view, and editor
  scroll smoothly under native input on each platform (trackpad inertia,
  mouse wheel, scrollbar drag); no jank or stuck scrollbars.
- [ ] OWNER MANUAL QA: macOS Quick Look on real hardware: space-bar
  preview of the supported file kinds opens and dismisses cleanly
  (STATUS open item 26).
- [ ] OWNER MANUAL QA: tier-B benchmark suite run once on the reference
  macOS machine in release mode; results attached to the release PR as a
  readable artifact. The authoritative gate is the CI bench job's in-job
  tier-B runs against the CI-fingerprinted baseline, not this run
  (08 §6) — budget/baseline entries are scoped by build mode + OS (CI
  profile/Linux vs QA release/macOS), so the two are never cross-compared.
