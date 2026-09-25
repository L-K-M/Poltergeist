# Poltergeist

A cross-platform two-pane file transfer client — SFTP first — for macOS,
Windows, and Linux, designed so mobile stays possible. Patterned after the
great macOS file-transfer apps (Transmit, ForkLift) and built as a sibling
of [Séance](https://github.com/L-K-M/Seance).

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*The ghost that moves your files.*

**Current version:** v<!-- version -->1.0.0<!-- /version --> · [Downloads and first-launch steps](docs/INSTALL.md) · [Releases](https://github.com/L-K-M/Poltergeist/releases)

## Your servers are your business

Poltergeist is open source and free. It has no account to create, no
telemetry, no analytics, no crash reporting, and no installer bundleware.
Beyond the servers you deliberately connect or back up to, it phones home
for exactly one thing: a link-only check that a newer release exists — on
by default, and one setting away from off. It tells you; you decide;
nothing auto-installs.

Passwords and secrets Poltergeist saves for you are sealed at rest under a
master key held in your operating system's keychain — never stored in
plaintext. With no OS keychain available, it will not save secrets at all
rather than fall back to something weaker. (Keys you already manage
yourself — an imported `~/.ssh` identity file — stay yours, where they
are.) Host keys are pinned on first use and a changed key is a hard stop,
not a shrug. If you back up your bookmarks, they leave your machine only
as end-to-end encrypted blobs to a Séance sync server — one you can
self-host — and the server cannot read them.

There is no paid tier, because there is nothing to gate. Transfer, sync,
and security are not features you rent.

## What Poltergeist is

- **Two independent panes**, each browsing a local folder or a remote server,
  with **tabs per pane** and drag-and-drop transfers between them.
- A **bookmarks sidebar** (ForkLift-style): favorite servers and folders,
  one click away, with **bookmark backup through Séance's E2E-encrypted sync
  server**.
- A **safe, fast, previewable sync feature**: see exactly what would be
  copied, updated, or deleted before anything happens.
- An **activity panel** showing live transfers and network operations.
- A **built-in editor** (shared lineage with Séance's conflict-aware remote
  editor) plus configurable external editors.
- The **usability bar is the point**: keyboard-first, fast, predictable, and
  polished — an app you'd happily use every day.

## Relationship to Séance

Séance is a personal SSH client with a session-scoped SFTP browser, an
E2E-encrypted sync server, and a hardened remote-edit pipeline. Poltergeist
inverts the emphasis — files first, terminal nowhere — while reusing Séance's
proven foundations (SSH/SFTP transport, TOFU host keys, vault, sync protocol,
editor). Improvements made here are ported back to Séance where they apply;
the porting policy is part of the plan.

## Known issues

- **Remote transfers in 1.0.0.** In the 1.0.0 release, tasks that name
  a remote endpoint (uploads, downloads, remote sync runs, and remote
  managed checkouts) fail fast with a typed `unsupported` error. The
  engine's bridged transfer lease (protocol v13) fixes this for the next
  release. See
  [STATUS open item 23](docs/STATUS.md).
- **Linux screen readers.** Flutter's Linux embedder exposes semantics
  through the legacy ATK layer; custom widgets are largely invisible to
  Orca/AT-SPI. Upstream tracks the rework in
  [flutter/flutter#159460](https://github.com/flutter/flutter/issues/159460)
  (checked 2026-09-22). Poltergeist builds the full semantics tree —
  merged row nodes, sort state, live-region completion announcements,
  focus-visible rings — and verifies it with automated semantics tests,
  but Linux screen-reader coverage is not claimed until upstream lands.
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
