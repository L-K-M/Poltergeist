# Poltergeist: engineering and product backlog

Consolidated 2026-09-26 from reviewed source at `913ca3da` and the sibling
review. The complete evidence, reproduction steps, scope limits and original
ideas are preserved in [tmp.md](tmp.md). Séance's `ANALYSIS.md` owns upstream
SSH/protocol/server work; this document owns Poltergeist integration and product
work. [STATUS](docs/STATUS.md) remains the implementation record and the
[decision log](docs/plan/00-OVERVIEW.md) governs product choices.

This is an unfinished-work list. An open implementation PR is awaiting owner
review, not merged functionality. Do not implement the same slice again.
Each task below has a bounded next action and an observable acceptance gate.
P0 means a trust boundary or critical loss risk; P1 means correctness, recovery
or important usability; P2 means substantial performance/accessibility/polish;
P3 means optional product exploration. Source findings are not live exploits.

## Implemented in open PRs from this review

| Finding | PR | Scope still awaiting owner review |
|---|---|---|
| PGE-01 | [#209](https://github.com/L-K-M/Poltergeist/pull/209) | Retain the backup's restore mapping when a replacement upload fails or is cancelled; flush journal records before replacement. The rename-before-journal crash window remains. |
| UI-01 | [#210](https://github.com/L-K-M/Poltergeist/pull/210) | Idempotent delete-dialog route completion and cancellation on dismissal/teardown. |
| PG-REV-001 | [#211](https://github.com/L-K-M/Poltergeist/pull/211) | Settle account-backup replies against their exact sent record so newer edits/deletes remain dirty. Shared LWW/revision policy remains. |
| PGE-03 | [#213](https://github.com/L-K-M/Poltergeist/pull/213) | Use the shared file/parent flush ordering before deleting a local cross-volume trash source; preserve originals on reported flush failure. Existing parent-fsync error suppression and remote durability remain. |

The final validation and review status is recorded below. These PRs are
intentionally left open. Remove their implemented scope from active work after
merge; preserve the named residuals.

## First safety work

### P1: Enforce the reviewed sync snapshot — PGE-02

Start at `packages/poltergeist_sync/lib/src/executor.dart:_verifySource` and
`_verifyDestination`, and `diff.dart:_matchedItem`. Source checks only kind/size;
destination checks reuse cross-endpoint mtime tolerance. Hash comparison does
not retain computed digests in the plan. Same-size post-preview edits can pass.

Split into source-mtime protection, retained hash preconditions, and explicit
same-endpoint destination rules. Check before destructive backup/removal.
Do not reuse accepted clock shifts or comparison tolerance to authorize a
post-preview mutation; adjust the documented plan contract where necessary.

Gate: same-length source edit, one-second destination edit, changed content
with preserved size/mtime in hash mode, Retry Failed, unreliable timestamps,
and unchanged files. Changed files conflict without touching destination.

### P1: Revalidate sync roots and source ancestors — PGE-04

`executor.dart:_checkParentChain` skips the root and is called only for the
destination. A top-level item checks no ancestor; source download checks the
leaf but can traverse a swapped parent. Capture canonical roots and validate
both roots plus relevant ancestor chains before execution and restoration.

Gate: replace destination root or source subfolder with a link after preview;
outside sentinel remains untouched and item conflicts. Preserve legitimate
initially selected aliases by canonicalizing before planning. A path-stat fix
does not eliminate concurrent races after validation; handle-relative native
operations are the longer-term boundary.

### P1: Complete platform durability guarantees — PGE-03 residual

PR #213 adds the missing shared local file/parent barrier to cross-device trash.
Do not reimplement that patch. The underlying `TransferJournalIo.fsyncDirectory`
still suppresses filesystem failures, and remote durability has no VFS primitive.
Define platform-supported guarantees and surface actual POSIX flush failures;
document unsupported directory flushing distinctly. Remote fsync needs its own
capability and must not be implied by a local fix.

Gate: actual file/parent flush failures prevent source deletion; unsupported
platforms have explicit behavior; ordinary rename remains fast; real cross-volume
fixture and crash testing. Unit operation-order tests do not prove power-loss
durability.

### P1: Restore safely across volumes — PGE-06

`journal.dart:restoreTrashedFiles` only renames back, although forward trash
supports EXDEV. It can remove the run-created current file before that reverse
rename fails. Add validated/durable reverse copy with exclusive staging and a
recoverable final replacement. Reuse snapshot checks for later user edits.

Gate: delete/update restore across volumes; failed copy or flush retains both
backup and current origin; changed current files are never overwritten;
successful restore preserves exact bytes and original name.

### P1: Persist state before publishing it in memory — PG-REV-004

`PersistentLocalRecordStore._mutate` changes live state before `_write`, then
heals its tail on failure. A failed cursor/tombstone write can appear committed
to later readers. Stage next state and publish after persistence, or define a
recoverable rollback/reload policy. Consider failures after rename separately.

Gate: inject failures into every record/cursor/displaced-winner mutation and
immediately perform another read/write; memory/reopened state obey the declared
contract. Domain changes and backup outbox still span separate files: plan a
transactional store if cross-file crash consistency is required.

### P1: Preserve valid stores through I/O errors — BOTH-REV-003

Main vault loading in `app/poltergeist_app/lib/services/file_stores.dart` catches
read failure as corruption. Port a shared behavior fix to both apps: read bytes
outside parse/schema catches, preserve retryable failures, quarantine only bad
content under a unique retained name, and expose actionable recovery.

Gate: permission/read failures leave bytes and trust untouched, retry succeeds,
bad UTF-8/JSON still quarantines, concurrent startup agrees, and failed saves
cannot publish an empty/partially mutated cache. Preserve re-key sidecar recovery.

## Account sync and shared security

### P0: Version authenticated account envelopes — BOTH-REV-006 / SOL-011

Upstream Séance owns `RecordCodec`. Kind/data are sealed; ID/time/device/deleted
are not, and deletion blobs are empty. Preserve Poltergeist's existing pin
conflict quarantine, but do not claim it authenticates the whole envelope.

Specify canonical client-authenticated identity, purpose, revision, epoch and
typed deletion; server sequence stays outside. Add compatibility readers,
old-client policy and migration/rollback fixtures before new writers. Coordinate
opaque wire IDs, durable revision history and replay protection in the same
migration. Never fork shared crypto locally.

Gate: field tamper, transplant, replay with winning metadata, forged tombstones,
old/new sibling interoperability and interrupted migration.

### P1: Batch large backup requests — PG-REV-002

`BookmarkCoordinator.runRound` pushes all dirty records at once; current upstream
Séance uses advertised limits and `batchForPush`. Audit the pinned dependencies,
bump them with the port audit, and consume the shared batcher in this coordinator.
Preserve exact-record settlement and accepted batches after later failure.

Gate: record/byte caps, advertised custom limits, old-server fallback, interruption
between batches, oversized single record and real HTTP server convergence.

### P1: Recover account activation as one operation — BOTH-REV-005

The staged vault re-key already exists. The remaining task is the account URL,
token, settings, key generation and sync-ledger transition around it. Journal
enrollment activation, block sync while unresolved, and retain old usable state
until the replacement is validated. Empty accounts need explicit key confirmation.

Gate: failure/restart at every persistence boundary, locked/missing key, old/new
account rollback and orphaned local secrets. Never upload under mixed account/key
state or synthesize a fresh master key over existing ciphertext.

### P1/P2: Adopt upstream SSH capabilities and secure transport policy

Séance now supports agent auth and saved-host jump chains; this older package
pin and Poltergeist's bindings need deliberate adoption, not another transport
fork. Audit signer lifetime, resolver capabilities, pool keys, every-hop TOFU,
interactive prompt serialization and unsupported mobile behavior.

Gate: real Unix/Windows agent, unavailable agent, chained auth/cancel/reconnect,
strict changed-key block at each hop, sftp-only chroot and import warnings.

Separately specify remote-HTTP account policy, allowing explicit loopback/tunnel
use where intended. Credentials and bearer tokens are not protected by record
encryption over cleartext HTTP. Test redirects, IPv6 and reverse-proxy base paths.
Upstream tasks also include synced-pin reconciliation, stale trust-dialog CAS,
hashed/revocable sessions, atomic account lifecycle and bounded server quotas.

## Files, cancellation and recovery workflows

### P2: Keep actual paths for both sync endpoints — PGE-05

Matching normalizes NFC/case, but `SyncItem.relativePath` stores only one side's
spelling. Carry per-side actual paths through plan, direction overrides, subtree
operations, journal and restore; retain a separate logical match/display key.
Version serialized plans compatibly. Never normalize I/O names globally.

Gate: NFC/NFD and case differences in both directions on strict fake filesystems,
mixed case sensitivity, nested folders, no duplicate names and exact restore.

### P1/P2: Make scan and hash cancellation release work — PGE-07

`ScanCancellation` is only a boolean; a pending listing or whole digest can delay
Cancel. Bridge a completion signal to VFS cancellation, release owned leases,
and ignore late completions. The pinned listing contract may need upstream work.
Only then consider bounded parallel hashing, based on measured workloads.

Gate: stalled listing/digest cancels promptly, later work never starts, leases
return, browse remains usable, no abandoned async errors.

### P1 feature: Expose and honor verification after transfer

D7 promises optional verification, but ordinary queue copies and native local
copies lack a user-facing verification mode. Add a persisted default/per-task
choice and compare landed content, not just outgoing bytes. Journal verification
results; a move must not delete its source before verification succeeds.

Gate: corruption-injecting destination, local/remote/remote-to-remote, cancellation,
failure reporting and source retention. Communicate cost and unchecked status.

### P1/P2: Make recovery and retention discoverable

Consolidates STATUS items 27-29 and PGE-01/06 residuals. Add interrupted-run
history, conservative temp reconciliation and a Recovery drawer over existing
journals/checkouts/trash. Expose exact origins, retained bytes and safe restore
actions. Add age/size notices and user-confirmed purge excluding live runs.
Warn when in-root backups may be served from a web document root; offer out-of-root
storage. Never silently expire the only recovery copy.

Gate: kill at each upload/rename/journal boundary, unknown temps, active runs,
orphaned journals, failed purge and later user edits. A committed but unjournaled
file needs reconciliation, not blind retry. Preserve unknown-size backups without
inventing zero as their size; standalone trash mappings currently require an int.
Measure per-record journal-flush overhead under many-small-file syncs.
Resume is a distinct feature from restart-from-scratch and belongs to the D25
design decision.

### P2 investigation: source changes and overlapping copy roots

Before changing code, reproduce the lower-confidence findings in tmp.md:
source mutation after copy before move deletion; child-before-parent root
normalization; folder copies into destinations reached by aliases/symlinks.
Test all actual enqueue paths, including OS drops. Escalate only reachable
failures; add canonical containment without rejecting valid cross-device work.

## Interface, aesthetics and platforms

### P1: Accessible and usable extra workspace windows — UI-05 / PG-REV-008

macOS extra views deliberately emit no semantics because the embedder otherwise
overwrites the main tree. Reproduce against the pinned engine, fix view-aware
routing or adopt a proven upstream version, then remove the workaround. Provide
an accessible main-window alternative while it exists. Keep native SDK-upgrade
tests for private macOS/Windows embedder APIs.

Gate: native VoiceOver in two windows, close/hide/reopen, unique titles and
correct focus. Separately complete secondary-window drop-in/out, Quick Look,
toolbar, Windows taskbar progress and remembered geometry. CI builds are not QA.

### P1 feature: Android file access and background transfers — UI-07

Implement SAF imports/exports with retained grants, foreground queue ownership,
Share and share-to-upload as separate slices. DocumentsProvider is a later
capability. Do not treat content URIs as stable paths or request all-files access
when grants suffice. Preserve explicit target choice and cancellation.

Gate: real providers/devices, revoked grants, background/process kill, notification
policy, low storage and restart. iOS remains explicitly unsupported until its
own storage, signing, editing and lifecycle gates pass.

### P1/P2: Show the real destination on phones — UI-06

`compact_selection_bar.dart` says Copy/Move to B while B is hidden. Show the host
and folder from the command's target snapshot, with an inspect/change action.
Make unavailable targets actionable and preserve full identity in semantics.

Gate: destination changes, reconnect/tab closure, long paths, 2x text/RTL and
queued transfers. Visible and actually queued targets must match at activation.

### P2: Show a settled preparation error in delete confirmation

PR #210 fixes the route lifetime. The existing preparation-error view still
shows an indeterminate counting spinner when `_confirmation` is null. Replace
it with a settled error state and explicit retry/cancel actions; restarting must
use a fresh cancellable count and cannot dismiss a newer route.

Gate: failed preparation stops announcing progress, retry succeeds or fails
clearly, and dismiss/retry races retain #210's idempotent completion behavior.

### P2: Bounded accessible notices, scaled chrome and private editing — UI-04/08/09

Port a bounded toast policy to both apps: visible limit, overflow/history,
live announcements, contrast-aware text and persistent actionable safety notices.
Respect focus, accessible navigation and reduced motion. Keep toasts above the
terminal prompt. Disable IME personalized learning for remote editor/search
fields, preserving composition and undo; it is a privacy hint, not OS isolation.

Gate: 20 notices at 320x568/2x text without overflow; one-shot actions and native
announcements; scaled breadcrumbs/tabs/auth dialogs; keyboard-open layouts and
no global clamp of the user's font scale.

### P2: Theme editing, endpoint identity and useful inspectors — UI-11/13

Themes already ship. Add resolved contrast diagnostics and a legible keyboard
reset/undo for an unreadable live palette. Verify theme copy/paste with Séance,
unknown terminal fields, partial malformed values, selections and status shapes.
Make the empty/multi-selection inspector summarize selection, destination and
next action from existing data, without remote I/O merely from painting.

Gate: extreme palettes, all presets, both settings engines, failed persistence,
single/multiple/no selection and narrow inspector. Preserve the shared semantic
glyph hues, quiet surfaces and explicit server colors.

The narrow comfortable sidebar fixtures expose little endpoint detail. Audit
existing tooltips and semantics, then make full user/host/port identity readily
discoverable without widening every row. Gate: long labels, identical hosts with
different users/ports, keyboard access and an explicit reveal affordance.

## Performance and engineering

### P2: Benchmark the shipped bridge and large editor — PGE-08 / PG-REV-009 / UI-10

D8's current queue and local hashing run on the UI isolate; remote-to-remote
bytes cross twice. Linux `copy_file_range` is synchronous despite async callers.
Measure M0/D12 budgets on the actual bridge and slow volumes, then move local
pumps/queue execution to workers if needed. Keep bounded messages and durability.

Also profile 4 MiB editor inputs, giant lines and Unicode: status byte/line scans
and text layout remain after syntax highlighting disables itself. Optimize
measured hot paths, not a speculative renderer replacement.

Gate: frame/input percentiles, cancel latency, memory and throughput under six
transfers, hash mode and large listings; editor typing/search/save correctness,
BOM/line endings and modest Android hardware.

### P2: Toolchain integrity and port parity — BOTH-REV-007/012

Pin/check appimagetool digests and source-aware cache keys before execution.
Test wrong cached binary and interrupted downloads. Keep the existing complete
release/checksum/version/license gates and documented personal signing policy.

Maintain executable parity checks for security-sensitive copied files and the
PORTS ledger; shared packages stay upstream. In particular, compare atomic-file,
vault, editor and prompt behavior, not only historical source timestamps.

### P1/P2 investigation: Make macOS test failures reproducible

The baseline below is not clean. Isolate the two `setTimes` access-time
assertions, `/var` versus `/private/var` temp-path failures, and the stalled
`pane_session_lifetime_test` with a disposed `PaneController` notification.
Run default macOS temporary paths and a canonical `TMPDIR=/private/tmp`
separately. Identify whether each failure is a fixture assumption, filesystem
behavior or a reachable product defect before changing containment rules.

Gate: each confirmed defect has a focused failing regression; full app tests
terminate under both temp configurations, delayed callbacks cannot notify
disposed panes, and genuine symlink escapes remain rejected. Do not loosen
safety checks or refresh goldens merely to obtain a green run.

## Small, distinctive product ideas

| Idea | First useful slice and acceptance criterion |
|---|---|
| Transfer receipt | Exact destination, counts, skips/failures, verification and retained backups, Reveal and Retry failed; partial/cancelled runs never look successful. Respect disabled history. |
| Explain this sync row / change postcard | Reasons and counts from the immutable plan, metadata/tolerance/hash policy and folder summary; overrides and exclusions match execution, with bounded rendering. |
| Ghost landing preview | Live destination breadcrumb and actual Copy/Move/count badge during drag; modifier/spring-navigation updates follow the real command snapshot, without delays or extra I/O. |
| Recovery drawer | Discoverable interrupted runs, dirty checkouts, trash usage and safe actions over existing stores; exact original paths, no silent cleanup. |
| Fingerprint sigil / connection passport | Deterministic fingerprint art plus full fingerprint, approval origin and jump route; memory aid only, changed key remains blocked. Coordinate with Séance. |
| Connection flight recorder | Opt-in bounded phase timings and previewed redacted export; no telemetry, credentials, commands or raw traces by default. |
| Production wards | Existing explicit host labels/colors appear in destructive-action review; never suggest arbitrary terminal commands are intercepted. |
| Breadcrumb return trail | Surface endpoint-scoped existing recents/history for fast returns; no duplicate store or hidden shell commands. |
| Quiet motion | One reduced-motion policy for transitions/receipts/toasts; real progress remains visible and terminal text never animates. |

## Evidence and verification limits

Local host used Flutter 3.47.3/Dart 3.13.3; CI pins Flutter 3.47.2. Baseline
core/sync analysis and app analysis were clean. Package baseline: 1780 passed,
26 skipped, two macOS access-time assertions failed. The full app baseline
reached 2721 passing/2 skipped/61 failures and then stalled; it was stopped
after more than ten minutes without progress (two additional incomplete-test
errors were reported during shutdown). Many failures rejected the Mac
temp alias `/var`; a controller teardown assertion also occurred. This is not
a green full-suite claim. Focused implementation checks are separate below.

All nine baseline sidebar capture tests passed, producing ten PNGs, with Arial/Courier substituted
through the fixtures' font aliases. Light/dark, narrow and phone/sidebar renders
look coherent without obvious overlapping rows. They do not prove native
accessibility, complete screen layout, IME behavior or release typography.
No local power-loss, physical mobile, Windows/Linux native-interaction or
sustained frame-time tests were performed in this review. Remote CI results
are recorded separately below.

## Implementation handoff

All code PRs remain open for owner review and merging. They are independent
branches from the reviewed main; resolve any overlapping STATUS prose when
merging. The final check/review snapshot is recorded at publication, and does
not certify later commits or native behavior.

| PR | Final reviewed head | Remote checks and review |
|---|---|---|
| #209 | `70d30e3c` | 19 checks passed; two dispatch-only M0 checks skipped. Two completed distinct-revision assessments, no agreed important findings. |
| #210 | `90f73b59` | 16 checks passed, including all five client builds; five integration/benchmark checks skipped by change filters. Two completed distinct-revision assessments, no agreed important findings. |
| #211 | `65cce109` | 19 checks passed, including SSH/server integration, benchmarks and all five client builds; two dispatch-only M0 checks skipped. Two completed distinct-revision assessments, no agreed important findings. |
| #213 | `7ddeff0a` | 19 checks passed, including SSH/server integration, benchmarks and all five client builds; two dispatch-only M0 checks skipped. Two completed distinct-revision assessments, no agreed important findings. |

| PR | Branch | Local evidence |
|---|---|---|
| #209 | `codex/preserve-sync-backup-recovery` | Failed/cancelled replacement regressions failed before repair; executor/journal and full sync suites pass, with real SSH fixtures skipped locally. Legacy journal compatibility is covered. |
| #210 | `codex/guard-delete-dialog-lifetime` | Six failing lifetime regressions repaired; 22 focused dialog/command tests and full Flutter analysis pass. Added the preparation-error dismissal case during review. |
| #211 | `codex/preserve-backup-edit-revisions` | Three races failed before repair; 110 core sync tests and latest core analysis pass. The unchanged implementation passed 53 app backup/settings tests and app analysis. A deduplication mutation makes the new duplicate-result regression fail. |
| #213 | `codex/flush-sync-trash-copies` | File-flush failure, operation-order and cancel-before-flush regressions failed before repair; 255 affected tests pass, three real-SSH fixtures skip, core/sync analysis clean. Unit barriers are not power-loss evidence. |

Review decisions to retain: #209's unknown-size recovery representation needs a
separate schema/restore migration, rather than supplying null to a required-int
field. #211's fake already clears displaced winners through `markSynced`, so an
additional clear is redundant. Typed diagnostics for malformed/duplicate backup
responses remain a small observability follow-up; do not log credentials or
repurpose decryption-corruption warnings for protocol anomalies.

#210's second assessment only suggested a STATUS prose line wrap; deferred after
two assessments on distinct revisions without agreed important findings. #209
also reached two such assessments. #211's second assessment on `65cce109` found
zero actionable suggestions, completing two distinct-revision assessments with
no agreed important findings. #213's review prompted the cancel-before-flush
regression and a clarification that directory-flush failures may be absorbed by
the existing shared helper; that durability limit remains an active task above.
Its second distinct-revision assessment found no agreed important issues;
optional direct coverage for remote copy cancellation and tighter STATUS wording
were deferred. The shared cancellation/cleanup path also handles remote copies,
but a remote fsync guarantee is not added or claimed. A follow-up regression
should cancel a non-local VFS after upload completion and prove that the original
remains, the orphan trash copy is removed, and no recovery mapping is emitted.
Clarify STATUS that remote copies skip the local barrier but honor post-copy
cancellation. No new remote failure was demonstrated during review.

Combined-patch check: #209 `70d30e3c`, #210 `90f73b59`, #211 `65cce109` and
#213 `7ddeff0a` applied together in a disposable checkout. Core/sync analysis,
642 backup/transfer/sync tests (three real-SSH skips), 70 app backup/settings/
delete-dialog tests and full app analysis passed. This is local integration
evidence, not a merge of any PR. The two sync patches needed an ordinary
three-way test-file merge; no source conflict remained. Keep both STATUS
entries when resolving adjacent documentation additions during owner merges:
a read-only merge preview of #209 and #213 confirms this documentation conflict
and no source/test conflicts.
