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

  /// Title of the Server application menu (D32's rename of 02 §9's Commands menu: connect, sync, workspaces, transfers).
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get menuServer;

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

  /// Title of the collapsible transcript under a connection-test result.
  ///
  /// In en, this message translates to:
  /// **'Connection log'**
  String get connectionLogTitle;

  /// Button that copies the transcript to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get connectionLogCopy;

  /// Placeholder inside the transcript card when there is nothing to show.
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

  /// Semantics label of the Connections list's loading spinner.
  ///
  /// In en, this message translates to:
  /// **'Loading servers'**
  String get connectionsLoading;

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

  /// Header of the sidebar's fixed Connections section (02 §4): the servers the connection pool currently holds.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get sidebarConnectionsSection;

  /// Header over the ungrouped favorites tail while named groups exist (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get sidebarUngroupedSection;

  /// Empty state of the sidebar's favorites list (02 §2.7's never-blank rule applied to §4).
  ///
  /// In en, this message translates to:
  /// **'No favorites yet. Save a location as a favorite to see it here.'**
  String get sidebarEmptyFavorites;

  /// Favorite row context verb: open per the preferred-pane rules (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get sidebarOpen;

  /// Favorite row context verb: open in a new tab of the resolved pane (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Open in New Tab'**
  String get sidebarOpenInNewTab;

  /// Favorite row and Connections row context verb: open in the pane a plain click would not have used (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Open in Other Pane'**
  String get sidebarOpenInOtherPane;

  /// Favorite row context verb: prompt for a new label (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Rename…'**
  String get sidebarRename;

  /// Title of the sidebar rename dialog.
  ///
  /// In en, this message translates to:
  /// **'Rename Favorite'**
  String get sidebarRenameTitle;

  /// Label of the rename dialog's single text field.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get sidebarRenameFieldLabel;

  /// Favorite row context verb opening the group submenu (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Move to Group'**
  String get sidebarMoveToGroup;

  /// Move-to-group submenu row that unfiles the favorite.
  ///
  /// In en, this message translates to:
  /// **'No Group'**
  String get sidebarNoGroup;

  /// Move-to-group submenu row that prompts for a group name and refiles the favorite into it (groups are member-carried — the move IS the create, 04 §2.1).
  ///
  /// In en, this message translates to:
  /// **'New Group…'**
  String get sidebarNewGroup;

  /// Title of the new-group name dialog.
  ///
  /// In en, this message translates to:
  /// **'New Group'**
  String get sidebarNewGroupTitle;

  /// Label of the new-group dialog's single text field.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get sidebarGroupFieldLabel;

  /// Favorite row context verb: remove the favorite after confirmation (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sidebarDelete;

  /// Title of the favorite-delete confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete Favorite'**
  String get sidebarDeleteTitle;

  /// Body of the favorite-delete confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{label}\" from favorites? This cannot be undone.'**
  String sidebarDeleteBody(String label);

  /// Transient notice when a sidebar store write (rename, regroup, delete) throws (02 §10).
  ///
  /// In en, this message translates to:
  /// **'That change couldn\'t be saved. Try again.'**
  String get sidebarActionFailed;

  /// Connections row context verb: drop the pool's reference for the server (02 §4).
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get sidebarDisconnect;

  /// Subtitle of a workspace-kind favorite while there is no single path to show.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get sidebarKindWorkspace;

  /// Subtitle of a saved-sync-kind favorite while there is no single path to show.
  ///
  /// In en, this message translates to:
  /// **'Saved sync'**
  String get sidebarKindSavedSync;

  /// Workspace favorite's context verb (02 §3): re-captures both panes' tab sets over the existing workspace — an update, never a duplicate.
  ///
  /// In en, this message translates to:
  /// **'Update Workspace'**
  String get sidebarWorkspaceUpdate;

  /// Transient notice (02 §10): a saved-sync-kind favorite's open targets the 05 sync preview, which lands after this slice.
  ///
  /// In en, this message translates to:
  /// **'Opening saved-sync favorites isn\'t available yet — the sync preview arrives in a later milestone.'**
  String get sidebarSyncLater;

  /// Command label: hide or show the global sidebar (view.toggleSidebar, 02 §1/§8.3/§9). At stage 1 it opens the overlay drawer instead.
  ///
  /// In en, this message translates to:
  /// **'Show/Hide Sidebar'**
  String get viewToggleSidebarLabel;

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

  /// Empty-folder drop hint on a local pane (02 §2.7): OS files dropped on the empty listing copy into it.
  ///
  /// In en, this message translates to:
  /// **'Drop files here to copy them'**
  String get paneDropHintLocal;

  /// Empty-folder drop hint on a remote pane (02 §2.7): OS files dropped on the empty listing upload into it.
  ///
  /// In en, this message translates to:
  /// **'Drop files here to upload them'**
  String get paneDropHintRemote;

  /// Drop-hover overlay line for a move verb (02 §5.1); {dir} is the destination directory.
  ///
  /// In en, this message translates to:
  /// **'Move to {dir}'**
  String dropMoveTo(String dir);

  /// Drop-hover overlay line for a same-filesystem copy (02 §5.1); {dir} is the destination directory.
  ///
  /// In en, this message translates to:
  /// **'Copy to {dir}'**
  String dropCopyTo(String dir);

  /// Drop-hover overlay line for a local→remote copy (02 §5.1); {dir} is the destination directory.
  ///
  /// In en, this message translates to:
  /// **'Upload to {dir}'**
  String dropUploadTo(String dir);

  /// Drop-hover overlay line for a remote→local copy (02 §5.1); {dir} is the destination directory.
  ///
  /// In en, this message translates to:
  /// **'Download to {dir}'**
  String dropDownloadTo(String dir);

  /// Drag-avatar label for a multi-row drag (02 §5.1).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item} other{{count} items}}'**
  String dropItemCount(int count);

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

  /// Accessible label of a listing row whose decoded name carries U+FFFD (02 §13's flagged-name rule: the row's disabled reason is part of the node).
  ///
  /// In en, this message translates to:
  /// **'{name}, {kind}, {size}, {modified} — name not valid UTF-8'**
  String paneRowSemanticsFlagged(
    String name,
    String kind,
    String size,
    String modified,
  );

  /// Tooltip on the warning badge of a listing row whose decoded name carries U+FFFD (02 §13's flagged-name rule).
  ///
  /// In en, this message translates to:
  /// **'Name is not valid UTF-8 — shown approximately'**
  String get paneFlaggedNameTooltip;

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

  /// Command label: navigate to the parent folder (go.enclosing; 10 §8's Go menu names it Enclosing Folder, Finder's term).
  ///
  /// In en, this message translates to:
  /// **'Enclosing Folder'**
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

  /// Transient notice strip (02 §10): the shown local folder's change watch failed repeatedly, so the listing no longer refreshes on its own until the next navigation, refresh, or tab switch (03 §7.5: watcher failure is never silent).
  ///
  /// In en, this message translates to:
  /// **'This folder stopped updating automatically. Refresh to see new changes.'**
  String get paneNoticeWatchStopped;

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

  /// Label of the Get Info inspector's permissions section (02 §2.6): a display line for targets the editor cannot touch, the D28 octal+rwx editor otherwise.
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

  /// Label of the Get Info inspector's octal permissions field (02 §2.6, D28) — four octal digits, the leading special-bits digit included.
  ///
  /// In en, this message translates to:
  /// **'Octal'**
  String get infoPanelPermOctal;

  /// Inline error under the Get Info inspector's octal field while its text is not exactly four octal digits (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Use four octal digits (0000–7777).'**
  String get infoPanelPermInvalid;

  /// Row label for the owner rwx checkboxes in the Get Info inspector's permissions grid (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get infoPanelPermOwner;

  /// Row label for the group rwx checkboxes in the Get Info inspector's permissions grid (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get infoPanelPermGroup;

  /// Row label for the others rwx checkboxes in the Get Info inspector's permissions grid (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Others'**
  String get infoPanelPermOthers;

  /// Column tooltip for the read checkboxes in the Get Info inspector's permissions grid (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get infoPanelPermRead;

  /// Column tooltip for the write checkboxes in the Get Info inspector's permissions grid (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get infoPanelPermWrite;

  /// Column tooltip for the execute checkboxes in the Get Info inspector's permissions grid (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Execute'**
  String get infoPanelPermExecute;

  /// Accessible name of one checkbox in the Get Info inspector's permissions grid — who is Owner/Group/Others, what is Read/Write/Execute (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'{who} {what}'**
  String infoPanelPermCell(String who, String what);

  /// Note under the Get Info inspector's display-only permissions row when the target's name is undecodable (02 §13's flagged-name rule: no path built from it may cross the wire).
  ///
  /// In en, this message translates to:
  /// **'The name is not valid UTF-8 — it can\'t be sent to the server.'**
  String get infoPanelPermBlockedName;

  /// Note under the Get Info inspector's display-only permissions row when the target is a symbolic link (the VFS refuses to chmod a link typed, and following it would change a different file).
  ///
  /// In en, this message translates to:
  /// **'A symbolic link\'s permissions can\'t be changed.'**
  String get infoPanelPermBlockedLink;

  /// Note under the Get Info inspector's display-only permissions row when the pane's filesystem has no POSIX chmod — a Windows local pane (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'This filesystem can\'t change permissions.'**
  String get infoPanelPermBlockedUnsupported;

  /// Affordance writing the Get Info inspector's permissions draft to the target (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get infoPanelApplyPermissions;

  /// Affordance starting the Get Info inspector's recursive permissions apply on a folder — count, confirm, then walk (02 §2.6, D28). The ellipsis marks that confirmation follows.
  ///
  /// In en, this message translates to:
  /// **'Apply to enclosed items…'**
  String get infoPanelApplyEnclosed;

  /// Inline refusal when a permissions change reaches a filesystem without POSIX chmod (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'This filesystem can\'t change permissions.'**
  String get infoPanelPermErrorUnsupported;

  /// Inline refusal when the filesystem denies a permissions change (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Permission denied — you may not own this item.'**
  String get infoPanelPermErrorDenied;

  /// Inline refusal when a permissions change finds the target gone (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'The item no longer exists.'**
  String get infoPanelPermErrorNotFound;

  /// Generic inline refusal when a permissions change fails for a reason with no authored copy (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'The change could not be completed.'**
  String get infoPanelPermError;

  /// Title of the Get Info inspector's recursive-permissions confirmation dialog (02 §2.6, D28; 02 §10's destructive family).
  ///
  /// In en, this message translates to:
  /// **'Apply to enclosed items?'**
  String get infoPanelEnclosedTitle;

  /// Progress line of the recursive-permissions confirmation while the read-only count pass lists the folder (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Counting the items inside “{name}”…'**
  String infoPanelEnclosedCounting(String name);

  /// Unquantified body of the recursive-permissions confirmation — the fallback when the count pass could not complete (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Apply {octal} to “{name}” and the items inside it?'**
  String infoPanelEnclosedBody(String octal, String name);

  /// Quantified body of the recursive-permissions confirmation once the count pass saw every reachable item (02 §2.6, D28; 02 §10's quantify-then-confirm rule).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Apply {octal} to “{name}”? It has no changeable items inside.} =1{Apply {octal} to “{name}” and the 1 item inside it?} other{Apply {octal} to “{name}” and the {count} items inside it?}}'**
  String infoPanelEnclosedBodyCounted(String octal, String name, int count);

  /// Disclosure line of the recursive-permissions confirmation counting enclosed items whose names are not valid UTF-8 — the count pass finished, so the count is exact (02 §13).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Includes 1 item with an undecodable name — it will be skipped.} other{Includes {count} items with undecodable names — they will be skipped.}}'**
  String infoPanelEnclosedFlaggedCounted(int count);

  /// Disclosure line of the recursive-permissions confirmation counting enclosed symbolic links — the count pass finished, so the count is exact (D28's never-follow rule).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Includes 1 symbolic link — it will be skipped.} other{Includes {count} symbolic links — they will be skipped.}}'**
  String infoPanelEnclosedLinksCounted(int count);

  /// Hedged disclosure line of the recursive-permissions confirmation when the count pass could not see every reachable item — flagged names and links are still skipped, unreadable folders leave their subtrees uncounted, and the dialog cannot claim zero (02 §13's never-silent rule).
  ///
  /// In en, this message translates to:
  /// **'The count was incomplete — items with undecodable names and symbolic links will be skipped, and some folders could not be read.'**
  String get infoPanelEnclosedIncomplete;

  /// Decline affordance of the recursive-permissions confirmation, and the cancel affordance of its running apply walk (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get infoPanelEnclosedCancel;

  /// Confirm affordance of the recursive-permissions confirmation dialog (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get infoPanelEnclosedApply;

  /// Live progress line of the recursive permissions apply in the Get Info inspector — the mode being written and the chmods completed so far (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Applying {octal}… {count, plural, =1{1 item changed} other{{count} items changed}}'**
  String infoPanelEnclosedProgress(String octal, int count);

  /// Terminal line of a completed recursive permissions apply in the Get Info inspector (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item changed} other{{count} items changed}}'**
  String infoPanelEnclosedDone(int count);

  /// Terminal line of a cancelled recursive permissions apply — the already-written count stays disclosed so a partial run never reads as clean (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Cancelled — {count, plural, =1{1 item changed} other{{count} items changed}}'**
  String infoPanelEnclosedCancelled(int count);

  /// Terminal line of a recursive permissions apply that ended on the folder's own refusal — its listing or its chmod (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'Could not finish'**
  String get infoPanelEnclosedFailed;

  /// Tally line of a settled recursive permissions apply counting enclosed items skipped for undecodable names (02 §13).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item skipped — name not valid UTF-8} other{{count} items skipped — names not valid UTF-8}}'**
  String infoPanelEnclosedSkipped(int count);

  /// Tally line of a settled recursive permissions apply counting enclosed symbolic links skipped (D28's never-follow rule).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 symbolic link skipped} other{{count} symbolic links skipped}}'**
  String infoPanelEnclosedLinks(int count);

  /// Tally line of a settled recursive permissions apply counting folders whose listing refused mid-walk — their subtrees were never reached (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 folder could not be read} other{{count} folders could not be read}}'**
  String infoPanelEnclosedUnreadable(int count);

  /// Tally line of a settled recursive permissions apply counting items whose chmod refused typed — the walk continues past them (02 §2.6, D28).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item refused the change} other{{count} items refused the change}}'**
  String infoPanelEnclosedRefused(int count);

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

  /// Menu label for view.toggleActivityPanel, which shows or hides the inspector's Transfers tab (10 §8's View menu: Info, Transfers, Alerts). Also the header activity button's tooltip.
  ///
  /// In en, this message translates to:
  /// **'Transfers'**
  String get viewToggleActivityPanelLabel;

  /// Commands-menu label for queue.togglePause (02 §9's Commands table names it verbatim).
  ///
  /// In en, this message translates to:
  /// **'Pause/Resume Transfers'**
  String get queueTogglePauseLabel;

  /// The activity panel's live-queue tab (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get activityTabActivity;

  /// The activity panel's persistent-log tab (02 §6).
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get activityTabHistory;

  /// Tooltip on the queue pause toggle (02 §6's stated copy, verbatim).
  ///
  /// In en, this message translates to:
  /// **'Pause stops new transfers; current files finish'**
  String get queuePauseTooltip;

  /// Tooltip on the queue toggle while the queue is paused.
  ///
  /// In en, this message translates to:
  /// **'Resume the transfer queue'**
  String get queueResumeTooltip;

  /// Tooltip for the activity header's bandwidth-limit button (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Bandwidth'**
  String get activityBandwidthButton;

  /// Glyph the bandwidth button shows while no limit is set (02 §6's header button shows ∞).
  ///
  /// In en, this message translates to:
  /// **'∞'**
  String get activityBandwidthUnlimited;

  /// The header's Clear-completed button: removes completed task rows (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Clear completed'**
  String get activityClearCompleted;

  /// Tooltip for the activity panel's hide affordance; equivalent to view.toggleActivityPanel.
  ///
  /// In en, this message translates to:
  /// **'Close panel'**
  String get activityClosePanel;

  /// The Activity tab's empty state (02 §2.7's never-blank rule applies here too).
  ///
  /// In en, this message translates to:
  /// **'No transfers in progress.'**
  String get activityEmpty;

  /// The History tab's empty state.
  ///
  /// In en, this message translates to:
  /// **'No transfer history yet.'**
  String get activityHistoryEmpty;

  /// Hint for the History tab's filter field (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Filter history'**
  String get activityHistoryFilter;

  /// The History tab's clear action (02 §6 names it verbatim).
  ///
  /// In en, this message translates to:
  /// **'Clear History'**
  String get activityHistoryClear;

  /// Banner over a queue restored from the journal (02 §6's exact copy).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer from your last session is paused} other{{count} transfers from your last session are paused}}'**
  String activityRestoredBanner(int count);

  /// The restored-queue banner's resume action (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get activityRestoredResume;

  /// The restored-queue banner's discard action (02 §6): cancels the restored tasks.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get activityRestoredDiscard;

  /// Per-task row action: cancels the transfer (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get activityCancelTask;

  /// Per-task and per-item row action: re-runs the failed work (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get activityRetryTask;

  /// Per-task row action: drops a finished row from the listing (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get activityRemoveTask;

  /// Per-task row action: opens the task's destination in the active pane (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Reveal in pane'**
  String get activityRevealInPane;

  /// Per-task row action: copies the failure text to the clipboard (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Copy error'**
  String get activityCopyError;

  /// Failure sentence on a task naming a remote endpoint before the engine protocol grows transfer verbs (open item 23).
  ///
  /// In en, this message translates to:
  /// **'Remote transfers aren\'t available yet — this build moves local files only.'**
  String get activityTaskRemoteUnavailable;

  /// Per-file sub-row action while the file is queued: pulls it from the task (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get activitySkipItem;

  /// Per-file sub-row action while the file is in flight: aborts that file only.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get activityCancelItem;

  /// Tooltip for a multi-file task row's expand chevron (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Show files'**
  String get activityExpandTask;

  /// Tooltip for an expanded task row's collapse chevron.
  ///
  /// In en, this message translates to:
  /// **'Hide files'**
  String get activityCollapseTask;

  /// The pending-conflict strip's summary line (02 §5.2/§6).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item needs an answer} other{{count} items need answers}}'**
  String activityConflictsTitle(int count);

  /// Opens the 5-verb conflict chooser for one parked item (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Resolve…'**
  String get conflictResolve;

  /// The conflict dialog's title line (02 §5.2's example copy).
  ///
  /// In en, this message translates to:
  /// **'{name} already exists in {destination}'**
  String conflictDialogTitle(String name, String destination);

  /// The conflict dialog's destination-side summary (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Existing: {details}'**
  String conflictExistingLine(String details);

  /// The conflict dialog's source-side summary (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Replacing it with: {details}'**
  String conflictReplacingLine(String details);

  /// Conflict verb: overwrite the destination (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get conflictVerbReplace;

  /// Conflict verb: overwrite only when the source is newer by more than the mtime tolerance (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Replace if newer'**
  String get conflictVerbReplaceIfNewer;

  /// Conflict verb: land under an auto-numbered name (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Keep both'**
  String get conflictVerbKeepBoth;

  /// Conflict verb: leave the destination untouched (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get conflictVerbSkip;

  /// Conflict verb, folders only: recurse, preserving destination-only entries (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get conflictVerbMerge;

  /// The conflict dialog's stop button: cancels the rest of the task (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get conflictStop;

  /// Dismisses the conflict dialog without answering — the item stays parked.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get conflictNotNow;

  /// The conflict dialog's task-scope checkbox (02 §5.2's exact wording).
  ///
  /// In en, this message translates to:
  /// **'Apply to all {count, plural, =1{1 remaining conflict} other{{count} remaining conflicts}} in this task'**
  String conflictApplyToAll(int count);

  /// The quit guard's dialog title (02 §10): shown when the window close is intercepted with live transfer tasks.
  ///
  /// In en, this message translates to:
  /// **'Quit while transfers are running?'**
  String get quitConfirmTitle;

  /// The quit dialog's warning line (02 §10) when no remaining-byte figure is known yet.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer is running} other{{count} transfers are running}}.'**
  String quitConfirmBody(int count);

  /// The quit dialog's warning line (02 §10's example copy): the remaining figure is the discovered-total floor, so 'so far' never overstates what is left.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer is running} other{{count} transfers are running}} ({remaining} remaining so far).'**
  String quitConfirmBodyRemaining(int count, String remaining);

  /// The quit dialog's honesty note (02 §10): until resumable transfers ship, a paused in-flight file restarts from byte zero on relaunch.
  ///
  /// In en, this message translates to:
  /// **'Files in progress restart from the beginning next launch.'**
  String get quitConfirmRestartNote;

  /// Quit verb (02 §10, default button): pauses the live tasks, flushes the journal, then lets the window destroy.
  ///
  /// In en, this message translates to:
  /// **'Pause and Quit'**
  String get quitPauseAndQuit;

  /// Quit verb (02 §10): cancels the live tasks so they do not restore, flushes the journal, then lets the window destroy.
  ///
  /// In en, this message translates to:
  /// **'Cancel Transfers and Quit'**
  String get quitCancelTransfersAndQuit;

  /// Quit verb (02 §10): cancels the close — the window stays open and transfers keep running.
  ///
  /// In en, this message translates to:
  /// **'Keep Transferring'**
  String get quitKeepTransferring;

  /// The journal-flush failure dialog's title (07 §3.5): shown when the close-path journal write fails or times out.
  ///
  /// In en, this message translates to:
  /// **'Transfer state could not be saved'**
  String get quitFlushFailedTitle;

  /// The journal-flush failure dialog's body (07 §3.5): the raw error is machine data rendered inside ARB copy.
  ///
  /// In en, this message translates to:
  /// **'Saving the transfer journal failed: {error}. The window stayed open so queued and in-flight transfers are not lost — quit again to retry.'**
  String quitFlushFailedBody(String error);

  /// Closes the journal-flush failure dialog; the window stays open either way.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get quitFlushFailedDismiss;

  /// Task state: waiting behind the queue's admission order.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get transferStateQueued;

  /// Task state: the discovery walk is still enumerating items.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get transferStateScanning;

  /// Task state: items are in flight.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get transferStateRunning;

  /// Task state: held by the queue pause or a task pause.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get transferStatePaused;

  /// Task/history outcome: finished successfully.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get transferStateCompleted;

  /// Task/history outcome: ended with failures.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get transferStateFailed;

  /// Task/history outcome: stopped by the user.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get transferStateCancelled;

  /// Item state: queued behind dispatch or a container.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get transferItemPending;

  /// Item state: parked on an unresolved name conflict (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Needs an answer'**
  String get transferItemConflict;

  /// Item state: left out of the transfer.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get transferItemSkipped;

  /// The local endpoint's name in a task's source → destination line.
  ///
  /// In en, this message translates to:
  /// **'This computer'**
  String get activityTaskRouteLocal;

  /// Multi-root task title (02 §6's '214 items to /var/www').
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item} other{{count} items}} to {destination}'**
  String activityTaskTitleMulti(int count, String destination);

  /// Multi-root delete task title.
  ///
  /// In en, this message translates to:
  /// **'Delete {count, plural, =1{1 item} other{{count} items}}'**
  String activityTaskTitleDelete(int count);

  /// Delete item outcome detail: delivered to the OS or remote trash (D15).
  ///
  /// In en, this message translates to:
  /// **'Moved to trash'**
  String get activityDeleteTrashed;

  /// Delete item outcome detail: unlinked without a trash hop (D15).
  ///
  /// In en, this message translates to:
  /// **'Deleted permanently'**
  String get activityDeletePermanent;

  /// The activity footer's growing totals (02 §5.3's 'so far' semantics; a trailing + marks still-scanning counts).
  ///
  /// In en, this message translates to:
  /// **'{done} of {total} items · {bytes} of {totalBytes} so far'**
  String activityFooterTotals(
    String done,
    String total,
    String bytes,
    String totalBytes,
  );

  /// Accessible label of one transfer-task row (02 §13: label + state on a live region so completion and failure announce, while progress stays silent).
  ///
  /// In en, this message translates to:
  /// **'{label}, {state}'**
  String activityRowSemantics(String label, String state);

  /// The status bar's transfer summary chip (02 §1: rate plus live task count).
  ///
  /// In en, this message translates to:
  /// **'{rate} · {count, plural, =1{{count} task} other{{count} tasks}}'**
  String statusTransferChip(String rate, int count);

  /// The status bar's bandwidth chip while any direction is limited (02 §6); a side shows ∞ when only the other is limited.
  ///
  /// In en, this message translates to:
  /// **'Limited: ↓{down} ↑{up}'**
  String statusLimitChip(String down, String up);

  /// Title of the throttle popover (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Bandwidth limits'**
  String get bandwidthPopoverTitle;

  /// The popover's per-direction limit label (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get bandwidthDownLabel;

  /// The popover's per-direction limit label (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get bandwidthUpLabel;

  /// Limit choice: no rate cap (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get bandwidthOff;

  /// Limit choice that opens the free-form rate field (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get bandwidthCustom;

  /// Hint inside the custom-rate field.
  ///
  /// In en, this message translates to:
  /// **'e.g. 2 MB/s'**
  String get bandwidthCustomHint;

  /// Inline error under the custom-rate field — invalid input is rejected, never silently clamped.
  ///
  /// In en, this message translates to:
  /// **'Enter a rate like 500 KB/s (up to {max})'**
  String bandwidthInvalid(String max);

  /// Applies the custom-rate field's value.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get bandwidthSet;

  /// History verb for a copy task (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get historyVerbCopy;

  /// History verb for a move task (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get historyVerbMove;

  /// History verb for a delete task (02 §6).
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get historyVerbDelete;

  /// Accessibility label for the panes↔activity-panel splitter (02 §1).
  ///
  /// In en, this message translates to:
  /// **'Resize activity panel'**
  String get resizeActivityPanel;

  /// The activity splitter's current height as whole pixels.
  ///
  /// In en, this message translates to:
  /// **'{value} px'**
  String activityPanelHeightPx(int value);

  /// Title of the Settings surface (02 §10).
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Menu command opening Settings at the Bookmark backup section (D21). 10 §8's Server menu wording; 10 §10 says Sync in both sibling apps.
  ///
  /// In en, this message translates to:
  /// **'Back up and sync…'**
  String get settingsBackupCommand;

  /// 02 §9's app.settings menu command — opens the Settings surface.
  ///
  /// In en, this message translates to:
  /// **'Settings…'**
  String get settingsCommand;

  /// Section header for the General tab's rows inside Settings (02 §10).
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsGeneralSection;

  /// Settings toggle for the D19 link-only update check (opt-out).
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheckEnabledLabel;

  /// Explainer under the update-check toggle; the D19/D23 trust claim.
  ///
  /// In en, this message translates to:
  /// **'Checks GitHub on launch and only links to the release page — it never downloads anything.'**
  String get updateCheckEnabledSubtitle;

  /// 04 §4.3's verbatim section title.
  ///
  /// In en, this message translates to:
  /// **'Bookmark backup'**
  String get backupTitle;

  /// 04 §4.3's verbatim intro.
  ///
  /// In en, this message translates to:
  /// **'Back up bookmarks, end-to-end encrypted, through a Séance sync server. Nothing readable ever leaves this device.'**
  String get backupIntro;

  /// 04 §4.3's verbatim Design B option, preselected.
  ///
  /// In en, this message translates to:
  /// **'Separate backup account — a new account just for Poltergeist, on the same server. Works with every Séance version.'**
  String get backupModeSeparate;

  /// 04 §4.3's verbatim Design A option; {version} is kMinimumSharedAccountSeanceVersion.
  ///
  /// In en, this message translates to:
  /// **'Shared Séance account — bookmarks live alongside your Séance data, and your Séance servers appear as bookmark sources. This app will hold your Séance encryption passphrase and could read everything in the account, including saved passwords. Requires Séance {version} or newer on all devices.'**
  String backupModeShared(String version);

  /// 04 §4.3's verbatim fleet-confirmation checkbox gating the shared-account Continue button; {version} is kMinimumSharedAccountSeanceVersion.
  ///
  /// In en, this message translates to:
  /// **'Every device that runs Séance with this account has version {version} or newer.'**
  String backupFleetCheckbox(String version);

  /// 04 §4.3's verbatim helper under the fleet checkbox.
  ///
  /// In en, this message translates to:
  /// **'Older Séance versions misread Poltergeist\'s records — update them everywhere before turning this on, and never add an older Séance to this account afterwards: the risk does not end at setup.'**
  String get backupFleetHelper;

  /// 04 §4.3's verbatim disclosure rendered under option 2 while kMinSharedVersionIncludesSeance56Fix is false.
  ///
  /// In en, this message translates to:
  /// **'Séance devices accept synced host-key pins without a conflict warning — including pins this app pushes.'**
  String get backupSharedPinDisclosure;

  /// 04 §4.3's verbatim 403 registration_closed copy (Design B register).
  ///
  /// In en, this message translates to:
  /// **'This server has registration closed. If you run it: temporarily set SEANCE_OPEN_REGISTRATION=1, create the account, then close it again — while it is open, anyone who can reach the server can register, so close it as soon as you are done. If someone else runs it, ask them to create an account for you.'**
  String get backupRegistrationClosed;

  /// 04 §4.3's verbatim passphrase callout.
  ///
  /// In en, this message translates to:
  /// **'The encryption passphrase never leaves your devices and cannot be recovered. Losing it means losing the backup.'**
  String get backupPassphraseCallout;

  /// 04 §4.5's verbatim three-cause decrypt-failure copy (syncPassphraseCheckFailedMessage mirrored in ARB).
  ///
  /// In en, this message translates to:
  /// **'The encryption passphrase could not decrypt this account\'s records. The passphrase may be wrong, the record may be corrupt, or it may use a newer schema.'**
  String get backupPassphraseCheckFailed;

  /// 04 §4.5's verbatim paused status while passphraseUnverified holds.
  ///
  /// In en, this message translates to:
  /// **'Backup paused until the passphrase is verified against the account\'s existing data.'**
  String get backupPaused;

  /// 04 §4.5's verbatim way-out for a paused shared account.
  ///
  /// In en, this message translates to:
  /// **'Open Séance on any device signed into this account and add or edit a server, then sync — backup resumes automatically.'**
  String get backupPausedWayOutShared;

  /// 04 §4.5's verbatim way-out for a paused separate account.
  ///
  /// In en, this message translates to:
  /// **'Open Poltergeist on another device signed into this account and add or edit a bookmark, then sync.'**
  String get backupPausedWayOutSeparate;

  /// 04 §4.5's verbatim KDF-downgrade refusal (KdfDowngradeException mirrored in ARB).
  ///
  /// In en, this message translates to:
  /// **'The sync server returned weaker password-hashing parameters than Poltergeist accepts — refusing to derive your key (possible downgrade attack).'**
  String get backupKdfRefusal;

  /// Label of the enrollment form's server field.
  ///
  /// In en, this message translates to:
  /// **'Sync server URL'**
  String get backupServerUrlField;

  /// Label of the enrollment form's username field.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get backupUsernameField;

  /// Label of the sync account password field.
  ///
  /// In en, this message translates to:
  /// **'Account password'**
  String get backupAccountPasswordField;

  /// Helper under the account password field.
  ///
  /// In en, this message translates to:
  /// **'Authenticates with the sync server.'**
  String get backupAccountPasswordHelper;

  /// Label of the backup encryption passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Encryption passphrase'**
  String get backupEncryptionPassphraseField;

  /// Helper under the encryption passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Encrypts the backup; use it on every device.'**
  String get backupEncryptionPassphraseHelper;

  /// Label of the register flow's confirmation field.
  ///
  /// In en, this message translates to:
  /// **'Confirm encryption passphrase'**
  String get backupConfirmPassphraseField;

  /// Segmented-control tab for enrolling against an existing account.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get backupLoginTab;

  /// Segmented-control tab for creating a new backup account.
  ///
  /// In en, this message translates to:
  /// **'Register'**
  String get backupRegisterTab;

  /// Runs the selected enrollment action.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get backupContinue;

  /// Abandons the enrollment or confirmation dialog.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get backupCancel;

  /// Dismisses the Backup settings surface.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get backupClose;

  /// Live-region status while a registration runs.
  ///
  /// In en, this message translates to:
  /// **'Registering…'**
  String get backupRegistering;

  /// Live-region status while a login runs.
  ///
  /// In en, this message translates to:
  /// **'Logging in…'**
  String get backupLoggingIn;

  /// Live-region status for an enrollment error the spec has no verbatim copy for.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String backupEnrollFailed(String error);

  /// Validation error for an unparseable or non-HTTP server URL (ported validator copy).
  ///
  /// In en, this message translates to:
  /// **'Enter a valid HTTP or HTTPS server URL.'**
  String get backupValidationUrl;

  /// Validation error for a userinfo-carrying server URL (ported validator copy).
  ///
  /// In en, this message translates to:
  /// **'Server URL must not include embedded credentials.'**
  String get backupValidationUrlCredentials;

  /// Validation error for an empty username (ported validator copy).
  ///
  /// In en, this message translates to:
  /// **'Enter a username.'**
  String get backupValidationUsername;

  /// Validation error for an empty account password (ported validator copy).
  ///
  /// In en, this message translates to:
  /// **'Enter the sync account password.'**
  String get backupValidationPassword;

  /// Validation error for an empty encryption passphrase (ported validator copy).
  ///
  /// In en, this message translates to:
  /// **'Enter the encryption passphrase.'**
  String get backupValidationPassphrase;

  /// Validation error for an empty confirmation field (ported validator copy).
  ///
  /// In en, this message translates to:
  /// **'Confirm the encryption passphrase before registering.'**
  String get backupValidationConfirm;

  /// Validation error when the confirmation differs (ported validator copy).
  ///
  /// In en, this message translates to:
  /// **'Encryption passphrases do not match.'**
  String get backupValidationMismatch;

  /// Mode label on the enrolled state's account summary.
  ///
  /// In en, this message translates to:
  /// **'Separate backup account'**
  String get backupEnrolledModeSeparate;

  /// Mode label on the enrolled state's account summary.
  ///
  /// In en, this message translates to:
  /// **'Shared Séance account'**
  String get backupEnrolledModeShared;

  /// The enrolled account's identity line.
  ///
  /// In en, this message translates to:
  /// **'{username} on {server}'**
  String backupEnrolledSummary(String username, String server);

  /// 04 §3.3's manual round button.
  ///
  /// In en, this message translates to:
  /// **'Back up now'**
  String get backupNow;

  /// Status while a backup round runs.
  ///
  /// In en, this message translates to:
  /// **'Backing up…'**
  String get backupSyncing;

  /// Enrolled status before any round has completed.
  ///
  /// In en, this message translates to:
  /// **'Not backed up yet.'**
  String get backupNeverSynced;

  /// Status for a round that finished within the minute (04 §3.3's "Last backed up 3 min ago" shape).
  ///
  /// In en, this message translates to:
  /// **'Last backed up just now'**
  String get backupLastSyncedJustNow;

  /// Status for a round that finished minutes ago (04 §3.3's verbatim "Last backed up 3 min ago" shape).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Last backed up 1 min ago} other{Last backed up {count} min ago}}'**
  String backupLastSyncedMinutesAgo(int count);

  /// Status for a round that finished hours ago.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Last backed up 1 hour ago} other{Last backed up {count} hours ago}}'**
  String backupLastSyncedHoursAgo(int count);

  /// Status for a round that finished days ago.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Last backed up 1 day ago} other{Last backed up {count} days ago}}'**
  String backupLastSyncedDaysAgo(int count);

  /// Status for the last round's failure (04 §3.3: error text lives in Settings → Backup).
  ///
  /// In en, this message translates to:
  /// **'Backup failed: {error}'**
  String backupSyncFailed(String error);

  /// Durable notice for the §7.3 dead-account posture (401 during a round drops to local-only).
  ///
  /// In en, this message translates to:
  /// **'The server rejected this device\'s sign-in — the backup account may have been deleted. Bookmarks stay safe on this device and nothing is pushed until you sign in again.'**
  String get backupDeadAccount;

  /// 04 §4.2's durable decode-failure tripwire: names the record id, all three candidate causes, and the remediation.
  ///
  /// In en, this message translates to:
  /// **'A synced record ({id}) could not be read after it decrypted — it may have been written by an older Séance version, be corrupt, or use a newer schema. Once the stale device is patched or removed, re-save the affected bookmark to restore it.'**
  String backupTripwireWarning(String id);

  /// 04 §3.2's durable pin-quarantine warning per conflicting host.
  ///
  /// In en, this message translates to:
  /// **'A synced host key for {locator} conflicts with the key this device trusts. This can mean a man-in-the-middle attack.'**
  String backupPinConflictWarning(String locator);

  /// Resolves a pin conflict by installing the pulled key (04 §3.2's accept).
  ///
  /// In en, this message translates to:
  /// **'Use synced key'**
  String get backupPinAcceptSynced;

  /// Title of the device-level credential-sync switch in shared mode (Séance's syncSecrets); the server editor's credential switch names it.
  ///
  /// In en, this message translates to:
  /// **'Sync saved passwords & keys'**
  String get backupSyncSecretsTitle;

  /// Subtitle of the device-level credential-sync switch.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted. Only includes servers where credential sync is also on.'**
  String get backupSyncSecretsSubtitle;

  /// Resolves a pin conflict by re-pushing the trusted key (04 §3.2's keep local).
  ///
  /// In en, this message translates to:
  /// **'Keep local key'**
  String get backupPinKeepLocal;

  /// 04 §3.1's durable corrupt-store notice; it must name that deleted bookmarks may reappear, not only that edits may be lost.
  ///
  /// In en, this message translates to:
  /// **'The local backup record store was unreadable and has been rebuilt — deleted bookmarks may reappear, and pending edits will re-upload on the next backup.'**
  String get backupStoreQuarantined;

  /// 04 §4.1's separate-mode account deletion entry point.
  ///
  /// In en, this message translates to:
  /// **'Delete backup account…'**
  String get backupDeleteAccount;

  /// Title of the separate-mode account deletion dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete backup account'**
  String get backupDeleteAccountTitle;

  /// 04 §4.1's deletion consequence copy — it deletes only Poltergeist's data.
  ///
  /// In en, this message translates to:
  /// **'This deletes the account {username} on {server} and every backup stored on it. This cannot be undone.'**
  String backupDeleteAccountBody(String username, String server);

  /// Typed-confirmation prompt above the name field (04 §4.1).
  ///
  /// In en, this message translates to:
  /// **'Type {username} to confirm.'**
  String backupDeleteConfirmHint(String username);

  /// Verb button confirming account deletion.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get backupDeleteConfirm;

  /// Inline error when the account deletion request fails.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the account: {error}'**
  String backupDeleteFailed(String error);

  /// 04 §4.2's shared-mode session end — the only shared-mode account action.
  ///
  /// In en, this message translates to:
  /// **'Sign out on this device'**
  String get backupSignOut;

  /// 04 §4.2's sign-out consequence copy — local forget only, server data untouched.
  ///
  /// In en, this message translates to:
  /// **'This device forgets its sign-in. The account and its data stay on the server.'**
  String get backupSignOutBody;

  /// 04 §4.4's verbatim B→A switch entry point, offered behind the fleet gate.
  ///
  /// In en, this message translates to:
  /// **'Switch to shared account…'**
  String get backupSwitchToShared;

  /// Title of the §4.4 B→A switch flow.
  ///
  /// In en, this message translates to:
  /// **'Switch to shared account'**
  String get backupSwitchTitle;

  /// Live-region status while the §4.4 switch runs.
  ///
  /// In en, this message translates to:
  /// **'Switching…'**
  String get backupSwitchWorking;

  /// Heading of the §4.4 hold set — quarantined pins needing an explicit decision.
  ///
  /// In en, this message translates to:
  /// **'Resolve host-key conflicts'**
  String get backupSwitchConflictTitle;

  /// Per-locator decision copy in the §4.4 hold set — adopt the fleet pin or keep the local one as a deliberate override.
  ///
  /// In en, this message translates to:
  /// **'The shared account holds a different host key for {locator}. Keeping this device\'s key pushes it to every device on the account — only keep it if you are sure it is the right key.'**
  String backupSwitchConflictBody(String locator);

  /// Resolves a held locator by adopting the fleet pin — no re-seal for that host (04 §4.4).
  ///
  /// In en, this message translates to:
  /// **'Use shared key'**
  String get backupSwitchAdoptFleet;

  /// Completion copy of the §4.4 switch — pushes may still hold while passphraseUnverified stands.
  ///
  /// In en, this message translates to:
  /// **'Switched to the shared account. Bookmarks and host-key pins push on the next backup.'**
  String get backupSwitchDone;

  /// Inline error when the §4.4 switch throws.
  ///
  /// In en, this message translates to:
  /// **'The switch could not finish: {error}'**
  String backupSwitchFailed(String error);

  /// 04 §4.4's verbatim optional post-switch delete, offered only after the first shared sync succeeds.
  ///
  /// In en, this message translates to:
  /// **'Also delete the separate backup account…'**
  String get backupDeleteSeparateAfterSwitch;

  /// The §4.4 delete offer's consequence copy.
  ///
  /// In en, this message translates to:
  /// **'The separate backup account {username} on {server} still exists — its sign-in was kept while the switch proved out. Delete it now, or keep it.'**
  String backupDeleteSeparateBody(String username, String server);

  /// Declines the §4.4 delete offer — the old account stays untouched.
  ///
  /// In en, this message translates to:
  /// **'Keep it'**
  String get backupDeleteSeparateDecline;

  /// 04 §4.4's note beside the decline — Poltergeist never auto-deletes the old account.
  ///
  /// In en, this message translates to:
  /// **'Removing it later requires re-enrolling into it first.'**
  String get backupDeleteSeparateLaterNote;

  /// Completion copy after the retained account's deletion.
  ///
  /// In en, this message translates to:
  /// **'The separate backup account was deleted.'**
  String get backupDeleteSeparateDone;

  /// Inline error when the retained-account deletion fails.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the separate account: {error}'**
  String backupDeleteSeparateFailed(String error);

  /// Command label: open the selected file in the built-in text editor (file.editBuiltIn, 02 §8.3, 06 §4.2).
  ///
  /// In en, this message translates to:
  /// **'Edit in Poltergeist'**
  String get fileEditBuiltInLabel;

  /// Title of the editor's unsaved-changes guard (06 §2.3), shown when leaving with dirty edits.
  ///
  /// In en, this message translates to:
  /// **'Discard unsaved changes?'**
  String get editorDiscardTitle;

  /// Body of the editor's unsaved-changes guard (06 §2.3).
  ///
  /// In en, this message translates to:
  /// **'Changes not saved to the local copy will be lost.'**
  String get editorDiscardBody;

  /// Declines the editor's discard confirmation: the editor stays open.
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get editorDiscardKeep;

  /// Accepts the editor's discard confirmation: unsaved edits are dropped.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get editorDiscardConfirm;

  /// Tooltip of the editor's find-bar affordance (06 §2.3).
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get editorFindTooltip;

  /// Tooltip of the editor's local-only save action (06 §2.4).
  ///
  /// In en, this message translates to:
  /// **'Save locally'**
  String get editorSaveLocallyTooltip;

  /// Tooltip of the editor's save-and-upload action on a managed checkout (06 §2.4).
  ///
  /// In en, this message translates to:
  /// **'Save and upload'**
  String get editorSaveAndUploadTooltip;

  /// Hint text of the editor's find query field (06 §2.3).
  ///
  /// In en, this message translates to:
  /// **'Find in file'**
  String get editorFindHint;

  /// Tooltip of the find bar's case-sensitivity toggle.
  ///
  /// In en, this message translates to:
  /// **'Match case'**
  String get editorMatchCaseTooltip;

  /// Tooltip of the find bar's previous-match button.
  ///
  /// In en, this message translates to:
  /// **'Previous match'**
  String get editorPreviousMatchTooltip;

  /// Tooltip of the find bar's next-match button.
  ///
  /// In en, this message translates to:
  /// **'Next match'**
  String get editorNextMatchTooltip;

  /// Tooltip of the find bar's close button.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get editorCloseSearchTooltip;

  /// Find bar counter shown when the query has no hits.
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get editorNoMatches;

  /// Find bar counter: ordinal of the active match over the total.
  ///
  /// In en, this message translates to:
  /// **'{current}/{total}'**
  String editorMatchCount(int current, int total);

  /// Find bar counter at the match cap: the plus marks a truncated total.
  ///
  /// In en, this message translates to:
  /// **'{current}/{total}+'**
  String editorMatchCountCapped(int current, int total);

  /// Editor status bar for a saved document (06 §2.3).
  ///
  /// In en, this message translates to:
  /// **'{lines} lines · {bytes} bytes'**
  String editorStatusClean(int lines, int bytes);

  /// Editor status bar with unsaved edits (06 §2.3).
  ///
  /// In en, this message translates to:
  /// **'{lines} lines · {bytes} bytes · Unsaved'**
  String editorStatusDirty(int lines, int bytes);

  /// 06 §2.4's toast matrix: the upload completed but the user typed during it — the on-disk copy lags the editor.
  ///
  /// In en, this message translates to:
  /// **'Uploaded the saved version; newer edits remain unsaved.'**
  String get editorSavedUploadedDirty;

  /// 06 §2.4's toast matrix: save-and-upload completed with a clean editor.
  ///
  /// In en, this message translates to:
  /// **'Saved and uploaded.'**
  String get editorSavedUploaded;

  /// 06 §2.4's toast matrix: the local save landed but the upload was declined (a cancelled conflict escalation).
  ///
  /// In en, this message translates to:
  /// **'Saved locally; not uploaded.'**
  String get editorSavedLocallyNotUploaded;

  /// 06 §2.4's toast matrix: a local-only save completed.
  ///
  /// In en, this message translates to:
  /// **'Saved locally.'**
  String get editorSavedLocally;

  /// Toast when a remote Edit in Poltergeist reaches the shell with no checkout session wired — a wiring defect, reported as such.
  ///
  /// In en, this message translates to:
  /// **'The checkout store is unavailable; remote files cannot be edited.'**
  String get editorCheckoutUnavailable;

  /// Title of the §3.4 conflict-escalation dialog: the remote moved under an open checkout.
  ///
  /// In en, this message translates to:
  /// **'Remote file changed'**
  String get editorConflictTitle;

  /// 06 §3.4's conflict-escalation body: names the file and its server. The neutral "(or was deleted)" matches the typed message — a deleted target has no newer version to overwrite.
  ///
  /// In en, this message translates to:
  /// **'“{name}” changed (or was deleted) on {server} after it was opened locally. Overwrite the remote version?'**
  String editorConflictBody(String name, String server);

  /// Declines the conflict overwrite — the safe default (02 §10).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get editorConflictCancel;

  /// Confirms the §3.4 escalation: retries the upload with overwriteRemoteChanges.
  ///
  /// In en, this message translates to:
  /// **'Overwrite Remote Version'**
  String get editorConflictOverwrite;

  /// Command label and submenu/chooser title: pick the application that opens the selected file (open-with-external, 02 §8.1/§9, 06 §4.2).
  ///
  /// In en, this message translates to:
  /// **'Open With'**
  String get fileOpenWithLabel;

  /// Open With ▸ row resolving to the built-in editor (poltergeist.builtin, 06 §4.2).
  ///
  /// In en, this message translates to:
  /// **'Built-in text editor'**
  String get openWithBuiltInLabel;

  /// Open With ▸ row resolving to the OS default application (poltergeist.system, 06 §4.2).
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get openWithSystemDefaultLabel;

  /// Open With ▸ row that picks an application not yet in the registry (06 §4.1).
  ///
  /// In en, this message translates to:
  /// **'Other…'**
  String get openWithOtherLabel;

  /// Open With ▸ terminal row deep-linking to the Editing settings section (06 §4.1/§8).
  ///
  /// In en, this message translates to:
  /// **'Configure Editors…'**
  String get openWithConfigureLabel;

  /// Title of the native application picker behind Open With ▸ Other… (06 §4.3) — also forwarded to the macOS NSOpenPanel.
  ///
  /// In en, this message translates to:
  /// **'Choose an editor application'**
  String get editorPickDialogTitle;

  /// Title of the remember-choice prompt after Open With ▸ Other… picked an application (06 §4.1).
  ///
  /// In en, this message translates to:
  /// **'Open “{name}” with {editor}?'**
  String openWithPickedTitle(String name, String editor);

  /// Checkbox of the remember-choice prompt: persists a per-extension editor binding (06 §4.1's extensionDefaults).
  ///
  /// In en, this message translates to:
  /// **'Always use {editor} for .{extension} files'**
  String openWithRememberForExtension(String editor, String extension);

  /// Aborts the remember-choice prompt — the file does not open.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get openWithCancel;

  /// Confirms the remember-choice prompt: opens the file with the picked application.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get openWithConfirmOpen;

  /// 06 §3.3's 12-second action toast when an external editor's save marks a managed checkout dirty (watch → debounce → SHA-256 reconcile).
  ///
  /// In en, this message translates to:
  /// **'“{name}” changed locally. Upload it?'**
  String checkoutDirtyUploadPrompt(String name);

  /// The dirty-checkout toast's action: uploads the changed local copy through the §3.4 pipeline.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get checkoutDirtyUploadAction;

  /// Confirmation toast after a dirty-checkout prompt's upload commits (06 §3.4).
  ///
  /// In en, this message translates to:
  /// **'Uploaded {name}'**
  String checkoutUploadSucceeded(String name);

  /// 06 §3.7's persistent pane banner while a bound server's managed checkouts hold dirty or missing local edits — the resume offer a relaunch owes the user.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file has local edits that aren\'t on the server yet.} other{{count} files have local edits that aren\'t on the server yet.}}'**
  String checkoutLocalEditsBanner(int count);

  /// The local-edits banner's action — opens the §3.7 review dialog.
  ///
  /// In en, this message translates to:
  /// **'Review…'**
  String get checkoutLocalEditsReview;

  /// Title of the 06 §3.7 local-edits review dialog, naming the server its rows belong to.
  ///
  /// In en, this message translates to:
  /// **'Local edits — {server}'**
  String checkoutLocalEditsTitle(String server);

  /// Empty state of the §3.7 review dialog (reachable from a remotePath favorite's Local Edits… with nothing pending).
  ///
  /// In en, this message translates to:
  /// **'No local edits for this server.'**
  String get checkoutLocalEditsEmpty;

  /// Badge on a review-dialog row whose local copy differs from its checkout baseline (06 §3.7).
  ///
  /// In en, this message translates to:
  /// **'Modified locally'**
  String get checkoutLocalEditsDirty;

  /// Badge on a review-dialog row whose local copy was deleted underneath the checkout (06 §3.7).
  ///
  /// In en, this message translates to:
  /// **'Local file missing'**
  String get checkoutLocalEditsMissing;

  /// Badge on a review-dialog row for a displaced record — 06 §3.5's occupant, still holding its local copy under a reclaimed remotePath.
  ///
  /// In en, this message translates to:
  /// **'Recovered'**
  String get checkoutLocalEditsRecoveredRecord;

  /// Section header for the preserved recordless checkout payloads in the §3.7 review dialog.
  ///
  /// In en, this message translates to:
  /// **'Recovered files'**
  String get checkoutLocalEditsRecoveredSection;

  /// 06 §3.7's pinned copy beside the recovered-payload rows — a recordless payload has no upload lane.
  ///
  /// In en, this message translates to:
  /// **'Recovered files can\'t upload from here — upload the file through a pane when you\'re done.'**
  String get checkoutLocalEditsRecoveredHint;

  /// Row action opening the local copy — a record row resolves through effectiveDefaultFor, a recovered row opens its file.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get checkoutLocalEditsOpen;

  /// Row action uploading the dirty local copy through the §3.4 CAS-guarded pipeline.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get checkoutLocalEditsUpload;

  /// Row action deleting the local copy after confirmation (06 §3.7).
  ///
  /// In en, this message translates to:
  /// **'Discard…'**
  String get checkoutLocalEditsDiscard;

  /// Tooltip on the disabled Upload action while the server is disconnected (06 §3.7).
  ///
  /// In en, this message translates to:
  /// **'Connect to upload'**
  String get checkoutLocalEditsConnectToUpload;

  /// Confirmation title before a §3.7 row's Discard deletes the local copy.
  ///
  /// In en, this message translates to:
  /// **'Discard local copy?'**
  String get checkoutLocalEditsDiscardTitle;

  /// Confirmation body before a §3.7 row's Discard — the loss the button commits to.
  ///
  /// In en, this message translates to:
  /// **'Any changes not uploaded to the server are deleted.'**
  String get checkoutLocalEditsDiscardBody;

  /// Aborts a §3.7 row's Discard — the local copy stays.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get checkoutLocalEditsDiscardCancel;

  /// Confirms a §3.7 row's Discard — deletes the local copy.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get checkoutLocalEditsDiscardConfirm;

  /// Dismisses the §3.7 local-edits review dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get checkoutLocalEditsClose;

  /// RemotePath favorite's context item opening the §3.7 local-edits review dialog — server-scoped, so it shows every dirty copy on that server including records no pane currently touches.
  ///
  /// In en, this message translates to:
  /// **'Local Edits…'**
  String get sidebarLocalEdits;

  /// Dismisses the Editing settings dialog (06 §8's bounded mount).
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get editorSettingsClose;

  /// Label of the §8 Default-editor dropdown — the registry's global defaultEditorId.
  ///
  /// In en, this message translates to:
  /// **'Default editor'**
  String get editorDefaultLabel;

  /// Default-editor dropdown option resolving to poltergeist.builtin (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Built-in editor'**
  String get editorBuiltInOption;

  /// Default-editor dropdown option resolving to poltergeist.system (06 §8).
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get editorSystemDefaultOption;

  /// Renders an editor definition configured for a different platform — visible but disabled (06 §8).
  ///
  /// In en, this message translates to:
  /// **'{name} (another platform)'**
  String editorNameOtherPlatform(String name);

  /// Section label above the configured external-editors list (06 §8).
  ///
  /// In en, this message translates to:
  /// **'External editors'**
  String get editorListLabel;

  /// Empty-state copy of the external-editors list (06 §8).
  ///
  /// In en, this message translates to:
  /// **'No external editors configured.'**
  String get editorEmptyState;

  /// Adds an external editor via the platform application picker (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Add Editor…'**
  String get editorAddLabel;

  /// Row action editing an external editor's display name and accepted extensions (06 §8's Edit Extensions… row action).
  ///
  /// In en, this message translates to:
  /// **'Edit…'**
  String get editorEditLabel;

  /// Row action removing an external editor — also the confirm button of its dialog (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get editorRemoveLabel;

  /// Title of the remove-editor confirmation (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String editorRemoveTitle(String name);

  /// Remove-editor confirmation body when the editor is not the default (06 §8).
  ///
  /// In en, this message translates to:
  /// **'The application is only removed from Poltergeist settings.'**
  String get editorRemoveBody;

  /// Remove-editor confirmation body when the editor is the current default (06 §8's reset rule).
  ///
  /// In en, this message translates to:
  /// **'This is the current default. Removing it resets the default to System default.'**
  String get editorRemoveDefaultBody;

  /// Title of the editor row's edit dialog (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Edit external editor'**
  String get editorEditTitle;

  /// Title of the post-pick edit dialog in the Add Editor… flow (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Add external editor'**
  String get editorAddTitle;

  /// Label of the editor dialog's display-name field (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get editorNameFieldLabel;

  /// Label of the editor dialog's extensions field (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Accepted file extensions (optional)'**
  String get editorExtensionsFieldLabel;

  /// Hint text of the extensions field — example compound extension included (06 §8).
  ///
  /// In en, this message translates to:
  /// **'dart, json, yaml, tar.gz'**
  String get editorExtensionsFieldHint;

  /// Helper text of the extensions field: an empty list accepts every file (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Leave blank to show this editor for every file.'**
  String get editorExtensionsFieldHelper;

  /// Cancels the editor add/edit/remove dialogs without persisting (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get editorDialogCancel;

  /// Commits the editor add/edit dialog's fields (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get editorDialogSave;

  /// Command label on macOS, where Space opens the native Quick Look surface (file.preview, Space, 02 §8.3/§9, 06 §5).
  ///
  /// In en, this message translates to:
  /// **'Quick Look'**
  String get filePreviewLabel;

  /// file.preview's command label off macOS — the docked in-app panel owns Space there, so the macOS-only 'Quick Look' name would be wrong (02 §8.3/§9, 06 §5).
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get filePreviewLabelNeutral;

  /// Command label for view.togglePreview, which shows or hides the inspector's Info tab, where the preview renders (10 §8's View menu: Info, Transfers, Alerts; D32 merged 06 §5.2's preview rail into Info).
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get viewTogglePreviewLabel;

  /// Accessibility label of the docked preview rail (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get previewPanelLabel;

  /// Tooltip of the preview panel's close button (06 §5.2's ✕ affordance).
  ///
  /// In en, this message translates to:
  /// **'Close preview'**
  String get previewPanelClose;

  /// The docked preview panel's empty state — no focused file (06 §5.2's idle phase).
  ///
  /// In en, this message translates to:
  /// **'Nothing to preview'**
  String get previewPanelEmpty;

  /// The remote prompt card: selection alone never downloads — Space or the Download button starts it (06 §5.3's explicit-action rule).
  ///
  /// In en, this message translates to:
  /// **'Press Space to download a preview.'**
  String get previewPressSpace;

  /// Button that starts (or confirms) a remote preview download (06 §5.3, §8).
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get previewDownloadLabel;

  /// Cancels a preview download confirmation, gate, or in-flight production (06 §5.2/§5.3).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get previewCancelLabel;

  /// Closes the Quick Look overlay's refusal card (06 §5.1).
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get previewDismissLabel;

  /// The §8 large-download confirmation for a known over-threshold remote preview (06 §5.2/§5.3).
  ///
  /// In en, this message translates to:
  /// **'Download {size} to preview “{name}”?'**
  String previewDownloadConfirm(String size, String name);

  /// Accessibility label of the preview download progress bar (06 §5.2's in-flight card).
  ///
  /// In en, this message translates to:
  /// **'Downloading preview'**
  String get previewDownloadingLabel;

  /// Preview download progress line over a known total (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'{transferred} of {total}'**
  String previewDownloadProgress(String transferred, String total);

  /// The Quick Look overlay's in-flight line: the item's name plus its progress (06 §5.1).
  ///
  /// In en, this message translates to:
  /// **'Downloading {name} — {progress}'**
  String previewDownloadingNamed(String name, String progress);

  /// The unknown-size gate card: a remote preview stream parked at the large-download threshold asks before continuing (06 §5.3).
  ///
  /// In en, this message translates to:
  /// **'{transferred} downloaded so far. Keep going?'**
  String previewGatePrompt(String transferred);

  /// Releases the parked unknown-size stream — the gate card's confirm answer (06 §5.3).
  ///
  /// In en, this message translates to:
  /// **'Keep downloading'**
  String get previewKeepDownloadingLabel;

  /// Note on the prompt card after a failed production — Space retries (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'The preview download failed.'**
  String get previewDownloadFailed;

  /// Note after a cancelled production — honest cancel copy, not a failure (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'The preview download was cancelled.'**
  String get previewDownloadCancelled;

  /// Promptless-card refusal: the known remote size exceeds the preview-cache cap (06 §5.3).
  ///
  /// In en, this message translates to:
  /// **'This file is larger than the preview cache allows.'**
  String get previewRefusalOverCacheCap;

  /// Promptless-card refusal: the file exceeds its kind's decode cap (64 MiB image/PDF, 06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'This file is too large to preview.'**
  String get previewRefusalOverKindCap;

  /// The text row's refusal for binary or non-UTF-8 content (06 §5.2/§1).
  ///
  /// In en, this message translates to:
  /// **'This file isn\'t UTF-8 text.'**
  String get previewRefusalNotText;

  /// Refusal when the focused file vanished between selection and render (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'This file no longer exists.'**
  String get previewRefusalMissing;

  /// The metadata card's Open verb — launches the focused entry through its real open path, never the cache copy (06 §5.3's open boundary).
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get previewOpenLabel;

  /// The metadata card's Open With verb — the editor chooser (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Open With…'**
  String get previewOpenWithLabel;

  /// The truncated-text bar's affordance — opens the file in the built-in editor (06 §5.2's text row).
  ///
  /// In en, this message translates to:
  /// **'Open in editor'**
  String get previewOpenInEditorLabel;

  /// The bar heading a capped preview — the text row's 1 MiB window or the PDF row's 20-page cap (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Preview truncated'**
  String get previewTruncatedLabel;

  /// Accessibility label of the rendered image preview.
  ///
  /// In en, this message translates to:
  /// **'Preview of {name}'**
  String previewImageLabel(String name);

  /// The caption under an image preview — the decoded frame's real dimensions (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'{width} × {height} pixels'**
  String previewImageDimensions(int width, int height);

  /// The panel header's multi-selection line (06 §5.2): count, the summed size of the size-known entries, and an explicit unknown-size count — never a silently incomplete total.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item} other{{count} items}} · {size}{unknown, plural, =0{} other{ · {unknown} size unknown}}'**
  String previewSelectionSummary(int count, String size, int unknown);

  /// The PDF preview's header (06 §5.2): shown is min(20, total) — a 5-page PDF reads 'Page 1–5 of 5', never '1–20 of 5'.
  ///
  /// In en, this message translates to:
  /// **'Page 1–{shown} of {total}'**
  String previewPdfPageRange(int shown, int total);

  /// Accessibility label of one rasterized PDF page in the preview rail.
  ///
  /// In en, this message translates to:
  /// **'Page {page} of {total}'**
  String previewPdfPageLabel(int page, int total);

  /// The PDF row's error body — a corrupt or password-locked document (06 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t render this PDF.'**
  String get previewPdfFailed;

  /// Settings → Editing section header for the preview cache and the shared large-download threshold (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Preview & downloads'**
  String get previewSettingsSectionTitle;

  /// Label of the preview-cache size-limit field (06 §8, default 512 MiB).
  ///
  /// In en, this message translates to:
  /// **'Preview cache limit'**
  String get previewCacheLimitLabel;

  /// Button that empties the preview cache (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Clear Preview Cache'**
  String get previewClearCacheLabel;

  /// Toast after Clear Preview Cache — reports bytes ACTUALLY reclaimed, never the pre-clear total (06 §8).
  ///
  /// In en, this message translates to:
  /// **'Cleared {mib} MiB of cached previews.'**
  String previewCacheCleared(int mib);

  /// Label of the shared large-download confirmation threshold (06 §8, default 100 MiB) — gates remote previews, Quick Look productions, compare sides, and external-editor checkouts.
  ///
  /// In en, this message translates to:
  /// **'Confirm downloads larger than'**
  String get previewThresholdLabel;

  /// Unit suffix of the Preview & downloads numeric fields (mebibytes).
  ///
  /// In en, this message translates to:
  /// **'MiB'**
  String get previewMiBSuffix;

  /// Plan-view tab title (05 §7): the pair's name.
  ///
  /// In en, this message translates to:
  /// **'Sync: {name}'**
  String syncTabTitle(String name);

  /// Live scan progress line (05 §3's verbatim shape).
  ///
  /// In en, this message translates to:
  /// **'Scanning… left {leftCount} entries · right {rightCount} entries'**
  String syncScanning(int leftCount, int rightCount);

  /// Scan-cancel and dialog-cancel verb in the sync plan view.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get syncCancel;

  /// Run-control verb (05 §10): holds the running sync between items.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get syncPause;

  /// Run-control verb (05 §10): releases a paused sync run.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get syncResume;

  /// Label of the plan view's sync-mode picker (05 §5).
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get syncModeLabel;

  /// One-way copy mode (05 §5): copy new and newer files, never delete.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get syncModeUpdate;

  /// One-way mirror mode (05 §5): make the destination match the source, deletions included.
  ///
  /// In en, this message translates to:
  /// **'Mirror'**
  String get syncModeMirror;

  /// Bidirectional mode (05 §5): newest files travel both ways, nothing is deleted.
  ///
  /// In en, this message translates to:
  /// **'Additive'**
  String get syncModeAdditive;

  /// Plan header clause (05 §7): new-file copies landing on the destination.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Copy {count} new file ({bytes})} other{Copy {count} new files ({bytes})}}'**
  String syncHeaderCopyNew(int count, String bytes);

  /// Plan header clause (05 §7): directory creations landing on the destination.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{create {count} folder} other{create {count} folders}}'**
  String syncHeaderCreateFolders(int count);

  /// Plan header clause (05 §7): overwrite updates landing on the destination — the count renders bare per the spec's sentence pattern.
  ///
  /// In en, this message translates to:
  /// **'update {count}'**
  String syncHeaderUpdateFiles(int count);

  /// Plan header tail (05 §7): the destination phrase closing the copy sentence — {destination} is '{favoriteLabel}:{path}', a shortened local path, or 'both sides' for Additive.
  ///
  /// In en, this message translates to:
  /// **'on {destination}.'**
  String syncHeaderOnDestination(String destination);

  /// Additive's {destination} value (05 §7): the two-way aggregate renders 'on both sides.'
  ///
  /// In en, this message translates to:
  /// **'both sides'**
  String get syncHeaderBothSides;

  /// Plan header sentence for a dirs-only plan (05 §7) — a plan with only directory creations must never show an empty headline.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Create {count} folder on {destination}.} other{Create {count} folders on {destination}.}}'**
  String syncHeaderCreateOnly(int count, String destination);

  /// Green plan-header tail (05 §7): rendered only when the plan holds no delete-phase items and no kind-change pre-deletes.
  ///
  /// In en, this message translates to:
  /// **'Nothing will be deleted.'**
  String get syncHeaderNothingDeleted;

  /// Red plan-header clause (05 §7): delete-phase files headed for the side's trash root.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete {count} file on {side} (moved to trash at {trashLocation}).} other{Delete {count} files on {side} (moved to trash at {trashLocation}).}}'**
  String syncHeaderDeleteTrash(int count, String side, String trashLocation);

  /// Red plan-header clause (05 §7): delete-phase files under the permanent-deletion opt-in.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete {count} file on {side} permanently.} other{Delete {count} files on {side} permanently.}}'**
  String syncHeaderDeletePermanent(int count, String side);

  /// Red plan-header clause (05 §7): kind-change pre-deletes whose removed versions go to trash.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Replace {count} file of a different kind on {side} (previous version moved to trash at {trashLocation}).} other{Replace {count} files of a different kind on {side} (previous versions moved to trash at {trashLocation}).}}'**
  String syncHeaderReplaceTrash(int count, String side, String trashLocation);

  /// Red plan-header clause (05 §7): kind-change pre-deletes under the permanent-deletion opt-in.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Replace {count} file of a different kind on {side} (previous version deleted permanently).} other{Replace {count} files of a different kind on {side} (previous versions deleted permanently).}}'**
  String syncHeaderReplacePermanent(int count, String side);

  /// Plan-header tail (05 §8 rail 3): a plan whose only removals are zero-count directory cleanups never shows the green 'nothing deleted' sentence.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Remove {count} empty folder on {side}.} other{Remove {count} empty folders on {side}.}}'**
  String syncHeaderRemoveEmptyFolders(int count, String side);

  /// Amber plan-header clause (05 §7): unresolved conflict rows.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} conflict needs a decision.} other{{count} conflicts need a decision.}}'**
  String syncHeaderConflicts(int count);

  /// Plan-header sentence for an equal pair (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Both sides match. Nothing to do.'**
  String get syncHeaderNothingToDo;

  /// The §4 sizeOnly fallback's own line under the header sentence (05 §7) — mtime trust is degraded, so the plan compares sizes only.
  ///
  /// In en, this message translates to:
  /// **'Timestamps are unreliable on at least one side — comparing by size only.'**
  String get syncHeaderSizeOnlyNotice;

  /// Warnings-strip header in the plan view (05 §7).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} scan warning} other{{count} scan warnings}}'**
  String syncWarningsTitle(int count);

  /// Filter chip: every plan item (05 §7).
  ///
  /// In en, this message translates to:
  /// **'All ({count})'**
  String syncFilterAll(int count);

  /// Filter chip: create actions (05 §7).
  ///
  /// In en, this message translates to:
  /// **'New ({count})'**
  String syncFilterNew(int count);

  /// Filter chip: overwrite updates (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Updates ({count})'**
  String syncFilterUpdates(int count);

  /// Filter chip: deletions including per-file kind-change pre-delete tolls (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Deletes ({count})'**
  String syncFilterDeletes(int count);

  /// Filter chip: rows needing a decision (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Conflicts ({count})'**
  String syncFilterConflicts(int count);

  /// Filter chip: equal, excluded, and user-skipped rows (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Skipped ({count})'**
  String syncFilterSkipped(int count);

  /// Placeholder text inside the plan view's item text filter (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Filter items'**
  String get syncFilterFieldHint;

  /// Toggle hiding equal/excluded rows (05 §7; default on).
  ///
  /// In en, this message translates to:
  /// **'Only show actions'**
  String get syncFilterOnlyActions;

  /// Plan row reason (05 §7): the entry exists on one side only.
  ///
  /// In en, this message translates to:
  /// **'only exists here'**
  String get syncReasonOnlyHere;

  /// Plan row reason (05 §7): one side's copy is newer — both ages render like '2 min ago'.
  ///
  /// In en, this message translates to:
  /// **'newer here ({sourceAge} vs {destinationAge})'**
  String syncReasonNewerHere(String sourceAge, String destinationAge);

  /// Plan row reason (05 §7): same name, different sizes.
  ///
  /// In en, this message translates to:
  /// **'sizes differ ({leftSize} vs {rightSize})'**
  String syncReasonSizesDiffer(String leftSize, String rightSize);

  /// Plan row reason (05 §7): hashes disagree.
  ///
  /// In en, this message translates to:
  /// **'contents differ'**
  String get syncReasonContentsDiffer;

  /// Plan row reason (05 §7): Additive's divergent-pair conflict.
  ///
  /// In en, this message translates to:
  /// **'changed on both sides'**
  String get syncReasonBothChanged;

  /// Plan row reason (05 §7): file vs folder vs link at one path — kind labels like 'file here, folder there'.
  ///
  /// In en, this message translates to:
  /// **'type differs ({leftKind} here, {rightKind} there)'**
  String syncReasonTypeDiffers(String leftKind, String rightKind);

  /// Plan row reason (05 §7): an ignore rule or the one-sided-symlink policy excluded the entry.
  ///
  /// In en, this message translates to:
  /// **'excluded by rule'**
  String get syncReasonExcluded;

  /// Plan row reason (05 §7): case variants that would merge on the destination.
  ///
  /// In en, this message translates to:
  /// **'names differ only by case'**
  String get syncReasonCaseCollision;

  /// Plan row reason (05 §7): NFC/NFD twins on one side.
  ///
  /// In en, this message translates to:
  /// **'names differ only by Unicode form'**
  String get syncReasonNormalizationCollision;

  /// Plan row reason (05 §7): the destination's local-safety funnel rejects a component.
  ///
  /// In en, this message translates to:
  /// **'name invalid on Windows'**
  String get syncReasonInvalidName;

  /// Plan row reason (05 §7): the other side failed to list this subtree (§6 rule 8).
  ///
  /// In en, this message translates to:
  /// **'couldn\'t scan — subtree excluded'**
  String get syncReasonScanError;

  /// Plan row reason (05 §7): the most common row when 'only show actions' is off.
  ///
  /// In en, this message translates to:
  /// **'identical'**
  String get syncReasonEqual;

  /// Plan row reason (05 §7): v1's SymlinkPolicy.skip rows.
  ///
  /// In en, this message translates to:
  /// **'symbolic link — skipped'**
  String get syncReasonSymlink;

  /// Entry-kind label inside reason strings (05 §7).
  ///
  /// In en, this message translates to:
  /// **'file'**
  String get syncKindFile;

  /// Entry-kind label inside reason strings (05 §7).
  ///
  /// In en, this message translates to:
  /// **'folder'**
  String get syncKindFolder;

  /// Entry-kind label inside reason strings (05 §7).
  ///
  /// In en, this message translates to:
  /// **'symbolic link'**
  String get syncKindSymlink;

  /// Entry-kind label inside reason strings (05 §7).
  ///
  /// In en, this message translates to:
  /// **'other'**
  String get syncKindOther;

  /// Side label inside sync copy (05 §7) — the pane-A side.
  ///
  /// In en, this message translates to:
  /// **'left'**
  String get syncSideLeft;

  /// Side label inside sync copy (05 §7) — the pane-B side.
  ///
  /// In en, this message translates to:
  /// **'right'**
  String get syncSideRight;

  /// Per-item override menu verb (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get syncOverrideSkip;

  /// Per-item override menu verb (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Copy left → right'**
  String get syncOverrideCopyLeftToRight;

  /// Per-item override menu verb (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Copy right → left'**
  String get syncOverrideCopyRightToLeft;

  /// Per-item override menu verb (05 §7) — Mirror mode only.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get syncOverrideDelete;

  /// Per-item override menu verb (05 §7): returns the row to its diff-suggested action.
  ///
  /// In en, this message translates to:
  /// **'Reset to suggested'**
  String get syncOverrideReset;

  /// Bulk-override result line (05 §7): in no-delete modes a bulk copy skips typeDiffers rows, reported never silent.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} type-differs row skipped — replacing a different kind stays a per-item choice} other{{count} type-differs rows skipped — replacing a different kind stays a per-item choice}}'**
  String syncOverrideSkippedTypeDiffers(int count);

  /// Bulk conflict bar's leading label (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Resolve conflicts:'**
  String get syncResolveConflictsLabel;

  /// Bulk conflict resolution verb (05 §7) — hidden whenever the pair's mtimes are untrusted.
  ///
  /// In en, this message translates to:
  /// **'Newer wins'**
  String get syncResolveNewerWins;

  /// Bulk conflict resolution verb (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Keep left'**
  String get syncResolveKeepLeft;

  /// Bulk conflict resolution verb (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Keep right'**
  String get syncResolveKeepRight;

  /// Bulk conflict resolution verb (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Skip all'**
  String get syncResolveSkipAll;

  /// Plan-view action-bar verb (05 §7/§9): persists the pair as a savedSync bookmark.
  ///
  /// In en, this message translates to:
  /// **'Save as Favorite…'**
  String get syncSaveAsFavorite;

  /// Run button with a copies-only consequence (05 §7's 'Copy 15 Files').
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Copy 1 File} other{Copy {count} Files}}'**
  String syncRunCopyFiles(int count);

  /// Run-button copy clause inside a multi-verb label (05 §7's 'Copy 12, Delete 5').
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Copy 1} other{Copy {count}}}'**
  String syncRunCopyPart(int count);

  /// Run-button mkdir clause (05 §7) — the dirs-only consequence.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Create {count} Folder} other{Create {count} Folders}}'**
  String syncRunCreateFolders(int count);

  /// Run-button delete clause inside a multi-verb label (05 §7's 'Copy 12, Delete 5').
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1} other{Delete {count}}}'**
  String syncRunDeletePart(int count);

  /// Disabled Run button for an all-equal plan (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Nothing to Do'**
  String get syncRunNothingToDo;

  /// First-run suggestion chip (05 §7): one known heavy directory contributes over half the plan.
  ///
  /// In en, this message translates to:
  /// **'{name} is {count} of these files — exclude?'**
  String syncHeavySuggestion(String name, int count);

  /// Typed-confirmation dialog title (05 §8 rail 3).
  ///
  /// In en, this message translates to:
  /// **'Confirm deletions'**
  String get syncDeleteConfirmTitle;

  /// Typed-confirmation body (05 §8 rail 3): the fraction clause tripped — {pct} renders the word 'half' at the 0.5 default and a numeric percentage otherwise.
  ///
  /// In en, this message translates to:
  /// **'This will delete {count} of {total} files on {side} — more than {pct} of that side. Type DELETE to continue.'**
  String syncDeleteConfirmFraction(
    int count,
    int total,
    String side,
    String pct,
  );

  /// Typed-confirmation body (05 §8 rail 3): the ≥90 % floor clause tripped — inclusive wording, never 'more than 90 %'.
  ///
  /// In en, this message translates to:
  /// **'This will delete {count} of {total} files on {side} — 90 % or more of that side. Type DELETE to continue.'**
  String syncDeleteConfirmFloor(int count, int total, String side);

  /// Placeholder inside the typed-confirmation field (05 §8 rail 3).
  ///
  /// In en, this message translates to:
  /// **'DELETE'**
  String get syncDeleteConfirmFieldHint;

  /// The {pct} slot of syncDeleteConfirmFraction at the default 0.5 threshold — the word, not a number (05 §8 rail 3).
  ///
  /// In en, this message translates to:
  /// **'half'**
  String get syncDeleteConfirmHalf;

  /// Typed-confirmation dialog's confirm verb (05 §8 rail 3) — disabled until the field reads exactly DELETE.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get syncDeleteConfirmButton;

  /// maxDelete refusal dialog title (05 §8 rail 4).
  ///
  /// In en, this message translates to:
  /// **'Too many deletions'**
  String get syncMaxDeleteTitle;

  /// maxDelete refusal body (05 §8 rail 4): explains and points at the pair's rules — never an override button.
  ///
  /// In en, this message translates to:
  /// **'This plan would delete {count} files on {side} — over the {cap}-file cap. Run stays disabled rather than silently diverging the destination. Raise the cap in the pair\'s rules to run it.'**
  String syncMaxDeleteBody(int count, String side, int cap);

  /// Ad-hoc pair's refusal escape (05 §8 rail 4): saves the pair and opens the editor on maxDelete, so Run-disabled is never a dead end.
  ///
  /// In en, this message translates to:
  /// **'Save as Favorite & Adjust Rules…'**
  String get syncMaxDeleteSaveAdjust;

  /// Summary-bar verb (05 §7): re-executes only the failed plan items.
  ///
  /// In en, this message translates to:
  /// **'Retry Failed'**
  String get syncRetryFailed;

  /// Summary-bar verb (05 §7/§8 rail 9): puts the run's trashed entries back.
  ///
  /// In en, this message translates to:
  /// **'Restore Trashed Files…'**
  String get syncRestoreTrashed;

  /// Summary-bar verb (05 §7): copies the run's per-item outcome table to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy Report'**
  String get syncCopyReport;

  /// Plan-view action-bar verb and Commands-menu row (05 §2.1/§7): copies the plan's ruleset rendered as the equivalent rsync invocation.
  ///
  /// In en, this message translates to:
  /// **'Copy as rsync Command'**
  String get syncCopyRsyncCommand;

  /// Toast after the rsync export lands on the clipboard (05 §2.1).
  ///
  /// In en, this message translates to:
  /// **'Copied rsync command'**
  String get syncCopiedRsyncCommand;

  /// Toast variant for a deletions:permanent + backups:none plan (05 §2.1): the one lethal configuration warns at copy time.
  ///
  /// In en, this message translates to:
  /// **'Copied rsync command — deletions are permanent when pasted'**
  String get syncCopiedRsyncCommandPermanent;

  /// Toast when the rsync export's clipboard write throws (a platform-channel failure surfaces as feedback, never an unhandled async error).
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t copy the rsync command — clipboard unavailable'**
  String get syncRsyncCopyFailed;

  /// Heavy-directory suggestion's accept verb (05 §9): adds the name to the pair's exclude rules.
  ///
  /// In en, this message translates to:
  /// **'Exclude'**
  String get syncHeavySuggestionAccept;

  /// Restore dialog title (05 §8 rail 9).
  ///
  /// In en, this message translates to:
  /// **'Restore Trashed Files'**
  String get syncRestoreDialogTitle;

  /// Restore dialog's count line — only journaled trash entries restore (05 §8 rail 9).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} file will be restored from trash.} other{{count} files will be restored from trash.}}'**
  String syncRestoreSummary(int count);

  /// Restore dialog's confirm verb.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get syncRestoreButton;

  /// Post-restore summary line: how many entries came back and how many were skipped.
  ///
  /// In en, this message translates to:
  /// **'{restored, plural, =1{Restored {restored} file} other{Restored {restored} files}}{skipped, plural, =0{} =1{ — {skipped} skipped} other{ — {skipped} skipped}}'**
  String syncRestoreResult(int restored, int skipped);

  /// Pair-editor direction choice (05 §5): one-way, left feeds right.
  ///
  /// In en, this message translates to:
  /// **'Left to right'**
  String get syncDirectionLeftToRight;

  /// Pair-editor direction choice (05 §5): one-way, right feeds left.
  ///
  /// In en, this message translates to:
  /// **'Right to left'**
  String get syncDirectionRightToLeft;

  /// Pair-editor direction choice (05 §5): bidirectional — Additive's direction.
  ///
  /// In en, this message translates to:
  /// **'Both ways'**
  String get syncDirectionBothWays;

  /// Pair editor's collapsible advanced-rules section title (05 §9).
  ///
  /// In en, this message translates to:
  /// **'Options'**
  String get syncEditorOptionsSection;

  /// Pair editor dialog title (05 §9) — the saved-sync definition surface.
  ///
  /// In en, this message translates to:
  /// **'Sync pair'**
  String get syncEditorTitle;

  /// Pair name field label.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get syncEditorNameLabel;

  /// Deletion-policy field label (05 §6): none / moved to trash / permanent.
  ///
  /// In en, this message translates to:
  /// **'Deletions'**
  String get syncEditorDeletionsLabel;

  /// Deletion-policy choice (05 §6): no deletions — Update and Additive's fixed value.
  ///
  /// In en, this message translates to:
  /// **'Never delete'**
  String get syncEditorDeletionsNone;

  /// Deletion-policy choice (05 §6, D15): deletions rename into .poltergeist-trash.
  ///
  /// In en, this message translates to:
  /// **'Move to trash'**
  String get syncEditorDeletionsTrash;

  /// Deletion-policy choice (05 §6): the explicit per-pair permanent opt-in.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get syncEditorDeletionsPermanent;

  /// Backup-policy field label (05 §8 rail 5): whether overwritten files keep a trashed previous version.
  ///
  /// In en, this message translates to:
  /// **'Overwrite backups'**
  String get syncEditorBackupsLabel;

  /// Backup-policy choice (05 §6): overwritten versions move to trash (default).
  ///
  /// In en, this message translates to:
  /// **'Keep in trash'**
  String get syncEditorBackupsTrash;

  /// Backup-policy choice (05 §6): overwrites keep no previous version.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get syncEditorBackupsNone;

  /// Comparison-mode field label (05 §4).
  ///
  /// In en, this message translates to:
  /// **'Compare by'**
  String get syncEditorComparisonLabel;

  /// Comparison-mode choice (05 §4, default).
  ///
  /// In en, this message translates to:
  /// **'Size and modification time'**
  String get syncEditorComparisonSizeMtime;

  /// Comparison-mode choice (05 §4): never consults mtimes.
  ///
  /// In en, this message translates to:
  /// **'Size only'**
  String get syncEditorComparisonSizeOnly;

  /// Comparison-mode choice (05 §4): size-equal pairs hash by streamed SHA-256.
  ///
  /// In en, this message translates to:
  /// **'Content hash'**
  String get syncEditorComparisonContentHash;

  /// Conflict-default field label (05 §5): what the diff does with rows needing a decision.
  ///
  /// In en, this message translates to:
  /// **'Conflicts'**
  String get syncEditorConflictLabel;

  /// Conflict-default choice (05 §6, default).
  ///
  /// In en, this message translates to:
  /// **'Ask each time'**
  String get syncEditorConflictAsk;

  /// Conflict-default choice (05 §6) — degrades to ask whenever mtimes are untrusted (§4).
  ///
  /// In en, this message translates to:
  /// **'Newer wins'**
  String get syncEditorConflictNewerWins;

  /// Conflict-default choice (05 §6).
  ///
  /// In en, this message translates to:
  /// **'Keep left'**
  String get syncEditorConflictKeepLeft;

  /// Conflict-default choice (05 §6).
  ///
  /// In en, this message translates to:
  /// **'Keep right'**
  String get syncEditorConflictKeepRight;

  /// Conflict-default choice (05 §6).
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get syncEditorConflictSkip;

  /// Hard deletion cap field label (05 §6/§8 rail 4, default 500).
  ///
  /// In en, this message translates to:
  /// **'Deletion cap (maxDelete)'**
  String get syncEditorMaxDeleteLabel;

  /// deleteFractionWarn field label (05 §6/§8 rail 3): the fraction of one side whose deletion asks for typed DELETE.
  ///
  /// In en, this message translates to:
  /// **'Typed-confirmation threshold'**
  String get syncEditorFractionWarnLabel;

  /// Gitignore-style exclude list field label (05 §3) — one pattern per line.
  ///
  /// In en, this message translates to:
  /// **'Exclude rules'**
  String get syncEditorExcludeLabel;

  /// includeHidden toggle label (05 §3, default on).
  ///
  /// In en, this message translates to:
  /// **'Include hidden files'**
  String get syncEditorIncludeHidden;

  /// trashPathLeft field label (05 §6): out-of-root trash for the left side, empty for in-root .poltergeist-trash.
  ///
  /// In en, this message translates to:
  /// **'Left trash path'**
  String get syncEditorTrashLeftLabel;

  /// trashPathRight field label (05 §6): out-of-root trash for the right side.
  ///
  /// In en, this message translates to:
  /// **'Right trash path'**
  String get syncEditorTrashRightLabel;

  /// Placeholder inside the pair editor's path fields (05 §9).
  ///
  /// In en, this message translates to:
  /// **'/path'**
  String get syncEditorPathHint;

  /// mtimeToleranceSecs field label (05 §4, default 2).
  ///
  /// In en, this message translates to:
  /// **'Modification-time tolerance (seconds)'**
  String get syncEditorMtimeToleranceLabel;

  /// preserveMtime toggle (05 §4, default on): off forces size-only comparison semantics.
  ///
  /// In en, this message translates to:
  /// **'Preserve modification times'**
  String get syncEditorPreserveMtime;

  /// transferConcurrency field label (05 §6, 1–8, default 4).
  ///
  /// In en, this message translates to:
  /// **'Transfer concurrency'**
  String get syncEditorConcurrencyLabel;

  /// Per-side case-sensitivity override (05 §3/§9) — the remote side's only sensitivity input.
  ///
  /// In en, this message translates to:
  /// **'Left case sensitivity'**
  String get syncEditorCaseLeftLabel;

  /// Per-side case-sensitivity override (05 §3/§9).
  ///
  /// In en, this message translates to:
  /// **'Right case sensitivity'**
  String get syncEditorCaseRightLabel;

  /// Case-sensitivity override choice: probe the local side / assume sensitive on remote.
  ///
  /// In en, this message translates to:
  /// **'Detect automatically'**
  String get syncEditorCaseAuto;

  /// Case-sensitivity override choice.
  ///
  /// In en, this message translates to:
  /// **'Case-sensitive'**
  String get syncEditorCaseSensitive;

  /// Case-sensitivity override choice.
  ///
  /// In en, this message translates to:
  /// **'Case-insensitive'**
  String get syncEditorCaseInsensitive;

  /// Pair editor's save verb.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get syncEditorSave;

  /// Pair editor's save verb when the editor opened from a plan view (05 §8 rail 4's 'saves the pair, opens the editor, rescans on close').
  ///
  /// In en, this message translates to:
  /// **'Save & Rescan'**
  String get syncEditorSaveAndRescan;

  /// Command label: define a saved sync pair (05 §9, sync.newSavedSync).
  ///
  /// In en, this message translates to:
  /// **'New Saved Sync…'**
  String get syncNewSavedSync;

  /// A sync pair's display name — each leg's endpoint label joined by the §7 direction glyph (tab title and favorite name).
  ///
  /// In en, this message translates to:
  /// **'{left} ⇄ {right}'**
  String syncPairLabel(String left, String right);

  /// Command label: build an ad-hoc pair from the two panes and open the Sync sheet (05 §7, 10 §7/§8, sync.synchronizePanes, ⌥⌘Y). The ellipsis says a sheet opens before anything runs.
  ///
  /// In en, this message translates to:
  /// **'Synchronize…'**
  String get syncSynchronizePanes;

  /// Plan-view verb: re-run the scan and diff (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Rescan'**
  String get syncRescan;

  /// Plan-view error sentence when scanning or diffing fails before a plan exists.
  ///
  /// In en, this message translates to:
  /// **'The scan could not complete — {error}'**
  String syncScanFailed(String error);

  /// Honest-absence error when a sync pair's endpoint is remote (STATUS item 23 — same posture the transfer queue takes).
  ///
  /// In en, this message translates to:
  /// **'Remote sync pairs aren\'t available yet — remote filesystems arrive with the engine-protocol transfer verbs.'**
  String get syncRemoteUnavailable;

  /// Plan-view run-error sentence: the executor aborted before finishing.
  ///
  /// In en, this message translates to:
  /// **'The run failed — {error}'**
  String syncRunFailed(String error);

  /// Post-run summary counts in the plan view's action bar (05 §7).
  ///
  /// In en, this message translates to:
  /// **'{done, plural, =1{{done} done} other{{done} done}} · {failed, plural, =1{{failed} failed} other{{failed} failed}} · {skipped, plural, =1{{skipped} skipped} other{{skipped} skipped}}'**
  String syncSummaryCounts(int done, int failed, int skipped);

  /// Endpoint label for a local side inside header copy — '{favoriteLabel}:{path}' renders as 'local:{path}' when the side has no bookmark label.
  ///
  /// In en, this message translates to:
  /// **'local'**
  String get syncPairLocalLabel;

  /// Toast after the plan view's Save as Favorite persists the pair as a savedSync bookmark (05 §7).
  ///
  /// In en, this message translates to:
  /// **'Saved sync \"{name}\" added to favorites'**
  String syncSavedFavoriteToast(String name);

  /// Command label: opens the Quick Open palette (02 §8.4, app.quickOpen, ⇧⌘P / Ctrl+Shift+P).
  ///
  /// In en, this message translates to:
  /// **'Quick Open…'**
  String get quickOpenCommandLabel;

  /// Semantics label of the Quick Open palette dialog (02 §8.4).
  ///
  /// In en, this message translates to:
  /// **'Quick Open'**
  String get quickOpenTitle;

  /// Placeholder inside the Quick Open palette's filter field.
  ///
  /// In en, this message translates to:
  /// **'Type a command or location'**
  String get quickOpenFieldHint;

  /// Footer hint under the Quick Open palette's list on macOS (⌥/⌘ glyphs).
  ///
  /// In en, this message translates to:
  /// **'Enter runs · ⌥Enter opens in the other pane · ⌘Enter opens in a new tab · Esc closes'**
  String get quickOpenHintMacos;

  /// Footer hint under the Quick Open palette's list on Windows/Linux.
  ///
  /// In en, this message translates to:
  /// **'Enter runs · Alt+Enter opens in the other pane · Ctrl+Enter opens in a new tab · Esc closes'**
  String get quickOpenHint;

  /// Section header over the palette's registered-command rows (02 §8.4).
  ///
  /// In en, this message translates to:
  /// **'Commands'**
  String get quickOpenSectionCommands;

  /// Section header over the palette's bookmark rows (02 §8.4).
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get quickOpenSectionFavorites;

  /// Section header over the palette's recently visited locations (02 §8.4).
  ///
  /// In en, this message translates to:
  /// **'Recents'**
  String get quickOpenSectionRecents;

  /// The palette's filtered-empty state (02 §8.4) — the field's literal query.
  ///
  /// In en, this message translates to:
  /// **'No matches for “{query}”'**
  String quickOpenNoMatches(String query);

  /// Accessibility label of one palette row: the row's title and its section name.
  ///
  /// In en, this message translates to:
  /// **'{label}, {section}'**
  String quickOpenRowSemantics(String label, String section);

  /// A command row's subtitle: the menu path the command lives under (02 §8.4's 'Commands ▸ name' shape).
  ///
  /// In en, this message translates to:
  /// **'{menu} ▸ {label}'**
  String quickOpenMenuPath(String menu, String label);

  /// Disabled-reason under a Recents row whose remote bookmark can no longer be resolved.
  ///
  /// In en, this message translates to:
  /// **'This server is no longer available'**
  String get quickOpenRecentUnavailable;

  /// Palette reason under a disabled Go Back row.
  ///
  /// In en, this message translates to:
  /// **'No earlier location'**
  String get commandDisabledNoBack;

  /// Palette reason under a disabled Go Forward row.
  ///
  /// In en, this message translates to:
  /// **'No later location'**
  String get commandDisabledNoForward;

  /// Palette reason under commands disabled while the pane has no live listing (verb/path commands).
  ///
  /// In en, this message translates to:
  /// **'Requires a browsed folder'**
  String get commandDisabledNoListing;

  /// Palette reason under commands disabled until a row is selected.
  ///
  /// In en, this message translates to:
  /// **'Requires a selected item'**
  String get commandDisabledNoSelection;

  /// Palette reason under the preview commands while no preview session is bound.
  ///
  /// In en, this message translates to:
  /// **'Previews are unavailable'**
  String get commandDisabledNoPreview;

  /// Palette reason under Show/Hide Sidebar while no bookmark store is wired.
  ///
  /// In en, this message translates to:
  /// **'Requires the sidebar'**
  String get commandDisabledNoSidebar;

  /// Palette reason under Sync Browsing / Synchronize Panes while either pane lacks a committed directory.
  ///
  /// In en, this message translates to:
  /// **'Requires browsed folders on both panes'**
  String get commandDisabledSyncAnchors;

  /// Palette reason under commands disabled while the pane holds no tab.
  ///
  /// In en, this message translates to:
  /// **'Requires an open tab'**
  String get commandDisabledNoTab;

  /// Palette reason under Reopen Closed Tab while the ghost ring is empty.
  ///
  /// In en, this message translates to:
  /// **'No recently closed tab'**
  String get commandDisabledNoClosedTab;

  /// Palette reason under tab-strip commands disabled on a single-tab strip.
  ///
  /// In en, this message translates to:
  /// **'Requires at least two tabs'**
  String get commandDisabledMultipleTabs;

  /// Palette reason under queue commands while no transfer-queue seam is bound.
  ///
  /// In en, this message translates to:
  /// **'Requires the transfer queue'**
  String get commandDisabledNoQueue;

  /// Palette reason under Copy rsync Command while the active tab is not a sync plan.
  ///
  /// In en, this message translates to:
  /// **'Requires an open sync plan'**
  String get commandDisabledNoPlan;

  /// Palette reason under commands that need the bookmark store.
  ///
  /// In en, this message translates to:
  /// **'Requires saved favorites'**
  String get commandDisabledNoBookmarks;

  /// Palette reason under app-scope commands gated on an in-flight command session (the one-shot rule).
  ///
  /// In en, this message translates to:
  /// **'Unavailable while another command is running'**
  String get commandDisabledBusy;

  /// Palette reason under Open With rows while no editor registry is bound.
  ///
  /// In en, this message translates to:
  /// **'Requires a configured external editor'**
  String get commandDisabledNoEditors;

  /// Palette reason and submenu empty-state under Workspaces ▸ while the library is empty.
  ///
  /// In en, this message translates to:
  /// **'No saved workspaces'**
  String get commandDisabledNoWorkspaces;

  /// Button inside the sidebar's empty-favorites state: opens the ssh_config import preview (D22's adoption offer). Kept parallel to the command label sshImportCommandLabel.
  ///
  /// In en, this message translates to:
  /// **'Import from ssh config…'**
  String get sidebarImportSshConfig;

  /// Header of the shared-mode sidebar section listing the Séance account's pulled serverConfig records (04 §4.2's catalog surface).
  ///
  /// In en, this message translates to:
  /// **'Séance servers'**
  String get sidebarCatalogSection;

  /// Group header over catalog servers that carry no group — Séance's own ungrouped section title.
  ///
  /// In en, this message translates to:
  /// **'Ungrouped'**
  String get sidebarCatalogUngrouped;

  /// Body copy inside the expanded Séance-servers section when the pulled catalog is empty.
  ///
  /// In en, this message translates to:
  /// **'No servers on this account yet. Add one in Séance and sync to see it here.'**
  String get sidebarCatalogEmpty;

  /// Body copy inside the Séance-servers section when the filter drops every row.
  ///
  /// In en, this message translates to:
  /// **'No servers match the filter.'**
  String get sidebarCatalogNoMatches;

  /// Hint text of the filter field above the Séance-servers list — the same affordance Séance's server list offers.
  ///
  /// In en, this message translates to:
  /// **'Filter servers'**
  String get sidebarCatalogFilter;

  /// Helper text under the catalog filter while a query is active and no row can be opened: the match count against the catalog total.
  ///
  /// In en, this message translates to:
  /// **'{matches} of {total}'**
  String sidebarCatalogFilterCount(int matches, int total);

  /// Helper text under the catalog filter while a query matches at least one row — names the Enter-opens-first-match affordance.
  ///
  /// In en, this message translates to:
  /// **'{matches} of {total} · ↵ opens the first'**
  String sidebarCatalogFilterCountOpenFirst(int matches, int total);

  /// Tooltip of the catalog filter's clear button.
  ///
  /// In en, this message translates to:
  /// **'Clear filter'**
  String get sidebarCatalogFilterClear;

  /// Tooltip/label of the manual sync button in the Séance-servers section header: runs one sync round immediately instead of waiting for the periodic cycle.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get sidebarCatalogSyncNow;

  /// Tooltip of the Séance-servers sync button while a round is in flight.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get sidebarCatalogSyncing;

  /// Tooltip of the Séance-servers sync button when the last round failed. {error} is the recorded failure description.
  ///
  /// In en, this message translates to:
  /// **'Last sync failed: {error}'**
  String sidebarCatalogSyncFailed(String error);

  /// Accessible label of one clickable ancestor segment in the pane's path bar (02 §13: button semantics, "Go to var").
  ///
  /// In en, this message translates to:
  /// **'Go to {segment}'**
  String panePathSegmentGoTo(String segment);

  /// Accessible label of a collapsible sidebar group header (02 §13: expanded state rides the node's expanded flag, the count is spelled out). {count} is an item-count clause like "3 items".
  ///
  /// In en, this message translates to:
  /// **'{title}, {count}'**
  String sidebarSectionSemantics(String title, String count);

  /// Tooltip of the button in the Séance servers section header that opens the server editor for a new server.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get sidebarCatalogAddServer;

  /// Context-menu verb on a Séance servers row that opens the server editor.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get sidebarCatalogEdit;

  /// Context-menu verb on a Séance servers row that copies the server, including its stored credential.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get sidebarCatalogDuplicate;

  /// Context-menu verb on a Séance servers row that deletes the server after confirmation.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sidebarCatalogDelete;

  /// Title of the catalog-row delete confirmation. {label} is the server's display name.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{label}\"?'**
  String sidebarCatalogDeleteTitle(String label);

  /// Body of the catalog-row delete confirmation: the serverConfig tombstone propagates the delete to the fleet.
  ///
  /// In en, this message translates to:
  /// **'This removes the server and any stored secret, on this device and — if it synced — your other devices.'**
  String get sidebarCatalogDeleteBody;

  /// Body of the catalog-row delete confirmation when the server has managed local checkouts. {count} is how many managed local edits would be deleted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This removes the server, its stored secret, and # managed local edit. Any changes not uploaded to the server will be deleted.} other{This removes the server, its stored secret, and # managed local edits. Any changes not uploaded to the server will be deleted.}}'**
  String sidebarCatalogDeleteBodyEdits(int count);

  /// Declines the catalog-row delete confirmation.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sidebarCatalogDeleteCancel;

  /// Confirms the catalog-row delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sidebarCatalogDeleteConfirm;

  /// Toast when duplicating a catalog server failed. {error} is the failure detail (a locked keyring, a changed source).
  ///
  /// In en, this message translates to:
  /// **'Could not duplicate \"{label}\": {error}'**
  String sidebarCatalogDuplicateFailed(String label, String error);

  /// Toast after a catalog server was duplicated. {label} is the copy's generated name.
  ///
  /// In en, this message translates to:
  /// **'Duplicated as \"{label}\"'**
  String sidebarCatalogDuplicated(String label);

  /// Action on the duplicated toast that opens the copy in the server editor.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get sidebarCatalogDuplicatedEdit;

  /// Title of the server editor for a new server.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get serverEditorAddTitle;

  /// Title of the server editor for an existing server.
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get serverEditorEditTitle;

  /// Label of the server-name field.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get serverEditorLabel;

  /// Label of the hostname field.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get serverEditorHost;

  /// Label of the port field.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get serverEditorPort;

  /// Label of the username field.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get serverEditorUsername;

  /// Label of the auth-method dropdown.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get serverEditorAuthentication;

  /// Auth-method choice: the system ssh-agent.
  ///
  /// In en, this message translates to:
  /// **'ssh-agent'**
  String get serverEditorAuthAgent;

  /// Auth-method choice: a stored password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get serverEditorAuthPassword;

  /// Auth-method choice: a private key, pasted or referenced.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get serverEditorAuthPrivateKey;

  /// Explainer under the ssh-agent auth choice.
  ///
  /// In en, this message translates to:
  /// **'Keys are provided by your ssh-agent; nothing is stored.'**
  String get serverEditorAgentInfo;

  /// Warning under the ssh-agent auth choice that the backend cannot authenticate that way yet.
  ///
  /// In en, this message translates to:
  /// **'ssh-agent auth isn\'t supported yet — connecting will fail. Choose Password or Private key for now.'**
  String get serverEditorAgentUnsupported;

  /// Label of the password field.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get serverEditorPasswordLabel;

  /// Title of the switch that keeps the private key on disk rather than storing it.
  ///
  /// In en, this message translates to:
  /// **'Reference a key file on disk'**
  String get serverEditorReferenceKeyTitle;

  /// Subtitle of the reference-key switch.
  ///
  /// In en, this message translates to:
  /// **'Don\'t store the key — read it at connect'**
  String get serverEditorReferenceKeySubtitle;

  /// Placeholder in the identity-file path field — a conventional key path, not a default.
  ///
  /// In en, this message translates to:
  /// **'~/.ssh/id_ed25519'**
  String get serverEditorIdentityFileHint;

  /// Label of the referenced-key path field.
  ///
  /// In en, this message translates to:
  /// **'Identity file path'**
  String get serverEditorIdentityFilePath;

  /// Button beside the identity-file path field that opens the file picker.
  ///
  /// In en, this message translates to:
  /// **'Browse…'**
  String get serverEditorBrowse;

  /// Label of the paste-a-key field.
  ///
  /// In en, this message translates to:
  /// **'Private key (PEM/OpenSSH)'**
  String get serverEditorPrivateKeyPem;

  /// Label of the key-passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase (optional)'**
  String get serverEditorKeyPassphrase;

  /// Label of the login-script field — a command typed into the server's shell after connecting (executed by Séance; stored and synced here).
  ///
  /// In en, this message translates to:
  /// **'Login script (optional)'**
  String get serverEditorLoginScript;

  /// Hint inside the login-script field.
  ///
  /// In en, this message translates to:
  /// **'e.g. cd ~/work && tmux attach -t work || tmux new -s work'**
  String get serverEditorLoginScriptHint;

  /// Explainer under the login-script field.
  ///
  /// In en, this message translates to:
  /// **'Runs as if typed at the prompt right after connecting. Its text and output land in scrollback — keep secrets out. Blank for none.'**
  String get serverEditorLoginScriptNote;

  /// Heading of the group/colour/mark section.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get serverEditorAppearance;

  /// Label of the group-name field.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get serverEditorGroup;

  /// Hint inside the group-name field.
  ///
  /// In en, this message translates to:
  /// **'Production, Home lab, … — blank for none'**
  String get serverEditorGroupHint;

  /// Heading of the accent-colour row.
  ///
  /// In en, this message translates to:
  /// **'Colour'**
  String get serverEditorColour;

  /// Heading of the mark row (glyph, emoji or imported image).
  ///
  /// In en, this message translates to:
  /// **'Mark'**
  String get serverEditorMark;

  /// Button that opens the mark picker.
  ///
  /// In en, this message translates to:
  /// **'Choose…'**
  String get serverEditorChooseMark;

  /// Tooltip of the button that resets the mark to the default glyph.
  ///
  /// In en, this message translates to:
  /// **'Use the default mark'**
  String get serverEditorDefaultMarkTooltip;

  /// Title of the per-server credential-sync switch.
  ///
  /// In en, this message translates to:
  /// **'Allow this credential to sync'**
  String get serverEditorSyncSecretTitle;

  /// Subtitle of the credential-sync switch while the server is excluded.
  ///
  /// In en, this message translates to:
  /// **'Not used while this server is excluded from sync.'**
  String get serverEditorSyncSecretExcluded;

  /// Subtitle of the credential-sync switch.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted. Also needs sync set up with \"Sync saved passwords & keys\" enabled.'**
  String get serverEditorSyncSecretSubtitle;

  /// Title of the whole-server sync-exclusion switch.
  ///
  /// In en, this message translates to:
  /// **'Exclude from sync'**
  String get serverEditorExcludeTitle;

  /// Subtitle of the exclusion switch while it is on.
  ///
  /// In en, this message translates to:
  /// **'Kept on this device only. A copy that synced earlier is removed from the sync server and from your other devices.'**
  String get serverEditorExcludeOnSubtitle;

  /// Subtitle of the exclusion switch while it is off.
  ///
  /// In en, this message translates to:
  /// **'Keep this server on this device only — never upload it.'**
  String get serverEditorExcludeOffSubtitle;

  /// Button that authenticates against the form's draft values without saving.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get serverEditorTest;

  /// Label of the test button while a test runs.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get serverEditorTesting;

  /// Screen-reader label of the spinner while a connection test runs.
  ///
  /// In en, this message translates to:
  /// **'Testing connection'**
  String get serverEditorTestingSemantic;

  /// Closes the server editor without saving.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverEditorCancel;

  /// Saves the server and closes the editor.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get serverEditorSave;

  /// Small print under the test button.
  ///
  /// In en, this message translates to:
  /// **'Testing authenticates without opening a shell or running the login script. A host key you approve here is trusted for the test only — the first real connection asks again.'**
  String get serverEditorTestDisclaimer;

  /// Validator message under a blank required field.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get serverEditorRequired;

  /// Validator message under an out-of-range port.
  ///
  /// In en, this message translates to:
  /// **'1–65535'**
  String get serverEditorPortRange;

  /// Headline of the inline report when the test itself failed (not the host's answer).
  ///
  /// In en, this message translates to:
  /// **'Could not test the connection.'**
  String get serverEditorTestFailedSummary;

  /// Toast when saving the server failed. {error} is the failure detail.
  ///
  /// In en, this message translates to:
  /// **'Could not save: {error}'**
  String serverEditorSaveFailed(String error);

  /// Title of the confirmation shown before excluding a synced server.
  ///
  /// In en, this message translates to:
  /// **'Exclude from sync?'**
  String get serverEditorExcludeConfirmTitle;

  /// Body of the exclusion confirmation.
  ///
  /// In en, this message translates to:
  /// **'If this server synced earlier, it is removed from the sync server and from your other devices, along with any credential that synced with it. This device keeps its copy.'**
  String get serverEditorExcludeConfirmBody;

  /// Declines the exclusion confirmation.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverEditorExcludeConfirmCancel;

  /// Confirms the exclusion.
  ///
  /// In en, this message translates to:
  /// **'Exclude'**
  String get serverEditorExcludeConfirmAction;

  /// Tooltip of the spectrum swatch that opens the custom colour picker.
  ///
  /// In en, this message translates to:
  /// **'Custom colour…'**
  String get serverEditorCustomColour;

  /// Tooltip of the custom-colour swatch once a colour is chosen. {hex} is the stored #RRGGBB string.
  ///
  /// In en, this message translates to:
  /// **'Custom colour ({hex})'**
  String serverEditorCustomColourValue(String hex);

  /// Title of the mark picker dialog.
  ///
  /// In en, this message translates to:
  /// **'Server mark'**
  String get serverMarkPickerTitle;

  /// Tab of the mark picker listing the built-in glyphs.
  ///
  /// In en, this message translates to:
  /// **'Icons'**
  String get serverMarkPickerIconsTab;

  /// Tab of the mark picker for an emoji mark.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get serverMarkPickerEmojiTab;

  /// Tab of the mark picker for an imported image.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get serverMarkPickerImageTab;

  /// Dismisses the mark picker without choosing.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverMarkPickerCancel;

  /// Hint inside the icon-tab search field.
  ///
  /// In en, this message translates to:
  /// **'Search icons — try k8s, psql, prod…'**
  String get serverMarkPickerSearchHint;

  /// Empty state of the icon search.
  ///
  /// In en, this message translates to:
  /// **'No icon matches.'**
  String get serverMarkPickerNoMatch;

  /// Heading of the no-mark icon section.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get serverMarkPickerDefault;

  /// How to reach the OS emoji picker on macOS.
  ///
  /// In en, this message translates to:
  /// **'Press Control-Command-Space for the system emoji picker.'**
  String get serverMarkPickerEmojiHintMacOS;

  /// How to reach the OS emoji picker on Windows.
  ///
  /// In en, this message translates to:
  /// **'Press Windows-. for the system emoji picker.'**
  String get serverMarkPickerEmojiHintWindows;

  /// How to reach the OS emoji picker on Linux.
  ///
  /// In en, this message translates to:
  /// **'Your desktop may offer an emoji picker with Control-Shift-E or Control-.'**
  String get serverMarkPickerEmojiHintLinux;

  /// How to reach the emoji input on platforms without a picker chord (mobile).
  ///
  /// In en, this message translates to:
  /// **'Switch your keyboard to emoji.'**
  String get serverMarkPickerEmojiHintOther;

  /// Label of the free-text emoji field.
  ///
  /// In en, this message translates to:
  /// **'Any emoji'**
  String get serverMarkPickerAnyEmoji;

  /// Error under the emoji field when it holds text that is not a single emoji.
  ///
  /// In en, this message translates to:
  /// **'One emoji, please.'**
  String get serverMarkPickerOneEmoji;

  /// Button that confirms the typed emoji.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get serverMarkPickerUse;

  /// Caveat under the emoji grid explaining cross-device rendering and the glyph fallback.
  ///
  /// In en, this message translates to:
  /// **'An emoji is drawn with the system’s own emoji font, so a device without one shows a box — the icon chosen under Icons is what it falls back to there.'**
  String get serverMarkPickerEmojiFontNote;

  /// Error shown when the picked image file could not be read.
  ///
  /// In en, this message translates to:
  /// **'That file could not be opened. Try another.'**
  String get serverMarkPickerOpenFailed;

  /// Error shown when the picked image exceeds the decode bound.
  ///
  /// In en, this message translates to:
  /// **'That file is too big to read. Crop or export it smaller first.'**
  String get serverMarkPickerTooLarge;

  /// Error shown when the picked file is not a decodable image.
  ///
  /// In en, this message translates to:
  /// **'That file could not be read as an image.'**
  String get serverMarkPickerUndecodable;

  /// Error shown when the picked image could not be re-encoded.
  ///
  /// In en, this message translates to:
  /// **'That image could not be prepared. Try again, or pick another.'**
  String get serverMarkPickerEncodeFailed;

  /// Error shown when the re-encoded image still exceeds the record-size bound.
  ///
  /// In en, this message translates to:
  /// **'That image would not fit in a server record even at badge size. Try a smaller or simpler one.'**
  String get serverMarkPickerIncompressible;

  /// Caption beside the badge on the image tab when no image is set.
  ///
  /// In en, this message translates to:
  /// **'No image on this server yet.'**
  String get serverMarkPickerNoImage;

  /// Caption beside the badge on the image tab when an image is set.
  ///
  /// In en, this message translates to:
  /// **'This server carries an image.'**
  String get serverMarkPickerHasImage;

  /// Button that imports an image when none is set.
  ///
  /// In en, this message translates to:
  /// **'Choose image…'**
  String get serverMarkPickerChooseImage;

  /// Button that imports an image when one is already set.
  ///
  /// In en, this message translates to:
  /// **'Replace image…'**
  String get serverMarkPickerReplaceImage;

  /// Button that reverts the mark to the image's fallback glyph.
  ///
  /// In en, this message translates to:
  /// **'Remove image'**
  String get serverMarkPickerRemoveImage;

  /// Readable list of accepted image formats (SVG excluded on iOS, which gets the photo picker).
  ///
  /// In en, this message translates to:
  /// **'PNG, JPEG, WebP or SVG'**
  String get serverMarkPickerImageFormats;

  /// Readable list of accepted image formats on iOS.
  ///
  /// In en, this message translates to:
  /// **'PNG, JPEG or WebP'**
  String get serverMarkPickerImageFormatsIos;

  /// Explainer at the bottom of the image tab. {formats} is the accepted-format list; {side} is the stored edge length in pixels.
  ///
  /// In en, this message translates to:
  /// **'{formats}. The image is cropped square, stored at {side} pixels, and travels inside this server’s own settings — so it reaches your other devices with everything else about the server, and never arrives without it. Anything larger than a badge can show would only be paid for on every sync. A transparent image shows the badge’s own background through it.'**
  String serverMarkPickerImageExplanation(String formats, int side);

  /// Title of the custom colour picker dialog.
  ///
  /// In en, this message translates to:
  /// **'Custom colour'**
  String get serverColorPickerTitle;

  /// Label of the hex-digits field.
  ///
  /// In en, this message translates to:
  /// **'Hex'**
  String get serverColorPickerHexLabel;

  /// Error under the hex field when it does not hold six hex digits.
  ///
  /// In en, this message translates to:
  /// **'Six hex digits'**
  String get serverColorPickerHexError;

  /// Label of the hue slider.
  ///
  /// In en, this message translates to:
  /// **'Hue'**
  String get serverColorPickerHue;

  /// Label of the saturation slider.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get serverColorPickerSaturation;

  /// Label of the brightness slider.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get serverColorPickerBrightness;

  /// Screen-reader value of the hue slider.
  ///
  /// In en, this message translates to:
  /// **'{degrees} degrees'**
  String serverColorPickerDegrees(int degrees);

  /// Screen-reader value of the saturation/brightness sliders.
  ///
  /// In en, this message translates to:
  /// **'{percent} percent'**
  String serverColorPickerPercent(int percent);

  /// Small print under the colour sliders.
  ///
  /// In en, this message translates to:
  /// **'Drawn as picked, with the mark kept legible on it in both themes. Devices running an older version show the nearest of the named colours instead.'**
  String get serverColorPickerHint;

  /// Dismisses the colour picker without choosing.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverColorPickerCancel;

  /// Confirms the picked colour.
  ///
  /// In en, this message translates to:
  /// **'Use colour'**
  String get serverColorPickerUse;

  /// Toast after the transcript was copied.
  ///
  /// In en, this message translates to:
  /// **'Log copied'**
  String get connectionLogCopied;

  /// Toast when the clipboard write failed.
  ///
  /// In en, this message translates to:
  /// **'Could not copy the log'**
  String get connectionLogCopyFailed;

  /// Screen-reader label of the success icon in the connection-test report.
  ///
  /// In en, this message translates to:
  /// **'Connection test succeeded'**
  String get connectionTestSucceeded;

  /// Screen-reader label of the failure icon in the connection-test report.
  ///
  /// In en, this message translates to:
  /// **'Connection test failed'**
  String get connectionTestFailed;

  /// D32 §8: tooltip of the header's ☰ button that holds the whole menu tree on Windows and Linux.
  ///
  /// In en, this message translates to:
  /// **'Main menu'**
  String get mainMenuTooltip;

  /// D32 §4: tooltip of the header's » overflow button on narrow windows.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get toolbarMoreTooltip;

  /// D32 §3: accessibility label of the right inspector column.
  ///
  /// In en, this message translates to:
  /// **'Inspector'**
  String get inspectorLabel;

  /// D32 §3: the inspector's Info tab (the focused item's preview and facts).
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get inspectorTabInfo;

  /// D32 §3: the inspector's Transfers tab (the transfer queue's rows).
  ///
  /// In en, this message translates to:
  /// **'Transfers'**
  String get inspectorTabTransfers;

  /// D32 §3: the inspector's Alerts tab (things that need the user).
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get inspectorTabAlerts;

  /// D32 §3: the Alerts tab's empty state.
  ///
  /// In en, this message translates to:
  /// **'All clear'**
  String get alertsEmpty;

  /// D32 alert row: a transfer task failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t transfer “{name}”'**
  String alertTransferFailed(String name);

  /// D32 alert row: parked transfer conflicts (02 §5.2).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 conflict needs a decision} other{{count} conflicts need a decision}}'**
  String alertConflictsPending(int count);

  /// D32 alert row: journaled work restored behind the queue pause.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer from last session is paused} other{{count} transfers from last session are paused}}'**
  String alertRestoredQueue(int count);

  /// D32 alert row: a server is blocked on a changed host key (D18).
  ///
  /// In en, this message translates to:
  /// **'The host key for {server} changed'**
  String alertHostKeyChanged(String server);

  /// D32 alert row: a server's connection failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t connect to {server}'**
  String alertConnectionFailed(String server);

  /// D32 alert row: managed checkouts with un-uploaded edits (06 §3.7).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 local edit on {server} isn\'t uploaded} other{{count} local edits on {server} aren\'t uploaded}}'**
  String alertLocalEdits(int count, String server);

  /// D32 alert row: a newer release exists (D19).
  ///
  /// In en, this message translates to:
  /// **'Poltergeist {version} is available'**
  String alertUpdateAvailable(String version);

  /// Alert row action: retry the failed transfer.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get alertActionRetry;

  /// Alert row action: show the Transfers tab.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get alertActionShow;

  /// Alert row action: go to the pending conflicts.
  ///
  /// In en, this message translates to:
  /// **'Resolve…'**
  String get alertActionResolve;

  /// Alert row action: open the review surface (host key, local edits).
  ///
  /// In en, this message translates to:
  /// **'Review…'**
  String get alertActionReview;

  /// Alert row action: open the release page in the browser.
  ///
  /// In en, this message translates to:
  /// **'View Release'**
  String get alertActionViewRelease;

  /// Tooltip of an alert row's dismiss button.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get alertActionDismiss;

  /// D32: view.toggleInspector's label while the inspector is hidden.
  ///
  /// In en, this message translates to:
  /// **'Show Inspector'**
  String get viewShowInspectorLabel;

  /// D32: view.toggleInspector's label while the inspector is shown.
  ///
  /// In en, this message translates to:
  /// **'Hide Inspector'**
  String get viewHideInspectorLabel;

  /// D32: View menu item that shows the inspector's Alerts tab.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get viewShowAlertsLabel;

  /// D32 §4: connect.quickConnect (⌘K) — Server menu item and header button tooltip.
  ///
  /// In en, this message translates to:
  /// **'Connect…'**
  String get connectQuickConnectLabel;

  /// D32 §4: the header's labelled Connect button.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectShortLabel;

  /// Title of the Connect dialog (⌘K).
  ///
  /// In en, this message translates to:
  /// **'Connect to Server'**
  String get connectDialogTitle;

  /// D32 §4: the header's labelled Sync button.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get syncShortLabel;

  /// D32 §4: selection.transferToOtherPane (F5).
  ///
  /// In en, this message translates to:
  /// **'Copy to Other Pane'**
  String get selectionCopyToOtherPaneLabel;

  /// D32: selection.moveToOtherPane (F6).
  ///
  /// In en, this message translates to:
  /// **'Move to Other Pane'**
  String get selectionMoveToOtherPaneLabel;

  /// Disabled reason for Copy/Move to Other Pane.
  ///
  /// In en, this message translates to:
  /// **'Select items, and open a folder in the other pane'**
  String get commandDisabledNeedsTwoPanes;

  /// Accessibility label of the sidebar splitter.
  ///
  /// In en, this message translates to:
  /// **'Resize sidebar'**
  String get resizeSidebar;

  /// Accessibility label of the inspector splitter.
  ///
  /// In en, this message translates to:
  /// **'Resize inspector'**
  String get resizeInspector;

  /// A region splitter's current width in whole pixels.
  ///
  /// In en, this message translates to:
  /// **'{value} pixels'**
  String splitterWidthPx(int value);

  /// Placeholder of the header's filter field (filters the active pane).
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get headerFilterHint;

  /// Header title while the active pane shows the launcher.
  ///
  /// In en, this message translates to:
  /// **'No location'**
  String get headerTitleEmpty;

  /// D32 §11: file.reveal on macOS — reveals the local item in Finder.
  ///
  /// In en, this message translates to:
  /// **'Show in Finder'**
  String get fileRevealMacLabel;

  /// D32 §11: file.reveal on Linux — reveals the local item in the desktop file manager.
  ///
  /// In en, this message translates to:
  /// **'Show in File Manager'**
  String get fileRevealLinuxLabel;

  /// D32 §11: file.reveal on Windows — reveals the local item in File Explorer.
  ///
  /// In en, this message translates to:
  /// **'Show in Explorer'**
  String get fileRevealWindowsLabel;

  /// Disabled reason for Show in Finder/File Manager: only local items can be revealed.
  ///
  /// In en, this message translates to:
  /// **'Select a local item'**
  String get commandDisabledRevealLocalOnly;

  /// D32 §8 Help menu: the sheet listing every command's shortcut.
  ///
  /// In en, this message translates to:
  /// **'Keyboard Shortcuts'**
  String get helpKeyboardShortcutsLabel;

  /// D32 §8 Help menu: opens the releases page in the browser.
  ///
  /// In en, this message translates to:
  /// **'Release Notes'**
  String get helpReleaseNotesLabel;

  /// D32 §8 Help menu: opens the issue tracker in the browser.
  ///
  /// In en, this message translates to:
  /// **'Report an Issue'**
  String get helpReportIssueLabel;

  /// Keyboard Shortcuts sheet: group for commands that live in no menu.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get helpShortcutsOtherGroup;

  /// Default name of a folder created by New Folder (file.newFolder); numbered like 'untitled folder (2)' when the name is taken. The inline rename opens on it right away.
  ///
  /// In en, this message translates to:
  /// **'untitled folder'**
  String get paneNewFolderName;

  /// Default name of an empty file created by New File (file.newFile); numbered like 'untitled file (2)' when the name is taken. The inline rename opens on it right away.
  ///
  /// In en, this message translates to:
  /// **'untitled file'**
  String get paneNewFileName;

  /// Error when New Folder / New File finds its default name and every numbered variant up to the limit already taken.
  ///
  /// In en, this message translates to:
  /// **'No free name is left for \"{name}\" in this folder.'**
  String paneCreateNamesExhausted(String name);

  /// Failed transfer, checkout, or sync row: the bookmark names a shared (synced) server that this device's pulled server list does not contain, so there is nothing to connect to.
  ///
  /// In en, this message translates to:
  /// **'The shared server \"{server}\" is not in the synced server list on this device.'**
  String activityTaskServerNotInCatalog(String server);

  /// file.newFolder (⇧⌘N / F7): creates an untitled folder and opens its rename.
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get fileNewFolderLabel;

  /// file.newFile (⌥⌘N): creates an empty untitled file and opens its rename.
  ///
  /// In en, this message translates to:
  /// **'New File'**
  String get fileNewFileLabel;

  /// file.duplicate (⌘D): a keep-both copy beside the selection.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get fileDuplicateLabel;

  /// file.delete on local items (macOS/Linux).
  ///
  /// In en, this message translates to:
  /// **'Move to Trash'**
  String get fileMoveToTrashLabel;

  /// file.delete on local items (Windows).
  ///
  /// In en, this message translates to:
  /// **'Move to Recycle Bin'**
  String get fileMoveToRecycleBinLabel;

  /// file.delete on a remote pane: remote deletes confirm first (D15).
  ///
  /// In en, this message translates to:
  /// **'Delete…'**
  String get fileDeleteRemoteLabel;

  /// file.deletePermanently (⌥⌘⌫ / Shift+Delete): always confirms.
  ///
  /// In en, this message translates to:
  /// **'Delete Immediately…'**
  String get fileDeletePermanentlyLabel;

  /// Delete dialog while the quantifying walk runs (cancellable).
  ///
  /// In en, this message translates to:
  /// **'Counting items…'**
  String get deleteDialogCounting;

  /// Delete dialog when preparing the delete failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t prepare the delete: {error}'**
  String deleteDialogPrepareFailed(String error);

  /// 02 §10 permanent delete headline with the walk's count and size.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1 item ({size}) from {location}?} other{Delete {count} items ({size}) from {location}?}}'**
  String deleteDialogDeleteCount(int count, String size, String location);

  /// 02 §10 permanent delete headline naming up to three items.
  ///
  /// In en, this message translates to:
  /// **'Delete “{names}” from {location}?'**
  String deleteDialogDeleteNames(String names, String location);

  /// 02 §10 permanent delete headline when the counting walk gave up.
  ///
  /// In en, this message translates to:
  /// **'Delete the selected items from {location}?'**
  String deleteDialogDeleteUnquantified(String location);

  /// 02 §10 server-trash headline.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Move 1 item ({size}) to .poltergeist-trash/ on {location}?} other{Move {count} items ({size}) to .poltergeist-trash/ on {location}?}}'**
  String deleteDialogMoveCount(int count, String size, String location);

  /// 02 §10 server-trash headline naming up to three items.
  ///
  /// In en, this message translates to:
  /// **'Move “{names}” to .poltergeist-trash/ on {location}?'**
  String deleteDialogMoveNames(String names, String location);

  /// 02 §10 server-trash headline when the counting walk gave up.
  ///
  /// In en, this message translates to:
  /// **'Move the selected items to .poltergeist-trash/ on {location}?'**
  String deleteDialogMoveUnquantified(String location);

  /// 02 §10 permanent delete warning line.
  ///
  /// In en, this message translates to:
  /// **'This cannot be undone.'**
  String get deleteDialogIrreversible;

  /// 02 §10 server-trash warning line.
  ///
  /// In en, this message translates to:
  /// **'Items are moved to .poltergeist-trash/ on the server.'**
  String get deleteDialogMoveWarning;

  /// D15's one-time trash-unavailable notice in the delete dialog; count is the number of selected items.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{The Trash isn\'t available here, so this item will be deleted permanently.} other{The Trash isn\'t available here, so these items will be deleted permanently.}}'**
  String deleteDialogTrashUnavailable(int count);

  /// 02 §13 flagged-descendant disclosure (exact count).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Includes 1 item with an undecodable name.} other{Includes {count} items with an undecodable name.}}'**
  String deleteDialogFlaggedExact(int count);

  /// 02 §13 flagged-descendant disclosure when the walk did not finish.
  ///
  /// In en, this message translates to:
  /// **'May include items with undecodable names.'**
  String get deleteDialogFlaggedMaybe;

  /// 02 §10 per-server trash option (pre-checked when the server opts in).
  ///
  /// In en, this message translates to:
  /// **'Move to .poltergeist-trash/ instead'**
  String get deleteDialogServerTrashCheckbox;

  /// 02 §10 helper under the server-trash checkbox.
  ///
  /// In en, this message translates to:
  /// **'Trashed files stay on the server, readable by anything that can read the folder, until you purge them.'**
  String get deleteDialogServerTrashHelper;

  /// Delete dialog's destructive confirm button.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete} other{Delete {count} Items}}'**
  String deleteDialogConfirmDelete(int count);

  /// Delete dialog's confirm button while the server-trash move is on.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Move to Trash} other{Move {count} Items}}'**
  String deleteDialogConfirmMove(int count);

  /// A header toolbar button's tooltip: its label, then its first keyboard shortcut ("New Folder  ⇧⌘N").
  ///
  /// In en, this message translates to:
  /// **'{label}  {shortcut}'**
  String toolbarTooltipWithShortcut(String label, String shortcut);

  /// The number on a count badge (the inspector toggle's alert count, the Transfers tab's live tasks).
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String badgeCount(int count);

  /// A count badge's text once the count passes 99.
  ///
  /// In en, this message translates to:
  /// **'99+'**
  String get badgeCountOverflow;

  /// Sync sheet plan sentence (D32 §7): a one-way pair's opening clause.
  ///
  /// In en, this message translates to:
  /// **'Your {destinationKind, select, remote{remote} other{local}} folder “{destination}” will be updated from your {sourceKind, select, remote{remote} other{local}} folder “{source}”.'**
  String syncPolicyOneWay(
    String destinationKind,
    String destination,
    String sourceKind,
    String source,
  );

  /// Plan sentence: one-way replacement under the size-and-date comparison. The engine replaces on ANY difference, so the copy never says only older files are replaced.
  ///
  /// In en, this message translates to:
  /// **'Files that differ in size or modification date will be replaced with the version from “{source}”, even when the copy in “{destination}” is newer.'**
  String syncPolicyReplaceSizeDate(String source, String destination);

  /// Plan sentence: one-way replacement under the size-only comparison.
  ///
  /// In en, this message translates to:
  /// **'Files that differ in size will be replaced with the version from “{source}”. Files of the same size are left alone, even when their dates differ.'**
  String syncPolicyReplaceSize(String source);

  /// Plan sentence: one-way replacement under the checksum comparison.
  ///
  /// In en, this message translates to:
  /// **'Files whose size or contents differ will be replaced with the version from “{source}”. Contents are compared by checksum, which reads every file of matching size on both sides.'**
  String syncPolicyReplaceChecksum(String source);

  /// Plan sentence: the engine's automatic size-only fallback after a side refused to keep modification dates.
  ///
  /// In en, this message translates to:
  /// **'Modification dates proved unreliable for this pair, so only sizes are compared.'**
  String get syncPolicySizeOnlyFallback;

  /// Plan sentence: overwrite backups go to the in-root sync trash folder of the destination.
  ///
  /// In en, this message translates to:
  /// **'Previous versions of replaced files are kept in {trash} inside “{destination}”.'**
  String syncPolicyBackupsInRoot(String trash, String destination);

  /// Plan sentence: overwrite backups go to a configured out-of-root trash path.
  ///
  /// In en, this message translates to:
  /// **'Previous versions of replaced files are kept in {trashPath}.'**
  String syncPolicyBackupsAt(String trashPath);

  /// Plan sentence: overwrite backups are turned off (a destructive clause).
  ///
  /// In en, this message translates to:
  /// **'Replaced files are overwritten without a backup.'**
  String get syncPolicyBackupsNone;

  /// Plan sentence: Mirror deletions into the sync trash (a destructive clause).
  ///
  /// In en, this message translates to:
  /// **'Files in “{destination}” that aren’t in “{source}” will be deleted (moved to {trash}).'**
  String syncPolicyDeleteTrash(String destination, String source, String trash);

  /// Plan sentence: Mirror deletions without a trash (a destructive clause).
  ///
  /// In en, this message translates to:
  /// **'Files in “{destination}” that aren’t in “{source}” will be deleted permanently.'**
  String syncPolicyDeletePermanent(String destination, String source);

  /// Plan sentence: the no-deletion assurance.
  ///
  /// In en, this message translates to:
  /// **'No files will be deleted.'**
  String get syncPolicyNoDeletes;

  /// Plan sentence: an Additive (both ways) pair's opening clause.
  ///
  /// In en, this message translates to:
  /// **'Your {leftKind, select, remote{remote} other{local}} folder “{left}” and your {rightKind, select, remote{remote} other{local}} folder “{right}” will each receive the files only the other one has.'**
  String syncPolicyBothWays(
    String leftKind,
    String left,
    String rightKind,
    String right,
  );

  /// Plan sentence (both ways): what makes two copies differ under size-and-date.
  ///
  /// In en, this message translates to:
  /// **'Files count as different when their size or modification date differs.'**
  String get syncPolicyDifferSizeDate;

  /// Plan sentence (both ways): what makes two copies differ under size-only.
  ///
  /// In en, this message translates to:
  /// **'Files count as different only when their size differs.'**
  String get syncPolicyDifferSize;

  /// Plan sentence (both ways): what makes two copies differ under checksum.
  ///
  /// In en, this message translates to:
  /// **'Files count as different when their size or checksum differs.'**
  String get syncPolicyDifferChecksum;

  /// Plan sentence (both ways): differing files become conflicts.
  ///
  /// In en, this message translates to:
  /// **'Files that differ are held as conflicts for you to decide; nothing is replaced automatically.'**
  String get syncPolicyConflictAsk;

  /// Plan sentence (both ways): the newer-wins conflict default.
  ///
  /// In en, this message translates to:
  /// **'When a file differs, the newer copy replaces the older one.'**
  String get syncPolicyConflictNewer;

  /// Plan sentence (both ways): a keep-this-side conflict default.
  ///
  /// In en, this message translates to:
  /// **'When a file differs, the version from “{winner}” replaces the other copy.'**
  String syncPolicyConflictKeep(String winner);

  /// Plan sentence (both ways): the skip conflict default.
  ///
  /// In en, this message translates to:
  /// **'Files that differ are left alone.'**
  String get syncPolicyConflictSkip;

  /// Plan sentence (both ways): overwrite backups land in the trash of whichever side is written.
  ///
  /// In en, this message translates to:
  /// **'Previous versions of replaced files are kept in each side’s sync trash.'**
  String get syncPolicyBackupsEachSide;

  /// Plan sentence: include-hidden is off.
  ///
  /// In en, this message translates to:
  /// **'Hidden files are left out.'**
  String get syncPolicyHiddenSkipped;

  /// Plan sentence: the pair skips items matching its exclude rules.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Items matching 1 rule are left out.} other{Items matching {count} rules are left out.}}'**
  String syncPolicyRulesSkipped(int count);

  /// Title of the sync options sheet (D32 §7).
  ///
  /// In en, this message translates to:
  /// **'Sync Files'**
  String get syncSheetTitle;

  /// Title of the sync sheet when it creates a saved sync favorite.
  ///
  /// In en, this message translates to:
  /// **'New Saved Sync'**
  String get syncSheetNewSavedTitle;

  /// Endpoint tile caption for a local folder.
  ///
  /// In en, this message translates to:
  /// **'This computer'**
  String get syncSheetThisComputer;

  /// Endpoint tile caption for a server whose name is unknown.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get syncSheetServerFallback;

  /// Endpoint tile label when a side has no folder yet; opens the full pair editor.
  ///
  /// In en, this message translates to:
  /// **'Choose Folders…'**
  String get syncSheetChooseFolders;

  /// Tooltip and accessibility label of the direction toggle between the endpoint tiles.
  ///
  /// In en, this message translates to:
  /// **'From {source} to {destination}. Click to reverse.'**
  String syncSheetDirectionTooltip(String source, String destination);

  /// Tooltip of the direction toggle while the pair syncs both ways.
  ///
  /// In en, this message translates to:
  /// **'Both ways. Click to sync one way.'**
  String get syncSheetBothWaysTooltip;

  /// The comparison row. {choice} marks where the comparison dropdown sits; the text around it renders on either side.
  ///
  /// In en, this message translates to:
  /// **'Use the {choice} to determine if a file has changed'**
  String syncSheetCompareSentence(String choice);

  /// Comparison dropdown choice.
  ///
  /// In en, this message translates to:
  /// **'Size and Modification Date'**
  String get syncSheetCompareSizeDate;

  /// Comparison dropdown choice.
  ///
  /// In en, this message translates to:
  /// **'File Size'**
  String get syncSheetCompareSize;

  /// Comparison dropdown choice.
  ///
  /// In en, this message translates to:
  /// **'Checksum'**
  String get syncSheetCompareChecksum;

  /// Checkbox: delete destination files the source does not have (Mirror).
  ///
  /// In en, this message translates to:
  /// **'Delete orphaned destination files'**
  String get syncSheetDeleteOrphans;

  /// Caption under the disabled delete checkbox in Additive mode.
  ///
  /// In en, this message translates to:
  /// **'Not available when syncing both ways'**
  String get syncSheetDeleteOrphansBothWays;

  /// Radio under the delete checkbox.
  ///
  /// In en, this message translates to:
  /// **'Move to trash (recommended)'**
  String get syncSheetDeleteToTrash;

  /// Radio under the delete checkbox.
  ///
  /// In en, this message translates to:
  /// **'Delete permanently'**
  String get syncSheetDeletePermanently;

  /// Checkbox in the sync sheet.
  ///
  /// In en, this message translates to:
  /// **'Include hidden files'**
  String get syncSheetIncludeHidden;

  /// Checkbox in the sync sheet.
  ///
  /// In en, this message translates to:
  /// **'Skip items matching rules'**
  String get syncSheetSkipRules;

  /// Button showing how many exclude rules the pair has.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No rules} =1{1 rule} other{{count} rules}}'**
  String syncSheetRuleCount(int count);

  /// Opens the exclude-rules editor.
  ///
  /// In en, this message translates to:
  /// **'Edit Rules…'**
  String get syncSheetEditRules;

  /// The time-tolerance row of the sync sheet.
  ///
  /// In en, this message translates to:
  /// **'{seconds, plural, =1{Modification date tolerance: 1 second} other{Modification date tolerance: {seconds} seconds}}'**
  String syncSheetTolerance(int seconds);

  /// Appended to the tolerance row when 1-hour shifts are accepted.
  ///
  /// In en, this message translates to:
  /// **'ignoring exact 1-hour differences'**
  String get syncSheetToleranceHourShift;

  /// Appended to the tolerance row for accepted shifts other than one hour (set in older builds or the advanced editor).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{plus 1 custom time shift} other{plus {count} custom time shifts}}'**
  String syncSheetToleranceOtherShifts(int count);

  /// The tolerance row while the comparison ignores dates.
  ///
  /// In en, this message translates to:
  /// **'Modification dates aren’t compared'**
  String get syncSheetToleranceUnused;

  /// Opens the time-tolerance dialog.
  ///
  /// In en, this message translates to:
  /// **'Time Offset…'**
  String get syncSheetTimeOffset;

  /// Lead-in above the plain-language plan sentence.
  ///
  /// In en, this message translates to:
  /// **'Here’s the plan:'**
  String get syncSheetPlanLead;

  /// Tooltip of the sheet’s ⋯ menu button.
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get syncSheetMore;

  /// ⋯ menu item that makes the pair copy missing files in both directions.
  ///
  /// In en, this message translates to:
  /// **'Sync Both Ways (Additive)'**
  String get syncSheetBothWays;

  /// ⋯ menu item opening the full pair editor.
  ///
  /// In en, this message translates to:
  /// **'Advanced…'**
  String get syncSheetAdvanced;

  /// Sheet button: scan and open the review without changing anything.
  ///
  /// In en, this message translates to:
  /// **'Simulate'**
  String get syncSheetSimulate;

  /// Sheet button (default): scan, then run when nothing is replaced, deleted, or in conflict.
  ///
  /// In en, this message translates to:
  /// **'Synchronize'**
  String get syncSheetSynchronize;

  /// Tooltip of the Simulate button.
  ///
  /// In en, this message translates to:
  /// **'Scan both sides and review the plan. Nothing changes until you run it.'**
  String get syncSheetSimulateTooltip;

  /// Tooltip of the Synchronize button.
  ///
  /// In en, this message translates to:
  /// **'Scan, then copy straight away when nothing would be replaced, deleted, or in conflict. Otherwise you review the plan first.'**
  String get syncSheetSynchronizeTooltip;

  /// Title of the name dialog that saves a sync pair to the sidebar.
  ///
  /// In en, this message translates to:
  /// **'Save as Favorite'**
  String get syncFavoriteNameTitle;

  /// Title of the exclude-rules editor.
  ///
  /// In en, this message translates to:
  /// **'Skip Rules'**
  String get syncRulesTitle;

  /// Help text of the exclude-rules field.
  ///
  /// In en, this message translates to:
  /// **'One pattern per line, gitignore style: *.log, build/, /private.txt, !keep.log'**
  String get syncRulesHint;

  /// Heading of the read-only list of built-in exclude patterns.
  ///
  /// In en, this message translates to:
  /// **'Always skipped'**
  String get syncRulesDefaultsTitle;

  /// Confirms the rules or time-offset dialog.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get syncRulesDone;

  /// Title of the time-tolerance dialog.
  ///
  /// In en, this message translates to:
  /// **'Time Offset'**
  String get syncTimeOffsetTitle;

  /// Field label: dates this close count as equal.
  ///
  /// In en, this message translates to:
  /// **'Tolerance in seconds'**
  String get syncTimeOffsetToleranceLabel;

  /// Help text under the tolerance field.
  ///
  /// In en, this message translates to:
  /// **'Modification dates this close together count as the same.'**
  String get syncTimeOffsetToleranceHelp;

  /// Checkbox in the time-offset dialog.
  ///
  /// In en, this message translates to:
  /// **'Ignore exact 1-hour differences'**
  String get syncTimeOffsetHourShift;

  /// Help text under the 1-hour checkbox.
  ///
  /// In en, this message translates to:
  /// **'For drives that store local time, such as FAT, across a daylight saving change.'**
  String get syncTimeOffsetHourShiftHelp;

  /// Banner on the review tab when Synchronize stopped before running. {reasons} is a comma-joined list of the fragments below.
  ///
  /// In en, this message translates to:
  /// **'This plan {reasons} — review before running.'**
  String syncHoldBanner(String reasons);

  /// Hold-banner fragment.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{deletes 1 file} other{deletes {count} files}}'**
  String syncHoldDeletes(int count);

  /// Hold-banner fragment.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{removes 1 empty folder} other{removes {count} empty folders}}'**
  String syncHoldEmptyFolders(int count);

  /// Hold-banner fragment.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{replaces 1 file} other{replaces {count} files}}'**
  String syncHoldReplaces(int count);

  /// Hold-banner fragment.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{has 1 conflict} other{has {count} conflicts}}'**
  String syncHoldConflicts(int count);

  /// Plan review section: new files and folders.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get syncSectionCopy;

  /// Plan review section: files that replace an existing copy.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get syncSectionUpdate;

  /// Plan review section: removals.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get syncSectionDelete;

  /// Plan review section: rows that need a decision.
  ///
  /// In en, this message translates to:
  /// **'Conflicts'**
  String get syncSectionConflicts;

  /// Plan review section: rows that will not change.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get syncSectionSkipped;

  /// Accessibility label of a plan review section header.
  ///
  /// In en, this message translates to:
  /// **'{section}, {count, plural, =1{1 item} other{{count} items}}'**
  String syncSectionSemantics(String section, int count);

  /// Plan review column header.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get syncColumnPath;

  /// Plan review column header.
  ///
  /// In en, this message translates to:
  /// **'Reason'**
  String get syncColumnReason;

  /// Accessibility label of a plan review row.
  ///
  /// In en, this message translates to:
  /// **'{path}: {action}, {reason}'**
  String syncRowSemantics(String path, String action, String reason);

  /// Row accessibility action.
  ///
  /// In en, this message translates to:
  /// **'copy to “{side}”'**
  String syncRowActionCopy(String side);

  /// Row accessibility action.
  ///
  /// In en, this message translates to:
  /// **'replace in “{side}”'**
  String syncRowActionUpdate(String side);

  /// Row accessibility action.
  ///
  /// In en, this message translates to:
  /// **'create folder in “{side}”'**
  String syncRowActionMakeDir(String side);

  /// Row accessibility action.
  ///
  /// In en, this message translates to:
  /// **'delete from “{side}”'**
  String syncRowActionDelete(String side);

  /// Row accessibility action.
  ///
  /// In en, this message translates to:
  /// **'conflict'**
  String get syncRowActionConflict;

  /// Row accessibility action.
  ///
  /// In en, this message translates to:
  /// **'skip'**
  String get syncRowActionSkip;

  /// Tooltip of a plan review row checkbox.
  ///
  /// In en, this message translates to:
  /// **'Space includes or skips this row'**
  String get syncRowToggleHint;

  /// Joins the quoted item names inside the delete headline (“a.txt”, “b.txt”): closes one quote, separates, opens the next. Use your locale's quotation marks, matching deleteDialogDeleteNames.
  ///
  /// In en, this message translates to:
  /// **'”, “'**
  String get deleteDialogNameSeparator;

  /// Listing column header: the item name column (click to sort).
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get paneColumnName;

  /// Listing column header: the size column (click to sort).
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get paneColumnSize;

  /// Listing column header: the modification date column (click to sort).
  ///
  /// In en, this message translates to:
  /// **'Date Modified'**
  String get paneColumnModified;

  /// Accessibility value of the column header the listing is sorted by, ascending.
  ///
  /// In en, this message translates to:
  /// **'Sorted ascending'**
  String get paneColumnSortedAscending;

  /// Accessibility value of the column header the listing is sorted by, descending.
  ///
  /// In en, this message translates to:
  /// **'Sorted descending'**
  String get paneColumnSortedDescending;

  /// Accessibility hint of a listing column header.
  ///
  /// In en, this message translates to:
  /// **'Sort by this column'**
  String get paneColumnSortHint;

  /// Location header's second line while rows are selected.
  ///
  /// In en, this message translates to:
  /// **'{selected} of {total} selected'**
  String paneSelectionSummary(int selected, int total);

  /// Location header's selection line with the selected files' total size, e.g. '3 of 329 selected · 42.1 MB'.
  ///
  /// In en, this message translates to:
  /// **'{summary} · {size}'**
  String paneSelectionSummaryWithSize(String summary, String size);

  /// Tooltip of the location header's menu button listing the enclosing folders.
  ///
  /// In en, this message translates to:
  /// **'Enclosing folders'**
  String get paneAncestorMenuTooltip;

  /// View menu toggle: show or hide dotfiles in the active tab.
  ///
  /// In en, this message translates to:
  /// **'Show Hidden Files'**
  String get viewToggleHiddenLabel;

  /// Copies the selected items' full paths (or the folder's) to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy Path'**
  String get selectionCopyPathLabel;

  /// Tab context menu: closes every other tab in this pane.
  ///
  /// In en, this message translates to:
  /// **'Close Other Tabs'**
  String get tabCloseOthersLabel;

  /// Tab context menu: opens a new tab at this tab's location.
  ///
  /// In en, this message translates to:
  /// **'Duplicate Tab'**
  String get tabDuplicateLabel;

  /// Tab context menu: moves the tab to the other pane's tab strip.
  ///
  /// In en, this message translates to:
  /// **'Move to Other Pane'**
  String get tabMoveToOtherPaneLabel;

  /// Tab context menu: copies the tab's folder path to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy Path'**
  String get tabCopyPathLabel;

  /// Helper under the prefilled Quick Connect field: what to type after the user name.
  ///
  /// In en, this message translates to:
  /// **'host[:port]'**
  String get quickConnectAddressHostHint;

  /// View menu submenu: sort the listing by Name, Size, or Date Modified.
  ///
  /// In en, this message translates to:
  /// **'Sort By'**
  String get viewSortByLabel;

  /// Sidebar section header over the local volumes (D32 §5). Rendered in caps.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get sidebarDevicesSection;

  /// Sidebar section header over the local-folder, workspace, and saved-sync bookmarks (D32 §5). Rendered in caps.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get sidebarFavoritesSection;

  /// Sidebar section header over saved servers, shared-account servers, and live Quick Connect sessions (D32 §5). Rendered in caps.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get sidebarServersSection;

  /// Tooltip of a collapsed sidebar section's chevron.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get sidebarShowSection;

  /// Tooltip of an expanded sidebar section's chevron.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get sidebarHideSection;

  /// Placeholder of the sidebar's filter field; it filters every section.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get sidebarFilterHint;

  /// Shown in the sidebar when the filter matches no row in any section.
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get sidebarNoMatches;

  /// Tooltip of the sidebar bottom bar's + menu.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get sidebarAddMenu;

  /// Tooltip of the sidebar bottom bar's gear (opens Settings).
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get sidebarSettings;

  /// Sidebar + menu: opens the server editor for a new shared-account server.
  ///
  /// In en, this message translates to:
  /// **'New Server…'**
  String get sidebarAddNewServer;

  /// Sidebar + menu: opens Connect (⌘K).
  ///
  /// In en, this message translates to:
  /// **'Quick Connect…'**
  String get sidebarAddQuickConnect;

  /// Sidebar + menu: saves the active pane's folder. Local folders land in Favorites, remote ones in Servers.
  ///
  /// In en, this message translates to:
  /// **'Add Current Folder to Favorites'**
  String get sidebarAddCurrentFolder;

  /// Tooltip of the Favorites section header's + button.
  ///
  /// In en, this message translates to:
  /// **'Add Current Folder'**
  String get sidebarFavoritesAdd;

  /// Tooltip of the Servers section header's + button when the server editor is available.
  ///
  /// In en, this message translates to:
  /// **'New Server'**
  String get sidebarServersAddNew;

  /// Tooltip of the Servers section header's + button when only Quick Connect is available.
  ///
  /// In en, this message translates to:
  /// **'Quick Connect'**
  String get sidebarServersAddConnect;

  /// Sidebar sync chip while this device is not enrolled in Sync; clicking opens the Sync settings.
  ///
  /// In en, this message translates to:
  /// **'Sync off'**
  String get sidebarSyncOff;

  /// Tooltip of the sidebar sync chip while Sync is off.
  ///
  /// In en, this message translates to:
  /// **'Set up Sync'**
  String get sidebarSyncOffTooltip;

  /// Sidebar sync chip after a failed round; clicking retries.
  ///
  /// In en, this message translates to:
  /// **'Sync failed'**
  String get sidebarSyncFailedChip;

  /// Sidebar sync chip while enrolled but before the first completed round.
  ///
  /// In en, this message translates to:
  /// **'Not synced yet'**
  String get sidebarSyncNever;

  /// Sidebar sync chip within a minute of the last completed round.
  ///
  /// In en, this message translates to:
  /// **'Synced · just now'**
  String get sidebarSyncedJustNow;

  /// Sidebar sync chip: minutes since the last completed round.
  ///
  /// In en, this message translates to:
  /// **'Synced · {minutes} min'**
  String sidebarSyncedMinutes(int minutes);

  /// Sidebar sync chip: hours since the last completed round.
  ///
  /// In en, this message translates to:
  /// **'Synced · {hours} h'**
  String sidebarSyncedHours(int hours);

  /// Sidebar sync chip: days since the last completed round.
  ///
  /// In en, this message translates to:
  /// **'Synced · {days} d'**
  String sidebarSyncedDays(int days);

  /// Trailing text of a server row shown in more than one tab: the number of tabs.
  ///
  /// In en, this message translates to:
  /// **'×{count}'**
  String sidebarTabCount(int count);

  /// Empty-Favorites offer: one click adds whichever of the three folders exist. Favorites sync, so they are never added silently.
  ///
  /// In en, this message translates to:
  /// **'Add Desktop, Documents, and Downloads'**
  String get sidebarFavoritesAddStandard;

  /// Empty-Favorites hint when none of the standard folders exist to offer.
  ///
  /// In en, this message translates to:
  /// **'Drag folders here to keep them close.'**
  String get sidebarFavoritesEmpty;

  /// Empty-Servers hint.
  ///
  /// In en, this message translates to:
  /// **'No servers yet. Connect to one, then save it here.'**
  String get sidebarServersEmpty;

  /// Placeholder row inside a group created with New Group… that has no members yet.
  ///
  /// In en, this message translates to:
  /// **'Drag favorites here'**
  String get sidebarGroupEmpty;

  /// Device row menu verb: saves the volume's folder as a favorite.
  ///
  /// In en, this message translates to:
  /// **'Add to Favorites'**
  String get sidebarAddToFavorites;

  /// Device row verb (menu and hover glyph) for removable volumes.
  ///
  /// In en, this message translates to:
  /// **'Eject'**
  String get sidebarEject;

  /// Menu verb on an unsaved Quick Connect session in the sidebar: saves it as a server.
  ///
  /// In en, this message translates to:
  /// **'Save to Servers…'**
  String get sidebarSaveToServers;

  /// Title of the name dialog that saves a Quick Connect session.
  ///
  /// In en, this message translates to:
  /// **'Save to Servers'**
  String get sidebarSaveToServersTitle;

  /// Announced after a live Quick Connect session's name in the sidebar (the row is shown in italics).
  ///
  /// In en, this message translates to:
  /// **'not saved'**
  String get sidebarUnsavedSession;

  /// Title of the rename dialog for a saved server row.
  ///
  /// In en, this message translates to:
  /// **'Rename Server'**
  String get sidebarRenameServerTitle;

  /// Title of the confirmation before removing a saved server row.
  ///
  /// In en, this message translates to:
  /// **'Remove Server'**
  String get sidebarDeleteServerTitle;

  /// Command label: shows and focuses the sidebar's filter field (view.filterSidebar, ⌥⌘F / Ctrl+Alt+F).
  ///
  /// In en, this message translates to:
  /// **'Filter Sidebar'**
  String get viewFilterSidebarLabel;

  /// Shown when the OS refuses to eject a volume.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t eject “{name}”. Close anything using it and try again.'**
  String sidebarEjectFailed(String name);

  /// Shown when Add Current Folder names a folder a favorite already holds.
  ///
  /// In en, this message translates to:
  /// **'“{label}” is already in Favorites.'**
  String sidebarAlreadyFavorite(String label);

  /// Body of the confirmation before removing a saved server row.
  ///
  /// In en, this message translates to:
  /// **'Remove “{label}” from Servers? This cannot be undone.'**
  String sidebarDeleteServerBody(String label);

  /// Announced after a device's name: its free space.
  ///
  /// In en, this message translates to:
  /// **'{size} available'**
  String sidebarFreeSpaceSemantics(String size);

  /// D32 §9: hint of the search bar at the top of the compact Home screen (the full-screen sidebar).
  ///
  /// In en, this message translates to:
  /// **'Search servers and folders'**
  String get compactHomeSearchHint;

  /// D32 §9: tooltip of the ⋮ overflow on the compact app bars; opens the command menus as a sheet.
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get compactMoreOptions;

  /// D32 §9: the pane switcher's short name for pane A (the left pane on wide windows).
  ///
  /// In en, this message translates to:
  /// **'A'**
  String get compactPaneLetterA;

  /// D32 §9: the pane switcher's short name for pane B (the right pane on wide windows).
  ///
  /// In en, this message translates to:
  /// **'B'**
  String get compactPaneLetterB;

  /// D32 §9: tooltip and announced action of the app bar's A · B pane switcher, e.g. 'Switch to Pane B'.
  ///
  /// In en, this message translates to:
  /// **'Switch to {pane}'**
  String compactPaneSwitchTooltip(String pane);

  /// D32 §9: announced state of the A · B pane switcher, e.g. 'Pane A is showing'.
  ///
  /// In en, this message translates to:
  /// **'{shown} is showing'**
  String compactPaneSwitcherSemantics(String shown);

  /// D32 §9: tooltip of the compact browser's search action, which filters the listing as you type.
  ///
  /// In en, this message translates to:
  /// **'Filter this folder'**
  String get compactFilterOpen;

  /// D32 §9: tooltip of the button that closes the compact browser's filter field and clears the filter.
  ///
  /// In en, this message translates to:
  /// **'Close filter'**
  String get compactFilterClose;

  /// D32 §9: second line of a compact listing row, e.g. '4.2 KB · Today 10:24'.
  ///
  /// In en, this message translates to:
  /// **'{size} · {date}'**
  String compactRowDetails(String size, String date);

  /// D32 §9: the size slot of a folder row's second line (a folder's listed size is not its contents).
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get compactRowFolder;

  /// D32 §9: the size slot of a symbolic link row's second line.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get compactRowLink;

  /// D32 §9: tooltip of a compact row's trailing ⋮, which opens the item's action sheet.
  ///
  /// In en, this message translates to:
  /// **'Actions for {name}'**
  String compactRowActions(String name);

  /// D32 §9: the contextual app bar's title while items are selected, e.g. '3 selected'. The selected files' size is appended through paneSelectionSummaryWithSize.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 selected} other{{count} selected}}'**
  String compactSelectionCount(int count);

  /// D32 §9: tooltip of the ✕ that leaves selection mode.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get compactSelectionClear;

  /// D32 §9: selection bar label of Copy to Other Pane, naming the other pane's letter, e.g. 'Copy to B'.
  ///
  /// In en, this message translates to:
  /// **'Copy to {pane}'**
  String compactActionCopyTo(String pane);

  /// D32 §9: selection bar label of Move to Other Pane, naming the other pane's letter, e.g. 'Move to B'.
  ///
  /// In en, this message translates to:
  /// **'Move to {pane}'**
  String compactActionMoveTo(String pane);

  /// D32 §9: selection bar label of the delete verb (Move to Trash locally, Delete on a server).
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get compactActionDelete;

  /// D32 §9: selection bar item that opens the remaining selection verbs as a sheet.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get compactActionMore;

  /// D32 §9: the floating progress pill shown while transfers run.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer} other{{count} transfers}}'**
  String compactTransfersPill(int count);

  /// D32 §9: the progress pill with the queue's overall progress, e.g. '2 transfers · 45%'.
  ///
  /// In en, this message translates to:
  /// **'{transfers} · {percent}%'**
  String compactTransfersPillProgress(String transfers, int percent);

  /// D32 §9: announced action of the progress pill; opens the inspector sheet on Transfers.
  ///
  /// In en, this message translates to:
  /// **'Show transfers'**
  String get compactTransfersPillTooltip;

  /// D32 §9: announced action of the inspector sheet's drag handle.
  ///
  /// In en, this message translates to:
  /// **'Close inspector'**
  String get compactSheetClose;

  /// D32 §9: dismisses the compact rename dialog without renaming.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get compactCancel;

  /// D32 §9: announced name of the compact browser's horizontally scrolling breadcrumb chips.
  ///
  /// In en, this message translates to:
  /// **'Folder path'**
  String get compactBreadcrumbsLabel;

  /// D32 §9: hint above Quick Connect when the shown pane has no tab open.
  ///
  /// In en, this message translates to:
  /// **'Connect to a server here, or go back to Home to pick a location.'**
  String get compactLauncherHint;

  /// D32 §9: title of the compact posture's path dialog (Go to Folder and Edit Path).
  ///
  /// In en, this message translates to:
  /// **'Go to folder'**
  String get compactGoToFolderTitle;

  /// D32 §9: the path dialog's confirm button; navigates to the typed path.
  ///
  /// In en, this message translates to:
  /// **'Go'**
  String get compactGo;

  /// D32 §9: confirms the compact Quick Select strip, keeping the matched selection.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get compactDone;

  /// DEVICES row on platforms that list no volumes (Android, iOS): opens the app's own files on this device.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get sidebarThisDevice;

  /// Screen-reader name of the in-app Quick Look overlay Space opens on Linux and Windows (D32, 06 §5.1).
  ///
  /// In en, this message translates to:
  /// **'Quick Look'**
  String get quickLookOverlayLabel;

  /// Tooltip of the Quick Look overlay's close button; Space and Esc close it too.
  ///
  /// In en, this message translates to:
  /// **'Close Quick Look'**
  String get quickLookClose;

  /// The Quick Look overlay's place in a multi-item selection, e.g. '2 of 5'.
  ///
  /// In en, this message translates to:
  /// **'{index} of {count}'**
  String quickLookPosition(int index, int count);

  /// Shown under the name in the Quick Look overlay for folders and file kinds it cannot render.
  ///
  /// In en, this message translates to:
  /// **'No preview for this kind of item.'**
  String get quickLookNoPreview;

  /// The pane's slim banner after a Quick Connect: the live session is not a saved server yet. The endpoint is user@host with any non-default port.
  ///
  /// In en, this message translates to:
  /// **'Not saved · {endpoint}'**
  String paneUnsavedSession(String endpoint);

  /// Tooltip of the Not saved banner's close button; hides the banner for this tab.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get paneUnsavedDismiss;

  /// Section label over the saved servers the Connect dialog (⌘K) offers as one-click rows above Quick Connect (D32 §4).
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get connectDialogServers;

  /// Tooltip of a sidebar row's visible ⋮ button, which opens the row's verbs (the shared sidebar kit's showMenuButton; Séance uses the same words).
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get sidebarRowMenu;

  /// D32 §9: second line of the compact Home's "This device" row. The local pane on a phone is the app's own storage, not the whole device.
  ///
  /// In en, this message translates to:
  /// **'App storage'**
  String get compactHomeThisDeviceSubtitle;

  /// D32 §9: second line of a DEVICES row on the compact Home, e.g. '23 GB free'.
  ///
  /// In en, this message translates to:
  /// **'{size} free'**
  String compactHomeFreeSpace(String size);

  /// D32 §9: a remote location on a compact Home row's second line: the server's name, then the folder, e.g. 'demo · /srv/www'.
  ///
  /// In en, this message translates to:
  /// **'{server} · {path}'**
  String compactHomeRemoteLocation(String server, String path);

  /// D32 §9: second line of a saved-sync favorite on the compact Home: its source and destination, e.g. '~/site → demo · /srv/www'.
  ///
  /// In en, this message translates to:
  /// **'{source} → {destination}'**
  String compactHomeSyncRoute(String source, String destination);

  /// D32 §9: second line of a server row on the compact Home while its state needs words: the state first, then user@host, e.g. 'Connecting… · deploy@example.com'.
  ///
  /// In en, this message translates to:
  /// **'{state} · {endpoint}'**
  String compactHomeServerState(String state, String endpoint);

  /// D32 §9: announced on a compact Home server row shown in several tabs (the row's visible ×N).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 tab open} other{{count} tabs open}}'**
  String compactHomeTabsOpen(int count);

  /// D32 §9: title of the compact Home's empty SERVERS state, above the Quick Connect and Import from ssh config buttons.
  ///
  /// In en, this message translates to:
  /// **'Connect to a server'**
  String get compactHomeServersEmptyTitle;

  /// D32 §9: body of the compact Home's empty SERVERS state.
  ///
  /// In en, this message translates to:
  /// **'Servers you save appear here, with their status.'**
  String get compactHomeServersEmptyBody;

  /// D32 §9: title of the compact Home's empty FAVORITES state.
  ///
  /// In en, this message translates to:
  /// **'Keep folders close'**
  String get compactHomeFavoritesEmptyTitle;

  /// D32 §9: body of the compact Home's empty FAVORITES state: how a folder becomes a favorite on a phone (the browser's ⋮ menu offers the verb).
  ///
  /// In en, this message translates to:
  /// **'Open a folder, then choose Add Current Folder to Favorites from its menu.'**
  String get compactHomeFavoritesEmptyBody;

  /// D32 §9: confirmation after the compact browser's ⋮ ▸ Add Current Folder to Favorites saved a local folder (Home, where the row appears, is a screen away).
  ///
  /// In en, this message translates to:
  /// **'Added “{label}” to Favorites.'**
  String compactAddedToFavorites(String label);

  /// D32 §9: confirmation after the compact browser's ⋮ ▸ Add Current Folder to Favorites saved a remote folder, which lands under Servers.
  ///
  /// In en, this message translates to:
  /// **'Saved “{label}” to Servers.'**
  String compactSavedToServers(String label);

  /// Command label: browse the tab's home, the user's home folder locally or the login folder on a server (go.home, ⇧⌘H, 02 §8.3, 10 §8's Go menu).
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get goHomeLabel;

  /// View menu command on Windows and Linux while the window is not full screen (10 §8). macOS shows AppKit's own item instead.
  ///
  /// In en, this message translates to:
  /// **'Enter Full Screen'**
  String get viewEnterFullScreenLabel;

  /// The same View menu command's label while the window is full screen (Windows and Linux, 10 §8).
  ///
  /// In en, this message translates to:
  /// **'Exit Full Screen'**
  String get viewExitFullScreenLabel;

  /// Disabled-command reason for Server ▸ Disconnect (connect.disconnect): the active tab shows no live server connection.
  ///
  /// In en, this message translates to:
  /// **'Requires a tab connected to a server'**
  String get commandDisabledNotConnected;

  /// Disabled-command reason for Server ▸ Save to Servers… (connect.saveToServers): the active tab is not browsing a Quick Connect session that is not saved yet.
  ///
  /// In en, this message translates to:
  /// **'Requires an unsaved Quick Connect session'**
  String get commandDisabledNoQuickConnect;

  /// Screen-reader announcement when ↑/↓ in the Connect dialog's (⌘K) address field highlight a saved server row: focus stays in the field, so this says which server Return now opens. {detail} is the row's user@host.
  ///
  /// In en, this message translates to:
  /// **'{server}, {detail}. Press Return to open it.'**
  String connectDialogHighlightAnnouncement(String server, String detail);

  /// Screen-reader announcement when ↑/↓ in the Connect dialog's address field move the highlight past the saved server rows, so Return submits the typed address again.
  ///
  /// In en, this message translates to:
  /// **'No server highlighted. Press Return to connect to the address.'**
  String get connectDialogHighlightCleared;
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
