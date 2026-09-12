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
  /// **'This folder is empty'**
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

  /// Banner shown while the remote transport reconnects (02 §2.7).
  ///
  /// In en, this message translates to:
  /// **'Connection to {label} lost — reconnecting…'**
  String paneConnectionLost(String label);

  /// The connection-lost banner's cancel action (stops reconnection).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get paneConnectionLostCancel;

  /// Relative modified date for today (02 §2.3).
  ///
  /// In en, this message translates to:
  /// **'Today at {time}'**
  String paneDateToday(String time);

  /// Relative modified date for yesterday (02 §2.3).
  ///
  /// In en, this message translates to:
  /// **'Yesterday at {time}'**
  String paneDateYesterday(String time);

  /// Screen-reader label of one listing row: announced name–size–date (D20).
  ///
  /// In en, this message translates to:
  /// **'{name}, {size}, {modified}'**
  String paneRowSemantics(String name, String size, String modified);

  /// Command label: navigate to the parent folder.
  ///
  /// In en, this message translates to:
  /// **'Parent Folder'**
  String get goEnclosingLabel;

  /// Command label: open the selected row.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get goOpenLabel;

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

  /// Tooltip of the Connections row action that opens the bookmark in the active pane.
  ///
  /// In en, this message translates to:
  /// **'Open in Pane'**
  String get connectionsOpenInPane;
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
