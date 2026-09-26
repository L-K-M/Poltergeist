# Poltergeist

A cross-platform two-pane SFTP file transfer client for macOS,
Windows, Linux, and Android. Built as a sibling of
[Séance](https://github.com/L-K-M/Seance).

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*The ghost that moves your files.*

**Current version:** v<!-- version -->1.0.1<!-- /version --> · [Downloads and first-launch steps](docs/INSTALL.md) · [Releases](https://github.com/L-K-M/Poltergeist/releases)


## Known issues

- **Remote transfers in 1.0.0 (fixed in 1.0.1).** In the 1.0.0
  release, tasks that name a remote endpoint (uploads, downloads, remote
  sync runs, and remote managed checkouts) fail fast with a typed
  `unsupported` error. 1.0.1 ships the engine's bridged transfer lease
  (protocol v13), which fixes this, so update if you are still on 1.0.0.
  See [STATUS open item 23](docs/STATUS.md).
- **Android.** The APK is a supported build from the release after
  1.0.1, with these gaps until each lands
  ([STATUS open item 33](docs/STATUS.md)):
  - the local pane is the app's own storage, not the whole device;
  - transfers stop when you leave the app, because Android freezes a
    backgrounded app that runs no foreground service;
  - there is no Share button, no "share to Poltergeist" upload, and no
    way for other apps to open your servers' files.
- **Linux screen readers.** Flutter's Linux embedder exposes semantics
  through the legacy ATK layer; custom widgets are largely invisible to
  Orca/AT-SPI. Upstream tracks the rework in
  [flutter/flutter#159460](https://github.com/flutter/flutter/issues/159460)
  (checked 2026-09-22). Poltergeist builds the full semantics tree —
  merged row nodes, sort state, live-region completion announcements,
  focus-visible rings — and verifies it with automated semantics tests,
  but Linux screen-reader coverage is not claimed until upstream lands.
- **Extra windows (desktop).** A window opened with File ▸ New Window
  does everything the first one does except, for now: take files dropped
  from other apps, drag files out to other apps, and on macOS show the
  unified toolbar, the system Quick Look panel (it uses Quick Look in the
  window), or anything to screen readers. Use the first window for those
  ([STATUS D39](docs/STATUS.md)).
- **Windows IME (IMM32).** Text input on Windows uses the legacy IMM32
  path: candidate-window positioning and composition-event delivery have
  known upstream defects (e.g.
  [flutter/flutter#128323](https://github.com/flutter/flutter/issues/128323),
  checked 2026-09-22). Rename fields and the editor inherit these
  behaviors; they are tracked upstream, not worked around locally.

## Where things stand

M0–M9 are executed: M0's dartssh2 fitness spike fixed the
transport numbers and M1–M9 built the app (panes, transfers, bookmarks,
sync, editor, polish). M10 is the v1.0 release — prepared and awaiting
the owner's tag; pre-releases v0.1.0 and v0.2.0 are published on the
[Releases page](https://github.com/L-K-M/Poltergeist/releases).
Implementation follows the plan in
[`docs/plan/`](docs/plan/) — start with
[`00-OVERVIEW.md`](docs/plan/00-OVERVIEW.md), the decision log. Current
state and next steps live in [`docs/STATUS.md`](docs/STATUS.md); install
instructions live in [`docs/INSTALL.md`](docs/INSTALL.md); the working
guide for agents and contributors is [`AGENTS.md`](AGENTS.md).
