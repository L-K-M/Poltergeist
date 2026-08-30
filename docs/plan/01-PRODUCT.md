# 01 — Product definition and positioning

This chapter fixes what Poltergeist is, who it serves, where it stands in the
competitive field, and what it deliberately refuses to be. It elaborates the
decision log in [00-OVERVIEW.md](00-OVERVIEW.md); where a statement here has a
decision number, that decision — not this prose — is the authority.

## 1. What Poltergeist is

Poltergeist is a cross-platform, SFTP-first, two-pane file transfer client:
local files or a remote server in either pane, tabs per pane, a ForkLift-style
bookmarks sidebar on the left, a collapsible Transmit-style activity panel
at the bottom (collapsing never hides activity: the status-bar transfer
chip always shows live queue state — D16), a built-in editor plus
external-editor round-tripping, and a safe,
previewable folder-sync feature. It is built in Flutter/Dart as a sibling of
Séance, the personal SSH client, and reuses Séance's transport, TOFU security,
encrypted sync, and editor foundations (D2, D3, D18) rather than reinventing
them. It is desktop software in the classic sense: one honest window, no
account, no telemetry, no server component of its own — bookmark backup rides
a Séance sync server the user may already run (D4, D18, D19).

The one-sentence product, verbatim from the overview:

> WinSCP's sync checklist with Transmit's polish and ForkLift's sidebar, on
> all three desktops, with E2E-encrypted bookmark backup through the Séance
> you already run — and no account, no telemetry, no rent.

Requirement R1 ("extremely high usability, polish, user-friendliness — the
point of the app") is the product. Every feature in this plan is subordinate
to it: a smaller feature set that is fast, legible, and honest beats a longer
checklist every time. The rest of this chapter explains why the market
rewards exactly that trade.

## 2. Who it is for

Three personas anchor every UX and scoping decision. When a design question
has no decision-log answer, resolve it in favor of these people, in this
order.

### P1 — the web developer deploying over SFTP

Maintains a handful of sites and apps on rented Linux boxes and shared
hosting. Lives in an editor, deploys by uploading changed files, occasionally
mirrors a `dist/` folder to a docroot. Today uses Transmit or ForkLift on
macOS, WinSCP or (grudgingly) FileZilla on Windows. Wants: instant-start
transfers, edit-remote-file-and-save-uploads, "Copy URL" for the file just
uploaded, and a sync that shows exactly what it will do before it does it.
Fears: uploading in the wrong direction, a mirror sync deleting something it
should not. Served chiefly by: the transfer queue (D16), the previewable
`SyncPlan` (D6), the editor pipeline (D17), focus-legibility in the UX spec
(02).

### P2 — the homelab and small-server operator who also runs Séance

Runs a NAS, a VPS or three, maybe a Raspberry Pi; already uses Séance as an
SSH client and possibly self-hosts its sync server. Hosts are sftp-only
chroots, busybox NAS boxes, and stock Debian — rsync is not reliably present
(one reason rsync is an exporter, not the engine — D6). Wants: the same
host keys, the same TOFU trust decisions, and the same bookmarks in the
terminal app and the file app, with backup that is end-to-end encrypted and
under their control. Served chiefly by: shared `seance_core` transport and
`TofuVerifier` (D2, D18), bookmark records on the Séance sync server (D4),
and planned "open in Séance" cross-links (v1.x, 04 §7.1; 02 marks the
affordances).

### P3 — the Windows or Linux user with no Transmit-class option

Knows exactly what a polished transfer client looks like — from screenshots,
from a work Mac, from a decade of "best FTP client" threads — and cannot buy
one. Windows offers dated-but-deep (WinSCP) or distrusted (FileZilla); Linux
offers essentially nothing in this class (Krusader aside, per the field
survey). This persona is the largest structural opportunity in the market and
the reason Windows and Linux ship from v1.0, not as afterthoughts (D1).
Served chiefly by: the per-platform conventions mandate (D11), the numeric
performance budgets (D12), Linux packaging that already exists in
`scripts/package-linux.sh` (D23).

Anti-persona, for scoping honesty: the enterprise MFT buyer (audit trails,
compliance, SSO), the cloud-storage power user who mainly needs S3/Drive
(D25 parks S3/WebDAV behind a capability matrix), and the ops engineer who
wants a connection hub over kubectl/docker (that is XPipe's territory, not
ours).

## 3. Competitive positioning

The field survey covered roughly twenty clients and file managers. The table
records, per competitor, what Poltergeist takes and what it refuses. "Take"
means the idea is scheduled somewhere in this plan; "refuse" means the
refusal is deliberate and durable.

| Competitor | What we take | What we refuse |
|---|---|---|
| Transmit 5 (macOS) | The polish benchmark: idle pane as Servers/Quick Connect/History launcher; 5-verb conflict model with per-direction defaults; sync Simulate dry-run; clock-skew handling; instant-start transfers with no upfront stat pass; add-server-from-live-connection; personality in icon and release notes | macOS-only forever; cloud-backend sprawl (~17 protocols with parity holes); summary-bar-only activity view (its launch mistake — D16 mandates per-item rows); shallow one-way-only sync |
| ForkLift 4 (macOS) | The sidebar model wholesale — one global left sidebar, favorites in named groups, a favorite is anything openable (folder, server, workspace, saved sync); Quick Open palette that teaches shortcuts (D21); sync preview with per-item veto; tabs per pane | iCloud-locked favorites sync; shipping a rewrite minus beloved behaviors (keyboard regressions dominated FL4's reception for years); "no bug fixes after license expiry" pricing |
| WinSCP (Windows) | The best sync UX in the field — checklist with per-row checkboxes, direction indicators, bulk toggles; the model for our `SyncPlan` preview (D6); thorough temp-file editor round-trip | Windows-only reach; visibly dated Win32 chrome; burying power behind dense dialogs. Move-candidate detection and per-pair diff are v2 ideas, not v1 promises |
| FileZilla (cross-platform) | Its user base — the largest pool of people waiting for something better; directory-comparison coloring as a cheap legibility win | Everything else: alien wxWidgets chrome, six collapsible sub-panes, bundled installer adware (the trust stance in §6 is the direct answer), a transfer history that does not work (D16 mandates one that does) |
| Cyberduck / Mountain Duck | Editor round-trip breadth (any external editor, re-upload on save); bookmark-as-first-class-object | Single-pane browsing (R2 requires two); the detached Transfers window (activity stays in-window, D16); mounting remotes as volumes — Mountain Duck's frozen "Synchronization ongoing" beachballs are the case study in hidden state (§5, trap 3) |
| Termius (cross-platform, subscription) | Proof that an E2E-encrypted cross-device vault is loved; SSH+SFTP under one roof validates the Séance pairing (D2, D4) | Renting basic SFTP behind a subscription; mandatory accounts; bolted-on file management with no real queue, sync, or editor loop |
| XPipe (cross-platform, open-core) | Respect for existing OpenSSH config — import `~/.ssh/config` including IdentityFile (D22 — XPipe fumbled IdentityFile); one-click edit-in-VS-Code energy (D17) | Paywalled security features (YubiKey behind a tier); JavaFX look-and-feel; being a connection hub rather than a transfer client |
| Muon / Snowflake | The feature checklist of what web devs do over SSH, minus its looks | Java Swing chrome; toolbox sprawl (terminal + process manager + disk analyzer) ahead of transfer depth |
| CrossFTP | Nothing beyond a cautionary datapoint | The whole JVM-generic pattern: cross-platform reach with native feel nowhere |
| Marta | Command-palette discipline: every action keyboard-addressable (D21) | Mouse-hostile spartanism; no remote story |
| Nimble Commander | Speed on huge directories as a bar to meet (D12) | Its remote anti-patterns: UI pauses before folders load, icon-only progress (latency must be visibly asynchronous — 02) |
| Double Commander | The honest lesson that toolkit matrices produce divergent bugs — one rendering stack (Flutter) sidesteps it (D1) | Shipping screens that say "ported"; D11 exists because owning 100% of platform conventions is the price of one stack |
| Total Commander / Krusader | Synchronize-dirs-with-preview lineage; proof Linux users respond to a real synchronizer | 1990s chrome; KDE lock-in; plugin-ecosystem-as-product |
| QSpace Pro | Evidence there is appetite for polished newcomers even on crowded macOS | Opaque provenance and vague privacy policy — for an app holding server credentials, trust is a feature (§6) |
| File Pilot / OneCommander | The "instant everything" feel bar our local panes are judged against on Windows (D12, D26) | No remote protocols to learn from; OneCommander's automation-depth creep |
| Files / Spacedrive | The lesson: polish without speed does not stick; grand abstractions fail before browsing is fast | Virtual-distributed-filesystem ambitions; shipping beauty over a slow lister |
| AeroFTP | Profile import as adoption fuel (D22); zero-telemetry positioning | 25-protocol kitchen sink; webview feel; bundled AI agent |
| GoodSync / ChronoSync / FreeFileSync | Proof deep sync sells | Overwhelming UI as the price of power — our sync power stays inside one previewable plan (D6); automation ambitions parked (D25) |
| rsync GUIs (Grsync, Acrosync) | Their one beloved feature: dry-run preview before commit — generalized into "the plan is the preview" (D6) and "Copy as rsync command" | rsync as the engine (absent on Windows servers, sftp-only chroots, busybox NAS; bypasses our auth/TOFU stack — D6) |

The position that falls out of this table: Poltergeist competes on depth in
exactly four surfaces — browsing, the transfer queue, sync preview, and the
editor loop — over one protocol done completely (SFTP), on three desktops,
with trust as an explicit feature. Everything else is either scheduled
consciously (D25, D27) or refused.

## 4. The ten differentiators

Tightened from the field survey's opportunity list; each is tied to the
decision that makes it real.

1. **WinSCP-grade sync preview with Transmit-grade looks, on all three
   desktops.** A typed `SyncPlan` that *is* the preview — per-item veto,
   direction and action legible per row, executor runs exactly what was
   reviewed (D6). Nobody ships this cross-platform. Flagship feature.
2. **E2E-encrypted, vendor-neutral bookmark backup.** Bookmark records travel
   inside Séance's existing encrypted-record protocol (`EncryptedRecord`, a
   new `RecordKind`) to a server the user can self-host (D4, D18). Panic Sync
   is Mac-only, ForkLift's is iCloud-only, Termius's is rented. Ours is open,
   E2E, and free.
3. **A Transmit-class experience on Windows and Linux at all.** The entire
   polish tier of this category is macOS-exclusive; D1 ships all three
   desktops at v1.0 and D11 makes each feel native.
4. **An honest, first-class transfer queue.** In-window bottom activity panel
   with per-item rows, reorder, per-item cancel/retry, conflict policy,
   bandwidth throttle, and a persistent history that actually works (D16) —
   against FileZilla's broken history and Cyberduck's detached window.
5. **The complete editor round-trip.** Séance's conflict-aware editor stack
   ported intact (D17): built-in editor with syntax highlighting and find,
   any external editor via `EditorRegistry`, managed checkout with SHA-256
   conflict authority (D7) — WinSCP's machinery, Cyberduck's breadth, plus a
   real built-in editor neither has.
6. **One SSH stack shared with a terminal sibling.** Keys, known-hosts pins,
   TOFU prompts, and 2FA behave identically in Séance and Poltergeist because
   they are the same code (D2, D5); "open terminal here" / "open files here"
   cross-links. Termius bundles both and rents the privilege; MobaXterm
   and Bitvise bundle both too, but as Windows-only, terminal-first
   tools — none pairs a first-class transfer client with a first-class
   terminal across platforms.
7. **Latency-honest remote browsing.** Cancellable navigation, visible
   per-pane connection state, no UI pause ever attributable to the network
   (D12 budgets; 02 specifies the affordances) — directly against Nimble
   Commander's freezes and Mountain Duck's hidden state.
8. **Import everything, previewed.** `~/.ssh/config` with IdentityFile at
   v1 via Séance's importer, FileZilla/WinSCP/Cyberduck formats in v1.x, all
   behind a preview + dedupe step (D22). Adoption is migration.
9. **Trust as a feature.** Open source, zero telemetry, no account, OS
   keystore for secrets, no installer adware, link-only update check (D18,
   D19) — positioned explicitly against the field's trust failures (§6).
10. **Command palette and total keyboard addressability.** Every action is a
    registered command feeding menus, shortcuts, and a Quick Open palette
    that displays and accepts shortcuts (D21). No one in this category has a
    real palette; it is also the cheapest path to power-user love, and it
    ports back to Séance (R10).

## 5. The five traps, and the structural guards

The survey's failure modes are not avoided by good intentions; each is pinned
to a decision, budget, or milestone that makes the failure hard to ship.

| # | Trap (who fell in) | Structural guard |
|---|---|---|
| 1 | Non-native uncanny valley (FileZilla, CrossFTP, XPipe, Double Commander) | D11 makes per-platform conventions non-negotiable: native titlebar on Windows/Linux, `macos_window_utils` unified toolbar, `PlatformMenuBar` on macOS, platform dialogs, shortcuts, and scroll physics. 02 specifies each; 08 tests keyboard and a11y invariants. One rendering stack (D1) removes the toolkit matrix that sank Double Commander |
| 2 | Slow basics kill polish (Spacedrive, Files) | D12's numeric budgets are CI benchmarks, not aspirations (10k-entry paint < 150 ms, tab switch < 100 ms, drop-to-transfer < 500 ms…). D8 keeps all heavy work off the UI isolate. D9 makes week one an engine fitness spike — the pool and scan designs are not finalized until M0 reports |
| 3 | Hidden or dishonest transfer state (Mountain Duck, Nimble, FileZilla history) | D16 declares the activity panel a trust organ: per-item rows always, every long operation visible, cancellable, inspectable; persistent queue and working history. D15 gives deletion one legible story. No mounting (§8) — mounting is where state goes to hide |
| 4 | Monetization that violates the tool contract (Termius, XPipe, FileZilla bundleware) | The Unlicense (§9) plus D19: no account, no telemetry, no paid tiers exist to gate anything. There is no rent to seek — the guard is that the mechanism is absent, not merely unused |
| 5 | Breadth before depth; sync that surprises (CrossFTP, AeroFTP, GoodSync's UI, Transmit's shallow sync) | SFTP-first scope with D25 as a written parking lot so nobody "helpfully" builds v2 early. D6's executor runs exactly the previewed plan and re-verifies preconditions per item; deletion requires the explicit Mirror mode; Update mode (no deletions) is the default. A sync that surprises the user is treated as a defect of the highest severity (08) |

## 6. Trust stance as product copy

D19 is a feature, and features get copy. The following text is the canonical
wording; the README, the website/release page, and first-run UI draw from it
verbatim or by tightening — never by adding claims. Do not promise more than
this (e.g. never claim "we cannot see your data" about the app itself; there
is no "we" at runtime — that is the point).

> **Your servers are your business.**
>
> Poltergeist is open source and free. It has no account to create, no
> telemetry, no analytics, no crash reporting, and no installer bundleware.
> It phones home for exactly one thing: an optional, link-only check that a
> newer release exists — it tells you, you decide, nothing auto-installs.
>
> Passwords and secrets Poltergeist saves for you are protected through
> your operating system's keychain, never stored in plain files. (Keys
> you already manage yourself — an imported `~/.ssh` identity file —
> stay yours, where they are.) Host keys are pinned on first use and a
> changed key is a hard
> stop, not a shrug. If you back up your bookmarks, they leave your machine
> only as end-to-end encrypted blobs to a Séance sync server — one you can
> self-host — and the server cannot read them.
>
> There is no paid tier, because there is nothing to gate. Transfer, sync,
> and security are not features you rent.

Engineering facts behind the copy, so it stays true: TOFU and the changed-key
hard block come from Séance's `TofuVerifier`; secrets ride the OS keystore
holding the master key; bookmark backup is whole-record sealed blobs in the
existing encrypted-record protocol (all D18, D4). The update check reuses
Séance's link-only banner pattern (D19, D23). Any future change that would
falsify a sentence of this copy requires editing D19 first (per the decision
log's change rule).

## 7. Personality and naming

The name stays **Poltergeist** (D24). The known collisions — the Capybara
PhantomJS driver, an Xcode file-watcher tool — are in unrelated categories
and acceptable for a personal open-source app; docs and release pages should
say "Poltergeist file transfer" once per page for search discoverability.
The product name is plain ASCII everywhere a file name or identifier appears
— this is a tested invariant in `packages/poltergeist_core` (Séance's
codesign lesson), and identifiers are already fixed:
`com.lkm.poltergeist_app` (Android/Linux GApplication),
`com.lkm.poltergeistApp` (Apple), Linux binary `poltergeist`.

Personality is part of the product (D24; Transmit's truck icon and Panic's
human voice are the precedent — a characterful identity compounds for
decades):

- **Icon direction.** A friendly ghost in motion — carrying, not haunting: a
  sheet-ghost hefting a box or envelope mid-flight. Readable at 16 px,
  distinctive in a dock, one strong silhouette. Master asset lives at
  `media-sources/poltergeist-icon.png` (created with the app scaffold;
  `scripts/package-linux.sh` requires it). Avoid horror tropes; the register
  is Casper, not Poltergeist-the-film.
- **Tagline.** "The ghost that moves your files." (fixed by D24). Use on the
  README, release page, and About box; do not coin variants per surface.
- **Voice.** Plain, warm, technically honest. Ghost and haunting puns are
  seasoning, not structure: at most one per surface (a release-notes
  headline, an empty-state line), never in error messages, confirmation
  dialogs, or anything a frightened user reads while deciding whether their
  files are safe. Error copy is literal and actionable, in the tradition of
  Transmit's transcript-window honesty.
- **Release notes.** Written by hand, in sentences, for humans: what changed,
  why, what to watch out for — plus honest "known issues" (the Linux
  screen-reader caveat of D20 belongs there, stated plainly). Never a bare
  commit list. No model identifiers anywhere (repo convention).
- **Honest docs.** Where the app has a limitation, the docs say so with
  numbers where possible (Transmit's "unreliable above 1 MB/sec" candor is
  the model).

## 8. Non-goals for v1

Each non-goal below is a decision, not an omission. The "reasoning users
will be given" column is real copy: it goes in the FAQ and in issue-template
responses, so the community hears a reason rather than silence. Internal
scheduling lives in the last column.

| Non-goal for v1 | Reasoning given to users | Where it lives |
|---|---|---|
| Protocol sprawl (S3, WebDAV, FTP, cloud drives) | "Poltergeist is SFTP-first on purpose. Every surface — queue, sync, editor — is built to be excellent over one protocol before any second one is considered. S3/WebDAV are on the v2 list behind a per-backend capability matrix, so a future backend can never silently break a promise the UI makes." | D25; 03 keeps the VFS seam (D3) clean |
| Mounting remotes as volumes (FUSE and kin) | "Mounting hides transfer state inside the OS, and hidden state is where trust dies — the frozen-'Synchronization ongoing' failure class. Poltergeist always shows you the queue instead." | Refused durably (§3 Mountain Duck row, §5 trap 3); not on the D25 list |
| Scheduled, watched, or background sync | "Sync in v1 is a supervised operation: you preview the plan, you run it, you watch it. Automation of an operation that can delete files earns trust only after the manual loop has it. Scheduled/watched sync is on the v2 list." | D25; engine stays open to it (05) |
| True two-way sync with baseline database | "Two-way sync without a state database cannot distinguish 'deleted here' from 'created there'. v1 ships Update, Mirror, and Additive two-way (never deletes); real bidirectional sync with tombstones and move detection is v2, built on the same plan/preview model." | D6, D25; 05 |
| Resumable transfers | "Needs ranged read/write support in the shared VFS first; the seam is planned, the feature is v2." | D25; D3 notes ranged read as an upstream addition |
| OS drag-out (promised files) | "Dragging out of Poltergeist onto the desktop requires per-OS 'promised file' machinery; it is v1.x, and the queue exposes the hook from day one." | D14 |
| Archives (create/extract/browse) | "Local zip create/extract lands in v1.x with slip-safe extraction; browsable and remote-side archives are scheduled later." | D27; 07 |
| Multi-window | "One window with two panes and tabs ships first; the workspace state is architected so multi-window becomes mechanical when Flutter's windowing API stabilizes." | D13, D25 |
| Custom Tools (user scripts) | "Powerful, and it deserves a real cross-platform shell story rather than a macOS-only one. Parked for v2." | D25 |
| Content search on remotes | "Honest cost: remote content search means scanning every file. We will not ship it until we can show its cost clearly. v2 list." | D25 |
| Mobile (iOS/Android) | "Desktop first. The architecture keeps mobile hooks (single-pane collapse, scoped file access, suspendable queue), and the constraints memo records what mobile will demand." | D29; 07 memo |
| Telemetry/crash reporting, accounts, auto-update | "These are not deferred features; they are refused ones. See the trust stance." | D19 (crash reporting may be reconsidered post-v1 only as opt-in, and only by amending D19) |

Two things that look like non-goals but are not: ssh-agent auth and
ProxyJump are table stakes scheduled as the first fast-follow after v1.0
with seams prepared during M2 (D10) — say "coming first, right after 1.0"
rather than "not planned"; and local↔local operations are first-class in v1
(D26), because a two-pane app whose local side feels second-rate loses P3 on
day one.

## 9. License posture

Poltergeist is released under the **Unlicense** — the file is already in the
repo. That is the strongest possible statement of §6: no copyleft lever, no
CLA, no dual-license upsell path; the code is a public-domain dedication.
The trust copy may say so plainly: "public-domain software; do anything you
like with it."

One dependency-hygiene fact must be handled before code moves (D30): Séance
currently has **no LICENSE file**. The git-pinned package dependencies
(`seance_protocol`, `seance_core` per D2) and especially the
copy-with-attribution ports of Séance app-layer code (managed-checkout
pipeline, editor stack, etc.) need Séance to declare a license first —
suggest the Unlicense to match, keeping the whole family friction-free.
This is tracked as a Séance-side prerequisite in 04's upstream-work section;
the porting ledger (`docs/PORTS.md`, per D2) records provenance for every
ported file regardless. Until Séance's license lands, git-depending on
pinned tags may proceed for development and CI — both repos share **one
rights holder**, who needs no license from themselves to build their own
code — but *publishing* release binaries that embed the pinned code
waits for the license too: this repo's Unlicense dedication grants third
parties no rights to the embedded Séance code, and §6's "do anything you
like with it" must never ship on an artifact it does not cover. In the
planned sequence this gate never actually bites — the first milestone
whose shipped app consumes Séance code is M2, and M2 already hard-gates
on PR-S0 landing (07 §2) — the sentence exists so a schedule change
cannot quietly falsify the trust copy. The
LICENSE is what any *third party* needs to consume, fork, or
redistribute either repo or anything built from it, and what the
copy-with-attribution step waits
for as a provenance-hygiene matter. No Séance source is copied into
Poltergeist before it lands —
sequencing that D2's copy-with-attribution step must respect.

## Definition of done

- The chapter states the one-sentence product verbatim from 00 and does not
  contradict any decision in the log.
- Three personas (P1 web deployer, P2 Séance-running operator, P3
  Windows/Linux user) are defined with fears/wants and mapped to the
  decisions that serve them; an anti-persona list bounds scope.
- The competitive table covers Transmit, ForkLift, WinSCP, FileZilla,
  Cyberduck/Mountain Duck, Termius, XPipe, and one-line entries for the rest
  of the surveyed field, each with an explicit take/refuse split.
- Exactly ten differentiators, each tied to a decision number.
- All five traps mapped to a concrete structural guard (decision, budget, or
  milestone), not to intentions.
- Trust stance exists as canonical user-facing copy consistent with D18/D19,
  with the engineering facts behind each claim named.
- Naming/personality section fixes tagline, icon direction, voice rules
  (including the no-puns-in-error-copy rule), and release-notes style; ASCII
  identifiers restated as the tested invariant they are.
- Every v1 non-goal carries user-facing reasoning and its deferral home
  (decision + chapter/milestone); D10 and D26 are explicitly distinguished
  from non-goals.
- License posture states the Unlicense for Poltergeist's original code —
  ported Séance files additionally follow the PORTS.md provenance
  convention and whatever license Séance declares — and the D30 Séance
  sequencing rule (no Séance source is copied until the D30 license PR,
  PR-S0, is merged on Séance `main`).

## Explicitly out of scope

- **Full UX specification** (window anatomy, panes, shortcuts, budgets as
  testable specs) — 02-UX.md.
- **Architecture and code-sharing mechanics** (packages, VFS, isolates,
  `docs/PORTS.md` process) — 03-ARCHITECTURE.md.
- **Bookmark schema, sync-server record format, and the Séance upstream PR
  sequence** (including the D30 license PR and the `RecordKind.unknown`
  fix that gates Design A) — 04-SEANCE-INTEGRATION.md.
- **Sync engine design and preview UX** (the `SyncPlan` model, safety rails,
  the full rsync analysis behind D6) — 05-SYNC.md.
- **Editor and preview pipeline details** — 06-EDITOR.md.
- **Milestone ordering and exit criteria** (M0 fitness spike, the D10
  fast-follow, the mobile-constraints memo) — 07-MILESTONES.md.
- **Benchmarks and test strategy enforcing D12 and the trap guards** —
  08-TESTING.md.
- **Icon production and asset pipeline** (01-PRODUCT.md fixes direction
  only) — the icon and derived assets are produced together with the app
  scaffold per docs/STATUS.md, and Linux packaging of them is handled by
  `scripts/package-linux.sh`.
