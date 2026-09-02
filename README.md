# Poltergeist

A cross-platform two-pane file transfer client — SFTP first — for desktop and
mobile, patterned after the great macOS file-transfer apps (Transmit, ForkLift)
and built as a sibling of [Séance](https://github.com/L-K-M/Seance).

*The ghost that moves your files.*

**Current version:** v<!-- version -->0.1.0<!-- /version --> · no tag or binaries yet — M0 is complete; the M1 scaffold is implemented, pending CI and the v0.1.0 rehearsal.

## What Poltergeist will be

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

## Where things stand

The repository carries infrastructure (CI, review workflow, build and
release scripts) and the design plan. M0 is complete. The M1 app scaffold is
implemented, but remains open until CI is green and the v0.1.0 rehearsal
completes. Implementation follows the plan in
[`docs/plan/`](docs/plan/) — start with
[`00-OVERVIEW.md`](docs/plan/00-OVERVIEW.md), the decision log. Current state
and next steps live in [`docs/STATUS.md`](docs/STATUS.md); the working
guide for agents and contributors is [`AGENTS.md`](AGENTS.md).
