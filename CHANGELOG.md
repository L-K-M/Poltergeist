# Changelog

## Unreleased

- **Remote transfers work.** Uploads, downloads, remote→remote copies,
  remote managed checkouts, previews, and remote sync endpoints now run
  through the engine's bridged transfer lease. 1.0.0 failed these tasks
  with `unsupported`.
- **Trust before secrets.** Connecting to a server for the first time now
  asks you to approve its host key before it asks for a password. An
  unreachable server fails without asking for a password at all.
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
