// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Poltergeist';

  @override
  String get paneAName => 'Pane A';

  @override
  String get paneBName => 'Pane B';

  @override
  String get emptyPanePrompt => 'Choose a location';

  @override
  String get resizePanes => 'Resize panes';

  @override
  String paneRatioPercent(int value) {
    return '$value%';
  }

  @override
  String get readyStatus => 'Ready';

  @override
  String get hostKeyUnknownTitle => 'Unknown host key';

  @override
  String get hostKeyChangedTitle => 'HOST KEY CHANGED';

  @override
  String hostKeyChangedWarning(String host) {
    return 'The key for $host does not match the one you previously trusted. This can mean a man-in-the-middle attack. Only continue if you know why the key changed.';
  }

  @override
  String hostKeyEndpoint(String host, int port) {
    return '$host:$port';
  }

  @override
  String get hostKeyFingerprintLabel => 'Fingerprint';

  @override
  String get hostKeyNewLabel => 'New key';

  @override
  String get hostKeyPreviousLabel => 'Previously trusted';

  @override
  String get hostKeyCancel => 'Cancel';

  @override
  String get hostKeyTrustConnect => 'Trust and connect';

  @override
  String get hostKeyTrustNewKey => 'Trust the new key';

  @override
  String get keyboardAuthTitle => 'Authentication';

  @override
  String get keyboardSubmit => 'Submit';

  @override
  String get keyboardCancel => 'Cancel';

  @override
  String get keyboardShowAnswer => 'Show answer';

  @override
  String get keyboardHideAnswer => 'Hide answer';

  @override
  String get credentialTitle => 'Authentication required';

  @override
  String credentialEndpoint(String username, String host, int port) {
    return '$username@$host:$port';
  }

  @override
  String get credentialPasswordField => 'Password';

  @override
  String get credentialKeyFileField => 'Key file';

  @override
  String get credentialKeyFileRequired => 'Choose a key file.';

  @override
  String get credentialPassphraseField => 'Passphrase';

  @override
  String get credentialSaveInVault => 'Save in vault';

  @override
  String get credentialConnect => 'Connect';

  @override
  String get credentialCancel => 'Cancel';

  @override
  String get credentialVaultUnavailable =>
      'Saved secrets are unavailable. Unlock or restore your system credential store, then retry — or enter the secret below.';

  @override
  String get credentialKeyFileUnreadable =>
      'The file could not be read as text.';

  @override
  String credentialKeyFileReadError(String error) {
    return 'Could not read the key file: $error';
  }

  @override
  String get connectionStateConnecting => 'Connecting…';

  @override
  String get connectionStateReconnecting => 'Reconnecting…';

  @override
  String get connectionFailedTitle => 'Connection failed';

  @override
  String get connectionBlockedTitle => 'Connection blocked';

  @override
  String get connectionDisconnectedTitle => 'Disconnected';

  @override
  String get connectionLogTitle => 'Connection log';

  @override
  String get connectionLogCopy => 'Copy';

  @override
  String get connectionLogEmpty => '(no log captured)';

  @override
  String get connectionRetry => 'Retry';

  @override
  String get vaultSaveFailed =>
      'Could not save the secret to the vault. The connection will continue.';

  @override
  String get sshImportTitle => 'Import servers from ssh config';

  @override
  String get sshImportLoading => 'Reading ssh config…';

  @override
  String sshImportLoadFailed(String path) {
    return 'Could not read $path.';
  }

  @override
  String get sshImportRetry => 'Try Again';

  @override
  String sshImportEmpty(String path) {
    return 'No importable hosts were found in $path.';
  }

  @override
  String get sshImportColumnImport => 'Import';

  @override
  String get sshImportColumnHost => 'Host';

  @override
  String get sshImportColumnEndpoint => 'Endpoint';

  @override
  String get sshImportColumnUser => 'User';

  @override
  String get sshImportColumnAuth => 'Auth';

  @override
  String get sshImportColumnNotes => 'Notes';

  @override
  String get sshImportAuthPassword => 'Password';

  @override
  String sshImportAuthKey(String path) {
    return 'Key: $path';
  }

  @override
  String sshImportDuplicateExisting(String label) {
    return 'Duplicate of bookmark “$label”';
  }

  @override
  String sshImportDuplicateEarlier(String alias) {
    return 'Duplicate of “$alias” in this import';
  }

  @override
  String get sshImportLimitProxyJump =>
      'Won’t behave as in ssh: ProxyJump — connects directly, not through the jump host';

  @override
  String get sshImportLimitProxyCommand =>
      'Won’t behave as in ssh: ProxyCommand — never executed';

  @override
  String get sshImportLimitMatch =>
      'Won’t behave as in ssh: Match blocks are ignored; settings may differ';

  @override
  String get sshImportLimitHostInclude =>
      'Won’t behave as in ssh: Include inside this host block is not applied';

  @override
  String get sshImportLimitInvalidPort => 'Cannot import: port outside 1–65535';

  @override
  String get sshImportUnresolvedIncludes => 'Unresolved includes';

  @override
  String sshImportNoteCycle(String path) {
    return '$path: include loop skipped';
  }

  @override
  String sshImportNoteDepth(String path) {
    return '$path: nested beyond the depth limit';
  }

  @override
  String sshImportNoteUnreadable(String path) {
    return '$path: could not be read';
  }

  @override
  String get sshImportCancel => 'Cancel';

  @override
  String get sshImportAction => 'Import';

  @override
  String sshImportActionCount(int count) {
    return 'Import $count';
  }

  @override
  String sshImportRowSemantics(String alias) {
    return 'Import $alias';
  }
}
