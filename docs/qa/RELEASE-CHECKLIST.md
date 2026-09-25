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
  the native hit-testing needs a Mac).
- [ ] **Windows** — OWNER MANUAL QA: native titlebar; snap layouts work;
  Flutter-drawn `MenuBar` complete; Alt+F4 quits cleanly with a running
  queue (prevent-close flush prompt).
- [ ] **Linux** — OWNER MANUAL QA: server-side decorations; `.deb` and
  AppImage both launch; `StartupWMClass` maps the window to the desktop
  entry (the `StartupWMClass=Com.lkm.poltergeist_app` contract itself is
  enforced by `scripts/package-linux.sh` + its test, not manual).

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
  manager: the items arrive, the destination's default verb applies
  (Finder/Explorer move within a volume, copy across), a move away
  refreshes the source pane, and nothing is ever moved to the Trash. Esc
  mid-drag cancels, and the next click in the pane still selects. The
  drag image shows the name, or "N items" with a count badge. Drag out
  and back into the other pane: it lands like an in-app drag (a
  same-volume move stays a move).
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
- [ ] OWNER MANUAL QA (Linux, Windows): drag a remote row past the window
  edge: no OS drag starts, the pane shows the "use Download To…" hint,
  and the drag keeps working inside the window.
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
