# M5 CLOSURE RECORD — 2026-09-19

M5 (sidebar, bookmarks, workspaces) is CLOSED on evidence. Audited
against main head `eb13c03` (post-#163, the workspaces merge). One
audit PR adds the missing proofs, one narrow defect fix, the STATUS
sweep, and this record; no features, no M6 work.

## Exit criteria (07 §3.6)

1. **Bookmark CRUD, grouping, and reorder persist across restart** —
   MET. Core store proof already on main
   (`packages/poltergeist_core/test/bookmarks/bookmark_store_test.dart`):
   `persists and reloads bookmarks across instances`, `save stamps
   updatedAt and persists`, `remove deletes the row`, `reorder mints a
   key between the named neighbors`, `moveToGroup refiles and lands at
   the group tail`, `sections order groups by name, ungrouped last`,
   plus the atomic-write/quarantine/version matrix — 53 tests in
   `test/bookmarks/` post-audit. **Audit gap closed:** every
   `SidebarController` test ran on `FakeBookmarkStore`, so the row
   verbs' persistence across an app relaunch was unproven. New
   `app/poltergeist_app/test/services/sidebar_persistence_test.dart`
   drives reorder → refile-to-group → rename → delete through the
   controller over a real `FileBookmarkStore`, asserts the on-disk
   document (`{version, bookmarks}`), then reads the same file through
   a fresh store + controller — the restart boundary — and verifies
   section order, group membership, the rename, and the deletion. This
   test cannot pass on a fake: it asserts file bytes and a second
   store instance.

2. **localFolder/remotePath open in the chosen pane; workspace
   restores tab sets exactly** — MET. Exact-restore was already proven
   by #163's suite: `workspace_apply_test.dart` (`replaces both panes
   and returns the prior snapshot`, `restores the saved active tab,
   not the appended default`, `restores per-tab lenses through
   restoreTransientState`, guard-decline leaves both panes untouched),
   `workspace_library_test.dart` (`persists across a full restart —
   bookmarks file and detail document`), `workspace_commands_test.dart`
   (both-pane replace + toast Undo), `workspace_capture_test.dart`
   (sidebar row restore). **Audit gap closed:** the 02 §4
   preferred-pane rule had only remotePath→active-pane coverage. New
   `workspace_panes_test.dart` cases: a remotePath favorite with
   `preferredPane: right` opens `pane.right.*` while the left pane is
   active; `Open in Other Pane` on that same bookmark resolves to
   `pane.left.*` (modifier flips the preferred side, not just the
   active one); a localFolder favorite with `preferredPane: right`
   browses `/srv/exports` in the right pane's tab while the left keeps
   its home location.

3. **Device-local fields proven non-syncing by serialization test** —
   MET, strengthened for the M5 additions. The existing purity group
   asserts the on-disk records carry only synced keys and equal
   `toJson()` verbatim — `left`/`right` were already in the allowlist
   and a workspace record is in the fixture. New test `no local-only
   key nests inside the workspace or server payloads` walks every map
   key at every depth of every kind's `toJson()` against the
   device-local key set, and pins the workspace location shape to
   exactly `{server, path}` — a nested local-only field under
   `left`/`right`/`server`/`sync` would previously have passed
   unnoticed. No secure-bookmark blob key exists anywhere in the
   model's serialized shape.

4. **Sidebar fully keyboard-operable, including drag reorder/group,
   D20 semantics on every row** — MET after one real defect fix.
   Drag coverage already existed (`a drop on a row lands on its edge
   side`, `a drop on a group header refiles the bookmark`); header
   keyboard toggle existed (`a tapped header holds focus for keyboard
   toggles`). **New coverage:** `arrow keys traverse the rows and
   Enter opens the focused one` (arrows + Enter + Space activation),
   `Shift+F10 raises the focused row's context menu`, and `every row
   kind carries its D20 button semantics` — all four favorite kinds,
   the live connection row, and both section-header kinds (header +
   button + expanded state, collapsed header reads expanded:false).
   **Defect found and fixed red-first:** a favorite row announced
   `button: true` even when `onOpenFavorite` is null — an inert row
   announcing an activatable role, exactly the WCAG 4.1.2 dead
   affordance the connection row's `button:` gate prevents. The new
   `a favorite with no open seam announces inert, not a button` failed
   against the unconditional flag, then passed after gating
   `button:` on `view.onOpenFavorite != null` in
   `sidebar_view.dart`.

## Risk check

- **Schema drift vs PR-S1:** none. The synced shape is the pinned
  `seance_protocol` `Bookmark.toJson()` verbatim; the purity suite
  pins the key set. The pinned model at `2e6d1f1` carries PR-S1's
  forward-compatible decode.
- **04 §2.1 temporary-copy bookkeeping:** `docs/PORTS.md`'s M5 entry
  is accurate — no copied model exists, PR-S1 is in the pin's
  ancestry, and the clause is retired. `sortKeyBetween` and
  `groupBookmarks` are fresh Poltergeist code over the upstream
  struct (PORTS records both as non-ports).
- **Silent fork:** none — `seance_core`/`seance_protocol` are consumed
  at the pin; nothing in `src/bookmarks/` copies Séance source.
- **AltGr+S (from #162):** recorded, not resolved — see open item 24.
  The collision is the whole Ctrl+Alt+letter column of 02 §8.3's
  Windows/Linux table (sidebar S, activity A, preview P, sync
  browsing B, new file N, edit E, synchronize Y, pane-focus arrows),
  not just S. Decision needed from the spec owner: re-letter the
  column, suppress app-scope activators under text-field focus, or
  both.

## §3.12 close chores

- STATUS.md swept: header reads M3+M4+M5 closed / M6 next; dated
  closure section added; open item 24 added.
- PORTS.md: no update needed — the M5 section (2026-09-19) already
  records the no-copy posture; re-verified against the pin during
  this audit.
- Séance pin cannot bump — no upstream tag contains `2e6d1f1`
  (open item 2); the S1 release M6 Design A needs is the same tag.
- No `TODO(pin)` markers in the tree.
- Mobile invariant (07 §5, M5 row) re-verified: the synced `Bookmark`
  model carries no device-local fields at all, so per-device grants
  (scoped-access blobs today, SAF tree URIs tomorrow) can only live
  in the device-local stores — collapse state in
  `AppPreferences`, workspace detail in `settings.json`, probe facts
  in the probe owner — all fenced off by the purity suite.
- `v0.5.0` tag chore NOT run — matching M3/M4's untagged closes; a
  tag push publishes release assets, left to the supervisor/owner
  (`lkm-release` at `~/.local/bin`).

## Honest gaps carried forward

- Open item 24 (above): the Ctrl+Alt+letter chord family needs a spec
  decision; AltGr users on affected layouts can fire app commands
  while typing until it lands.
- Open item 23's remote half: remote transfers still fail honestly
  until the engine protocol grows transfer verbs.
- `savedSync` favorites post the honest not-yet notice — their open
  verb lands with the 05 sync preview (02 §3), an M6-neighbor
  surface, not an M5 gap.
- Keyboard-operable drag reorder/group is covered by the store-level
  `reorder`/`moveToGroup` verbs and pointer-drop widget tests; a
  dedicated keyboard drag affordance (cut/paste-style move) is not a
  §3.6 requirement and stays unimplemented — menus already expose the
  same refile/reorder through keyboard-reachable items.

## Local verification (this audit host)

- `dart test packages/poltergeist_core` — 1239 passed, 18 skipped
  (fixture-gated; Docker/SSH-integration skips as before).
- `flutter test` (app/poltergeist_app) — 1325 passed.
- `dart analyze packages/poltergeist_core` — clean.
- `flutter analyze` (app) — clean.
- Red-first witness: `a favorite with no open seam announces inert,
  not a button` failed before the `sidebar_view.dart` gate and passed
  after; all other additions are coverage proofs that pass on the
  merged code (they assert file bytes / engine open calls / semantics
  nodes a fake or absent feature could not produce).
- CI run IDs for the exact PR head are recorded in the PR body.
