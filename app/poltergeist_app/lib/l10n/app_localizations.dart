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

  /// Prompt shown before a pane has a location.
  ///
  /// In en, this message translates to:
  /// **'Choose a location'**
  String get emptyPanePrompt;

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
