import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Application and main window title.
  ///
  /// In en, this message translates to:
  /// **'Poltergeist'**
  String get appTitle;

  /// Title of the File application menu.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get menuFile;

  /// Title of the Edit application menu.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get menuEdit;

  /// Title of the View application menu.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get menuView;

  /// Title of the Go application menu.
  ///
  /// In en, this message translates to:
  /// **'Go'**
  String get menuGo;

  /// Title of the Commands application menu (02 §9 menu table).
  ///
  /// In en, this message translates to:
  /// **'Commands'**
  String get menuCommands;

  /// Title of the Window application menu.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get menuWindow;

  /// Title of the Help application menu.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get menuHelp;

  /// Label for the left file pane.
  ///
  /// In en, this message translates to:
  /// **'Pane A'**
  String get paneAName;

  /// Label for the right file pane.
  ///
  /// In en, this message translates to:
  /// **'Pane B'**
  String get paneBName;

  /// State of a pane with no engine session behind it (user terms; the engine concept is internal).
  ///
  /// In en, this message translates to:
  /// **'Browsing is unavailable right now.'**
  String get paneNoEngine;

  /// State of an unbound pane (no location, nothing in flight).
  ///
  /// In en, this message translates to:
  /// **'This pane has no location open.'**
  String get paneNoLocation;

  /// Accessibility label for the pane splitter.
  ///
  /// In en, this message translates to:
  /// **'Resize panes'**
  String get resizePanes;

  /// Current pane splitter position as a whole percentage.
  ///
  /// In en, this message translates to:
  /// **'{value}%'**
  String paneRatioPercent(int value);

  /// Idle application status.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get readyStatus;

  /// Title of the first-use host-key approval dialog.
  ///
  /// In en, this message translates to:
  /// **'Unknown host key'**
  String get hostKeyUnknownTitle;

  /// Title of the changed-key hard-block dialog (D18).
  ///
  /// In en, this message translates to:
  /// **'HOST KEY CHANGED'**
  String get hostKeyChangedTitle;

  /// Warning body of the changed-key dialog.
  ///
  /// In en, this message translates to:
  /// **'The key for {host} does not match the one you previously trusted. This can mean a man-in-the-middle attack. Only continue if you know why the key changed.'**
  String hostKeyChangedWarning(String host);

  /// The endpoint whose key is presented, host:port.
  ///
  /// In en, this message translates to:
  /// **'{host}:{port}'**
  String hostKeyEndpoint(String host, int port);

  /// Label above the presented key's fingerprint (first use).
  ///
  /// In en, this message translates to:
  /// **'Fingerprint'**
  String get hostKeyFingerprintLabel;

  /// Label above the changed dialog's presented fingerprint.
  ///
  /// In en, this message translates to:
  /// **'New key'**
  String get hostKeyNewLabel;

  /// Label above the changed dialog's pinned fingerprint.
  ///
  /// In en, this message translates to:
  /// **'Previously trusted'**
  String get hostKeyPreviousLabel;

  /// Declines the host-key dialog.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get hostKeyCancel;

  /// Approves a first-use host key and continues connecting.
  ///
  /// In en, this message translates to:
  /// **'Trust and connect'**
  String get hostKeyTrustConnect;

  /// Re-pins a changed host key after explicit review.
  ///
  /// In en, this message translates to:
  /// **'Trust the new key'**
  String get hostKeyTrustNewKey;

  /// Fallback title when the server sends no challenge name.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get keyboardAuthTitle;

  /// Sends the keyboard-interactive answers.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get keyboardSubmit;

  /// Cancels the keyboard-interactive challenge.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get keyboardCancel;

  /// Tooltip revealing a challenge field.
  ///
  /// In en, this message translates to:
  /// **'Show answer'**
  String get keyboardShowAnswer;

  /// Tooltip re-obscuring a challenge field.
  ///
  /// In en, this message translates to:
  /// **'Hide answer'**
  String get keyboardHideAnswer;

  /// Title of the connect-time credential dialog.
  ///
  /// In en, this message translates to:
  /// **'Authentication required'**
  String get credentialTitle;

  /// The endpoint the credential prompt is for.
  ///
  /// In en, this message translates to:
  /// **'{username}@{host}:{port}'**
  String credentialEndpoint(String username, String host, int port);

  /// Label of the password field.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get credentialPasswordField;

  /// Label of the identity-file path field.
  ///
  /// In en, this message translates to:
  /// **'Key file'**
  String get credentialKeyFileField;

  /// Validation shown when key authentication has no identity-file path.
  ///
  /// In en, this message translates to:
  /// **'Choose a key file.'**
  String get credentialKeyFileRequired;

  /// Label of the private-key passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Passphrase'**
  String get credentialPassphraseField;

  /// Checkbox storing the entered secret in the local vault.
  ///
  /// In en, this message translates to:
  /// **'Save in vault'**
  String get credentialSaveInVault;

  /// Answers the credential prompt and continues connecting.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get credentialConnect;

  /// Cancels the credential prompt; the connect fails.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get credentialCancel;

  /// Banner shown when the vault could not be read before prompting (the localized render of the ported keystore exception, D20).
  ///
  /// In en, this message translates to:
  /// **'Saved secrets are unavailable. Unlock or restore your system credential store, then retry — or enter the secret below.'**
  String get credentialVaultUnavailable;

  /// Sanitized detail for an identity file that cannot be decoded or otherwise read normally.
  ///
  /// In en, this message translates to:
  /// **'The file could not be read as text.'**
  String get credentialKeyFileUnreadable;

  /// Inline error when the identity file cannot be read.
  ///
  /// In en, this message translates to:
  /// **'Could not read the key file: {error}'**
  String credentialKeyFileReadError(String error);

  /// Status while a first connect attempt runs.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connectionStateConnecting;

  /// Status while automatic recovery retries.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get connectionStateReconnecting;

  /// Heading of the failed-connection view.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailedTitle;

  /// Heading shown while a host-key block is unresolved (D18).
  ///
  /// In en, this message translates to:
  /// **'Connection blocked'**
  String get connectionBlockedTitle;

  /// Heading of the disconnected view.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get connectionDisconnectedTitle;

  /// Header of the collapsible live transcript.
  ///
  /// In en, this message translates to:
  /// **'Connection log'**
  String get connectionLogTitle;

  /// Copies the transcript to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get connectionLogCopy;

  /// Placeholder when no transcript lines arrived.
  ///
  /// In en, this message translates to:
  /// **'(no log captured)'**
  String get connectionLogEmpty;

  /// Reopens the connection after a failure.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get connectionRetry;

  /// Transient notice when saving a prompted secret failed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the secret to the vault. The connection will continue.'**
  String get vaultSaveFailed;

  /// Title of the ssh_config import preview dialog (D22).
  ///
  /// In en, this message translates to:
  /// **'Import servers from ssh config'**
  String get sshImportTitle;

  /// Shown while the config and its includes are read.
  ///
  /// In en, this message translates to:
  /// **'Reading ssh config…'**
  String get sshImportLoading;

  /// Error when the root ssh config is missing or unreadable.
  ///
  /// In en, this message translates to:
  /// **'Could not read {path}.'**
  String sshImportLoadFailed(String path);

  /// Re-runs the config load after a failure.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get sshImportRetry;

  /// Shown when the resolved config contains no host blocks.
  ///
  /// In en, this message translates to:
  /// **'No importable hosts were found in {path}.'**
  String sshImportEmpty(String path);

  /// Table header over the per-row import checkboxes.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get sshImportColumnImport;

  /// Table header for the host alias column.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get sshImportColumnHost;

  /// Table header for the host:port column.
  ///
  /// In en, this message translates to:
  /// **'Endpoint'**
  String get sshImportColumnEndpoint;

  /// Table header for the username column.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get sshImportColumnUser;

  /// Table header for the authentication method column.
  ///
  /// In en, this message translates to:
  /// **'Auth'**
  String get sshImportColumnAuth;

  /// Table header for the duplicate/limitation notes column.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get sshImportColumnNotes;

  /// Auth cell for a host without an IdentityFile.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get sshImportAuthPassword;

  /// Auth cell naming the referenced identity file (reference-style; the key itself is never read at import time).
  ///
  /// In en, this message translates to:
  /// **'Key: {path}'**
  String sshImportAuthKey(String path);

  /// Note chip when an existing bookmark already targets the same host+port+username.
  ///
  /// In en, this message translates to:
  /// **'Duplicate of bookmark “{label}”'**
  String sshImportDuplicateExisting(String label);

  /// Note chip when an earlier row in the same import targets the same endpoint.
  ///
  /// In en, this message translates to:
  /// **'Duplicate of “{alias}” in this import'**
  String sshImportDuplicateEarlier(String alias);

  /// Chip for a host whose ProxyJump Poltergeist does not execute (D10).
  ///
  /// In en, this message translates to:
  /// **'Won’t behave as in ssh: ProxyJump — connects directly, not through the jump host'**
  String get sshImportLimitProxyJump;

  /// Chip for a host whose ProxyCommand Poltergeist does not execute.
  ///
  /// In en, this message translates to:
  /// **'Won’t behave as in ssh: ProxyCommand — never executed'**
  String get sshImportLimitProxyCommand;

  /// Chip shown on every row when the config contains Match blocks.
  ///
  /// In en, this message translates to:
  /// **'Won’t behave as in ssh: Match blocks are ignored; settings may differ'**
  String get sshImportLimitMatch;

  /// Chip for a host block whose Include directives are lost on import.
  ///
  /// In en, this message translates to:
  /// **'Won’t behave as in ssh: Include inside this host block is not applied'**
  String get sshImportLimitHostInclude;

  /// Chip for a row whose Port directive is out of range.
  ///
  /// In en, this message translates to:
  /// **'Cannot import: port outside 1–65535'**
  String get sshImportLimitInvalidPort;

  /// Chip for rows whose User/Port/HostName/IdentityFile global defaults the pinned importer drops.
  ///
  /// In en, this message translates to:
  /// **'Won’t behave as in ssh: defaults from a top-level or Host * block are not inherited'**
  String get sshImportLimitWildcardDefaults;

  /// Heading of the informational include-resolution note list.
  ///
  /// In en, this message translates to:
  /// **'Unresolved includes'**
  String get sshImportUnresolvedIncludes;

  /// Note for an include that re-enters a file already on its chain.
  ///
  /// In en, this message translates to:
  /// **'{path}: include loop skipped'**
  String sshImportNoteCycle(String path);

  /// Note for an include nested past OpenSSH's own recursion cap.
  ///
  /// In en, this message translates to:
  /// **'{path}: nested beyond the depth limit'**
  String sshImportNoteDepth(String path);

  /// Note for an include target that is missing or unreadable.
  ///
  /// In en, this message translates to:
  /// **'{path}: could not be read'**
  String sshImportNoteUnreadable(String path);

  /// Closes the import preview without importing.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sshImportCancel;

  /// Import button label when nothing is selected (disabled).
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get sshImportAction;

  /// Import button label with the number of selected hosts.
  ///
  /// In en, this message translates to:
  /// **'Import {count}'**
  String sshImportActionCount(int count);

  /// Accessibility label for a row's import checkbox.
  ///
  /// In en, this message translates to:
  /// **'Import {alias}'**
  String sshImportRowSemantics(String alias);

  /// Toolbar entry that opens the ssh_config import preview (D22).
  ///
  /// In en, this message translates to:
  /// **'Import from ssh config…'**
  String get sshImportCommandLabel;

  /// Confirmation after the imported rows were persisted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Imported 1 favorite} other{Imported {count} favorites}}'**
  String sshImportImported(int count);

  /// Notice when the bookmark store cannot be read for dedupe.
  ///
  /// In en, this message translates to:
  /// **'Could not read the favorites file.'**
  String get sshImportFavoritesLoadFailed;

  /// Notice when persisting the imported bookmarks fails.
  ///
  /// In en, this message translates to:
  /// **'Could not save the imported favorites.'**
  String get sshImportFavoritesSaveFailed;

  /// Tooltip and semantics label of the grey status dot: the server has not been probed yet or probing is disabled.
  ///
  /// In en, this message translates to:
  /// **'Reachability unknown'**
  String get probeStatusUnknown;

  /// Tooltip and semantics label of the green status dot: the server answered the reachability probe.
  ///
  /// In en, this message translates to:
  /// **'Reachable'**
  String get probeStatusOnline;

  /// Tooltip and semantics label of the red status dot: the server did not answer the reachability probe.
  ///
  /// In en, this message translates to:
  /// **'Unreachable'**
  String get probeStatusOffline;

  /// Label of the composed server indicator while authenticated transports exist.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connectionStateConnected;

  /// Label of the composed server indicator while the pool holds no transport for the server and no failure is known.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get connectionStateNotConnected;

  /// Toolbar command label and page title of the Connections surface (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get connectionsTitle;

  /// Semantics label of the Connections list's loading spinner.
  ///
  /// In en, this message translates to:
  /// **'Loading servers'**
  String get connectionsLoading;

  /// Empty state of the Connections list: the app holds no server reference.
  ///
  /// In en, this message translates to:
  /// **'No servers yet.'**
  String get connectionsEmpty;

  /// Inline error when the bookmark store cannot be read for the Connections list.
  ///
  /// In en, this message translates to:
  /// **'Could not read the favorites file.'**
  String get connectionsLoadFailed;

  /// Warning copy on a host-key-blocked row (D18: the block is never lifted silently).
  ///
  /// In en, this message translates to:
  /// **'Blocked until you review the host key at the next connection attempt.'**
  String get connectionsBlockedWarning;

  /// Affordance leading to the changed-key review dialog, which the next connect attempt raises.
  ///
  /// In en, this message translates to:
  /// **'Review host key…'**
  String get connectionsReviewHostKey;

  /// Per-pane attribution of a terminal recovery failure (03 §3.3).
  ///
  /// In en, this message translates to:
  /// **'Pane {pane} failed: {message}'**
  String connectionsPaneFailure(String pane, String message);

  /// State shown while the initial local home channel opens.
  ///
  /// In en, this message translates to:
  /// **'Opening home…'**
  String get paneOpeningHome;

  /// State shown while a remote bookmark's connection opens.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {label}…'**
  String paneConnectingTo(String label);

  /// Empty-folder state of a pane listing (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'This folder is empty.'**
  String get paneEmptyFolder;

  /// Pane footer count of visible entries.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item} other{{count} items}}'**
  String paneItemCount(int count);

  /// Pane footer line while a navigation is in flight past the anti-flash grace (02 §2.8). Translator note: Esc is the literal key name and must stay untranslated.
  ///
  /// In en, this message translates to:
  /// **'Loading {name} — Esc cancels'**
  String paneLoadingFolder(String name);

  /// Tooltip of the pane's cancel affordance while loading.
  ///
  /// In en, this message translates to:
  /// **'Cancel loading'**
  String get paneCancelLoading;

  /// The pending remote connection's cancel action, shown past the anti-flash grace (abandons the in-flight connect).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get paneConnectCancel;

  /// Screen-reader announcement for the transient type-ahead badge: the prefix accumulated so far while the 1-second buffer lives.
  ///
  /// In en, this message translates to:
  /// **'Names starting with \"{buffer}\"'**
  String paneTypeAheadBadge(String buffer);

  /// Inline error sentence for the notFound taxonomy kind.
  ///
  /// In en, this message translates to:
  /// **'The folder could not be found.'**
  String get paneErrorNotFound;

  /// Inline error sentence for the permissionDenied taxonomy kind.
  ///
  /// In en, this message translates to:
  /// **'You don\'t have permission to open this folder.'**
  String get paneErrorPermissionDenied;

  /// Inline error sentence for the unsupported taxonomy kind.
  ///
  /// In en, this message translates to:
  /// **'This operation is not supported here.'**
  String get paneErrorUnsupported;

  /// Inline error sentence for the disconnected taxonomy kind.
  ///
  /// In en, this message translates to:
  /// **'The connection was closed.'**
  String get paneErrorDisconnected;

  /// Inline error sentence for the conflict taxonomy kind.
  ///
  /// In en, this message translates to:
  /// **'The item changed while being opened.'**
  String get paneErrorConflict;

  /// Inline error sentence for the cancelled taxonomy kind.
  ///
  /// In en, this message translates to:
  /// **'The operation was cancelled.'**
  String get paneErrorCancelled;

  /// Inline error sentence for the other taxonomy kind.
  ///
  /// In en, this message translates to:
  /// **'The folder could not be opened.'**
  String get paneErrorOther;

  /// Diagnostic line for a non-VFS fault while opening a remote connection.
  ///
  /// In en, this message translates to:
  /// **'The connection to this server could not be opened.'**
  String get paneFaultConnectionOpen;

  /// Diagnostic line for a non-VFS fault while opening the local browser.
  ///
  /// In en, this message translates to:
  /// **'The local file browser could not be opened.'**
  String get paneFaultLocalOpen;

  /// Diagnostic line for a non-VFS fault while listing a folder.
  ///
  /// In en, this message translates to:
  /// **'This folder could not be listed.'**
  String get paneFaultListFolder;

  /// Diagnostic line when the editable path field's submission cannot resolve to a location under the pane's path rules — rejected before any folder listing is attempted (02 §2.1).
  ///
  /// In en, this message translates to:
  /// **'That is not a folder path this pane can open. Use an absolute path, ~, or a name in this folder.'**
  String get paneFaultInvalidPath;

  /// Inline-rename validation error: the typed name is blank or all whitespace — rejected before any rename request (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Enter a name.'**
  String get paneFaultRenameNameEmpty;

  /// Inline-rename validation error: the typed name contains the listing's path separator — a rename never moves an item across folders (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'A name cannot contain “/”.'**
  String get paneFaultRenameNameSeparator;

  /// Inline-rename validation error: the pane's filesystem forbids the typed name — on a local pane under Windows, the NTFS-reserved characters, a control character, a DOS device name, or a trailing dot or space (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'That name is not allowed here.'**
  String get paneFaultRenameNameInvalid;

  /// Inline-rename error: the row under edit left the listing mid-session — a refresh, another client's delete, or a filter edit removed it (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'The item is no longer in this folder.'**
  String get paneFaultRenameTargetGone;

  /// File-open error (02 §2.6): the engine's default-application launch failed with an error outside the typed filesystem taxonomy — the pane's authored line for an opaque failure.
  ///
  /// In en, this message translates to:
  /// **'The file could not be opened.'**
  String get paneFaultOpenFile;

  /// Banner shown while the remote transport reconnects (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Connection to {label} lost — reconnecting…'**
  String paneConnectionLost(String label);

  /// A pane could not obtain a usable listing after transport recovery.
  ///
  /// In en, this message translates to:
  /// **'Connection to {label} could not be restored.'**
  String paneConnectionRecoveryFailed(String label);

  /// The connection-lost banner's cancel action (stops reconnection).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get paneConnectionLostCancel;

  /// Reconnect bar over a session-restored remote tab's cached listing (02 §3): the tab never connected this session — it shows the persisted snapshot until Reconnect or, with the auto-reconnect setting on, activation.
  ///
  /// In en, this message translates to:
  /// **'Session restored — {label} is offline.'**
  String paneRestoredOffline(String label);

  /// The session-restored tab's Reconnect bar action (02 §3): opens the remote binding the persisted session recorded.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get paneReconnect;

  /// Transient notice strip (02 §10): the Open action on a remote file — the managed-checkout pipeline arrives with the editor milestone.
  ///
  /// In en, this message translates to:
  /// **'Remote files can\'t be opened in place yet — Poltergeist will download and open them in a later milestone.'**
  String get paneNoticeOpenRemoteUnavailable;

  /// Transient notice strip (02 §10): the Double-click action preference resolved to Edit in Poltergeist, whose editor arrives in a later milestone.
  ///
  /// In en, this message translates to:
  /// **'Editing files in Poltergeist isn\'t available yet — the editor arrives in a later milestone.'**
  String get paneNoticeEditLater;

  /// Transient notice strip (02 §10): the Double-click action preference resolved to Transfer to other pane, whose queue arrives in a later milestone.
  ///
  /// In en, this message translates to:
  /// **'Transferring to the other pane isn\'t available yet — the transfer queue arrives in a later milestone.'**
  String get paneNoticeTransferLater;

  /// Tooltip for the transient notice strip's close button (02 §10).
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get paneNoticeDismiss;

  /// Relative modified date for today (02 §2.3). The time string must be produced with the active locale (locale-aware hour and minute, e.g. DateFormat.jm); never a hard-coded pattern.
  ///
  /// In en, this message translates to:
  /// **'Today at {time}'**
  String paneDateToday(String time);

  /// Relative modified date for yesterday (02 §2.3). The time string must be produced with the active locale (locale-aware hour and minute, e.g. DateFormat.jm); never a hard-coded pattern.
  ///
  /// In en, this message translates to:
  /// **'Yesterday at {time}'**
  String paneDateYesterday(String time);

  /// Screen-reader label of one listing row: announced name–kind–size–date in that order regardless of visual column order (D20, 02 §13).
  ///
  /// In en, this message translates to:
  /// **'{name}, {kind}, {size}, {modified}'**
  String paneRowSemantics(
    String name,
    String kind,
    String size,
    String modified,
  );

  /// Screen-reader kind word for a regular file row (RemoteFileType.file).
  ///
  /// In en, this message translates to:
  /// **'file'**
  String get paneRowKindFile;

  /// Screen-reader kind word for a directory row (RemoteFileType.directory).
  ///
  /// In en, this message translates to:
  /// **'folder'**
  String get paneRowKindDirectory;

  /// Screen-reader kind word for a symbolic-link row (RemoteFileType.symbolicLink).
  ///
  /// In en, this message translates to:
  /// **'symbolic link'**
  String get paneRowKindSymbolicLink;

  /// Screen-reader kind word for an entry that is none of file, directory, or symbolic link (RemoteFileType.other). Must not claim the entry is a regular file.
  ///
  /// In en, this message translates to:
  /// **'item'**
  String get paneRowKindOther;

  /// Command label: navigate to the previous location in the tab's history (go.back, 02 §2.1).
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get goBackLabel;

  /// Command label: swap the pane's path bar for an editable field seeded with the current location (go.editPath, 02 §2.1).
  ///
  /// In en, this message translates to:
  /// **'Edit Path'**
  String get goEditPathLabel;

  /// Command label: navigate to the parent folder.
  ///
  /// In en, this message translates to:
  /// **'Parent Folder'**
  String get goEnclosingLabel;

  /// Command label: navigate to the next location in the tab's history (go.forward, 02 §2.1).
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get goForwardLabel;

  /// Command label: open the selected row.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get goOpenLabel;

  /// Command label: rename the selected row inline in the listing (file.rename, 02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get fileRenameLabel;

  /// Command label: open the non-modal info inspector over the focused pane (file.getInfo, 02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Get Info'**
  String get fileGetInfoLabel;

  /// Accessible label of the inline-rename text field that replaces the edited row's name (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get paneRenameFieldLabel;

  /// Command label: open the pane's editable path field seeded empty (go.toFolder, 02 §2.1).
  ///
  /// In en, this message translates to:
  /// **'Go to Folder…'**
  String get goToFolderLabel;

  /// Command label: refresh the focused pane's listing.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get viewRefreshLabel;

  /// Command label: move focus to the left pane.
  ///
  /// In en, this message translates to:
  /// **'Focus Left Pane'**
  String get paneFocusLeftLabel;

  /// Command label: move focus to the right pane.
  ///
  /// In en, this message translates to:
  /// **'Focus Right Pane'**
  String get paneFocusRightLabel;

  /// Command label: swap focus between the panes.
  ///
  /// In en, this message translates to:
  /// **'Swap Pane Focus'**
  String get paneSwapFocusLabel;

  /// Command label: select every row of the focused pane's listing (edit.selectAll, 02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Select All'**
  String get editSelectAllLabel;

  /// Command label: replace the focused pane's selection with its complement (edit.invertSelection, 02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Invert Selection'**
  String get editInvertSelectionLabel;

  /// Command label: open the Quick Select field over the focused pane's listing (selection.quickSelect, 02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Quick Select'**
  String get selectionQuickSelectLabel;

  /// Label of the Quick Select text field that drops below the path bar (02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Quick Select'**
  String get quickSelectFieldLabel;

  /// Hint inside the Quick Select field describing its two match shapes: a literal name fragment, or a whole-name glob with * wildcards (02 §2.5). Keep it terse — it is placeholder text, not documentation.
  ///
  /// In en, this message translates to:
  /// **'name fragment or *.ext'**
  String get quickSelectFieldHint;

  /// Segmented-toggle segment: matching rows are added to the current selection (02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get quickSelectAddLabel;

  /// Segmented-toggle segment: matching rows are removed from the current selection (02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get quickSelectRemoveLabel;

  /// Command label: open the filter field over the focused pane's listing (view.filter, 02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get viewFilterLabel;

  /// Accessible label of the pane's filter text field (02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get paneFilterFieldLabel;

  /// Hint inside the pane filter field stating its match shape: a case-insensitive substring of the name — no glob, no diacritic folding (02 §2.5). Keep it terse — it is placeholder text, not documentation.
  ///
  /// In en, this message translates to:
  /// **'name contains'**
  String get paneFilterFieldHint;

  /// Helper text beside the pane filter field while a query is active: visible row count of the listing's total (02 §2.5).
  ///
  /// In en, this message translates to:
  /// **'{visible} of {total}'**
  String paneFilterCount(int visible, int total);

  /// Clears the pane's active name filter (button and tooltip, 02 §2.5/§2.7).
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get paneFilterClear;

  /// Filtered-to-nothing empty state of a pane listing (02 §2.7): names the active filter query.
  ///
  /// In en, this message translates to:
  /// **'No items match \"{query}\"'**
  String paneFilterNoMatch(String query);

  /// Accessible label of the pane's editable path field that replaces the segment bar (02 §2.1, go.editPath/go.toFolder).
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get panePathFieldLabel;

  /// Hint inside the pane's editable path field stating the accepted shapes: an absolute path, ~ for the home folder, or a name relative to the current folder (02 §2.1). Keep it terse — it is placeholder text, not documentation.
  ///
  /// In en, this message translates to:
  /// **'/path, ~, or a name in this folder'**
  String get panePathFieldHint;

  /// Tooltip of the Connections row action that opens the bookmark in the active pane.
  ///
  /// In en, this message translates to:
  /// **'Open in Pane'**
  String get connectionsOpenInPane;

  /// Accessible label of a pane's tab strip container (02 §3).
  ///
  /// In en, this message translates to:
  /// **'Tabs'**
  String get tabStripLabel;

  /// Command label and button tooltip: open a new tab in the focused pane (tab.new, 02 §3).
  ///
  /// In en, this message translates to:
  /// **'New Tab'**
  String get tabNewLabel;

  /// Command label and chip-button tooltip: close a tab (tab.close, 02 §3).
  ///
  /// In en, this message translates to:
  /// **'Close Tab'**
  String get tabCloseLabel;

  /// Command label: reopen the most recently closed tab in the focused pane (tab.reopenClosed, 02 §3).
  ///
  /// In en, this message translates to:
  /// **'Reopen Closed Tab'**
  String get tabReopenClosedLabel;

  /// Command label: activate the next tab in the focused pane's strip (tab.next, 02 §3).
  ///
  /// In en, this message translates to:
  /// **'Next Tab'**
  String get tabNextLabel;

  /// Command label: activate the previous tab in the focused pane's strip (tab.previous, 02 §3).
  ///
  /// In en, this message translates to:
  /// **'Previous Tab'**
  String get tabPreviousLabel;

  /// Title of a tab — and the pane's surface — while no location is bound (the 02 §2.7 launcher).
  ///
  /// In en, this message translates to:
  /// **'Launcher'**
  String get tabLauncherTitle;

  /// Tooltip of a remote tab chip: the bookmark's label and the tab's full remote path (02 §3).
  ///
  /// In en, this message translates to:
  /// **'{server} — {path}'**
  String tabTooltipRemote(String server, String path);

  /// Title of the guarded tab-close confirmation (02 §3), shown when the tab still has work in flight.
  ///
  /// In en, this message translates to:
  /// **'Close Tab?'**
  String get tabCloseConfirmTitle;

  /// Lead-in of the guarded tab-close confirmation: names the tab, then the active guard triggers follow as a list (02 §3).
  ///
  /// In en, this message translates to:
  /// **'\"{tab}\" has work in progress:'**
  String tabCloseConfirmBody(String tab);

  /// Tab-close guard item: the tab has an outstanding listing navigation (02 §3).
  ///
  /// In en, this message translates to:
  /// **'A navigation is still in flight.'**
  String get tabCloseTriggerNavigation;

  /// Tab-close guard item: the tab's inline-rename session is open (02 §3).
  ///
  /// In en, this message translates to:
  /// **'An inline rename is in progress.'**
  String get tabCloseTriggerInlineRename;

  /// Tab-close guard item: a recursive folder-size computation is running on the tab (02 §3).
  ///
  /// In en, this message translates to:
  /// **'A folder-size computation is running.'**
  String get tabCloseTriggerFolderSize;

  /// Tab-close guard item: an apply-to-enclosed-items permissions change is running on the tab (02 §3).
  ///
  /// In en, this message translates to:
  /// **'An apply-to-enclosed-items change is running.'**
  String get tabCloseTriggerApplyToEnclosed;

  /// Tab-close guard item: the tab anchors a Sync Browsing pair (02 §3, §7).
  ///
  /// In en, this message translates to:
  /// **'The tab anchors a sync pair.'**
  String get tabCloseTriggerSyncAnchor;

  /// Declines the guarded tab close: the tab and its in-flight work stay.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get tabCloseConfirmCancel;

  /// Accepts the guarded tab close despite its in-flight work.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get tabCloseConfirmClose;

  /// Command label: hide or show the second pane, preserving its tabs and per-tab state (view.toggleSecondPane, 02 §3/§8.3/§9).
  ///
  /// In en, this message translates to:
  /// **'Show/Hide Second Pane'**
  String get viewToggleSecondPaneLabel;

  /// Command label: link the two panes so relative navigation replays at the same path below the other pane's anchor (view.toggleSyncBrowsing, 02 §7/§8.3/§9).
  ///
  /// In en, this message translates to:
  /// **'Sync Browsing'**
  String get viewToggleSyncBrowsingLabel;

  /// Linked-state chip text on both path bars and the status bar while Sync Browsing replays navigation (02 §7).
  ///
  /// In en, this message translates to:
  /// **'Sync browsing'**
  String get syncBrowsingChip;

  /// Bare suspended-state chip text (02 §7): the re-visibility cases — an anchored tab switched away or the second pane hidden — and a diverged pair carry it.
  ///
  /// In en, this message translates to:
  /// **'Sync browsing suspended'**
  String get syncBrowsingSuspended;

  /// Suspended chip for the missing-mirror cause (02 §7): the replayed relative directory does not exist on the named pane.
  ///
  /// In en, this message translates to:
  /// **'Sync browsing suspended — \"{name}\" missing on {side}'**
  String syncBrowsingSuspendedMissing(String name, String side);

  /// Suspended chip for the escape cause (02 §7): a navigation left the fixed anchor root, so the link is suspended rather than replaying `..` chains.
  ///
  /// In en, this message translates to:
  /// **'Sync browsing suspended — outside the anchor subtree'**
  String get syncBrowsingSuspendedOutside;

  /// The left pane named as a word inside the missing-mirror suspension copy (02 §7).
  ///
  /// In en, this message translates to:
  /// **'left'**
  String get syncBrowsingSideLeft;

  /// The right pane named as a word inside the missing-mirror suspension copy (02 §7).
  ///
  /// In en, this message translates to:
  /// **'right'**
  String get syncBrowsingSideRight;

  /// Heading of the launcher's Quick Connect form (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Quick Connect'**
  String get quickConnectTitle;

  /// Label of the Quick Connect address field (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get quickConnectAddressLabel;

  /// Placeholder inside the Quick Connect address field showing both accepted forms (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'user@host:port or sftp://user@host/path'**
  String get quickConnectAddressHint;

  /// Action starting the Quick Connect session (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get quickConnectConnect;

  /// Visible interpretation when an in-range numeric token is read as a port (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'{port} → port; use sftp://{host}/{port} for a folder named {port}'**
  String quickConnectHintPort(String port, String host);

  /// Visible interpretation when an out-of-range numeric token is read as a folder name (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'{token} is out of the port range, so it connects on port 22 and opens a folder named {token}.'**
  String quickConnectHintPath(String token);

  /// Rejection hint for an unbracketed multi-colon host (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'The host holds more than one colon. Wrap the IPv6 address in [ ], for example user@[2001:db8::1].'**
  String get quickConnectHintIpv6;

  /// Inline notice shown when the parser strips a pasted password (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'A pasted password was removed. It is never stored — enter it when prompted.'**
  String get quickConnectPasswordStripped;

  /// Error shown for an empty Quick Connect address.
  ///
  /// In en, this message translates to:
  /// **'Enter a server address, for example user@host.'**
  String get quickConnectEmptyError;

  /// Error shown for a Quick Connect address without a host.
  ///
  /// In en, this message translates to:
  /// **'Enter a host after the @, for example user@host.'**
  String get quickConnectMissingHostError;

  /// Error shown for a port-position value outside 1–65535 in an sftp:// URL (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'The port in this address is not valid. Use 1–65535.'**
  String get quickConnectInvalidPortError;

  /// Error shown for a non-sftp URL pasted into Quick Connect (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Only sftp:// addresses are supported here.'**
  String get quickConnectUnsupportedSchemeError;

  /// Title of the post-connect bar offering to keep the live adhoc session as a favorite (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Save as favorite…'**
  String get saveFavoriteTitle;

  /// Label of the favorite-name field in the save bar (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get saveFavoriteNameLabel;

  /// Action persisting the live adhoc session as a favorite (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveFavoriteSave;

  /// Inline error shown when persisting the favorite throws.
  ///
  /// In en, this message translates to:
  /// **'Could not save the favorite. Try again.'**
  String get saveFavoriteFailed;

  /// Transient notice strip (02 §10): saving was attempted where no bookmark store is wired (the favorites store is M5's).
  ///
  /// In en, this message translates to:
  /// **'Saving favorites isn\'t available yet — the sidebar arrives in a later milestone.'**
  String get paneNoticeSaveFavoriteLater;

  /// Transient notice strip (02 §10): the Get Info inspector's copy-path affordance landed on the clipboard (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Path copied to clipboard.'**
  String get paneNoticePathCopied;

  /// Accessible name of the Get Info inspector panel (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get infoPanelLabel;

  /// Tooltip of the Get Info inspector's close affordance (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Close info panel'**
  String get infoPanelClose;

  /// Body of the Get Info inspector while the pane has no selection or cursor to target (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Select an item to inspect it.'**
  String get infoPanelEmpty;

  /// Secondary line of the Get Info inspector while a multi-selection is inspected — the panel shows the primary row and counts the rest (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item selected} other{{count} items selected}}'**
  String infoPanelSelectedCount(int count);

  /// Label of the Get Info inspector's kind row (file/folder/symbolic link, 02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Kind'**
  String get infoPanelKind;

  /// Label of the Get Info inspector's size row (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get infoPanelSize;

  /// Affordance starting the on-demand recursive folder-size measure in the Get Info inspector (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Calculate'**
  String get infoPanelCalculateSize;

  /// Affordance cancelling the in-flight folder-size measure in the Get Info inspector (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get infoPanelCancelSize;

  /// Live progress value of the Get Info inspector's folder-size row while the measure runs (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'{size} so far — {count, plural, =1{1 item} other{{count} items}}'**
  String infoPanelSizeProgress(String size, int count);

  /// Settled value of the Get Info inspector's folder-size row: the measured total and the entry count (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'{size} — {count, plural, =1{1 item} other{{count} items}}'**
  String infoPanelSizeResult(String size, int count);

  /// Sub-line under the Get Info inspector's settled folder-size row counting entries that carried no size or refused their listing — the total is partial (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item could not be measured} other{{count} items could not be measured}}'**
  String infoPanelSizePartial(int count);

  /// Terminal value of the Get Info inspector's folder-size row when the folder's own listing refused (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Could not measure'**
  String get infoPanelSizeFailed;

  /// Label of the Get Info inspector's modified-date row (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Modified'**
  String get infoPanelModified;

  /// Label of the Get Info inspector's accessed-date row (02 §2.6). The VFS model carries no created date, so accessed is the second date the panel can honestly render.
  ///
  /// In en, this message translates to:
  /// **'Accessed'**
  String get infoPanelAccessed;

  /// Label of the Get Info inspector's read-only permissions row (02 §2.6). The D28 editor is later work — this row only displays.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get infoPanelPermissions;

  /// Combined value of the Get Info inspector's permissions row: symbolic rwx rendering followed by the octal form in parentheses (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'{symbolic} ({octal})'**
  String infoPanelPermissionsValue(String symbolic, String octal);

  /// Label of the Get Info inspector's read-only owner row (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get infoPanelOwner;

  /// Label of the Get Info inspector's read-only group row (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get infoPanelGroup;

  /// Label of the Get Info inspector's full-path row (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get infoPanelPath;

  /// Tooltip of the Get Info inspector's copy affordance beside the full path (02 §2.6).
  ///
  /// In en, this message translates to:
  /// **'Copy path'**
  String get infoPanelCopyPath;

  /// Title of the Commands menu's Workspaces submenu listing the saved workspaces (02 §3, M3 interim until the M5 sidebar).
  ///
  /// In en, this message translates to:
  /// **'Workspaces'**
  String get menuWorkspaces;

  /// Commands-menu item that names and saves the current two-pane arrangement as a workspace (02 §9's table slot, 02 §3).
  ///
  /// In en, this message translates to:
  /// **'Save Workspace…'**
  String get workspaceSaveCommand;

  /// Title of the workspace-save name prompt.
  ///
  /// In en, this message translates to:
  /// **'Save Workspace'**
  String get workspaceSaveTitle;

  /// Label of the workspace-save prompt's name field.
  ///
  /// In en, this message translates to:
  /// **'Workspace name'**
  String get workspaceNameField;

  /// Confirms the workspace-save prompt.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get workspaceSaveAction;

  /// Dismisses the workspace-save prompt without saving.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get workspaceSaveCancel;

  /// Transient toast after a workspace snapshot persisted (02 §10: transient outcomes only).
  ///
  /// In en, this message translates to:
  /// **'Workspace \"{name}\" saved'**
  String workspaceSavedToast(String name);

  /// Transient action toast after a workspace replaced both panes' tabs (02 §3's exact copy); carries the Undo action.
  ///
  /// In en, this message translates to:
  /// **'Workspace \"{name}\" opened'**
  String workspaceOpenedToast(String name);

  /// The workspace-opened toast's action: restores the tab sets the open displaced (02 §3).
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get workspaceUndoAction;

  /// Disabled row inside the Workspaces submenu while no workspace has been saved yet.
  ///
  /// In en, this message translates to:
  /// **'No Saved Workspaces'**
  String get workspaceMenuEmpty;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
