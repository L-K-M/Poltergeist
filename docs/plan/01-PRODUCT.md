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
refusal is deliberate and durable. A third category — deferred to v2
(D25) — is neither taken nor refused: where a row names a v2 idea, read
it as parked (§8 lists each non-goal with the decision that refuses or
defers it).

| Competitor | What we take | What we refuse |
|---|---|---|
| Transmit 5 (macOS) | The polish benchmark: idle pane as Servers/Quick Connect/History launcher; 5-verb conflict model with per-direction defaults; sync Simulate dry-run; clock-skew handling; instant-start transfers with no upfront stat pass; add-server-from-live-connection; personality in icon and release notes | macOS-only forever; cloud-backend sprawl (~17 protocols with parity holes); summary-bar-only activity view (its launch mistake — D16 mandates per-item rows); sync with no plan-grade preview or deletion-safety story (our own true two-way sync is deliberately v2 too, §8 — the v1 difference is the previewable, never-surprising plan, D6) |
| ForkLift 4 (macOS) | The sidebar model wholesale — one global left sidebar, favorites in named groups, a favorite is anything openable (folder, server, workspace, saved sync); Quick Open palette that teaches shortcuts (D21); sync preview with per-item veto; tabs per pane | iCloud-locked favorites sync; shipping a rewrite minus beloved behaviors (keyboard regressions dominated FL4's reception for years); "no bug fixes after license expiry" pricing |
| WinSCP (Windows) | The best sync UX in the field — checklist with per-row checkboxes, direction indicators, bulk toggles; the model for our `SyncPlan` preview (D6); thorough temp-file editor round-trip | Windows-only reach; visibly dated Win32 chrome; burying power behind dense dialogs. Move-candidate detection and per-pair diff are v2 ideas, not v1 promises |
| FileZilla (cross-platform) | Its user base — the largest pool of people waiting for something better; directory-comparison coloring as a cheap legibility win | Everything else: alien wxWidgets chrome, six collapsible sub-panes, bundled installer adware (the trust stance in §6 is the direct answer), a transfer history that does not work (D16 mandates one that does) |
| Cyberduck / Mountain Duck | Editor round-trip breadth (any external editor, re-upload on save); bookmark-as-first-class-object | Single-pane browsing (R2 requires two); the detached Transfers window (activity stays in-window, D16); mounting remotes as volumes (D31) — Mountain Duck's frozen "Synchronization ongoing" beachballs are the case study in hidden state (§5, trap 3) |
| Termius (cross-platform, subscription) | Proof that an E2E-encrypted cross-device vault is loved; SSH+SFTP under one roof validates the Séance pairing (D2, D4) | Renting basic SFTP behind a subscription; mandatory accounts; bolted-on file management with no real queue, sync, or editor loop |
| MobaXterm / Bitvise (Windows) | Proof that bundling terminal + transfers earns loyalty | Windows-only, terminal-first: the transfer side is a side dish, never the product |
| XPipe (cross-platform, open-core) | Respect for existing OpenSSH config — import `~/.ssh/config` including IdentityFile (D22); one-click edit-in-VS-Code energy (D17) | Paywalled security features (YubiKey behind a tier); JavaFX look-and-feel; being a connection hub rather than a transfer client |
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
| GoodSync / ChronoSync / FreeFileSync | Proof deep sync sells — FreeFileSync in particular ships preview-grade (dry-run comparison) sync across Windows/macOS/Linux | Overwhelming UI as the price of power — our sync power stays inside one previewable plan (D6); automation ambitions parked (D25) |
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
   reviewed (D6). Nobody ships this combination cross-platform — the
   preview-grade sync, the polish, and all three desktops at once.
   FreeFileSync ships preview-grade sync on all three desktops but not
   the polish (§3); the rsync GUIs ship only the preview. Flagship feature.
2. **E2E-encrypted, vendor-neutral bookmark backup.** Bookmark records travel
   inside Séance's existing encrypted-record protocol (`EncryptedRecord`, a
   new `RecordKind`) to a server the user can self-host (D4, D18). Panic Sync
   is Apple-only, ForkLift's is iCloud-only, Termius's is rented. Ours is open,
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
   conflict authority (D7) — WinSCP's machinery, Cyberduck's breadth, plus
   syntax highlighting: WinSCP's own built-in editor is explicitly
   Notepad-equivalent (its docs say so), and Cyberduck has no built-in
   editor at all.
6. **One SSH stack shared with a terminal sibling.** Identity-file keys,
   known-hosts pins,
   TOFU prompts, and 2FA behave identically in Séance and Poltergeist because
   they are the same code (D2, D5 — at v1 every shared auth path except
   ssh-agent and ProxyJump is in scope; those two land in the first
   post-1.0 fast-follow, D10); "open terminal here" / "open files here"
   cross-links (v1.x, 04 §7.1). Termius bundles both and rents the privilege; MobaXterm
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
   D19, D23) — positioned explicitly against the field's trust failures (§6).
10. **Command palette and total keyboard addressability.** Every action is a
    registered command feeding menus, shortcuts, and a Quick Open palette
    that displays and accepts shortcuts (D21). ForkLift's Quick Open and
    Marta's command-palette discipline (§3) are the in-category
    precedents — both macOS-only; no one ships a full command palette
    across all three desktops. It is also the cheapest path to power-user
    love, and it
    ports back to Séance (R10).

## 5. The five traps, and the structural guards

The survey's failure modes are not avoided by good intentions; each is pinned
to a decision, budget, or milestone that makes the failure hard to ship.

| # | Trap (who fell in) | Structural guard |
|---|---|---|
| 1 | Non-native uncanny valley (FileZilla, CrossFTP, XPipe, Double Commander) | D11 makes per-platform conventions non-negotiable: native titlebar on Windows/Linux, `macos_window_utils` unified toolbar, `PlatformMenuBar` on macOS, platform dialogs, shortcuts, and scroll physics. 02 specifies each; 08 tests keyboard and a11y invariants. One rendering stack (D1) removes the toolkit matrix that sank Double Commander |
| 2 | Slow basics kill polish (Spacedrive, Files) | D12's numeric budgets are CI benchmarks, not aspirations (10k-entry paint < 150 ms, tab switch < 100 ms, drop-to-transfer < 500 ms…). D8 keeps all heavy work off the UI isolate. D9 makes week one an engine fitness spike — the pool and scan designs are not finalized until M0 reports |
| 3 | Hidden or dishonest transfer state (Mountain Duck, Nimble, FileZilla history) | D16 declares the activity panel a trust organ: per-item rows always, every long operation visible, cancellable, inspectable; persistent queue and working history. D15 gives deletion one legible story. No mounting, ever (D31; §8) — mounting is where state goes to hide |
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
> Beyond the servers you deliberately connect or back up to, it phones
> home for exactly one thing: a link-only check that a newer release
> exists — on by default, and one setting away from off. It tells you;
> you decide; nothing auto-installs.
>
> Passwords and secrets Poltergeist saves for you are sealed at rest under a
> master key held in your operating system's keychain — never stored in
> plaintext. With no OS keychain available, it will not save secrets at
> all rather than fall back to something weaker. (Keys
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
hard block come from Séance's `TofuVerifier`; secrets are sealed at rest
under a master key held in the OS keystore (so "never stored in
plaintext" is exact — the store on disk is ciphertext, the key is in the
keystore — and where the OS offers no keystore, as on Linux without a
secret service, saving secrets **fails closed** rather than falling back
to any on-disk key, so the claim stays unconditional); bookmark backup is whole-record sealed blobs in the
existing encrypted-record protocol (all D18, D4). The update check reuses
Séance's link-only banner pattern (D19, D23); the "phones home for exactly
one thing" claim is enforced, not merely asserted — an 08 egress test
audits the app's outbound destinations and fails on any host beyond the
connections configured in its fixtures (a stub SFTP endpoint and a stub
sync server standing in for the user's real servers, since a CI test has
no real user configuration), the fixture sync server (only when backup
is enabled),
and the single update-check URL — gated on its own setting, not on
backup being enabled (they are deliberately different conditions: backup
is opt-in, the update check is opt-out per D19/D23, and conflating the
two in the egress test would produce a false pass or false fail on this
copy's flagship claim). Any future change that would
falsify a sentence of this copy requires editing the governing decision
first — D18 (keystore sealing, TOFU, E2E blobs), D4 (bookmark records on
the sync server), D23 (link-only update distribution), or D19
(accounts/telemetry/paid tiers), whichever the change touches — per the
decision log's change rule.

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
| Mounting remotes as volumes (FUSE and kin) | "Mounting hides transfer state inside the OS, and hidden state is where trust dies — the frozen-'Synchronization ongoing' failure class. Poltergeist always shows you the queue instead." | Refused durably by D31 (§3 Mountain Duck row, §5 trap 3); not on the D25 list |
| Scheduled, watched, or background sync | "Sync in v1 is a supervised operation: you preview the plan, you run it, you watch it. Automation of an operation that can delete files earns trust only after the manual loop has it. Scheduled/watched sync is on the v2 list." | D25; engine stays open to it (05) |
| True two-way sync with baseline database | "Two-way sync without a state database cannot distinguish 'deleted here' from 'created there'. v1 ships Update, Mirror, and Additive two-way (never deletes); real bidirectional sync with tombstones and move detection is v2, built on the same plan/preview model." | D6, D25; 05 |
| Resumable transfers | "In v1, an interrupted transfer restarts from the beginning. Picking up where it left off needs protocol plumbing we haven't built yet; the groundwork is planned and resuming is on the v2 list." | D25; D3 notes ranged read as an upstream addition |
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

Poltergeist's original code is released under the **Unlicense** — the file
is already in the repo. That is the strongest possible statement of §6: no
copyleft lever, no CLA, no dual-license upsell path; the code is a
public-domain dedication. The trust copy may say so plainly — "public-domain
software; do anything you like with it" — **provided every line in the
shipped artifact is actually Unlicensed**, i.e. provided Séance also lands
the Unlicense for PR-S0 (below). If PR-S0 instead lands a different
permissive, attribution-compatible license (MIT, BSD, …) — which the gate
accepts — the ported files it covers carry that license's own attribution
terms, PORTS.md records provenance per file, and both the trust copy and the
repo-level Unlicense dedication get scoped down to "original code" rather
than the whole artifact, so neither over-claims rights the repo cannot
actually grant.

One dependency-hygiene fact gates landing any Séance-derived code in this
repo and gates publishing — other development is not gated (D30, and this
paragraph's own carve-out below): Séance
currently has **no LICENSE file**. The git-pinned package dependencies
(`seance_protocol`, `seance_core` per D2) and especially the
copy-with-attribution ports of Séance app-layer code (managed-checkout
pipeline, editor stack, etc.) need Séance to declare a license first —
suggest the Unlicense to match, keeping the whole family friction-free.
This is tracked as a Séance-side prerequisite in 04's upstream-work section;
the porting ledger (`docs/PORTS.md`, per D2) records provenance for every
ported file regardless. Until Séance's license lands, git-depending on
pinned commit SHAs (tags can be re-pointed; SHAs cannot) may proceed for
development and CI — both repos share **one rights holder**, who needs no
license from themselves to build their own code.

That single-holder claim is **verified against recorded authorship, not
assumed**, by this audit procedure:

- **Command**: `git --no-replace-objects -c log.mailmap=false log <pinned-SHA>
  --format='%an <%ae>%n%cn <%ce>%n%(trailers)' |
  LC_ALL=C sort -u` — `log.mailmap` and `refs/replace` are pinned off
  because either can rewrite recorded identities per clone (a mailmap
  entry can canonicalize — or launder — an external contributor's
  address onto the maintainer's own, and a replace ref changes recorded
  authorship wholesale, both defeating the byte-stability `LC_ALL=C`
  buys); needs a git with the bare `%(trailers)` placeholder
  (verified present since at least git 2.17, 2018, via git-scm.com's
  archived pretty-formats docs — far below any git a 2026-era contributor
  runs, so a non-constraint rather than a version floor worth pinning
  precisely), which surfaces every attribution trailer (`Co-authored-by`,
  `Signed-off-by`, `Reported-by`, …) *in the message's final trailer
  block* — git's trailer parser only recognizes that one block (verified
  empirically: a `Co-authored-by:` line followed by another paragraph is
  invisible to `%(trailers)` but still matches `--grep`) — not
  `Co-authored-by` alone, since
  any of them can be the only automated trace of an external contribution
  the maintainer committed under their own identity. Committer identity
  (`%cn <%ce>`) rides alongside author identity because a rebase, a
  `git am`, or a merge bot can record a different committer than author —
  another automated trace the block must not miss.
- **Companion scan**: `%(trailers)` misses an attribution line stranded
  outside the final trailer block, so also run a whole-message sweep and
  reconcile it against the sorted identity record above: `git log
  <pinned-SHA> -i --grep=co-authored-by --grep=signed-off-by
  --grep=reported-by --grep=helped-by --grep=reviewed-by --grep=tested-by
  --grep=suggested-by --format='%H %an <%ae>'` (multiple `--grep`s OR by
  default, exactly as the external-hit procedure below already relies
  on). A commit this sweep lists whose attribution line is absent from
  the sorted identity record means the block parse missed it — treat that
  attribution exactly like an external hit, below.
- **Scope**: walks **only the pin's ancestors** (the code actually
  embedded) — plain `git log <pinned-SHA>` traverses every parent
  transitively regardless of refs, so **no `--all`**, which would union
  in every ref's history and fold in post-pin commits, unrelated
  branches, and synthetic `refs/pull/*/merge` authors, spuriously
  tripping the block and making the record non-reproducible as upstream
  advances. Run in a **full, non-shallow** clone so the ancestor walk is
  never silently truncated; `LC_ALL=C` keeps the recorded output
  byte-stable across machines.
- **Record**: the output goes to `docs/PORTS.md` against the audited
  commit SHA and is re-run whenever the pinned Séance ref changes (an
  accepted upstream patch reaches Poltergeist only then, and CI can
  observe the pin moving); patches applied under the owner's identity are
  attributed to their real author by hand. The audit bounds what git
  *recorded*, not what exists: content with no authorship trace at all —
  a vendored file, a snippet pasted into a commit the owner authored,
  history predating the repo — is invisible to it, so the single-holder
  conclusion additionally rests on Séance containing no vendored
  third-party code, checked on the same trigger as the audit itself —
  when the pin first lands and whenever the pinned ref changes — by
  inspecting the tree diff old-pin..new-pin for new vendored directories
  or foreign license/copyright headers, never a one-time check: a
  vendoring commit added after an earlier check lands under the owner's
  own identity, invisible to the `git log` identity lines, so only
  re-scanning on every pin change catches it before it flows into a
  published binary.
- **On an external hit**: pinpoint its exact commits by re-running the
  audit scoped to that author (`git -c grep.patternType=basic log
  <pinned-SHA> -i --author="<email>"
  --committer="<email>" --grep="<email>"` — `grep.patternType` is pinned
  so a contributor's local config (e.g. `perl`) can't silently change
  what the escaping rule below means; git ORs `--author`,
  `--committer`, and `--grep` by default, so this catches the person as
  commit author, committer, *or* trailer co-author under any trailer kind
  (`Co-authored-by`, `Signed-off-by`, `Reported-by`, …); `--committer` is
  not optional here — it is the only one of the three that matches the
  committer identity the initial audit's `%cn <%ce>` was added to catch,
  and neither `--author` nor `--grep` matches it. All three patterns are
  git's default POSIX **basic** regular expressions, where `.` (and,
  rarely, `*` in a generated local part) are the BRE-active characters in
  an address and must be escaped — `+` is a literal BRE character and
  must *not* be escaped, since GNU BRE reads `\+` as a
  one-or-more quantifier that then fails to match a literal `+` (verified
  empirically on GNU grep: `grep "a+b"` matches a literal `a+b`,
  `grep "a\+b"` does not — BSD/macOS libc BRE also treats `\+` as literal
  rather than a quantifier, so the operative rule, never escape `+`,
  holds on both regex flavors even though the specific failure mode
  differs) — an address like `user+tag@example.com` therefore needs no
  escaping of its `+` at all, only its BRE-active characters escaped
  (every real domain has at least one `.`, so "match on the
  metacharacter-free domain"
  is not a real escape hatch — escape the dots, and any `*`, in whatever
  substring is
  chosen, full address included) and record
  them in PORTS.md, so the block acts on the commits actually ancestral
  to the pin rather than a bare name. That contribution's code then waits
  for the LICENSE like any third party's — which, since the
  single-holder premise no longer holds for the commits it touches,
  includes rewinding the dev/CI git dependency to a pin whose ancestry
  excludes it (git ancestry is monotonic, so advancing the pin keeps
  every ancestor embedded; only a rewind to a commit that predates the
  contribution drops it) or obtaining a grant covering it — and blocks
  the copy-with-attribution ports until they grant it. A bot-authored hit
  (a merge bot, a CI-triggered commit, Dependabot) fits neither remedy —
  there is no human to rewind past on principle or ask for a grant — so
  PORTS.md records the maintainer's by-hand call instead: content-free
  bot commits (merges, version bumps with no code change) are noted and
  cleared; content-bearing ones with a human-authored underlying change
  are attributed to that human; content-bearing ones with *no* human
  underlying change — a Dependabot lockfile/manifest regeneration, the
  common case — are noted as mechanically derived from already-licensed
  published dependency metadata and cleared on that basis, never
  attributed to an author that doesn't exist.

The **hard gate** comes first: no Séance source is copied into
Poltergeist until the D30 license PR (PR-S0) merges on Séance `main`
**with a permissive, attribution-compatible license** — the gate is
content-aware, not a merge-event checkbox. If PR-S0 somehow landed
anything else (a copyleft term, say), D30 reopens rather than proceeding
under PORTS.md alone, because provenance records conflicts; it does not
resolve them. This sequencing is imposed by **D30**, which D2's
copy-with-attribution step respects; the LICENSE — together with whatever
license Séance declares for the ported files, whose provenance PORTS.md
records — is what any *third party* needs to consume, fork, or
redistribute either repo or anything built from it.

*Publishing* release binaries that embed the pinned code waits for the
license too: this repo's Unlicense dedication grants third parties no
rights to the embedded Séance code, and 01 §6's "do anything you like
with it" must never ship on an artifact it does not cover. In the planned
sequence this gate never actually bites — the first milestone whose
shipped app consumes Séance code is M2, and M2 already hard-gates on
PR-S0 landing (07 §2) — the clause exists so a schedule change cannot
quietly falsify the trust copy. There is no upstream-veto risk to plan
around: both repos are the same owner's, so a stalled PR-S0 is a
scheduling risk (07 §6 risk 4), never a rejection — and never a reason to
fork or clean-room Séance code, which D2 forbids outright.

## Definition of done

- The chapter states the one-sentence product verbatim from 00 and does not
  contradict any decision in the log.
- Three personas (P1 web deployer, P2 Séance-running operator, P3
  Windows/Linux user) are defined with fears/wants and mapped to the
  decisions that serve them; an anti-persona list bounds scope.
- The competitive table covers Transmit, ForkLift, WinSCP, FileZilla,
  Cyberduck/Mountain Duck, Termius, XPipe, and one-line entries for the rest
  of the surveyed field, each with an explicit take/refuse split.
- One differentiator per decision the competitive analysis identifies,
  each tied to a decision number; the expected count is whatever the
  decision log holds at write time, not a fixed target.
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
  convention and whatever license Séance declares — and carries the D30
  Séance sequencing rule (the content-aware PR-S0 gate) exactly as §9
  words it; that gate's normative wording lives only in §9 — every
  other mention of it, in the rest of this chapter and in 02–08, is a
  summary that defers to §9 as the sole normative source.

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
