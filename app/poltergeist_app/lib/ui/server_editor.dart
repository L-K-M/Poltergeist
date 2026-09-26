// Ported from Séance app/seance_app/lib/ui/server_editor.dart @ 035b0d8 (tag
// v0.9.1); see docs/PORTS.md.
// Divergences: `AppState` becomes [ServerEditorDelegate] — the seven seams
// the form actually uses, so the dialog builds in a widget test without
// standing up the app. Strings localize through ARB (D20). The
// security-scoped identity-file bookmark machinery (`_keyBookmark`,
// `_bookmarkFor`, `draftIdentityBookmark`) is dropped: Poltergeist is not
// sandboxed, so Browse… returns a plain path and the referenced key opens
// by path at connect. Poltergeist adds the D37 "Simultaneous transfers"
// override, which Séance has no use for and which is stored on the device
// rather than in the synced config.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/transfer_limits_controller.dart'
    show transferConcurrencyChoices;
import '../services/uuid.dart';
import 'connection_test_report.dart';
import 'server_appearance.dart';
import 'server_color_picker.dart';
import 'server_grouping.dart';
import 'server_mark_picker.dart';
import 'top_toast.dart';

/// What the editor needs from the application layer — the seams Séance's
/// `AppState`/`AppServices` answered, named one per use so a test double is a
/// handful of fields rather than a services hierarchy.
abstract class ServerEditorDelegate {
  /// The catalog's servers, for the group quick-select chips and for the
  /// freshest `updatedAt` a save must outrank.
  List<ServerConfig> get servers;

  /// Whether a sync account is linked — gates the exclusion confirmation.
  bool get syncConfigured;

  /// The app's own seed colour, the custom picker's starting point when no
  /// named accent is in force.
  Color get themeSeed;

  /// Pick a "reference, don't store" identity file; null when cancelled.
  Future<String?> pickIdentityFile();

  /// The stored credential [secretId] names — for the referenced-key
  /// passphrase carry-over. Throws when the vault is locked.
  Future<Secret?> readSecret(String secretId);

  /// Persist the config and, when [secret] is given, its credential. Throws
  /// when the vault is unavailable or the write fails.
  Future<void> save(ServerConfig config, {Secret? secret});

  /// D37: the cap every server follows unless it chose its own — what the
  /// editor's "Default (…)" choice names.
  TransferConcurrency get defaultTransferConcurrency;

  /// [serverId]'s own cap on simultaneous transfers, or null when it
  /// follows [defaultTransferConcurrency].
  TransferConcurrency? transferConcurrencyFor(String serverId);

  /// Store [serverId]'s own cap, or clear it with null. Device-local, not
  /// part of the synced config. Throws when the write fails.
  Future<void> saveTransferConcurrency(
    String serverId,
    TransferConcurrency? value,
  );

  /// Authenticate against the form's draft state — typed-but-unsaved
  /// credential fields included — and report it.
  Future<ConnectionTestResult> testConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    SshConnectionLog? log,
  });
}

/// Whether turning "exclude from sync" on needs confirming before it takes.
///
/// Only when there is something to retract: a server being added has never
/// been anywhere, one already excluded has been retracted once already, and
/// with no sync account configured there is no other device that could lose
/// it. Turning the switch back off is never destructive.
///
/// [syncConfigured] is read as it is *now*, which is not quite the same
/// question. A server that synced before the account was unlinked still has a
/// copy out there, and the stored exclusion would retract it on the first
/// round after re-linking, unprompted. Answering that properly needs a "has
/// ever synced" bit this device does not keep, and the alternative — always
/// confirming — puts a dialog in front of someone who has never had a sync
/// account at all. The narrow gap is recorded here rather than papered over.
bool excludingNeedsConfirmation({
  required ServerConfig? existing,
  required bool syncConfigured,
}) => existing != null && !existing.excludeFromSync && syncConfigured;

/// The credential this Save writes, or null when the form describes none and
/// the stored one should stay as it is.
///
/// Blank means "keep what is stored" when every box of that method is blank:
/// the fields start empty when an existing server is opened, so writing a
/// blank through would replace the stored credential with nothing on any save
/// that only touched some other field.
///
/// Not box by box, though, and the passphrase is where that shows: a *typed*
/// PEM writes `keyPassphrase: null` even when the passphrase box is blank,
/// because a newly pasted key brings its own — so re-pasting the same
/// encrypted key and leaving the passphrase alone drops the stored one.
///
/// Known gap, pre-existing and not closed here: when the auth *method*
/// changed and nothing was typed, "what is stored" is a credential of the old
/// kind. Nothing is written, so the config keeps its `secretRef` — now
/// pointing at, say, a password under a server set to key auth, until a
/// credential for the new method is entered. Clearing the ref instead would
/// throw away a working credential on a method switch the user may undo in
/// the same sitting, which is the worse of the two. `docs/STATUS.md`
/// follow-up 17 tracks it.
///
/// A *referenced* key is the case this exists for. Its passphrase is the only
/// credential that mode has, and it used to be dropped — the box was shown,
/// filled and ignored — so `Test connection`, which authenticates with what
/// was typed, reported success for a key the saved server could not decrypt.
/// [stored] is carried through when one is written, because switching to a
/// referenced file leaves an already-stored PEM unread rather than discarded,
/// and switching back has to find it again.
@visibleForTesting
Secret? plannedCredential({
  required AuthMethod auth,
  required bool referenceKeyFile,
  required String password,
  required String keyPem,
  required String keyPassphrase,
  required String secretId,
  Secret? stored,
}) {
  if (auth == AuthMethod.password) {
    if (password.isEmpty) return null;
    return Secret(id: secretId, kind: SecretKind.password, value: password);
  }
  if (auth != AuthMethod.privateKey) return null;
  if (!referenceKeyFile) {
    if (keyPem.isEmpty) return null;
    return Secret(
      id: secretId,
      kind: SecretKind.privateKey,
      value: keyPem,
      keyPassphrase: keyPassphrase.isEmpty ? null : keyPassphrase,
    );
  }
  if (keyPassphrase.isEmpty) return null;
  return Secret(
    id: secretId,
    kind: SecretKind.privateKey,
    // The key itself stays on disk; only what decrypts it is stored. What is
    // carried over has to be a key: the entry under this id belongs to
    // whatever auth method last wrote it, and a server that used a password
    // before would otherwise have that password stored as its PEM — read back
    // as one the next time the key is typed rather than referenced.
    value: stored?.kind == SecretKind.privateKey ? stored!.value : '',
    // The typed passphrase belongs to the key *file*, and it lands beside the
    // PEM carried above — which was stored with a passphrase of its own. One
    // entry holds one passphrase, so the pair can end up mismatched, and
    // switching back to a pasted key without re-pasting finds a PEM that no
    // longer decrypts. Carrying the old passphrase instead would break the
    // referenced key, which is the one the server is set to use. STATUS
    // follow-up 17 has both halves of the single-slot problem.
    keyPassphrase: keyPassphrase,
  );
}

/// Whether [plannedCredential] will read [stored], so a caller knows when it
/// has to fetch the existing vault entry first.
///
/// The condition lives here rather than being restated at the call site: read
/// too narrowly, `stored` arrives null on a branch that carries it through and
/// an existing PEM is overwritten with nothing — the data loss the carry-over
/// exists to prevent. A test fuzzes the two together: wherever this is false,
/// [plannedCredential] must return the same thing with and without a [Secret]
/// in hand.
@visibleForTesting
bool plannedCredentialReadsStored({
  required AuthMethod auth,
  required bool referenceKeyFile,
  required String keyPassphrase,
}) =>
    auth == AuthMethod.privateKey &&
    referenceKeyFile &&
    keyPassphrase.isNotEmpty;

/// The timestamp a save should carry: the wall clock, but never one this
/// config has already passed.
///
/// `updatedAt` is what orders this edit against every other device's, and a
/// device whose clock trails the record it pulled — the ordinary case once one
/// device runs even slightly fast — would otherwise stamp an edit that ties
/// with, or loses to, the copy it means to replace, and quietly not take
/// anywhere else.
///
/// Exclusion is where that costs most: `SyncCoordinator` dates the retraction
/// tombstone from this timestamp, so a losing stamp leaves the server and its
/// credential on the sync server and on every other device while this one
/// shows the switch on. The coordinator does re-date a retraction it sees
/// outranked, so the difference is retracting on the first push rather than a
/// round later — but the first push is where it belongs, and a monotonic stamp
/// costs one comparison.
///
/// It outranks the record *this device has pulled*, which is the whole of what
/// a local clamp can know. An edit racing a remote change this device has not
/// seen yet can still tie with it or lose, and lose silently — closing that
/// needs the coordinator, which re-dates a retraction it sees outranked.
int nextUpdatedAt(int? existingUpdatedAt, {required int now}) =>
    math.max(now, (existingUpdatedAt ?? 0) + 1);

/// The dialog [excludingNeedsConfirmation] gates, as a function so a test can
/// tap its buttons without standing up an editor.
///
/// Dismissing it — barrier tap, Escape — resolves to null, which has to read
/// as "no": the caller is about to delete data on other devices, and the one
/// input that means the user never answered must not be the one that proceeds.
Future<bool> confirmSyncExclusion(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.serverEditorExcludeConfirmTitle),
      content: Text(l10n.serverEditorExcludeConfirmBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.serverEditorExcludeConfirmCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.serverEditorExcludeConfirmAction),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Add or edit a server. Password / private-key material is written to the
/// encrypted vault; the config stores only a reference.
Future<void> showServerEditor(
  BuildContext context,
  ServerEditorDelegate delegate,
  ServerConfig? existing,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: _ServerEditor(delegate: delegate, existing: existing),
      ),
    ),
  );
}

class _ServerEditor extends StatefulWidget {
  final ServerEditorDelegate delegate;
  final ServerConfig? existing;
  const _ServerEditor({required this.delegate, this.existing});

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _group;
  final _password = TextEditingController();
  final _keyPem = TextEditingController();
  final _keyPath = TextEditingController();
  final _keyPassphrase = TextEditingController();
  final _loginScript = TextEditingController();

  late AuthMethod _auth;
  late ServerTint _tint;

  /// What a server shows before anything is chosen. Named once: the reset
  /// button's visibility and its action both compare against it, and a second
  /// literal that drifted would leave the button offering to reset a mark that
  /// is already default.
  static const ServerMark _defaultMark = ServerGlyphMark(null);

  /// What the badge shows: a glyph, an emoji, or an imported image. Held as
  /// the resolved mark rather than as the three fields it is stored in, so
  /// the precedence between them lives in one place (see [ServerMark]).
  late ServerMark _mark;
  bool _referenceKeyFile = true;

  /// This server's own D37 cap, null to follow the default; and the one it
  /// had when the editor opened, so a Save writes it only when it changed.
  TransferConcurrency? _transferLimit;
  TransferConcurrency? _storedTransferLimit;
  late bool _syncSecret;
  late bool _excludeFromSync;
  bool _busy = false;

  /// The id a *new* server will be saved under, minted once rather than per
  /// save so a test connection and the save that follows describe one server,
  /// and so a save that failed and is retried does not mint a second identity.
  final String _draftId = uuidV4();

  /// The vault id a *new* server's credential is saved under, minted once for
  /// the same reason as [_draftId] and one the credential needs more:
  /// `save` writes the vault before the config store, so a save that
  /// stored the secret and then failed on the config write left an entry
  /// behind — and a retry minting a fresh id orphaned it in the keyring with
  /// nothing pointing at it and nothing that would ever clean it up.
  final String _draftSecretId = uuidV4();

  /// The connection test: whether one is running, what the last one found,
  /// and which attempt is current. The counter is the cancellation flag — the
  /// SSH layer has no cancel seam, so a superseded or abandoned attempt is
  /// left to finish and its result dropped.
  bool _testing = false;
  ConnectionTestResult? _testResult;
  int _testAttempt = 0;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: e?.label ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 22}');
    _user = TextEditingController(text: e?.username ?? '');
    _group = TextEditingController(text: e?.group ?? '');
    _tint = e == null ? ServerTint.none : ServerTint.of(e);
    _mark = e?.mark ?? _defaultMark;
    // Default new servers to password: ssh-agent is offered but not yet
    // supported by the backend, so defaulting to it would dead-end the very
    // first "add a server and connect".
    _auth = e?.authMethod ?? AuthMethod.password;
    _keyPath.text = e?.identityFilePath ?? '';
    _referenceKeyFile = e?.identityFilePath != null;
    _loginScript.text = e?.loginScript ?? '';
    _storedTransferLimit = e == null
        ? null
        : widget.delegate.transferConcurrencyFor(e.id);
    _transferLimit = _storedTransferLimit;
    // New credentials default to syncable (a no-op until the global "sync
    // saved passwords & keys" is on); existing servers keep their stored
    // choice.
    _syncSecret = e?.syncSecret ?? true;
    _excludeFromSync = e?.excludeFromSync ?? false;
    for (final field in _connectionFields) {
      field.addListener(_dropTestResult);
    }
  }

  /// Every text field in the form, so [dispose] releases them all.
  List<TextEditingController> get _fields => [
    _label,
    _host,
    _port,
    _user,
    _group,
    _password,
    _keyPem,
    _keyPath,
    _keyPassphrase,
    _loginScript,
  ];

  /// The fields a connection test's outcome actually depends on.
  ///
  /// Narrower than [_fields] because [_dropTestResult] does not merely grey
  /// out a stale result — it bumps `_testAttempt`, which abandons a test
  /// still in flight. Renaming a server, moving it to another group or
  /// editing its login script cannot change what a connection does (the
  /// script is never executed, which the disclaimer beside it says), so
  /// discarding a result the user waited minutes for over a typo in the name
  /// is a cost with nothing bought for it.
  List<TextEditingController> get _connectionFields => [
    _host,
    _port,
    _user,
    _password,
    _keyPem,
    _keyPath,
    _keyPassphrase,
  ];

  /// Forget the last test result, and abandon one still running, because the
  /// form no longer describes what is being tested.
  ///
  /// A green "authenticated" sitting beside a host that has since been retyped
  /// reads as current, and the report's whole claim is that it describes the
  /// server about to be saved. An attempt *in flight* is the same problem
  /// arriving late, so the counter moves too and its result lands as
  /// superseded — which means clearing [_testing] here as well, or the *Test*
  /// button would stay disabled behind a live spinner, waiting on a result
  /// that will be dropped. Save is never gated on a running test: it takes
  /// `_busy` alone, so a test in flight does not block saving.
  ///
  /// Guarded so typing does not rebuild the dialog on every keystroke.
  void _dropTestResult() {
    _testAttempt++;
    if (_testResult != null || _testing) {
      setState(() {
        _testResult = null;
        _testing = false;
      });
    }
  }

  @override
  void dispose() {
    for (final c in _fields) {
      // Disposing drops the listeners with it; removing them first is only so
      // a late notification cannot reach setState on the way down.
      c.removeListener(_dropTestResult);
      c.dispose();
    }
    super.dispose();
  }

  /// Whether Return, pressed with the focus where it is now, should save.
  ///
  /// Save is the dialog's default button, and a form whose fields swallow
  /// Return is one where the mouse has to come back at the end of every
  /// edit. But Return already means something in two places: a multi-line
  /// field, where it is a newline, and a focused control that activates on
  /// it — a button, a switch, the auth dropdown — where the app-level binding
  /// would otherwise fire it. Both keep their meaning; everywhere else it is
  /// Save. Answered false rather than swallowing the key, so the event goes
  /// on to whatever owned it before this existed. [anywhere] is the modified
  /// chord, which saves even from the script box.
  ///
  /// Gated on [_busy] alone, like the Save button: a connection test in
  /// flight does not block saving (see the button for why), so Return does
  /// not either.
  ///
  /// An input method mid-composition is the third owner of Return. The
  /// desktop engines hand a key to the framework first and to the input
  /// method only if the framework declined, so while a Japanese or Chinese
  /// composition is open the key has to be declined here for Return to
  /// commit the text rather than save around it.
  bool _returnSaves({required bool anywhere}) {
    if (_busy) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    final editable = focus?.findAncestorWidgetOfExactType<EditableText>();
    // Before the chord's early return: a composition is open text, and the
    // chord saving around it would persist the half-typed preedit.
    if (editable != null) {
      final composing = editable.controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) return false;
    }
    if (anywhere) return true;
    if (focus == null) return true;
    if (editable != null && editable.maxLines != 1) return false;
    return Actions.maybeFind<ActivateIntent>(focus) == null;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): _SaveIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _SaveIntent(),
        // The chord editors use for "submit despite being multi-line", on
        // both modifier conventions, since the shortcut is unbound otherwise
        // and a macOS user's hands expect the one, a Linux user's the other.
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            _SaveIntent(anywhere: true),
        SingleActivator(LogicalKeyboardKey.enter, meta: true):
            _SaveIntent(anywhere: true),
        SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
            _SaveIntent(anywhere: true),
        SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
            _SaveIntent(anywhere: true),
      },
      child: Actions(
        actions: {_SaveIntent: _SaveAction(this)},
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null
                  ? l10n.serverEditorAddTitle
                  : l10n.serverEditorEditTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _label,
              decoration: InputDecoration(labelText: l10n.serverEditorLabel),
              validator: _required,
            ),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    decoration: InputDecoration(
                      labelText: l10n.serverEditorHost,
                    ),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    decoration: InputDecoration(
                      labelText: l10n.serverEditorPort,
                    ),
                    keyboardType: TextInputType.number,
                    validator: _validatePort,
                  ),
                ),
              ],
            ),
            TextFormField(
              controller: _user,
              decoration: InputDecoration(labelText: l10n.serverEditorUsername),
              validator: _required,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<AuthMethod>(
              initialValue: _auth,
              decoration: InputDecoration(
                labelText: l10n.serverEditorAuthentication,
              ),
              items: [
                DropdownMenuItem(
                  value: AuthMethod.agent,
                  child: Text(l10n.serverEditorAuthAgent),
                ),
                DropdownMenuItem(
                  value: AuthMethod.password,
                  child: Text(l10n.serverEditorAuthPassword),
                ),
                DropdownMenuItem(
                  value: AuthMethod.privateKey,
                  child: Text(l10n.serverEditorAuthPrivateKey),
                ),
              ],
              // Through _dropTestResult, not a bare clear: the auth method is
              // baked into the config a test runs against, so one already in
              // flight is describing a credential the form no longer holds —
              // and would otherwise land looking current.
              onChanged: (v) {
                setState(() => _auth = v ?? AuthMethod.agent);
                _dropTestResult();
              },
            ),
            const SizedBox(height: 8),
            ..._authFields(),
            const SizedBox(height: 20),
            ..._syncFields(),
            const SizedBox(height: 20),
            ..._loginScriptFields(),
            const SizedBox(height: 20),
            ..._transferFields(),
            const SizedBox(height: 20),
            ..._appearanceFields(),
            const SizedBox(height: 20),
            Row(
              children: [
                // Flexible, so the row never overflows: on a phone at a large
                // text scale the three buttons are wider than the dialog, and
                // this is the one whose label can wrap onto a second line
                // without changing what the row means.
                Flexible(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: _busy || _testing ? null : _testConnection,
                      icon: _testing
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              // Labelled like the outcome icons: a spinner is
                              // the one state with nothing to read, so without
                              // this a screen-reader user cannot tell a running
                              // test from a button that did nothing.
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                semanticsLabel:
                                    l10n.serverEditorTestingSemantic,
                              ),
                            )
                          : const Icon(Icons.wifi_tethering, size: 18),
                      label: Text(
                        _testing
                            ? l10n.serverEditorTesting
                            : l10n.serverEditorTest,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Cancel stays live during a test: the attempt cannot be
                // stopped, but being unable to leave the dialog for the five
                // minutes an authentication may take is worse than letting it
                // finish unwatched.
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.serverEditorCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  // Not disabled while a test runs: an attempt can take
                  // minutes, and the only other way out was typing a character
                  // into any field to drop the test. Saving mid-test is sound
                  // — any edit that could make the two disagree already
                  // supersedes the attempt, and the save pops the editor, so
                  // the late result is discarded by the mounted check.
                  onPressed: _busy ? null : _save,
                  child: Text(l10n.serverEditorSave),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.serverEditorTestDisclaimer,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
            ),
            if (_testResult != null) const SizedBox(height: 12),
            // The spinner announces that a test started; without this the one
            // thing that matters — how it ended — arrives silently, and a
            // screen-reader user has to go looking for it. Kept mounted while
            // idle rather than added with the result: several screen readers
            // announce a live region whose content changes and stay quiet for
            // one that appears already filled.
            Semantics(
              liveRegion: true,
              child: _testResult == null
                  ? const SizedBox.shrink()
                  : ConnectionTestReport(result: _testResult!),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _authFields() {
    final l10n = AppLocalizations.of(context);
    switch (_auth) {
      case AuthMethod.agent:
        return [
          Text(l10n.serverEditorAgentInfo),
          const SizedBox(height: 8),
          Text(
            l10n.serverEditorAgentUnsupported,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ];
      case AuthMethod.password:
        return [
          TextFormField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.serverEditorPasswordLabel,
            ),
          ),
          _syncSecretToggle(),
        ];
      case AuthMethod.privateKey:
        return [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.serverEditorReferenceKeyTitle),
            subtitle: Text(l10n.serverEditorReferenceKeySubtitle),
            value: _referenceKeyFile,
            // Same as the auth dropdown: this switches the test between the
            // key on disk and the pasted one, so an attempt already running
            // is about the other of the two.
            onChanged: (v) {
              setState(() => _referenceKeyFile = v);
              _dropTestResult();
            },
          ),
          if (_referenceKeyFile)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _keyPath,
                    decoration: InputDecoration(
                      labelText: l10n.serverEditorIdentityFilePath,
                      hintText: l10n.serverEditorIdentityFileHint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _browseForKey,
                  child: Text(l10n.serverEditorBrowse),
                ),
              ],
            )
          else
            TextFormField(
              controller: _keyPem,
              maxLines: 5,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: l10n.serverEditorPrivateKeyPem,
                border: const OutlineInputBorder(),
              ),
            ),
          TextFormField(
            controller: _keyPassphrase,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.serverEditorKeyPassphrase,
            ),
          ),
          // Only the stored key (not the referenced-file case) is a secret
          // that could sync.
          if (!_referenceKeyFile) _syncSecretToggle(),
        ];
    }
  }

  /// An optional command to run in this server's shell once it opens. Typed
  /// into the session rather than executed on a side channel — which is what
  /// Séance does with it when the server opens a terminal there; Poltergeist
  /// stores and syncs the field so a round trip preserves it.
  List<Widget> _loginScriptFields() {
    final l10n = AppLocalizations.of(context);
    return [
      const Divider(),
      const SizedBox(height: 8),
      TextFormField(
        controller: _loginScript,
        maxLines: 3,
        minLines: 1,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: InputDecoration(
          labelText: l10n.serverEditorLoginScript,
          hintText: l10n.serverEditorLoginScriptHint,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        l10n.serverEditorLoginScriptNote,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
      ),
    ];
  }

  /// D37's override: how many files the queue moves to or from this server
  /// at once. Kept apart from the connection fields it sits near because it
  /// never reaches the config — it is stored on this device alone.
  List<Widget> _transferFields() {
    final l10n = AppLocalizations.of(context);
    String describe(TransferConcurrency value) =>
        value.files?.toString() ?? l10n.transferLimitAutomatic;
    return [
      const Divider(),
      const SizedBox(height: 8),
      DropdownButtonFormField<_TransferLimitChoice>(
        key: const ValueKey('serverEditor.transferLimit'),
        initialValue: _TransferLimitChoice(_transferLimit),
        decoration: InputDecoration(labelText: l10n.serverEditorTransferLimit),
        items: [
          DropdownMenuItem(
            value: const _TransferLimitChoice(null),
            child: Text(
              l10n.serverEditorTransferLimitDefault(
                describe(widget.delegate.defaultTransferConcurrency),
              ),
            ),
          ),
          DropdownMenuItem(
            value: const _TransferLimitChoice(TransferConcurrency.automatic()),
            child: Text(l10n.transferLimitAutomatic),
          ),
          for (final files in transferConcurrencyChoices)
            DropdownMenuItem(
              value: _TransferLimitChoice(TransferConcurrency.fixed(files)),
              child: Text('$files'),
            ),
        ],
        onChanged: (choice) => setState(() => _transferLimit = choice?.own),
      ),
      const SizedBox(height: 4),
      Text(
        l10n.serverEditorTransferLimitNote,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
      ),
    ];
  }

  /// How this server is filed and marked in the list: its group, its accent
  /// colour, and its icon. All three are optional and none of them affect how
  /// the connection is made — they exist so a list of thirty boxes can be read
  /// at a glance, and so "am I on prod?" has an answer you don't have to read.
  List<Widget> _appearanceFields() {
    final l10n = AppLocalizations.of(context);
    final existing = existingServerGroups(widget.delegate.servers);
    return [
      const Divider(),
      const SizedBox(height: 8),
      Row(
        children: [
          // Colour and mark combine, so they are previewed together rather
          // than left to be imagined from two separate pickers — and as the
          // list draws them: the colour a line beside the mark, not under it.
          ServerAccentBar(tint: _tint),
          const SizedBox(width: 8),
          ServerBadge(tint: _tint, mark: _mark),
          const SizedBox(width: 12),
          Text(
            l10n.serverEditorAppearance,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _group,
        decoration: InputDecoration(
          labelText: l10n.serverEditorGroup,
          hintText: l10n.serverEditorGroupHint,
        ),
      ),
      if (existing.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            // Retyping an existing group by hand is how you end up with
            // "Prod " and "prodution" as separate sections. Case already
            // folds together; the chips take care of the rest.
            for (final group in existing)
              ActionChip(
                label: Text(group),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _group.text = group),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      Text(
        l10n.serverEditorColour,
        style: Theme.of(context).textTheme.labelMedium,
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final color in <ServerColor?>[null, ...ServerColor.values])
            _ColorSwatch(
              tint: ServerTint(named: color),
              selected: _tint == ServerTint(named: color),
              onTap: () => setState(() => _tint = ServerTint(named: color)),
            ),
          // Last, after the named ten: the picker is the way past them, not
          // the first thing to reach for.
          _CustomColorSwatch(color: _tint.custom, onTap: _pickCustomColor),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        l10n.serverEditorMark,
        style: Theme.of(context).textTheme.labelMedium,
      ),
      const SizedBox(height: 6),
      // A button rather than the grid this used to be: the glyphs alone no
      // longer fit a form field, and emoji and imported images need room of
      // their own. The preview beside "Appearance" above shows the result.
      // Wrap rather than Row: at 280 logical pixels of form width — what a
      // dialog gives on a phone — and 1.5x text the three controls overflow
      // a Row by 30 pixels. Measured, and the reason the grid this replaced
      // was a Wrap too.
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ServerBadge(tint: _tint, mark: _mark, size: 44),
          OutlinedButton.icon(
            onPressed: _pickMark,
            icon: const Icon(Icons.palette_outlined),
            label: Text(l10n.serverEditorChooseMark),
          ),
          if (_mark != _defaultMark)
            IconButton(
              tooltip: l10n.serverEditorDefaultMarkTooltip,
              icon: const Icon(Icons.backspace_outlined),
              onPressed: () => setState(() => _mark = _defaultMark),
            ),
        ],
      ),
    ];
  }

  Future<void> _pickMark() async {
    final chosen = await showServerMarkPicker(context, current: _mark);
    if (chosen == null || !mounted) return;
    setState(() => _mark = chosen);
  }

  /// Open the colour picker on the colour in force: the custom one if there
  /// is one, else the seed of the named accent — so "a bit darker than teal"
  /// starts from teal — else the app's own seed.
  Future<void> _pickCustomColor() async {
    final named = _tint.named;
    final chosen = await showServerColorPicker(
      context,
      initial:
          _tint.custom ??
          (named == null
              ? widget.delegate.themeSeed
              : serverColorSeed(named)),
      mark: _mark,
    );
    if (chosen == null || !mounted) return;
    setState(() => _tint = ServerTint.custom(chosen));
  }

  /// Per-server opt-in for including this credential in sync. Gated globally
  /// by the "Sync saved passwords & keys" setting, so it's a no-op until
  /// that's on.
  ///
  /// Excluding the whole server settles the question, so the switch reads off
  /// and takes no input then. What it *stores* is still the user's own choice
  /// ([_syncSecret]) rather than the displayed false: clearing the exclusion
  /// has to give them back the answer they picked, not silently opt their
  /// credential out on the way through.
  Widget _syncSecretToggle() {
    final l10n = AppLocalizations.of(context);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.serverEditorSyncSecretTitle),
      subtitle: Text(
        _excludeFromSync
            ? l10n.serverEditorSyncSecretExcluded
            : l10n.serverEditorSyncSecretSubtitle,
      ),
      value: _syncSecret && !_excludeFromSync,
      onChanged: _excludeFromSync
          ? null
          : (v) => setState(() => _syncSecret = v),
    );
  }

  /// Whether this server takes part in sync at all.
  ///
  /// Worth saying out loud in the subtitle, because "exclude" understates what
  /// the switch does to a server that has already synced: the retraction is a
  /// tombstone, so the other devices lose their copy. Only this device keeps
  /// one, which is the point — but it is not something to find out afterwards.
  List<Widget> _syncFields() {
    final l10n = AppLocalizations.of(context);
    return [
      const Divider(),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.serverEditorExcludeTitle),
        subtitle: Text(
          _excludeFromSync
              ? l10n.serverEditorExcludeOnSubtitle
              : l10n.serverEditorExcludeOffSubtitle,
        ),
        value: _excludeFromSync,
        onChanged: (v) async {
          if (v && !await _confirmExclusion()) return;
          if (mounted) setState(() => _excludeFromSync = v);
        },
      ),
    ];
  }

  /// Ask before an exclusion that reaches other devices.
  ///
  /// Turning this on for a server that may already have synced is the one
  /// thing this editor does that deletes data somewhere else, and the switch
  /// sits a few rows from the login script and the colour picker, which lowers
  /// the stakes it looks like it carries. Subtitles get skimmed; a dialog does
  /// not.
  ///
  /// Nothing is asked when there is nothing to retract — a server being added
  /// has never been anywhere, and with no sync account configured there is no
  /// other device to lose it. Turning the switch back off is not destructive
  /// either way.
  Future<bool> _confirmExclusion() => excludingNeedsConfirmation(
    existing: widget.existing,
    syncConfigured: widget.delegate.syncConfigured,
  )
      ? confirmSyncExclusion(context)
      : Future<bool>.value(true);

  /// Pick an identity file: "reference, don't store" mode reads the key from
  /// this path at connect time.
  Future<void> _browseForKey() async {
    final picked = await widget.delegate.pickIdentityFile();
    if (picked == null || !mounted) return;
    setState(() => _keyPath.text = picked);
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty)
          ? AppLocalizations.of(context).serverEditorRequired
          : null;

  String? _validatePort(String? v) {
    final port = int.tryParse((v ?? '').trim());
    if (port == null || port < 1 || port > 65535) {
      return AppLocalizations.of(context).serverEditorPortRange;
    }
    return null;
  }

  /// The server the form currently describes, with [secretRef] as its
  /// credential reference. Shared by Save and Test connection so a test can
  /// never run against a different server than the one about to be saved.
  ServerConfig _formConfig({required String? secretRef, required int now}) {
    final existing = widget.existing;
    final mark = _mark.stored;
    final tint = _tint.stored;
    return ServerConfig(
      id: existing?.id ?? _draftId,
      label: _label.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _user.text.trim(),
      authMethod: _auth,
      secretRef: secretRef,
      // ProxyJump editing is not exposed yet; preserve the saved route.
      // Séance reads this same record, so dropping it here would take the
      // route away on every device (Séance #131's fix, X-02).
      jumpHostId: existing?.jumpHostId,
      // Blank reads as "no file referenced", not as a path made of nothing:
      // the validator blocks an empty path, and a caller that ever reached
      // here without it would otherwise ask the SSH layer to read `''`.
      identityFilePath:
          (_auth == AuthMethod.privateKey &&
              _referenceKeyFile &&
              _keyPath.text.trim().isNotEmpty)
          ? _keyPath.text.trim()
          : null,
      syncSecret: _syncSecret,
      // Normalized here rather than trusted from the field, so a trailing
      // space typed into the group name can't fork a second section that
      // looks identical to the one the user meant to join.
      group: normalizeServerGroup(_group.text),
      color: tint.color,
      customColor: tint.customColor,
      // Read once rather than three times: encoding an image mark for storage
      // is not free, and the three have to come from one reading anyway so
      // they cannot disagree about which is in force.
      icon: mark.icon,
      iconEmoji: mark.emoji,
      iconImage: mark.image,
      loginScript: normalizeLoginScript(_loginScript.text),
      excludeFromSync: _excludeFromSync,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
  }

  /// Connect and authenticate with what the form holds right now — including
  /// a password or key typed but not yet saved, which is not in the vault and
  /// would otherwise be tested as whatever is stored (or as nothing at all,
  /// for a server being added).
  Future<void> _testConnection() async {
    if (!_form.currentState!.validate()) return;
    final attempt = ++_testAttempt;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final log = SshConnectionLog();
    final config = _formConfig(
      secretRef: widget.existing?.secretRef,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    // Refused like a real connect (jump_host_guard.dart): the pinned opener
    // would authenticate straight to the host, around the bastion the route
    // names, with whatever credential the form holds. The pinned
    // `runConnectionTest` tests anyway and only notes the skipped jump host;
    // a trial is still a dial.
    if (config.jumpHostId != null) {
      final summary = AppLocalizations.of(
        context,
      ).connectionJumpHostUnsupported;
      setState(() {
        _testing = false;
        // Nothing was dialed, so the transcript is the summary alone: it
        // ends with the summary, as every failed trial's does.
        _testResult = ConnectionTestResult(
          ok: false,
          summary: summary,
          log: summary,
        );
      });
      return;
    }
    final ConnectionTestResult result;
    try {
      result = await widget.delegate.testConnection(
        config,
        // A credential box is hidden (and stale) once the auth method stops
        // using it, and the PEM box also while the key is referenced from
        // disk; passing either then would test text the user cannot see.
        // The credential resolver reads each draft only under its own auth
        // method, so this changes nothing it does — it makes the call site
        // say what it means. The passphrase stays with the method, not the
        // reference toggle: it decrypts the on-disk key too.
        draftPassword: _auth == AuthMethod.password ? _password.text : null,
        draftPrivateKey: _auth == AuthMethod.privateKey && !_referenceKeyFile
            ? _keyPem.text
            : null,
        draftKeyPassphrase: _auth == AuthMethod.privateKey
            ? _keyPassphrase.text
            : null,
        log: log,
      );
    } catch (error) {
      // runConnectionTest turns every failure it can see into a result, so
      // reaching here means something outside it went wrong. Belt and braces,
      // because the alternative is the wedged editor `_save` is careful to
      // avoid: _testing stuck on, Save disabled, and Cancel — which throws
      // away everything just typed — as the only way out.
      log.freeze();
      if (!mounted || attempt != _testAttempt) return;
      // The same inline report an expected failure gets, not a toast: what
      // went wrong is by definition unexpected, so it is the detail worth
      // keeping — and a toast fades with it.
      setState(() {
        _testing = false;
        _testResult = ConnectionTestResult(
          ok: false,
          summary: AppLocalizations.of(context).serverEditorTestFailedSummary,
          notes: ['$error'],
          log: log.toString(),
        );
      });
      return;
    }
    log.freeze();
    // Superseded by a newer attempt, or the dialog is gone: drop it.
    if (!mounted || attempt != _testAttempt) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final existing = widget.existing;
    // Against the freshest copy this device holds, not the one captured when
    // the editor opened: a round that pulled a newer record meanwhile is
    // exactly the record this stamp has to outrank.
    final latest = existing == null
        ? null
        : widget.delegate.servers
            .where((s) => s.id == existing.id)
            .map((s) => s.updatedAt)
            .fold<int>(existing.updatedAt, math.max);
    final now = nextUpdatedAt(
      latest,
      now: DateTime.now().millisecondsSinceEpoch,
    );

    final existingRef = existing?.secretRef;
    // Everything the form says, read here — before the awaited vault call
    // below. `_busy` disables the buttons, not the fields, so a keyring that
    // prompts (macOS) or is slow to answer leaves them editable for as long
    // as it takes: read afterwards, a keystroke landing in that window is
    // saved without ever passing the `validate()` this method opened with,
    // and a host cleared after Save was pressed is written empty.
    final password = _password.text;
    final keyPem = _keyPem.text;
    final keyPassphrase = _keyPassphrase.text;
    // The auth dropdown and the reference switch too, and for the same
    // reason: they are as enabled as the text boxes while `_busy`, and the
    // credential is planned *after* the vault read below. Flipped in that
    // window, `plannedCredential` would describe a different server than the
    // config being saved — password material written over a stored PEM while
    // the config saves as key auth, which is the exact cross-method
    // corruption the carry-over logic exists to prevent.
    final auth = _auth;
    final referenceKeyFile = _referenceKeyFile;
    final transferLimit = _transferLimit;
    // The config too, and not only the credential fields: it reads seven more
    // controllers. Its `secretRef` is the one thing that cannot be known yet
    // — whether a credential is written depends on what the vault answers —
    // so it is built against the existing ref and corrected below, which is
    // a field this form does not own rather than one the user could edit.
    final formConfig = _formConfig(secretRef: existingRef, now: now);
    // Only when a referenced key's passphrase is about to be written over an
    // entry that may hold a PEM: every other branch replaces the entry whole.
    Secret? stored;
    if (existingRef != null &&
        plannedCredentialReadsStored(
          auth: auth,
          referenceKeyFile: referenceKeyFile,
          keyPassphrase: keyPassphrase,
        )) {
      try {
        stored = await widget.delegate.readSecret(existingRef);
      } catch (e) {
        // A locked keyring, reported like the save failure below rather than
        // silently writing the passphrase over the key it was stored beside.
        if (!mounted) return;
        setState(() => _busy = false);
        showTopToastIn(
          context,
          message: AppLocalizations.of(context).serverEditorSaveFailed('$e'),
        );
        return;
      }
    }
    final secretId = existingRef ?? _draftSecretId;
    final secret = plannedCredential(
      auth: auth,
      referenceKeyFile: referenceKeyFile,
      password: password,
      keyPem: keyPem,
      keyPassphrase: keyPassphrase,
      secretId: secretId,
      stored: stored,
    );

    final config = secret != null && secretId != existingRef
        // `updatedAt` is not restated here: `_formConfig` already stamped it
        // with the same `now`, and repeating it reads as though a save that
        // reuses its secret entry keeps an older one.
        ? formConfig.copyWith(secretRef: secretId)
        : formConfig;
    try {
      // The vault write inside throws when the OS keyring is unavailable —
      // tell the user instead of wedging the editor with _busy stuck on.
      await widget.delegate.save(config, secret: secret);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showTopToastIn(
        context,
        message: AppLocalizations.of(context).serverEditorSaveFailed('$e'),
      );
      return;
    }
    // After the config, so a server that failed to save never gains a cap,
    // and only when the choice changed, so a settings file that cannot be
    // written does not fail a Save that never touched it.
    if (transferLimit != _storedTransferLimit) {
      try {
        await widget.delegate.saveTransferConcurrency(config.id, transferLimit);
        _storedTransferLimit = transferLimit;
      } catch (e) {
        // The server is saved; the editor stays open so Save retries the
        // part that failed.
        if (!mounted) return;
        setState(() => _busy = false);
        showTopToastIn(
          context,
          message: AppLocalizations.of(
            context,
          ).serverEditorTransferLimitSaveFailed('$e'),
        );
        return;
      }
    }
    if (mounted) Navigator.of(context).pop();
  }
}

/// One entry of the "Simultaneous transfers" menu: the server's own cap, or
/// null for the default. A wrapper because a dropdown reads a null value as
/// nothing selected.
@immutable
class _TransferLimitChoice {
  const _TransferLimitChoice(this.own);

  final TransferConcurrency? own;

  @override
  bool operator ==(Object other) =>
      other is _TransferLimitChoice && other.own == own;

  @override
  int get hashCode => own.hashCode;
}

/// Return, in the editor: save the server, unless the focus is somewhere the
/// key means something else (see `_returnSaves`).
class _SaveIntent extends Intent {
  /// Set for the modified chord, which saves wherever the focus is.
  final bool anywhere;
  const _SaveIntent({this.anywhere = false});
}

/// An [Action] rather than a callback so that declining is possible: an
/// action that is not enabled leaves the key event unhandled, and it carries
/// on to the text field or button that was going to take it. A
/// `CallbackShortcuts` binding would have consumed it either way.
class _SaveAction extends Action<_SaveIntent> {
  final _ServerEditorState _editor;
  _SaveAction(this._editor);

  @override
  bool isEnabled(_SaveIntent intent) =>
      _editor._returnSaves(anywhere: intent.anywhere);

  @override
  Object? invoke(_SaveIntent intent) {
    _editor._save();
    return null;
  }
}

/// One choice in the colour row. The first is null — "no colour" — drawn as
/// the same neutral tone an untagged server gets in the list, so the option
/// shows what it does rather than describing it.
class _ColorSwatch extends StatelessWidget {
  final ServerTint tint;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.tint,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(context, tint);
    final fill = accent?.container ?? scheme.surfaceContainerHighest;
    final foreground = accent?.onContainer ?? scheme.onSurfaceVariant;
    // Declared selected, like the mark picker's tiles: the ring and the tick
    // are visual, and a screen reader is otherwise told eleven equal
    // buttons.
    return Semantics(
      button: true,
      selected: selected,
      child: Tooltip(
        message: serverColorLabel(tint.named),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: _swatchSize,
            height: _swatchSize,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? _selectedSwatchBorder : 1,
              ),
            ),
            // A tick rather than a ring alone: at 34px on a phone the ring
            // is easy to miss, and the swatches differ only by hue.
            child: selected
                ? Icon(Icons.check, size: _swatchIconSize, color: foreground)
                : null,
          ),
        ),
      ),
    );
  }
}

/// The colour row's geometry, shared by the named swatches and the custom
/// one so the row reads as one control.
const double _swatchSize = 34;
const double _selectedSwatchBorder = 2.5;
const double _swatchIconSize = 16;

/// The colour row's way past the named ten: a swatch that opens the picker.
///
/// Shows the custom colour when one is chosen, as a swatch like its
/// neighbours, so the row reads "this one is selected" the same way whether
/// the choice was named or picked. With none chosen it wears the spectrum
/// instead of a colour, which is the one honest answer to "what does this
/// button give me" before it has been pressed.
class _CustomColorSwatch extends StatelessWidget {
  /// The custom colour in force, or null when a named accent (or none) is.
  final Color? color;
  final VoidCallback onTap;

  const _CustomColorSwatch({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = color;
    final selected = chosen != null;
    final accent = chosen == null
        ? null
        : serverAccent(context, ServerTint(custom: chosen));
    return Semantics(
      button: true,
      selected: selected,
      child: Tooltip(
        message: chosen == null
            ? AppLocalizations.of(context).serverEditorCustomColour
            : AppLocalizations.of(
                context,
              ).serverEditorCustomColourValue(formatServerCustomColor(chosen)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: _swatchSize,
            height: _swatchSize,
            decoration: BoxDecoration(
              color: accent?.container,
              gradient: selected
                  ? null
                  : SweepGradient(
                      colors: [
                        for (var hue = 0; hue <= 360; hue += 60)
                          HSVColor.fromAHSV(1, hue.toDouble(), 0.6, 0.95)
                              .toColor(),
                      ],
                    ),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? _selectedSwatchBorder : 1,
              ),
            ),
            child: Icon(
              selected ? Icons.check : Icons.colorize,
              size: _swatchIconSize,
              // Over the spectrum, a fixed dark tone: no single "on" colour
              // fits every hue, and the lighter tones the sweep is drawn in
              // carry dark well enough.
              color: accent?.onContainer ?? Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}
