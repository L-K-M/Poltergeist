# Release QA checklist

Manual QA per release — automated tests cannot see native chrome, IMEs, or
screen readers (08 §9). Copy this file into the release PR, fill every row
with the QA machine's result and date, and attach the filled copy to the PR.

## Per-platform chrome (D11)

- [ ] **macOS**: unified toolbar look; traffic lights placed correctly at
  every window size; native menu bar complete with enabled-states correct;
  Edit-menu routing (Copy/Paste against file list vs rename field vs
  editor); no "Show Tab Bar" leakage; focus flag cleared after closing the
  last editor (the SEA-008 class).
- [ ] **Windows**: native titlebar; snap layouts work; Flutter-drawn
  `MenuBar` complete; Alt+F4 quits cleanly with a running queue
  (prevent-close flush prompt).
- [ ] **Linux**: server-side decorations; `.deb` and AppImage both launch;
  `StartupWMClass` maps the window to the desktop entry.

## IME smoke

Flutter desktop on Windows is IMM32, not TSF — composition behavior is the
known-divergent surface.

- [ ] Rename a file with Japanese and Korean input on Windows, macOS, and
  Linux (IBus/fcitx): composition renders in place, Enter commits, Esc
  cancels the composition without cancelling the rename.
- [ ] Type CJK in the editor and the filter field; verify highlighting
  never fights composition (the `CodeEditingController` IME guard).

## Screen reader smoke

- [ ] **macOS VoiceOver** and **Windows NVDA** (Narrator as an optional
  secondary pass): traverse file rows (name–kind–size–date announced),
  column headers with sort state, tabs, sidebar groups (expanded state),
  activity rows (completion announced once); operate one full transfer
  keyboard-and-reader only.
- [ ] **Linux**: not tested — broken upstream (see README's known-issues
  note for the linked issue). Each release re-checks whether upstream has
  fixed it and drops the exclusion when the fix lands.

## Trust and platform behaviors

- [ ] First-launch unsigned-app paths (D23): Gatekeeper right-click-open on
  macOS, SmartScreen "More info → Run anyway" on Windows — both match the
  documented steps.
- [ ] Trash per platform (D15): macOS Put Back works; Windows Explorer
  undo restores; Linux restore-from-trash verified — `gio trash --restore`
  where the installed GLib supports the flag (it takes the trash-side
  suffixed name, not the original path), else `gio open trash://` + a
  file-manager restore; record which path the QA machine used.
- [ ] Drop-in from Finder/Explorer/Nautilus into each pane; in-app
  pane↔pane drag; confirm drag-out is absent (v1) and the "Download to…"
  path covers it.
- [ ] Theme flip (light/dark) live-restyles listing, plan view, and
  editor; HiDPI scaling at 100 %/150 %/200 % shows no clipped chrome.
- [ ] Tier-B benchmark suite run once on the reference macOS machine in
  release mode; results attached to the release PR as a readable artifact.
  The authoritative gate is the CI bench job's in-job tier-B runs against
  the CI-fingerprinted baseline, not this run (08 §6) — budget/baseline
  entries are scoped by build mode + OS (CI profile/Linux vs QA
  release/macOS), so the two are never cross-compared.
